import 'dart:math' as math;

import 'media_info.dart';
import 'target_spec.dart';

/// Which encoder the pipeline will use, and what dialect of flags it speaks.
///
/// The app cannot ship libx264 — it is GPL, and a GPL binary inside a store
/// app makes the whole app GPL. The hardware encoders are LGPL-safe and much
/// faster on a phone, so they are what ships. libx264 stays available for the
/// desktop harness, where it is useful as a quality ceiling to measure against.
class VideoEncoder {
  const VideoEncoder({
    required this.name,
    required this.supportsCrf,
    required this.supportsPreset,
    required this.supportsSceneCut,
    required this.acceptsLevelFlag,
  });

  final String name;
  final bool supportsCrf;
  final bool supportsPreset;
  final bool supportsSceneCut;

  /// The hardware encoders reject or ignore an explicit `-level`, and a
  /// rejected level fails the whole encode rather than degrading. Software
  /// x264 takes it happily.
  final bool acceptsLevelFlag;

  static const x264 = VideoEncoder(
    name: 'libx264',
    supportsCrf: true,
    supportsPreset: true,
    supportsSceneCut: true,
    acceptsLevelFlag: true,
  );

  /// Apple platforms, including the Mac running the harness. Using this on the
  /// desktop keeps calibration honest: measuring x264 output would flatter a
  /// pipeline that ships VideoToolbox.
  static const videoToolbox = VideoEncoder(
    name: 'h264_videotoolbox',
    supportsCrf: false,
    supportsPreset: false,
    supportsSceneCut: false,
    acceptsLevelFlag: false,
  );

  static const mediaCodec = VideoEncoder(
    name: 'h264_mediacodec',
    supportsCrf: false,
    supportsPreset: false,
    supportsSceneCut: false,
    acceptsLevelFlag: false,
  );
}

/// What to do with the source's audio.
///
/// Encoding is preferred, but not always possible: a minimal ffmpeg build may
/// ship no AAC encoder at all. Stream copy rescues the common case, since phone
/// video is almost always already AAC — and copying is both lossless and free.
enum AudioHandling { encode, copy, drop }

/// A concrete, inspectable decision about one file.
///
/// Deliberately a value object rather than a string of flags: the calibration
/// report needs to say *why* a file came out 1080x1920 at 4200kbps, and a
/// built command line is a terrible thing to explain.
class ConformPlan {
  const ConformPlan({
    required this.source,
    required this.preset,
    required this.encoder,
    required this.outputWidth,
    required this.outputHeight,
    required this.fps,
    required this.videoBitrateKbps,
    required this.gopFrames,
    required this.filterChain,
    required this.audioHandling,
    required this.audioEncoderName,
    required this.scaled,
    required this.toneMapped,
    required this.sourceIsHdr,
    required this.notes,
  });

  final MediaInfo source;
  final Preset preset;
  final VideoEncoder encoder;
  final int outputWidth;
  final int outputHeight;
  final double fps;
  final int videoBitrateKbps;
  final int gopFrames;
  final String filterChain;
  final AudioHandling audioHandling;
  final String? audioEncoderName;

  /// False when the source already fit inside the target box. Worth surfacing:
  /// an untouched-resolution file that still gained quality proves the win came
  /// from bitrate and pre-filtering, not from resizing.
  final bool scaled;

  /// True when the HDR source was actually converted to SDR. When false and
  /// [sourceIsHdr] is true, the file was passed through without conversion and
  /// must not be tagged Rec.709.
  final bool toneMapped;
  final bool sourceIsHdr;

  final List<String> notes;

