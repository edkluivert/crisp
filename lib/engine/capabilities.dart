import 'conform_plan.dart';
import 'ffmpeg_runner.dart';

/// What the ffmpeg binary in front of us can actually do.
///
/// None of this is safe to assume. The bundled build differs by package
/// variant and by platform, the documentation does not enumerate encoders or
/// filters, and the desktop build is a completely different binary again.
/// Detecting once and carrying the answer beats discovering it halfway through
/// a user's first encode — which is exactly how the missing AAC encoder was
/// found, as an opaque "conversion failed" on a real device.
class FfmpegCapabilities {
  const FfmpegCapabilities({
    required this.encoder,
    required this.audioEncoder,
    required this.canToneMap,
    required this.h264Encoders,
    required this.audioEncoders,
    required this.filters,
  });

  /// Null when the build ships no usable H.264 encoder at all — a real
  /// possibility that has to be reported, not crashed on.
  final VideoEncoder? encoder;

  /// Null when nothing can encode AAC. Not fatal: source audio that is already
  /// AAC can be stream-copied instead, which is both lossless and free.
  final String? audioEncoder;

  /// zscale, which proper HDR to SDR conversion needs. Absent from minimal
  /// builds, in which case HDR footage is passed through rather than mangled.
  final bool canToneMap;

  final List<String> h264Encoders;
  final List<String> audioEncoders;

  /// Every filter this build carries. Denoise and pre-sharpen are enhancements
  /// — worth skipping quietly if absent, never worth failing a file over.
  final Set<String> filters;

  bool get canDenoise => filters.contains('hqdn3d');
  bool get canSharpen => filters.contains('unsharp');
  bool get canScale => filters.contains('scale');

  bool get usable => encoder != null;

  static Future<FfmpegCapabilities> detect(FfmpegRunner runner) async {
    final encoders = await runner.ffmpeg(['-hide_banner', '-encoders']);
    final names = _encoderNames(encoders.output);

    VideoEncoder? chosenVideo;
    // Hardware first: faster, cooler, and free of the GPL entanglement that
    // rules libx264 out of a shipping build anyway.
    for (final candidate in [
      VideoEncoder.videoToolbox,
      VideoEncoder.mediaCodec,
      VideoEncoder.x264,
    ]) {
      if (names.contains(candidate.name)) {
        chosenVideo = candidate;
        break;
      }
    }

    // `aac_at` is Apple's AudioToolbox encoder and is present on Apple
    // platforms even in builds that dropped the native one. Order matters:
    // matching must be exact, because "aac" is a substring of both "aac_at"
    // and "libfdk_aac".
    String? chosenAudio;
    for (final candidate in ['aac_at', 'aac', 'libfdk_aac', 'aac_mediacodec']) {
      if (names.contains(candidate)) {
        chosenAudio = candidate;
        break;
      }
    }

    final filters = await runner.ffmpeg(['-hide_banner', '-filters']);

    final filterNames = _filterNames(filters.output);

    return FfmpegCapabilities(
      encoder: chosenVideo,
      audioEncoder: chosenAudio,
      filters: filterNames,
      canToneMap:
          filterNames.contains('zscale') && filterNames.contains('tonemap'),
      h264Encoders: names.where((n) => n.contains('h264')).toList(),
      audioEncoders:
          names.where((n) => n.contains('aac') || n.contains('opus')).toList(),
    );
  }

  /// Pulls the encoder names out of `ffmpeg -encoders`.
  ///
  /// Lines look like ` A....D aac    AAC (Advanced Audio Coding)`, so the name
  /// is the second whitespace-separated field. Substring matching against the
  /// raw output would be enough to confuse "aac" with "libfdk_aac", and then
  /// the build would claim a codec it does not have.
  static Set<String> _encoderNames(String output) {
    final names = <String>{};
    for (final line in output.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final flags = parts[0];
      // The flag column is exactly six characters of letters and dots.
      if (flags.length != 6 || !RegExp(r'^[VAS.][.EF][.S][.X][.B][.D]$')
          .hasMatch(flags)) {
        continue;
      }
      names.add(parts[1]);
    }
    return names;
  }

  /// `ffmpeg -filters` lines look like ` TS hqdn3d  V->V  Apply a ...`, so the
  /// name is the second field after a short flag column.
  static Set<String> _filterNames(String output) {
    final names = <String>{};
    for (final line in output.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 3) continue;
      if (!RegExp(r'^[TSC.]{1,3}$').hasMatch(parts[0])) continue;
      names.add(parts[1]);
    }
    return names;
  }

  String get summary {
    if (encoder == null) return 'No H.264 encoder available';
    final audio = audioEncoder ?? 'no AAC — audio copied or dropped';
    return '${encoder!.name} · $audio${canToneMap ? ' · HDR' : ''}';
  }
}
