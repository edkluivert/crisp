import 'dart:io';

import '../engine/call_log.dart';
import '../engine/capabilities.dart';
import '../engine/media_info.dart';

/// Builds the text a user sends when something breaks.
///
/// The aim is that one paste is enough to reproduce a failure without a
/// conversation: what the file was, what the device could do, which command
/// died, and what ffmpeg said on the way out. Anything less and the first reply
/// is always the same three questions.
class Diagnostics {
  Diagnostics(this.log);

  final CallLog log;

  MediaInfo? _source;
  FfmpegCapabilities? _capabilities;
  String? _failureMessage;
  String? _failureDetail;
  DateTime? _failedAt;

  /// Context is captured as the session progresses rather than at the moment of
  /// failure, because by then the interesting values are usually out of scope.
  void noteSource(MediaInfo source) => _source = source;

  void noteCapabilities(FfmpegCapabilities capabilities) =>
      _capabilities = capabilities;

  void noteFailure(String message, String? detail) {
    _failureMessage = message;
    _failureDetail = detail;
    _failedAt = DateTime.now();
  }

  void clearFailure() {
    _failureMessage = null;
    _failureDetail = null;
    _failedAt = null;
  }

  bool get hasFailure => _failureMessage != null;

  /// The whole report, as plain text.
  String render() {
    final b = StringBuffer()
      ..writeln('CRISP DIAGNOSTIC REPORT')
      ..writeln('=' * 60)
      ..writeln('Generated: ${DateTime.now().toIso8601String()}')
      ..writeln('Platform:  ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}')
      ..writeln('Dart:      ${Platform.version.split(' ').first}')
      ..writeln();

    b
      ..writeln('BUILD CAPABILITIES')
      ..writeln('-' * 60);
    final caps = _capabilities;
    if (caps == null) {
      b.writeln('not probed');
    } else {
      b
        ..writeln('video encoder: ${caps.encoder?.name ?? 'NONE FOUND'}')
        ..writeln('audio encoder: ${caps.audioEncoder ?? 'NONE FOUND'}')
        ..writeln('tone mapping:  ${caps.canToneMap ? 'yes' : 'no'}')
        ..writeln('h264 present:  ${caps.h264Encoders.join(', ')}')
        ..writeln('aac present:   ${caps.audioEncoders.join(', ')}');
    }
    b.writeln();

    b
      ..writeln('SOURCE FILE')
      ..writeln('-' * 60)
      ..writeln(_source?.diagnostic ?? 'not probed')
      ..writeln();

    if (_failureMessage != null) {
      b
        ..writeln('FAILURE')
        ..writeln('-' * 60)
        ..writeln('when:  ${_failedAt?.toIso8601String()}')
        ..writeln('what:  $_failureMessage')
        ..writeln('detail:')
        ..writeln(_failureDetail ?? '(none)')
        ..writeln();
    }

    final failed = log.failures.toList();
    if (failed.isNotEmpty) {
      b
        ..writeln('FAILED COMMANDS (${failed.length})')
        ..writeln('-' * 60);
      for (final call in failed) {
        b
          ..writeln('exit ${call.exitCode} after ${call.elapsed.inMilliseconds}ms')
          ..writeln('  ${call.commandLine}')
          ..writeln('  ffmpeg said:');
        for (final line in (call.errorTail ?? '').split('\n')) {
          b.writeln('    $line');
        }
        b.writeln();
      }
    }

    b
      ..writeln('ALL CALLS (${log.calls.length}, newest last)')
      ..writeln('-' * 60);
    for (final call in log.calls) {
      b.writeln('${call.ok ? 'ok  ' : 'FAIL'} '
          '${call.elapsed.inMilliseconds.toString().padLeft(6)}ms  '
          '${call.commandLine}');
    }

    return b.toString();
  }

  /// Written next to the app's other data so it survives the process dying,
  /// which is exactly when a log is most wanted and least available.
  Future<File> writeToFile(Directory directory) async {
    final file = File('${directory.path}/crisp-diagnostics.txt');
    await file.writeAsString(render());
    return file;
  }
}
