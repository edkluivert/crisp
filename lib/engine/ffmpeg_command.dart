import 'conform_plan.dart';
import 'target_spec.dart';

/// Builds argument lists. Never runs anything.
///
/// Keeping this pure is what lets the desktop harness and the phone run the
/// same pipeline: the harness hands these args to a system ffmpeg process, the
/// app hands the identical args to FFmpegKit. If they diverged, calibration on
/// the Mac would tell us nothing about what ships.
class FfmpegCommand {
  const FfmpegCommand._();

  static List<String> probe(String inputPath) => [
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_streams',
        '-show_format',
        inputPath,
      ];

  static List<String> conform({
    required ConformPlan plan,
    required String inputPath,
    required String outputPath,
  }) {
    final spec = plan.preset.spec;
    final args = <String>[
      '-y', '-hide_banner',
      '-i', inputPath,
      '-vf', plan.filterChain,
      '-r', plan.fps.toStringAsFixed(3),
      '-c:v', plan.encoder.name,
    ];

    if (spec.rateMode == RateMode.quality && plan.encoder.supportsCrf) {
      args.addAll(['-crf', '${spec.crf}']);
      // CRF with a ceiling: quality-targeted, but never allowed to spike past
      // the rate the downstream pipeline tolerates. Only emitted when a preset
      // asks for it explicitly — bare CRF stays bare.
      if (spec.maxrateKbpsOverride != null) {
        args.addAll([
          '-maxrate', '${spec.maxrateKbps}k',
          '-bufsize', '${spec.bufsizeKbps}k',
        ]);
      }
    } else {
      args.addAll([
        '-b:v', '${plan.videoBitrateKbps}k',
        '-maxrate', '${spec.maxrateKbps}k',
        '-bufsize', '${spec.bufsizeKbps}k',
      ]);
    }

    if (plan.encoder.supportsPreset) {
      // Slow is affordable here — this runs once per share, not in real time,
      // and a better first encode is the entire premise of the product.
      args.addAll(['-preset', 'slow']);
    }

    args.addAll(['-profile:v', spec.profile]);
    if (plan.encoder.acceptsLevelFlag) {
      args.addAll(['-level', spec.level]);
    }
    args.addAll(['-g', '${plan.gopFrames}', '-keyint_min', '${plan.gopFrames}']);
    if (plan.encoder.supportsSceneCut) {
      // Fixed keyframe cadence. Scene-cut keyframes land in different places
      // than the downstream encoder's, and mismatched anchors are where
      // re-encoded video visibly pulses.
      args.addAll(['-sc_threshold', '0']);
    }

    // Tag colour explicitly. Untagged Rec.709 is the usual reason a clip comes
    // back looking washed out or oversaturated: each decoder guesses, and they
    // do not all guess the same.
    //
    // But only claim Rec.709 when it is true. An HDR source we could not
    // tone-map is still BT.2020, and stamping bt709 on it would turn a colour
    // problem into a lie the player then acts on.
    if (!plan.sourceIsHdr || plan.toneMapped) {
      args.addAll([
        '-colorspace', spec.colorMatrix,
        '-color_primaries', spec.colorPrimaries,
        '-color_trc', 'bt709',
        '-color_range', 'tv',
      ]);
    }

    if (plan.encoder.name == 'libx264') {
      // Strip the x264 version banner the encoder writes into the stream.
      // Part of the proven WhatsApp spec — the output carries no marker that
      // it has already been through an encoder.
      args.addAll(['-x264-params', 'sei=0']);
    }

    switch (plan.audioHandling) {
      case AudioHandling.encode:
        args.addAll([
          '-c:a', plan.audioEncoderName ?? spec.audio.codec,
          '-b:a', '${spec.audio.bitrateKbps}k',
          '-ar', '${spec.audio.sampleRate}',
          '-ac', '${spec.audio.channels}',
        ]);
      case AudioHandling.copy:
        args.addAll(['-c:a', 'copy']);
      case AudioHandling.drop:
        args.add('-an');
    }

    // Moov atom first, so the file starts playing before it finishes loading.
    // The isom brand matches what WhatsApp's own encoder writes.
    args.addAll(['-brand', 'isom', '-movflags', '+faststart', outputPath]);
    return args;
  }

  /// Compares [distortedPath] against [referencePath] with the given filter.
  ///
  /// Both streams are forced to the reference geometry and frame rate first —
  /// WhatsApp routinely returns a different resolution, and the comparison
  /// filters silently produce nonsense on mismatched inputs rather than
  /// failing, which is a very easy way to publish a confidently wrong number.
  static List<String> compare({
    required String referencePath,
    required String distortedPath,
    required int width,
    required int height,
    required double fps,
    required String metric,
  }) {
    final rate = fps.toStringAsFixed(3);
    final geometry = 'scale=$width:$height:flags=bicubic,setsar=1,fps=$rate';
    return [
      '-hide_banner',
      '-i', distortedPath,
      '-i', referencePath,
      '-lavfi',
      '[0:v]$geometry[dist];[1:v]$geometry[ref];[dist][ref]$metric',
      '-f', 'null', '-',
    ];
  }
}
