import 'media_info.dart';

/// A model of what WhatsApp does to an upload.
///
/// This is the app's single most important object and its least certain one.
/// Every number here is a guess until a calibration round trip replaces it,
/// which is why [calibrated] exists: the UI must never present modelled output
/// as fact while these are still assumptions.
///
/// The two edges matter separately. [passBitrateKbps] and the pass geometry
/// describe what WhatsApp will leave alone; the `forced` values describe what
/// it does to everything else. Crisp's entire strategy is to land a file in the
/// gap between them. If that gap turns out to be empty — if the pass limits and
/// the forced limits are the same numbers — then conforming buys nothing and
/// the honest move is to say so.
class WhatsAppModel {
  const WhatsAppModel({
    required this.id,
    required this.label,
    required this.adaptive,
    required this.passMaxShortEdge,
    required this.passMaxLongEdge,
    required this.passBitrateKbps,
    required this.forcedMaxShortEdge,
    required this.forcedMaxLongEdge,
    required this.forcedBitrateKbps,
    this.imagePassMaxLongEdge = 1600,
    this.imageForcedMaxLongEdge = 1600,
    this.imageForcedQuality = 8,
    this.maxClipDuration = const Duration(seconds: 90),
    this.maxFileSizeBytes = 16 * 1024 * 1024,
    this.calibrated = false,
  });

  final String id;
  final String label;

  /// When false, everything is re-encoded to the forced target no matter what
  /// arrives — the world in which Crisp cannot help.
  final bool adaptive;

  final int passMaxShortEdge;
  final int passMaxLongEdge;
  final int passBitrateKbps;

  final int forcedMaxShortEdge;
  final int forcedMaxLongEdge;
  final int forcedBitrateKbps;

  /// Photos get their own caps. The long-edge limit is the one that matters —
  /// exceed it and the image is resampled, which is where the mush comes from.
  final int imagePassMaxLongEdge;
  final int imageForcedMaxLongEdge;

  /// mjpeg quality scale (2 best, 31 worst) that the model assumes WhatsApp
  /// re-encodes at.
  final int imageForcedQuality;

  /// How long one Status clip may be. Raised from 30s to 90s by WhatsApp; a
  /// longer source has to be split into several.
  final Duration maxClipDuration;

  /// The hard ceiling on a Status upload, and the constraint that actually
  /// governs quality.
  ///
  /// Everything else is negotiable; this is not. A clip over the cap is
  /// re-encoded no matter how carefully it was conformed, which means a
  /// pipeline that targets a bitrate without looking at duration can hand
  /// WhatsApp a file that is guaranteed to be destroyed. Ninety seconds inside
  /// 16MB is about 1.4 Mbps for everything — so length and quality are the same
  /// dial, and the honest way to get HD is a shorter clip, not a cleverer
  /// encoder.
  final int maxFileSizeBytes;

  /// True only once these numbers came from a measured round trip rather than
  /// from an assumption.
  final bool calibrated;

  /// The optimistic theory: generous pass-through, harsh treatment outside it.
  static const adaptiveGuess = WhatsAppModel(
    id: 'adaptive_guess',
    label: 'Adaptive (assumed)',
    adaptive: true,
    passMaxShortEdge: 1080,
    passMaxLongEdge: 1920,
    passBitrateKbps: 2500,
    forcedMaxShortEdge: 720,
    forcedMaxLongEdge: 1280,
    forcedBitrateKbps: 1000,
  );

  /// The pessimistic theory: one transform, applied to everything.
  static const fixedGuess = WhatsAppModel(
    id: 'fixed_guess',
    label: 'Fixed (assumed)',
    adaptive: false,
    passMaxShortEdge: 0,
    passMaxLongEdge: 0,
    passBitrateKbps: 0,
    forcedMaxShortEdge: 720,
    forcedMaxLongEdge: 1280,
    forcedBitrateKbps: 1000,
  );

  static const List<WhatsAppModel> theories = [adaptiveGuess, fixedGuess];

  /// Whether a file of this shape would be waved through untouched.
  bool passesThrough(MediaInfo info) {
    if (!adaptive) return false;
    final withinGeometry = info.displayWidth <= passMaxShortEdge &&
        info.displayHeight <= passMaxLongEdge;
    final withinBitrate = info.effectiveVideoBitrate <= passBitrateKbps * 1000;
    return withinGeometry && withinBitrate;
  }

  /// Whether a photo of this size would be left alone.
  bool imagePassesThrough(MediaInfo info) {
    if (!adaptive) return false;
    final long = info.displayWidth > info.displayHeight
        ? info.displayWidth
        : info.displayHeight;
    return long <= imagePassMaxLongEdge;
  }

  /// The most video bitrate that fits the size cap for a clip of [duration].
  ///
  /// A margin is held back because container overhead, keyframes and rate
  /// control all overshoot slightly, and being 2% over the cap costs as much as
  /// being 50% over.
  int videoBitrateBudgetKbps(
    Duration duration, {
    int audioKbps = 128,
    double margin = 0.92,
  }) {
    final seconds = duration.inMilliseconds / 1000.0;
    if (seconds <= 0) return 0;
    final totalKbps = (maxFileSizeBytes * 8 / seconds / 1000) * margin;
    final videoKbps = totalKbps - audioKbps;
    return videoKbps < 0 ? 0 : videoKbps.round();
  }

  /// How many clips a source of [duration] has to become.
  int clipCountFor(Duration duration) {
    if (duration <= maxClipDuration) return 1;
    return (duration.inMilliseconds / maxClipDuration.inMilliseconds).ceil();
  }

  /// The headroom a conformed file should aim for, as a bitrate in kbps.
  ///
  /// Slightly under the pass ceiling rather than exactly at it: bitrate control
  /// is approximate, and overshooting the threshold by a few percent would flip
  /// the file into the forced path and lose everything.
  int get aimBitrateKbps => adaptive ? (passBitrateKbps * 0.92).round() : forcedBitrateKbps;
}
