import 'dart:io';

import 'conform_plan.dart';
import 'ffmpeg_command.dart';
import 'ffmpeg_runner.dart';
import 'media_info.dart';
import 'metrics.dart';
import 'target_spec.dart';

/// What one preset did to one file.
class ConformOutcome {
  const ConformOutcome({
    required this.preset,
    required this.outputPath,
    required this.elapsed,
    this.plan,
    this.output,
    this.error,
  });

  final Preset preset;
  final String outputPath;
  final Duration elapsed;
  final ConformPlan? plan;
  final MediaInfo? output;
  final String? error;

  bool get ok => error == null;
}

/// Probe, conform, measure. The whole engine, minus the platform.
class CrispPipeline {
  const CrispPipeline(this.runner);

  final FfmpegRunner runner;

  Future<MediaInfo> probe(String path) async {
    final result = await runner.ffprobe(FfmpegCommand.probe(path));
    if (!result.ok) {
      throw StateError('ffprobe failed on $path: ${result.stderr.trim()}');
    }
    return MediaInfo.parseFfprobeJson(result.stdout);
  }

  /// Produces the file we would hand to WhatsApp.
  Future<ConformOutcome> conform({
    required String inputPath,
    required String outputPath,
    required Preset preset,
    required VideoEncoder encoder,
    MediaInfo? sourceInfo,
    bool canToneMap = false,
    bool canDenoise = true,
    bool canSharpen = true,
    String? audioEncoder,
    int? budgetKbps,
    Duration? clipDuration,
  }) async {
    final started = DateTime.now();
    final source = sourceInfo ?? await probe(inputPath);

    // The control is a byte copy rather than a remux. A remux would already be
    // a change, and then the baseline would not be "what happens today".
    if (preset.passthrough) {
      await File(inputPath).copy(outputPath);
      return ConformOutcome(
        preset: preset,
        outputPath: outputPath,
        elapsed: DateTime.now().difference(started),
        output: source,
      );
    }

    final plan = ConformPlan.build(
      source: source,
      preset: preset,
      encoder: encoder,
      canToneMap: canToneMap,
      canDenoise: canDenoise,
      canSharpen: canSharpen,
      audioEncoder: audioEncoder,
      budgetKbps: budgetKbps,
      clipDuration: clipDuration,
    );
    var attempt = plan;
    var result = await runner.ffmpeg(FfmpegCommand.conform(
      plan: attempt,
      inputPath: inputPath,
      outputPath: outputPath,
    ));

    // Audio is the most common reason a whole conform dies, and it is never
    // worth losing the video over. A build with no AAC encoder, a codec whose
    // decoder was left out, a stream the encoder refuses — all of it fails the
    // same way and all of it is survivable by asking for less. The picture is
    // the product; the soundtrack is not worth the file.
    for (final fallback in [AudioHandling.copy, AudioHandling.drop]) {
      if (result.ok || !_looksLikeAudioFailure(result.stderr)) break;
      if (attempt.audioHandling == fallback) continue;
      attempt = attempt.withAudio(fallback);
      result = await runner.ffmpeg(FfmpegCommand.conform(
        plan: attempt,
        inputPath: inputPath,
        outputPath: outputPath,
      ));
      if (result.ok) {
        attempt.notes.add(fallback == AudioHandling.copy
            ? 'audio could not be re-encoded — copied from the source instead'
            : 'audio could not be encoded or copied — the clip is silent');
      }
    }

    if (!result.ok) {
      return ConformOutcome(
        preset: preset,
        outputPath: outputPath,
        elapsed: DateTime.now().difference(started),
        plan: attempt,
        error: _lastMeaningfulLine(result.stderr),
      );
    }
    final plan_ = attempt;

    return ConformOutcome(
      preset: preset,
      outputPath: outputPath,
      elapsed: DateTime.now().difference(started),
      plan: plan_,
      output: await probe(outputPath),
    );
  }

  /// Whether a failure points at the audio stream rather than the video one.
  ///
  /// Matching on ffmpeg's prose is unlovely, but the exit code says nothing
  /// about which stream gave up. The naive version of this — searching the
  /// whole output for "aac" — matched every file that merely *has* AAC audio,
  /// because ffmpeg prints the input's stream listing before it does anything.
  /// A filter-chain error then burned two pointless retries before failing
  /// anyway. So a line must look like a complaint *and* be about the audio.
  static bool _looksLikeAudioFailure(String stderr) {
    const complaints = [
      'error', 'could not', 'unknown encoder', 'invalid', 'failed', 'no such'
    ];
    const audioish = ['aac', 'audio', '#0:1', 'opus'];

    for (final raw in stderr.split('\n')) {
      final line = raw.toLowerCase();
      // The input's own stream listing names the audio codec. That is
      // information, not a complaint.
      if (line.contains('stream #') && line.contains('audio:')) continue;
      if (!complaints.any(line.contains)) continue;
      if (audioish.any(line.contains)) return true;
    }
    return false;
  }

  /// Scores [distortedPath] against [referencePath].
  ///
  /// Geometry is taken from the reference, so a file that came back at a lower
  /// resolution is upscaled before comparison — which is the honest way to
  /// score it, since that is exactly what the viewer's screen does.
  Future<QualityScore?> score({
    required String referencePath,
    required String distortedPath,
    MediaInfo? referenceInfo,
  }) async {
    final ref = referenceInfo ?? await probe(referencePath);

    Future<String> run(String metric) async {
      final r = await runner.ffmpeg(FfmpegCommand.compare(
        referencePath: referencePath,
        distortedPath: distortedPath,
        width: ref.displayWidth,
        height: ref.displayHeight,
        fps: ref.fps,
        metric: metric,
      ));
      return r.output;
    }

    final ssim = MetricParser.ssim(await run('ssim'));
    final psnr = MetricParser.psnr(await run('psnr'));
    if (ssim == null || psnr == null) return null;
    return QualityScore(ssim: ssim, psnrDb: psnr);
  }

  /// ffmpeg's fatal error is usually several lines above the end of stderr,
  /// buried under progress output.
  static String _lastMeaningfulLine(String stderr) {
    final lines = stderr
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('frame='))
        .toList();
    if (lines.isEmpty) return 'ffmpeg failed with no output';
    return lines.length <= 3 ? lines.join(' | ') : lines.sublist(lines.length - 3).join(' | ');
  }
}
