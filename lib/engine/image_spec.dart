import 'dart:math' as math;

import 'media_info.dart';

/// Photos take the same beating as video, for the same reason: WhatsApp
/// resamples anything above its pixel cap and re-encodes the JPEG at a quality
/// well below what a modern phone camera produces.
///
/// The strategy is identical to the video path — arrive already inside the cap
/// so the resample never happens — but the knobs are different enough that
/// sharing [TargetSpec] would have meant a type full of fields that only apply
/// half the time.
class ImagePreset {
  const ImagePreset({
    required this.id,
    required this.label,
    required this.rationale,
    required this.maxLongEdge,
    required this.quality,
    this.sharpenAmount = 0.0,
    this.denoiseStrength = 0.0,
    this.scaler = 'lanczos',
    this.chromaSubsampling = '420',
    this.passthrough = false,
  });

  const ImagePreset.control()
      : id = 'control',
        label = 'Untouched original',
        rationale = 'Posting straight from the gallery.',
        maxLongEdge = 0,
        quality = 0,
        sharpenAmount = 0.0,
        denoiseStrength = 0.0,
        scaler = 'lanczos',
        chromaSubsampling = '420',
        passthrough = true;

  final String id;
  final String label;
  final String rationale;
  final int maxLongEdge;

  /// ffmpeg's mjpeg scale, where 2 is near-lossless and 31 is unusable. Low
  /// numbers cost file size, and file size is what pushes an upload over the
  /// threshold that triggers a re-encode — so this is a balance, not a
  /// "set it to 2" decision.
  final int quality;

  final double sharpenAmount;
  final double denoiseStrength;
  final String scaler;

  /// 4:2:0 halves colour resolution and is what almost everything expects.
  /// 4:4:4 keeps it, which visibly helps saturated edges and text, at a size
  /// penalty that may cost more than it gains once WhatsApp re-encodes.
  final String chromaSubsampling;

  final bool passthrough;
}

class CrispImagePresets {
  const CrispImagePresets._();

  static const control = ImagePreset.control();

  /// What the app ships. Sized for the forward route: the file's first (and
  /// ideally only) encode is WhatsApp's chat-HD pass, which keeps images up to
  /// roughly 4096px — so shrinking below that throws away pixels nothing was
  /// going to take anyway. The old 1600px cap came from the Status compressor
  /// this route bypasses, and it was also below the threshold at which
  /// WhatsApp offers HD at all, which silently removed the HD option.
  static const conformed = ImagePreset(
    id: 'img_conformed',
    label: 'Conformed',
    rationale: 'Full resolution up to the chat-HD cap, near-lossless quality, '
        'light pre-sharpening.',
    maxLongEdge: 4096,
    quality: 2,
    sharpenAmount: 0.5,
  );

  /// Larger, betting the cap is more generous than folklore says.
  static const conformedLarge = ImagePreset(
    id: 'img_conformed_large',
    label: 'Conformed, large',
    rationale: 'Tests whether the pixel cap is above 1600px on the long edge.',
    maxLongEdge: 2048,
    quality: 3,
    sharpenAmount: 0.4,
  );

  /// Keeps full chroma. Worth measuring separately because it helps exactly the
  /// content people complain most about — text, logos, saturated graphics.
  static const conformedSharp = ImagePreset(
    id: 'img_conformed_444',
    label: 'Conformed, full chroma',
    rationale: 'Keeps 4:4:4 colour for text and saturated edges.',
    maxLongEdge: 1600,
    quality: 2,
    sharpenAmount: 0.6,
    chromaSubsampling: '444',
  );

  static const List<ImagePreset> all = [
    control,
    conformed,
    conformedLarge,
    conformedSharp,
  ];
}

/// Builds the argument list for one photo.
class ImageCommand {
  const ImageCommand._();

  static List<String> conform({
    required MediaInfo source,
    required ImagePreset preset,
    required String inputPath,
    required String outputPath,
  }) {
    final filters = <String>[];

    if (preset.denoiseStrength > 0) {
      filters.add('hqdn3d='
          'luma_spatial=${preset.denoiseStrength.toStringAsFixed(2)}:'
          'chroma_spatial=${(preset.denoiseStrength * 0.75).toStringAsFixed(2)}:'
          'luma_tmp=0:chroma_tmp=0');
    }

    final (w, h) = fit(
      width: source.displayWidth,
      height: source.displayHeight,
      maxLongEdge: preset.maxLongEdge,
    );
    if (w != source.displayWidth || h != source.displayHeight) {
      filters.add('scale=width=$w:height=$h:flags=${preset.scaler}');
    }
    if (preset.sharpenAmount > 0) {
      filters.add('unsharp='
          'luma_msize_x=5:luma_msize_y=5:'
          'luma_amount=${preset.sharpenAmount.toStringAsFixed(2)}:'
          'chroma_msize_x=5:chroma_msize_y=5:chroma_amount=0');
    }
    // yuvj* is the full-range JPEG flavour; using the studio-range variant here
    // is the classic cause of washed-out photos.
    filters.add(switch (preset.chromaSubsampling) {
      '444' => 'format=pix_fmts=yuvj444p',
      '422' => 'format=pix_fmts=yuvj422p',
      _ => 'format=pix_fmts=yuvj420p',
    });

    return [
      '-y', '-hide_banner',
      '-i', inputPath,
      '-vf', filters.join(','),
      '-q:v', '${preset.quality}',
      // Strip metadata: orientation is already baked in by the scale filter,
      // and a stale EXIF rotation flag would rotate the image a second time.
      '-map_metadata', '-1',
      outputPath,
    ];
  }

  /// Scales to fit a long-edge cap without upscaling.
  static (int, int) fit({
    required int width,
    required int height,
    required int maxLongEdge,
  }) {
    if (maxLongEdge <= 0) return (width, height);
    final long = math.max(width, height);
    if (long <= maxLongEdge) return (width, height);
    final ratio = maxLongEdge / long;
    int even(int v) => v.isEven ? math.max(2, v) : math.max(2, v - 1);
    return (even((width * ratio).round()), even((height * ratio).round()));
  }
}