  static ConformPlan build({
    required MediaInfo source,
    required Preset preset,
    required VideoEncoder encoder,
    bool canToneMap = false,
    bool canDenoise = true,
    bool canSharpen = true,
    String? audioEncoder,
    int? budgetKbps,
    Duration? clipDuration,
  }) {
    final notes = <String>[];
    final spec = preset.spec;

    final srcW = source.displayWidth;
    final srcH = source.displayHeight;
    final srcLong = math.max(srcW, srcH);
    final srcShort = math.min(srcW, srcH);

    // Fit inside the box on both edges, preserving aspect. The smaller of the
    // two ratios is the binding constraint.
    final longRatio = spec.maxLongEdge / srcLong;
    final shortRatio = spec.maxShortEdge / srcShort;
    var ratio = math.min(longRatio, shortRatio);

    if (ratio >= 1.0 && !preset.allowUpscale) {
      ratio = 1.0;
      notes.add('source already inside the target box — not upscaling');
    }

    var outW = _even((srcW * ratio).round());
    var outH = _even((srcH * ratio).round());

    if (spec.padToCanvas) {
      // Every clip leaves as the same portrait frame, letterboxed if needed —
      // never cropped. The step-down ladder below still applies; a 9:16
      // canvas scales cleanly through 720x1280 and 540x960.
      outW = spec.maxShortEdge;
      outH = spec.maxLongEdge;
    }

    final fps = math.min(source.fps, spec.maxFps);
    if (fps < source.fps) {
      notes.add('frame rate capped ${source.fps.toStringAsFixed(2)} -> '
          '${fps.toStringAsFixed(2)}');
    }

    // Never spend more bitrate than the source actually carries. Re-encoding a
    // 2Mbps source at 6Mbps invents nothing; it just hands WhatsApp a bigger
    // file to squeeze, which makes the result worse rather than better.
    final sourceKbps = (source.effectiveVideoBitrate / 1000).round();
    final seconds = (clipDuration ?? source.duration).inSeconds;
    var bitrate = spec.videoBitrateKbps;

    if (spec.spendBudget && budgetKbps != null && budgetKbps > 0) {
      // Spend the cap, do not hide from it. The ceiling, the source and the
      // budget all bound the answer; the smallest of them is the honest one.
      bitrate = math.min(spec.videoBitrateKbps, budgetKbps);
      if (sourceKbps > 0) bitrate = math.min(bitrate, sourceKbps);
      notes.add('${seconds}s inside the size cap allows $budgetKbps kbps — '
          'using $bitrate');
    } else {
      if (sourceKbps > 0 && bitrate > sourceKbps) {
        bitrate = sourceKbps;
        notes.add('target bitrate clamped to source ($sourceKbps kbps)');
      }
      if (budgetKbps != null && budgetKbps > 0 && bitrate > budgetKbps) {
        bitrate = budgetKbps;
        notes.add('bitrate cut to $budgetKbps kbps to keep ${seconds}s '
            'inside the size cap');
      }
    }

    // Below roughly this much information per pixel, H.264 stops resolving
    // detail and starts resolving blocks. When that happens the honest move is
    // fewer, better pixels rather than more, worse ones — a sharp 720p beats a
    // mushy 1080p, and it is the same file size either way.
    var stepped = false;
    if (bitrate > 0) {
      double bitsPerPixel(int w, int h) => (bitrate * 1000) / (w * h * fps);
      // Tuned so a 45-second clip keeps 1080p at ~2.6 Mbps, which still looks
      // good, while 60s and beyond step down rather than smear.
      const floor = 0.040;
      if (bitsPerPixel(outW, outH) < floor) {
        for (final shortEdge in const [1080, 720, 540, 480, 360]) {
          final currentShort = math.min(outW, outH);
          if (shortEdge >= currentShort) continue;
          final scale = shortEdge / currentShort;
          final w = _even((outW * scale).round());
          final h = _even((outH * scale).round());
          outW = w;
          outH = h;
          stepped = true;
          if (bitsPerPixel(w, h) >= floor) break;
        }
        if (stepped) {
          notes.add('stepped down to ${outW}x$outH — $bitrate kbps cannot '
              'sustain a larger frame');
        }
      }
    }
    final scaled2 = outW != srcW || outH != srcH;

    final filters = <String>[];

    // HDR first, before anything samples the pixels. Phones shoot 10-bit HDR
    // by default now, and a naive `format=yuv420p` on BT.2020 content clips the
    // highlights and produces the flat, grey look people blame on compression.
    // Proper conversion needs zscale, which the minimal ffmpeg build may not
    // carry — so it is a runtime capability, not an assumption.
    var toneMapped = false;
    if (source.isHdr || source.isTenBit) {
      if (source.hasPqOrHlg && canToneMap) {
        filters.addAll([
          'zscale=transfer=linear:npl=100',
          // The tonemap filter's first option is itself called `tonemap`, so
          // the doubled name is correct and not a typo.
          'tonemap=tonemap=hable:desat=0',
          'zscale=primaries=bt709:transfer=bt709:matrix=bt709:range=tv',
        ]);
        toneMapped = true;
        notes.add('HDR source tone-mapped to SDR');
      } else if (source.hasPqOrHlg) {
        notes.add('HDR (${source.colorTransfer}) cannot be converted to SDR on '
            'this device — colour is passed through as-is');
      } else if ((source.colorPrimaries ?? '').contains('bt2020')) {
        // Wide gamut on a conventional curve. `colorspace` is a core filter and
        // handles this correctly. Note the value is `bt2020`, not `bt2020-10` —
        // the latter is a transfer characteristic and the filter rejects it.
        filters.add('colorspace=all=bt709:iall=bt2020:format=yuv420p');
        toneMapped = true;
        notes.add('wide-gamut source converted to Rec.709');
      } else {
        // Ordinary Rec.709 that merely happens to be 10-bit. Nothing to
        // convert: the format step at the end of the chain drops the depth,
        // and pretending this was BT.2020 would wreck the colour.
        notes.add('10-bit source reduced to 8-bit');
      }
    }

    if (preset.denoiseStrength > 0 && !canDenoise) {
      notes.add('this build has no hqdn3d filter — denoise skipped');
    }
    if (preset.sharpenAmount > 0 && !canSharpen) {
      notes.add('this build has no unsharp filter — pre-sharpening skipped');
    }

    if (preset.denoiseStrength > 0 && canDenoise) {
      final d = preset.denoiseStrength;
      // Every option is named. Positional filter arguments are accepted by
      // FFmpeg 9 on the desktop but rejected outright by the FFmpeg 8 build
      // that ships on the phone — "No option name near '1.00:0.75...'" — so
      // shorthand works everywhere it is tested and fails everywhere it ships.
      // Chroma and temporal are kept gentler: temporal denoising smears
      // handheld footage.
      filters.add('hqdn3d='
          'luma_spatial=${_f(d)}:'
          'chroma_spatial=${_f(d * 0.75)}:'
          'luma_tmp=${_f(d * 1.5)}:'
          'chroma_tmp=${_f(d * 1.5)}');
    }
    if (spec.padToCanvas) {
      filters.add('scale=w=$outW:h=$outH:'
          'force_original_aspect_ratio=decrease:flags=${preset.scaler}');
      filters.add(
          'pad=width=$outW:height=$outH:x=(ow-iw)/2:y=(oh-ih)/2');
    } else if (scaled2) {
      filters.add('scale=width=$outW:height=$outH:flags=${preset.scaler}');
    }
    // Non-square pixels have to be normalised or the scale above stretches the
    // picture. Harmless on the 1:1 footage that makes up almost everything.
    if (source.hasOddSampleAspect) {
      filters.add('setsar=sar=1');
      notes.add('non-square pixels (${source.sampleAspectRatio}) normalised');
    }
    if (preset.sharpenAmount > 0 && canSharpen) {
      // A moderate 5x5 kernel; the amount does the work. Chroma is left alone
      // because sharpening chroma produces coloured fringing that costs bits.
      filters.add('unsharp='
          'luma_msize_x=5:luma_msize_y=5:'
          'luma_amount=${_f(preset.sharpenAmount)}:'
          'chroma_msize_x=5:chroma_msize_y=5:chroma_amount=0');
    }
    filters.add('format=pix_fmts=${spec.pixelFormat}');

    // Audio is decided here rather than in the command builder so the reason
    // ends up in the notes, where a user can see why their clip lost its sound.
    final AudioHandling audioHandling;
    if (!source.hasAudio) {
      audioHandling = AudioHandling.drop;
    } else if (audioEncoder != null) {
      audioHandling = AudioHandling.encode;
    } else if ((source.audioCodec ?? '').contains('aac')) {
      audioHandling = AudioHandling.copy;
      notes.add('no AAC encoder in this build — audio stream-copied intact');
    } else {
      audioHandling = AudioHandling.drop;
      notes.add('no AAC encoder, and the source audio is '
          '${source.audioCodec} — audio had to be dropped');
    }

    return ConformPlan(
      source: source,
      preset: preset,
      encoder: encoder,
      outputWidth: outW,
      outputHeight: outH,
      fps: fps,
      videoBitrateKbps: bitrate,
      gopFrames: math.max(1, (fps * spec.gopSeconds).round()),
      filterChain: filters.join(','),
      audioHandling: audioHandling,
      audioEncoderName: audioEncoder,
      scaled: scaled2,
      toneMapped: toneMapped,
      sourceIsHdr: source.isHdr || source.isTenBit,
      notes: notes,
    );
  }

  /// Same plan, different audio decision. Used by the retry ladder when an
  /// encode fails for reasons that point at the audio stream.
  ConformPlan withAudio(AudioHandling handling) => ConformPlan(
        source: source,
        preset: preset,
        encoder: encoder,
        outputWidth: outputWidth,
        outputHeight: outputHeight,
        fps: fps,
        videoBitrateKbps: videoBitrateKbps,
        gopFrames: gopFrames,
        filterChain: filterChain,
        audioHandling: handling,
        audioEncoderName: audioEncoderName,
        scaled: scaled,
        toneMapped: toneMapped,
        sourceIsHdr: sourceIsHdr,
        notes: notes,
      );

  /// H.264 requires even dimensions under 4:2:0 chroma subsampling; an odd
  /// number here fails the encode outright rather than degrading.
  static int _even(int v) => v.isEven ? math.max(2, v) : math.max(2, v - 1);

  static String _f(double v) => v.toStringAsFixed(2);

  @override
  String toString() => '${preset.id}: ${outputWidth}x$outputHeight '
      '@${fps.toStringAsFixed(2)} ${videoBitrateKbps}kbps [$filterChain]';
}
