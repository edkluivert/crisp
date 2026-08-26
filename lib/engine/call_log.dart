import 'ffmpeg_runner.dart';

/// One ffmpeg or ffprobe invocation and how it went.
class FfmpegCall {
  const FfmpegCall({
    required this.at,
    required this.tool,
    required this.args,
    required this.exitCode,
    required this.elapsed,
    this.errorTail,
  });

  final DateTime at;
  final String tool;
  final List<String> args;
  final int exitCode;
  final Duration elapsed;

  /// Only kept for failures. ffmpeg's output runs to hundreds of lines on a
  /// successful encode and none of it is worth storing.
  final String? errorTail;

  bool get ok => exitCode == 0;

  /// The command as typed, with directories stripped.
  ///
  /// Paths are reduced to their last segment: the filename is what makes an
  /// error reproducible, while the directory tree above it is the user's
  /// business and no help in diagnosing anything.
  String get commandLine =>
      '$tool ${args.map(_redact).join(' ')}';

  static String _redact(String arg) {
    if (!arg.contains('/')) return _quote(arg);
    final segments = arg.split('/');
    return _quote('…/${segments.last}');
  }

  static String _quote(String arg) =>
      arg.contains(' ') ? '"$arg"' : arg;
}

/// A bounded history of what the engine asked ffmpeg to do.
///
/// Exists because "conversion failed" on its own is unactionable. The command
/// that failed, and the last thing ffmpeg said before giving up, turn a bug
/// report into something that can be reproduced on a desktop in seconds.
class CallLog {
  CallLog({this.capacity = 40});

  final int capacity;
  final List<FfmpegCall> _calls = [];

  List<FfmpegCall> get calls => List.unmodifiable(_calls);
  Iterable<FfmpegCall> get failures => _calls.where((c) => !c.ok);

  void record(FfmpegCall call) {
    _calls.add(call);
    // Oldest first out. A long session should not grow without bound, and the
    // calls immediately around a failure are the ones that matter.
    while (_calls.length > capacity) {
      _calls.removeAt(0);
    }
  }

  void clear() => _calls.clear();
}

/// Wraps any [FfmpegRunner] and writes every call into a [CallLog].
///
/// A decorator rather than a change to the runners themselves: both the device
/// and desktop implementations get this for free, and the engine above the seam
/// stays unaware that anything is being recorded.
class RecordingRunner implements FfmpegRunner {
  RecordingRunner(this.inner, this.log);

  final FfmpegRunner inner;
  final CallLog log;

  @override
  Future<RunResult> ffmpeg(List<String> args) =>
      _record('ffmpeg', args, () => inner.ffmpeg(args));

  @override
  Future<RunResult> ffprobe(List<String> args) =>
      _record('ffprobe', args, () => inner.ffprobe(args));

  Future<RunResult> _record(
    String tool,
    List<String> args,
    Future<RunResult> Function() run,
  ) async {
    final started = DateTime.now();
    try {
      final result = await run();
      log.record(FfmpegCall(
        at: started,
        tool: tool,
        args: args,
        exitCode: result.exitCode,
        elapsed: DateTime.now().difference(started),
        errorTail: result.ok ? null : _tail(result.output),
      ));
      return result;
    } on Object catch (e) {
      // A throw is rarer than a non-zero exit but far more confusing, so it is
      // recorded in the same place rather than vanishing up the stack.
      log.record(FfmpegCall(
        at: started,
        tool: tool,
        args: args,
        exitCode: -1,
        elapsed: DateTime.now().difference(started),
        errorTail: 'threw: $e',
      ));
      rethrow;
    }
  }

  /// The interesting part of ffmpeg's output is the end. Progress lines are
  /// dropped because they are noise and there are thousands of them.
  static String _tail(String output, {int lines = 25}) {
    final kept = output
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty && !l.startsWith('frame=') && !l.startsWith('size='))
        .toList();
    if (kept.length <= lines) return kept.join('\n');
    return kept.sublist(kept.length - lines).join('\n');
  }
}
