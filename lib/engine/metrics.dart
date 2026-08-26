import 'dart:math' as math;

/// Similarity scores for one round trip.
///
/// SSIM tracks perceived structural damage and is the number to lead with.
/// PSNR is retained because it is sensitive to the flat-area banding that SSIM
/// under-weights, and banding in gradients is one of the most visible ways
/// WhatsApp's encoder fails.
class QualityScore {
  const QualityScore({required this.ssim, required this.psnrDb});

  final double ssim;
  final double psnrDb;

  /// SSIM compresses hard near the top of its range: 0.98 and 0.995 look very
  /// different on screen but sit close together numerically. Working in dB
  /// spreads that tail out so preset-to-preset differences are legible.
  double get ssimDb {
    if (ssim >= 1.0) return 99.0;
    if (ssim <= 0.0) return 0.0;
    return -10 * (math.log(1 - ssim) / math.ln10);
  }

  @override
  String toString() =>
      'SSIM ${ssim.toStringAsFixed(5)} (${ssimDb.toStringAsFixed(2)}dB) '
      'PSNR ${psnrDb.toStringAsFixed(2)}dB';
}

/// Pulls the summary lines out of ffmpeg's stderr.
class MetricParser {
  const MetricParser._();

  /// Matches e.g. `SSIM Y:0.987 (18.9) U:... V:... All:0.981 (17.2)`
  static final RegExp _ssim = RegExp(r'All:\s*([0-9.]+)');

  /// Matches e.g. `PSNR y:41.2 u:45.1 v:44.8 average:42.0 min:... max:...`
  static final RegExp _psnr = RegExp(r'average:\s*(inf|[0-9.]+)');

  static double? ssim(String output) {
    final m = _ssim.firstMatch(output);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  static double? psnr(String output) {
    final m = _psnr.firstMatch(output);
    if (m == null) return null;
    final raw = m.group(1)!;
    // Identical streams report `inf`, which is a legitimate result when a
    // preset happened to be a true passthrough.
    if (raw == 'inf') return 99.0;
    return double.tryParse(raw);
  }
}
