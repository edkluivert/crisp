import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

import '../ffmpeg_runner.dart';

/// The on-device half of the [FfmpegRunner] seam.
///
/// Deliberately thin. Everything interesting already happened in the planner —
/// this only hands the same argument list to a bundled binary instead of a
/// system one, which is what keeps desktop calibration meaningful.
///
/// The `_min` LGPL variant is used on purpose. The default package is GPL,
/// which would make the whole app GPLv3 and unshippable on the App Store.
class FfmpegKitRunner implements FfmpegRunner {
  const FfmpegKitRunner();

  @override
  Future<RunResult> ffmpeg(List<String> args) async {
    final session = await FFmpegKit.executeWithArguments(args);
    final code = await session.getReturnCode();
    // FFmpegKit merges the streams; almost everything ffmpeg emits — including
    // the metric summaries — would have been stderr on a desktop.
    final logs = await session.getAllLogsAsString() ?? '';
    return RunResult(
      exitCode: code?.getValue() ?? -1,
      stdout: '',
      stderr: logs,
    );
  }

  @override
  Future<RunResult> ffprobe(List<String> args) async {
    final session = await FFprobeKit.executeWithArguments(args);
    final code = await session.getReturnCode();
    final output = await session.getOutput() ?? '';
    // Probe output is the payload, not a log, so it belongs on stdout where
    // the parser expects to find it.
    return RunResult(
      exitCode: ReturnCode.isSuccess(code) ? 0 : (code?.getValue() ?? -1),
      stdout: output,
      stderr: '',
    );
  }
}
