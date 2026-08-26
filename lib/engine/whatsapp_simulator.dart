import 'dart:io';
import 'dart:math' as math;

import 'conform_plan.dart';
import 'ffmpeg_runner.dart';
import 'image_spec.dart';
import 'media_info.dart';
import 'pipeline.dart';
import 'whatsapp_model.dart';

/// Produces the file WhatsApp would hand back.
///
/// Used for two very different jobs, and the distinction matters:
///
///   * in the harness, to rehearse a theory before spending real Status posts;
///   * in the app, to show the user the damage they are avoiding.
///
/// The second use is only honest while the model is labelled as a model. A
/// forecast drawn from [WhatsAppModel.calibrated] == false is an educated
/// guess, and the UI is responsible for saying so.
class WhatsAppSimulator {
  const WhatsAppSimulator({
    required this.pipeline,
    required this.model,
    required this.encoder,
    this.audioEncoder,
  });

  final CrispPipeline pipeline;
  final WhatsAppModel model;
  final VideoEncoder encoder;

  /// Null when the build cannot encode AAC. The forecast then copies or drops
  /// audio, exactly as the real conform does — the two paths have to agree or
  /// the comparison is between two different things.
  final String? audioEncoder;

  Future<MediaInfo> simulate({
    required String inputPath,
    required String outputPath,
    MediaInfo? inputInfo,
  }) async {
    final info = inputInfo ?? await pipeline.probe(inputPath);

    if (model.passesThrough(info)) {
      await File(inputPath).copy(outputPath);
      return info;
    }

    final fitted = _fit(
      width: info.displayWidth,
      height: info.displayHeight,
      maxShort: model.forcedMaxShortEdge,
      maxLong: model.forcedMaxLongEdge,
    );

    final result = await pipeline.runner.ffmpeg([
      '-y', '-hide_banner',
      '-i', inputPath,
      // Bicubic rather than lanczos on purpose: this is meant to imitate a
      // fast, indifferent pipeline, not a careful one.
      '-vf', 'scale=width=${fitted.$1}:height=${fitted.$2}:flags=bicubic,'
          'format=pix_fmts=yuv420p',
      '-c:v', encoder.name,
      '-b:v', '${model.forcedBitrateKbps}k',
      '-maxrate', '${(model.forcedBitrateKbps * 1.1).round()}k',
      '-bufsize', '${(model.forcedBitrateKbps * 1.2).round()}k',
      ..._audioArgs(info, 96),
      '-movflags', '+faststart',
      outputPath,
    ]);

    if (!result.ok) {
      throw StateError('simulation failed: ${result.stderr.split('\n').last}');
    }
    return pipeline.probe(outputPath);
  }

  /// The photo equivalent: resample to the cap and re-encode at the quality
  /// the model assumes.
  Future<MediaInfo> simulateImage({
    required String inputPath,
    required String outputPath,
    MediaInfo? inputInfo,
  }) async {
    final info = inputInfo ?? await pipeline.probe(inputPath);

    if (model.imagePassesThrough(info)) {
      await File(inputPath).copy(outputPath);
      return info;
    }

    final (w, h) = ImageCommand.fit(
      width: info.displayWidth,
      height: info.displayHeight,
      maxLongEdge: model.imageForcedMaxLongEdge,
    );

    final result = await pipeline.runner.ffmpeg([
      '-y', '-hide_banner',
      '-i', inputPath,
      '-vf', 'scale=width=$w:height=$h:flags=bicubic,format=pix_fmts=yuvj420p',
      '-q:v', '${model.imageForcedQuality}',
      '-map_metadata', '-1',
      outputPath,
    ]);
    if (!result.ok) {
      throw StateError('image simulation failed: ${result.stderr.split('\n').last}');
    }
    return pipeline.probe(outputPath);
  }

