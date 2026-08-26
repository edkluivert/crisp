import 'dart:io';

import '../ffmpeg_runner.dart';

/// Runs the real binaries. Desktop and CI only.
///
/// The app cannot use this — a phone has no ffmpeg on its PATH — which is the
/// entire reason [FfmpegRunner] exists. Anything that imports this file is
/// harness code by definition.
class ProcessRunner implements FfmpegRunner {
  const ProcessRunner({
    this.ffmpegPath = 'ffmpeg',
    this.ffprobePath = 'ffprobe',
  });

  final String ffmpegPath;
  final String ffprobePath;

  @override
  Future<RunResult> ffmpeg(List<String> args) => _run(ffmpegPath, args);

  @override
  Future<RunResult> ffprobe(List<String> args) => _run(ffprobePath, args);

  static Future<RunResult> _run(String executable, List<String> args) async {
    final result = await Process.run(executable, args);
    return RunResult(
      exitCode: result.exitCode,
      stdout: result.stdout as String? ?? '',
      stderr: result.stderr as String? ?? '',
    );
  }

  /// Fails loudly at startup rather than producing a confusing error from the
  /// first encode.
  static Future<void> assertAvailable({
    String ffmpegPath = 'ffmpeg',
    String ffprobePath = 'ffprobe',
  }) async {
    for (final exe in [ffmpegPath, ffprobePath]) {
      try {
        final r = await Process.run(exe, ['-version']);
        if (r.exitCode != 0) throw ProcessException(exe, ['-version']);
      } catch (_) {
        throw StateError(
          '$exe not found on PATH. Install it with `brew install ffmpeg`.',
        );
      }
    }
  }
}
