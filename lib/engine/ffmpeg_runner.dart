/// The result of one ffmpeg or ffprobe invocation.
class RunResult {
  const RunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// ffmpeg writes almost everything worth reading to stderr, including the
  /// metric summaries, so callers usually want both streams together.
  String get output => '$stdout\n$stderr';
}

/// The single seam between the pure pipeline and the platform running it.
///
/// Desktop implements this with `Process`; the app implements it with
/// FFmpegKit. Nothing above this line knows which one it is talking to.
abstract class FfmpegRunner {
  Future<RunResult> ffmpeg(List<String> args);
  Future<RunResult> ffprobe(List<String> args);
}
