import 'dart:convert';

/// What a file actually is, as opposed to what its extension claims.
///
/// Everything downstream plans against this: whether to scale, whether the
/// source is already smaller than the target, how long a Status clip has to be
/// cut into. Parsed from `ffprobe -show_streams -show_format -of json`, which
/// is identical output whether ffprobe ran from a shell or from FFmpegKit.
class MediaInfo {
  const MediaInfo({
    required this.width,
    required this.height,
    required this.fps,
    required this.duration,
    required this.videoCodec,
    required this.rotation,
    required this.sizeBytes,
    this.videoBitrate,
    this.audioCodec,
    this.audioBitrate,
    this.audioSampleRate,
    this.audioChannels,
    this.pixelFormat,
    this.colorPrimaries,
    this.colorTransfer,
    this.sampleAspectRatio,
  });

  /// Coded dimensions — before any rotation metadata is applied.
  final int width;
  final int height;
  final double fps;
  final Duration duration;
  final String videoCodec;

  /// 0, 90, 180 or 270. Phone video is almost always stored landscape with a
  /// rotation flag, so planning against [width]/[height] directly would size
  /// every portrait clip wrong.
  final int rotation;
  final int sizeBytes;
  final int? videoBitrate;
  final String? audioCodec;
  final int? audioBitrate;
  final int? audioSampleRate;
  final int? audioChannels;
  final String? pixelFormat;
  final String? colorPrimaries;
  final String? colorTransfer;

  /// Non-square pixels. Phone footage is normally 1:1, but anything that has
  /// been through an editor or came off a camcorder may not be — and scaling
  /// such a file without correcting for it silently stretches the picture.
  final String? sampleAspectRatio;

  bool get hasAudio => audioCodec != null;

  /// Modern phones record 10-bit HDR by default. Treating it as ordinary
  /// 8-bit SDR is one of the ways a file that looks fine in the gallery comes
  /// out grey and flat after conversion.
  bool get isTenBit {
    final fmt = pixelFormat ?? '';
    return fmt.contains('10le') ||
        fmt.contains('10be') ||
        fmt.contains('p010') ||
        fmt.contains('12le');
  }

  bool get isHdr {
    final primaries = colorPrimaries ?? '';
    final transfer = colorTransfer ?? '';
    return primaries.contains('bt2020') ||
        transfer.contains('smpte2084') ||
        transfer.contains('arib-std-b67');
  }

  /// PQ or HLG transfer. These are the true HDR curves, and converting them to
  /// SDR needs real tone mapping — the `colorspace` filter cannot do it, so
  /// without zscale there is no honest conversion available.
  bool get hasPqOrHlg {
    final transfer = colorTransfer ?? '';
    return transfer.contains('smpte2084') || transfer.contains('arib-std-b67');
  }

  bool get hasOddSampleAspect {
    final sar = sampleAspectRatio;
    if (sar == null || sar.isEmpty || sar == 'N/A') return false;
    return sar != '1:1';
  }

  bool get isRotatedQuarter => rotation == 90 || rotation == 270;

  /// The dimensions a viewer perceives, with rotation applied.
  int get displayWidth => isRotatedQuarter ? height : width;
  int get displayHeight => isRotatedQuarter ? width : height;

  double get displayAspect => displayHeight == 0 ? 0 : displayWidth / displayHeight;
  int get pixelCount => displayWidth * displayHeight;

  /// Overall bitrate in bits per second, derived when the stream does not
  /// declare its own. Containers frequently omit per-stream bitrate.
  int get effectiveVideoBitrate {
    if (videoBitrate != null && videoBitrate! > 0) return videoBitrate!;
    final seconds = duration.inMilliseconds / 1000.0;
    if (seconds <= 0) return 0;
    // Audio is a rounding error next to video at these sizes; close enough
    // for planning, and the encoder gets an explicit target anyway.
    return ((sizeBytes * 8) / seconds).round();
  }

