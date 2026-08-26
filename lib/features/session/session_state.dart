import 'package:equatable/equatable.dart';

import '../../engine/media_info.dart';

enum MediaKind { video, image }

sealed class SessionState extends Equatable {
  const SessionState();

  @override
  List<Object?> get props => [];
}

class SessionIdle extends SessionState {
  const SessionIdle();
}

/// Long jobs report which step they are on rather than a bare spinner. The
/// steps have genuinely different durations, and "Encoding" sitting still for
/// a while reads as progress in a way a spinner does not.
class SessionWorking extends SessionState {
  const SessionWorking({required this.step, this.detail});

  final String step;
  final String? detail;

  @override
  List<Object?> get props => [step, detail];
}

/// The file is conformed and ready to hand to WhatsApp. That is the whole
/// deliverable: the result on screen, one button out.
class SessionReady extends SessionState {
  const SessionReady({
    required this.kind,
    required this.outputPath,
    required this.outputInfo,
    required this.sourceInfo,
    this.notes = const [],
  });

  final MediaKind kind;

  /// The full-length conformed file — what actually gets shared.
  final String outputPath;
  final MediaInfo outputInfo;
  final MediaInfo sourceInfo;

  /// What the planner had to decide or work around for this particular file —
  /// an HDR source it could not convert, non-square pixels it normalised.
  /// These belong on screen: they are the difference between "the app is
  /// broken" and "your file is unusual and here is what happened to it".
  final List<String> notes;

  @override
  List<Object?> get props => [kind, outputPath, sourceInfo, notes];
}

class SessionFailed extends SessionState {
  const SessionFailed({required this.message, this.detail});

  final String message;
  final String? detail;

  @override
  List<Object?> get props => [message, detail];
}
