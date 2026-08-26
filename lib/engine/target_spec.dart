/// How the encoder is asked to hit its number.
enum RateMode {
  /// A fixed target with a ceiling. This is the mode that matters for Crisp:
  /// the whole strategy is to land just under WhatsApp's own bitrate ceiling,
  /// and quality-targeted encoding cannot promise where it will land.
  constrainedBitrate,

  /// Quality-targeted (CRF). Useful for producing a reference master, and for
  /// measuring how much headroom a source actually has.
  quality,
}

class AudioSpec {
  const AudioSpec({
    this.codec = 'aac',
    this.bitrateKbps = 128,
    this.sampleRate = 44100,
    this.channels = 2,
  });

  final String codec;
  final int bitrateKbps;
  final int sampleRate;
  final int channels;
}

/// The shape we want the file to be in when WhatsApp receives it.
///
/// Expressed as long/short edge rather than width/height so one spec covers
/// portrait, landscape and square without the caller branching on orientation.
class TargetSpec {
  const TargetSpec({
    required this.maxLongEdge,
    required this.maxShortEdge,
    required this.videoBitrateKbps,
    this.maxFps = 30,
    this.rateMode = RateMode.constrainedBitrate,
    this.crf = 20,
    this.profile = 'high',
    this.level = '4.0',
    this.gopSeconds = 2.0,
    this.pixelFormat = 'yuv420p',
    this.audio = const AudioSpec(),
    this.maxClipDuration,
    this.maxrateKbpsOverride,
    this.bufsizeKbpsOverride,
    this.spendBudget = false,
    this.padToCanvas = false,
    this.colorPrimaries = 'bt709',
    this.colorMatrix = 'bt709',
  });

  final int maxLongEdge;
  final int maxShortEdge;
  final int videoBitrateKbps;

  /// Treat [videoBitrateKbps] as a ceiling to spend up to, rather than a figure
  /// to hit.
  ///
  /// Presets that exist to test a bitrate hypothesis want a fixed number. The
  /// preset the app ships wants the opposite: WhatsApp's 16MB cap is the real
  /// constraint, and deliberately sitting far below it throws away quality that
  /// was free. A ten-second clip can afford 8 Mbps inside the cap; sending it
  /// at 2.3 left most of the budget unspent.
  final bool spendBudget;

  final double maxFps;
  final RateMode rateMode;
  final int crf;
  final String profile;
  final String level;

  /// Keyframe spacing in seconds. Short GOPs cost bitrate but survive
  /// re-encoding better, because the downstream encoder can anchor on our
  /// keyframes instead of inventing its own mid-motion.
  final double gopSeconds;
  final String pixelFormat;
  final AudioSpec audio;

  /// Status clips get cut at this length. Left null until calibration
  /// establishes the real limit for the installed WhatsApp version.
  final Duration? maxClipDuration;

  /// Set only when a preset needs to break the default relationship between
  /// target and ceiling. Normally left null.
  final int? maxrateKbpsOverride;
  final int? bufsizeKbpsOverride;

  /// Letterbox into an exact maxShortEdge x maxLongEdge portrait canvas
  /// instead of fitting inside it. Copied from a service measured to survive
  /// Status cleanly: every clip arrives as the same 9:16 frame WhatsApp's own
  /// encoder would produce, so geometry gives it nothing to change.
  final bool padToCanvas;

  /// Colour metadata stamped on the output. bt709 is correct for phone video;
  /// the proven WhatsApp spec tags bt470bg matrix and primaries instead —
  /// mimicking what WhatsApp's own encoder emits.
  final String colorPrimaries;
  final String colorMatrix;

  /// A ceiling only slightly above target keeps the stream close to constant
  /// bitrate. A wildly variable stream invites the downstream encoder to make
  /// its own decisions, which is exactly what we are trying to avoid.
  int get maxrateKbps => maxrateKbpsOverride ?? (videoBitrateKbps * 1.15).round();

  /// One second of buffer at the ceiling. Larger buffers permit longer
  /// excursions above target, which show up as bitrate spikes on motion.
  int get bufsizeKbps => bufsizeKbpsOverride ?? maxrateKbps;

  TargetSpec copyWith({
    int? maxLongEdge,
    int? maxShortEdge,
    int? videoBitrateKbps,
    double? maxFps,
    RateMode? rateMode,
    int? crf,
    double? gopSeconds,
    AudioSpec? audio,
    Duration? maxClipDuration,
  }) =>
      TargetSpec(
        maxLongEdge: maxLongEdge ?? this.maxLongEdge,
        maxShortEdge: maxShortEdge ?? this.maxShortEdge,
        videoBitrateKbps: videoBitrateKbps ?? this.videoBitrateKbps,
        maxFps: maxFps ?? this.maxFps,
        rateMode: rateMode ?? this.rateMode,
        crf: crf ?? this.crf,
        profile: profile,
        level: level,
        gopSeconds: gopSeconds ?? this.gopSeconds,
        pixelFormat: pixelFormat,
        audio: audio ?? this.audio,
        maxClipDuration: maxClipDuration ?? this.maxClipDuration,
        maxrateKbpsOverride: maxrateKbpsOverride,
        bufsizeKbpsOverride: bufsizeKbpsOverride,
        spendBudget: spendBudget,
        padToCanvas: padToCanvas,
        colorPrimaries: colorPrimaries,
        colorMatrix: colorMatrix,
      );
}

/// A named hypothesis about what survives the trip.
///
/// Presets exist to be raced against each other. None of them is "correct"
/// until a calibration run says so, and the winner is expected to change when
/// WhatsApp changes its encoder.
class Preset {
  const Preset({
    required this.id,
    required this.label,
    required this.rationale,
    required this.spec,
    this.sharpenAmount = 0.0,
    this.denoiseStrength = 0.0,
    this.scaler = 'lanczos',
    this.allowUpscale = false,
    this.passthrough = false,
  });

  /// A control that does nothing at all — the file goes to WhatsApp exactly as
  /// the camera left it. Every other preset has to beat this to justify itself.
  const Preset.control()
      : id = 'control',
        label = 'Untouched original',
        rationale = 'What happens today when you post straight from the gallery. '
            'The number to beat.',
        spec = const TargetSpec(
          maxLongEdge: 0,
          maxShortEdge: 0,
          videoBitrateKbps: 0,
        ),
        sharpenAmount = 0.0,
        denoiseStrength = 0.0,
        scaler = 'lanczos',
        allowUpscale = false,
        passthrough = true;

  final String id;
  final String label;
  final String rationale;
  final TargetSpec spec;

  /// `unsharp` luma amount. Counteracts the softening the downstream encoder
  /// applies. Too much and the re-encode has to spend bits on ringing, which
  /// costs more than the sharpening gained.
  final double sharpenAmount;

  /// `hqdn3d` luma strength. Sensor noise is expensive to encode and the first
  /// thing a starved encoder destroys; removing it early leaves more bits for
  /// detail that matters.
  final double denoiseStrength;

  final String scaler;

  /// Off by default. Upscaling spends bitrate inventing pixels, then the
  /// downstream encoder throws them away again.
  final bool allowUpscale;

  final bool passthrough;
}