  static MediaInfo parseFfprobeJson(String jsonText) {
    final root = jsonDecode(jsonText) as Map<String, dynamic>;
    final streams = (root['streams'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    final format = root['format'] as Map<String, dynamic>? ?? const {};

    final video = streams.firstWhere(
      (s) => s['codec_type'] == 'video',
      orElse: () => throw const FormatException('no video stream'),
    );
    final audio = streams.where((s) => s['codec_type'] == 'audio').firstOrNull;

    return MediaInfo(
      width: _int(video['width']) ?? 0,
      height: _int(video['height']) ?? 0,
      fps: _parseRate(video['avg_frame_rate'] as String?) ??
          _parseRate(video['r_frame_rate'] as String?) ??
          30.0,
      duration: _parseDuration(video['duration'] ?? format['duration']),
      videoCodec: video['codec_name'] as String? ?? 'unknown',
      rotation: _parseRotation(video),
      sizeBytes: _int(format['size']) ?? 0,
      videoBitrate: _int(video['bit_rate']),
      pixelFormat: video['pix_fmt'] as String?,
      colorPrimaries: video['color_primaries'] as String?,
      colorTransfer: video['color_transfer'] as String?,
      sampleAspectRatio: video['sample_aspect_ratio'] as String?,
      audioCodec: audio?['codec_name'] as String?,
      audioBitrate: _int(audio?['bit_rate']),
      audioSampleRate: _int(audio?['sample_rate']),
      audioChannels: _int(audio?['channels']),
    );
  }

  /// ffprobe reports rotation in two places depending on the container, and
  /// newer builds report it as a negative displaymatrix angle. Normalised here
  /// so callers never have to care which shape it arrived in.
  static int _parseRotation(Map<String, dynamic> video) {
    int? raw;
    final sideData = video['side_data_list'] as List<dynamic>?;
    if (sideData != null) {
      for (final entry in sideData.cast<Map<String, dynamic>>()) {
        final r = entry['rotation'];
        if (r != null) raw = _int(r) ?? double.tryParse('$r')?.round();
      }
    }
    raw ??= _int((video['tags'] as Map<String, dynamic>?)?['rotate']);
    if (raw == null) return 0;
    final normalised = ((raw % 360) + 360) % 360;
    return normalised;
  }

  static double? _parseRate(String? rate) {
    if (rate == null || rate.isEmpty) return null;
    final parts = rate.split('/');
    if (parts.length != 2) return double.tryParse(rate);
    final num = double.tryParse(parts[0]);
    final den = double.tryParse(parts[1]);
    if (num == null || den == null || den == 0) return null;
    return num / den;
  }

  static Duration _parseDuration(Object? value) {
    final seconds = value == null ? null : double.tryParse('$value');
    if (seconds == null) return Duration.zero;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  static int? _int(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse('$value');
  }

  /// Deliberately dense. This string ends up in error reports, and the whole
  /// point is that a failure tells you what was unusual about the file.
  String get diagnostic => [
        '${displayWidth}x$displayHeight',
        '${fps.toStringAsFixed(2)}fps',
        videoCodec,
        pixelFormat ?? 'pix?',
        if (isTenBit) '10-bit',
        if (isHdr) 'HDR',
        if (rotation != 0) 'rot$rotation',
        if (hasOddSampleAspect) 'sar $sampleAspectRatio',
        '${(effectiveVideoBitrate / 1000).round()}kbps',
        '${duration.inMilliseconds}ms',
        audioCodec ?? 'no audio',
      ].join(' · ');

  @override
  String toString() =>
      '${displayWidth}x$displayHeight @${fps.toStringAsFixed(2)}fps '
      '$videoCodec ${(effectiveVideoBitrate / 1000).round()}kbps '
      '${duration.inMilliseconds}ms ${(sizeBytes / 1048576).toStringAsFixed(2)}MB';
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
