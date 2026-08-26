import 'package:flutter_bloc/flutter_bloc.dart';

import '../../engine/call_log.dart';
import '../../engine/capabilities.dart';
import '../../engine/image_spec.dart';
import '../../engine/io/ffmpeg_kit_runner.dart';
import '../../engine/media_info.dart';
import '../../engine/pipeline.dart';
import '../../engine/presets.dart';
import '../../engine/target_spec.dart';
import '../../engine/whatsapp_model.dart';
import '../../services/diagnostics.dart';
import '../../services/workspace.dart';
import 'session_state.dart';

/// Drives one file from picked to shareable: probe, conform, done.
///
/// This used to build a three-way damage forecast before encoding anything.
/// That machinery answered a research question the calibration harness answers
/// better, and it made every session slow — so the app now does the one thing
/// the user came for and gets out of the way.
class SessionCubit extends Cubit<SessionState> {
  SessionCubit({
    CrispPipeline? pipeline,
    CallLog? callLog,
    this.model = WhatsAppModel.adaptiveGuess,
    this.videoPreset = CrispPresets.mezzanine,
    this.imagePreset = CrispImagePresets.conformed,
  })  : callLog = callLog ?? CallLog(),
        super(const SessionIdle()) {
    // Every call goes through the recorder, so a failure report describes what
    // actually ran rather than what the code intended to run.
    this.pipeline = pipeline ??
        CrispPipeline(RecordingRunner(const FfmpegKitRunner(), this.callLog));
    diagnostics = Diagnostics(this.callLog);
  }

  late final CrispPipeline pipeline;
  late final Diagnostics diagnostics;
  final CallLog callLog;
  final WhatsAppModel model;

  /// The preset the app actually ships with. Which one belongs here is an open
  /// question until a calibration round trip answers it — see the README. The
  /// binding is deliberately this shallow so swapping the winner is one line.
  final Preset videoPreset;
  final ImagePreset imagePreset;

  Workspace? _workspace;
  FfmpegCapabilities? _capabilities;

  static const _videoExtensions = {'mp4', 'mov', 'm4v', '3gp', 'mkv', 'webm', 'avi'};
  static const _imageExtensions = {'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp'};

  /// Resolved once and cached. Which encoders and filters the bundled build
  /// exposes is undocumented and varies by platform, so it is detected rather
  /// than assumed.
  Future<FfmpegCapabilities> _resolveCapabilities() async {
    final cached = _capabilities;
    if (cached != null) return cached;

    final detected = await FfmpegCapabilities.detect(pipeline.runner);
    if (!detected.usable) {
      throw StateError(
        'This build ships no usable H.264 encoder. '
        '${detected.h264Encoders.isEmpty ? 'None found at all.' : 'Found: ${detected.h264Encoders.join('; ')}'}',
      );
    }
    return _capabilities = detected;
  }

  Future<void> process(String sourcePath) async {
    await _workspace?.dispose();
    final workspace = _workspace = await Workspace.create();

    MediaInfo? probed;
    try {
      emit(const SessionWorking(step: 'Reading the file'));
      final source = probed = await pipeline.probe(sourcePath);
      diagnostics
        ..clearFailure()
        ..noteSource(source);
      final kind = _kindOf(sourcePath, source);

      emit(const SessionWorking(step: 'Checking what this device can encode'));
      final capabilities = await _resolveCapabilities();
      diagnostics.noteCapabilities(capabilities);

      if (kind == MediaKind.image) {
        emit(const SessionWorking(step: 'Preparing your photo'));
        final out = workspace.path('crisp_share.jpg');
        final result = await pipeline.runner.ffmpeg(ImageCommand.conform(
          source: source,
          preset: imagePreset,
          inputPath: sourcePath,
          outputPath: out,
        ));
        if (!result.ok) {
          throw StateError(
              'photo encode failed: ${_lastLines(result.stderr)}');
        }
        emit(SessionReady(
          kind: MediaKind.image,
          outputPath: out,
          outputInfo: await pipeline.probe(out),
          sourceInfo: source,
        ));
        return;
      }

      // A source already inside the envelope gains nothing from an encode —
      // WhatsApp re-encodes whatever we hand it, so our generation of loss
      // would be pure damage. Pass it through untouched.
      final srcLong = source.displayWidth > source.displayHeight
          ? source.displayWidth
          : source.displayHeight;
      final srcShort = source.displayWidth > source.displayHeight
          ? source.displayHeight
          : source.displayWidth;
      final srcKbps = (source.effectiveVideoBitrate / 1000).round();
      final alreadyIdeal = !source.isHdr &&
          !source.isTenBit &&
          srcLong <= 1920 &&
          srcShort <= 1080 &&
          srcKbps > 0 &&
          srcKbps <= 12000;
      if (alreadyIdeal) {
        emit(SessionReady(
          kind: MediaKind.video,
          outputPath: sourcePath,
          outputInfo: source,
          sourceInfo: source,
          notes: const ['already ideal — passed through untouched'],
        ));
        return;
      }

      emit(const SessionWorking(
        step: 'Preparing your video',
        detail: 'Usually faster than watching it once',
      ));
      final out = workspace.path('crisp_share.mp4');
      final outcome = await pipeline.conform(
        inputPath: sourcePath,
        outputPath: out,
        preset: videoPreset,
        encoder: capabilities.encoder!,
        sourceInfo: source,
        canToneMap: capabilities.canToneMap,
        canDenoise: capabilities.canDenoise,
        canSharpen: capabilities.canSharpen,
        audioEncoder: capabilities.audioEncoder,
        clipDuration: source.duration,
      );
      if (!outcome.ok) throw StateError(outcome.error!);

      emit(SessionReady(
        kind: MediaKind.video,
        outputPath: out,
        outputInfo: outcome.output!,
        sourceInfo: source,
        notes: outcome.plan?.notes ?? const [],
      ));
    } on Object catch (e) {
      // The file's own characteristics are the most useful thing in a failure
      // report: almost every failure here is caused by something unusual about
      // the source — HDR, 10-bit, an odd rotation — and the error alone does
      // not say which.
      final detail = probed == null
          ? e.toString()
          : '${e.toString()}\n\nFile: ${probed.diagnostic}';
      diagnostics.noteFailure('Could not process this file', detail);
      emit(SessionFailed(
        message: 'Could not process this file',
        detail: detail,
      ));
    }
  }

  MediaKind _kindOf(String path, MediaInfo info) {
    final ext = path.split('.').last.toLowerCase();
    if (_imageExtensions.contains(ext)) return MediaKind.image;
    if (_videoExtensions.contains(ext)) return MediaKind.video;
    // Extension is a claim, not evidence. A still has no duration.
    return info.duration.inMilliseconds > 0 ? MediaKind.video : MediaKind.image;
  }

  /// ffmpeg buries the useful line at the bottom of a wall of banner noise.
  static String _lastLines(String log, [int count = 2]) {
    final lines = log.split('\n').where((l) => l.trim().isNotEmpty).toList();
    return lines
        .skip(lines.length <= count ? 0 : lines.length - count)
        .join(' · ');
  }

  void reset() {
    _workspace?.dispose();
    _workspace = null;
    emit(const SessionIdle());
  }

  @override
  Future<void> close() async {
    await _workspace?.dispose();
    return super.close();
  }
}