  /// Lifts a short representative section out of a clip.
  ///
  /// The comparison needs three encodes to mean anything, and doing that to a
  /// two-minute video takes long enough that nobody waits.
  ///
  /// Stream copy is tried first because it is instant and lossless, which keeps
  /// the reference honest. It is also unreliable in ways that only show up on
  /// real footage: seeking lands on the nearest keyframe, and for long-GOP or
  /// oddly-muxed files the result can be empty, truncated, or unplayable while
  /// still exiting zero. So the output is verified rather than trusted, and a
  /// re-encode picks up the pieces when it is not usable.
  /// Returns true when stream copy was not usable and a re-encode was needed.
  /// Worth surfacing: it is the difference between an instant, lossless
  /// reference and a slower, slightly lossy one.
  static Future<bool> extractSlice({
    required FfmpegRunner runner,
    required String inputPath,
    required String outputPath,
    required Duration sourceDuration,
    required CrispPipeline pipeline,
    required VideoEncoder encoder,
    Duration length = const Duration(seconds: 4),
  }) async {
    // The middle is a better bet than the opening, which is often a hand
    // reaching for the phone rather than the subject.
    final startMs = math.max(
      0,
      ((sourceDuration.inMilliseconds - length.inMilliseconds) / 2).round(),
    );
    final startArg = (startMs / 1000).toStringAsFixed(3);
    final lengthArg = (length.inMilliseconds / 1000).toStringAsFixed(3);

    final copied = await runner.ffmpeg([
      '-y', '-hide_banner',
      '-ss', startArg,
      '-i', inputPath,
      '-t', lengthArg,
      '-c', 'copy',
      '-avoid_negative_ts', 'make_zero',
      outputPath,
    ]);

    // Length is checked, not just validity. Stream copy cannot cut mid-GOP, so
    // on long-keyframe footage it runs on to the end of the enclosing group —
    // a 4-second request can come back as 8. That is still a valid file, but it
    // doubles the three encodes that follow, which is the opposite of why the
    // slice exists. Past a tolerance it is cheaper to re-encode exactly.
    if (copied.ok &&
        await _isUsable(pipeline, outputPath, expected: length)) {
      return false;
    }

    // Re-encode fallback. Near-lossless so the slice is still a fair reference
    // for the comparison, just slower to produce.
    final reencoded = await runner.ffmpeg([
      '-y', '-hide_banner',
      '-ss', startArg,
      '-i', inputPath,
      '-t', lengthArg,
      '-c:v', encoder.name,
      '-b:v', '20000k',
      '-pix_fmt', 'yuv420p',
      // Audio is copied rather than re-encoded: the slice is a reference, and
      // an encoder that may not exist is not worth risking for it.
      '-c:a', 'copy',
      '-movflags', '+faststart',
      outputPath,
    ]);

    if (!reencoded.ok || !await _isUsable(pipeline, outputPath)) {
      throw StateError(
        'Could not read a usable sample from this video. '
        '${_tail(reencoded.stderr)}',
      );
    }
    return true;
  }

  /// A file that exists is not a file that plays. Both checks matter: ffmpeg
  /// exits zero on some truncated outputs, and a zero-duration slice would
  /// produce three black previews and no error.
  static Future<bool> _isUsable(
    CrispPipeline pipeline,
    String path, {
    Duration? expected,
  }) async {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() < 1024) return false;
    try {
      final info = await pipeline.probe(path);
      if (info.duration.inMilliseconds <= 200 ||
          info.displayWidth <= 0 ||
          info.displayHeight <= 0) {
        return false;
      }
      if (expected != null) {
        final limit = (expected.inMilliseconds * 1.4).round();
        if (info.duration.inMilliseconds > limit) return false;
      }
      return true;
    } on Object {
      return false;
    }
  }

  static String _tail(String stderr) {
    final lines = stderr
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return lines.isEmpty ? '' : lines.last;
  }

  List<String> _audioArgs(MediaInfo info, int kbps) {
    if (!info.hasAudio) return const ['-an'];
    if (audioEncoder != null) {
      return ['-c:a', audioEncoder!, '-b:a', '${kbps}k'];
    }
    if ((info.audioCodec ?? '').contains('aac')) return const ['-c:a', 'copy'];
    return const ['-an'];
  }

  static (int, int) _fit({
    required int width,
    required int height,
    required int maxShort,
    required int maxLong,
  }) {
    final long = math.max(width, height);
    final short = math.min(width, height);
    final ratio = math.min(maxLong / long, math.min(maxShort / short, 1.0));
    int even(int v) => v.isEven ? math.max(2, v) : math.max(2, v - 1);
    return (even((width * ratio).round()), even((height * ratio).round()));
  }
}
