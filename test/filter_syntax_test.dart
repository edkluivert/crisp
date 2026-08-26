import 'package:crisp/engine/conform_plan.dart';
import 'package:crisp/engine/image_spec.dart';
import 'package:crisp/engine/media_info.dart';
import 'package:crisp/engine/presets.dart';
import 'package:crisp/engine/whatsapp_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards a bug that reached a real device.
///
/// Filter arguments can be written positionally (`hqdn3d=1:0.75:1.5:1.5`) or by
/// name (`hqdn3d=luma_spatial=1:...`). FFmpeg 9, which is what a developer's
/// desktop is likely to have, accepts both. The FFmpeg 8 build that ships
/// inside the app rejects the positional form outright — "No option name near
/// '1.00:0.75:1.50:1.50'" — so shorthand passes every local test and then fails
/// on every phone.
///
/// There is no way to catch that by running the desktop binary, because the
/// desktop binary is not the one that matters. So the rule is asserted against
/// the strings themselves.
extension on MediaInfo {
  MediaInfo copyForDuration(Duration d) => MediaInfo(
        width: width,
        height: height,
        fps: fps,
        duration: d,
        videoCodec: videoCodec,
        rotation: rotation,
        sizeBytes: (d.inMilliseconds / 1000 * 12000000 / 8).round(),
        videoBitrate: videoBitrate,
        audioCodec: audioCodec,
        pixelFormat: pixelFormat,
        colorPrimaries: colorPrimaries,
        colorTransfer: colorTransfer,
        sampleAspectRatio: sampleAspectRatio,
      );
}

void main() {
  /// Every `:`-separated argument of every filter must be `name=value`.
  void expectFullyNamed(String chain, {required String because}) {
    for (final filter in chain.split(',')) {
      if (filter.isEmpty) continue;
      final eq = filter.indexOf('=');
      if (eq < 0) continue; // a filter with no arguments at all, e.g. `null`

      final name = filter.substring(0, eq);
      final args = filter.substring(eq + 1);

      for (final arg in args.split(':')) {
        expect(
          arg.contains('='),
          isTrue,
          reason: 'Filter "$name" uses a positional argument "$arg" in:\n'
              '  $chain\n'
              'FFmpeg 8 on the phone rejects positional filter options. '
              'Write it as name=value. ($because)',
        );
      }
    }
  }

  MediaInfo source({
    int width = 1080,
    int height = 1920,
    String pixelFormat = 'yuv420p',
    String? primaries,
    String? transfer,
    String sar = '1:1',
  }) =>
      MediaInfo(
        width: width,
        height: height,
        fps: 30,
        duration: const Duration(seconds: 10),
        videoCodec: 'h264',
        rotation: 0,
        sizeBytes: 20 * 1024 * 1024,
        videoBitrate: 12000000,
        audioCodec: 'aac',
        pixelFormat: pixelFormat,
        colorPrimaries: primaries,
        colorTransfer: transfer,
        sampleAspectRatio: sar,
      );

  group('video filter chains are fully named', () {
    for (final preset in CrispPresets.all.where((p) => !p.passthrough)) {
      test(preset.id, () {
        final plan = ConformPlan.build(
          source: source(),
          preset: preset,
          encoder: VideoEncoder.mediaCodec,
        );
        expectFullyNamed(plan.filterChain, because: 'preset ${preset.id}');
      });
    }

    test('downscaling path', () {
      final plan = ConformPlan.build(
        source: source(width: 2160, height: 3840),
        preset: CrispPresets.hd720Tuned,
        encoder: VideoEncoder.mediaCodec,
      );
      expect(plan.filterChain, contains('scale=width='));
      expectFullyNamed(plan.filterChain, because: 'a 4K source is downscaled');
    });

    test('non-square pixels', () {
      final plan = ConformPlan.build(
        source: source(sar: '2:1'),
        preset: CrispPresets.hd1080Edge,
        encoder: VideoEncoder.mediaCodec,
      );
      expect(plan.filterChain, contains('setsar=sar=1'));
      expectFullyNamed(plan.filterChain, because: 'anamorphic source');
    });

    test('wide-gamut conversion', () {
      final plan = ConformPlan.build(
        source: source(pixelFormat: 'yuv420p10le', primaries: 'bt2020'),
        preset: CrispPresets.hd1080Edge,
        encoder: VideoEncoder.mediaCodec,
      );
      expectFullyNamed(plan.filterChain, because: 'BT.2020 source');
    });

    test('HDR tone mapping', () {
      final plan = ConformPlan.build(
        source: source(
          pixelFormat: 'yuv420p10le',
          primaries: 'bt2020',
          transfer: 'smpte2084',
        ),
        preset: CrispPresets.hd1080Edge,
        encoder: VideoEncoder.mediaCodec,
        canToneMap: true,
      );
      expectFullyNamed(plan.filterChain, because: 'PQ source is tone-mapped');
    });
  });

  group('image filter chains are fully named', () {
    for (final preset in CrispImagePresets.all.where((p) => !p.passthrough)) {
      test(preset.id, () {
        final args = ImageCommand.conform(
          source: source(width: 4032, height: 3024),
          preset: preset,
          inputPath: 'in.jpg',
          outputPath: 'out.jpg',
        );
        final chain = args[args.indexOf('-vf') + 1];
        expectFullyNamed(chain, because: 'image preset ${preset.id}');
      });
    }
  });

  group('capability guards', () {
    test('denoise is skipped, and said so, when the filter is missing', () {
      final plan = ConformPlan.build(
        source: source(),
        preset: CrispPresets.hd720Tuned,
        encoder: VideoEncoder.mediaCodec,
        canDenoise: false,
      );
      expect(plan.filterChain, isNot(contains('hqdn3d')));
      expect(plan.notes.any((n) => n.contains('hqdn3d')), isTrue);
    });

    test('sharpening is skipped when the filter is missing', () {
      final plan = ConformPlan.build(
        source: source(),
        preset: CrispPresets.hd720Tuned,
        encoder: VideoEncoder.mediaCodec,
        canSharpen: false,
      );
      expect(plan.filterChain, isNot(contains('unsharp')));
      expect(plan.notes.any((n) => n.contains('unsharp')), isTrue);
    });
  });

  group('audio handling', () {
    test('stream copy when no encoder is available and source is AAC', () {
      final plan = ConformPlan.build(
        source: source(),
        preset: CrispPresets.hd1080Edge,
        encoder: VideoEncoder.mediaCodec,
      );
      expect(plan.audioHandling, AudioHandling.copy);
    });

    test('encodes when an encoder is available', () {
      final plan = ConformPlan.build(
        source: source(),
        preset: CrispPresets.hd1080Edge,
        encoder: VideoEncoder.mediaCodec,
        audioEncoder: 'aac',
      );
      expect(plan.audioHandling, AudioHandling.encode);
      expect(plan.audioEncoderName, 'aac');
    });
  });

  group('size budget', () {
    const model = WhatsAppModel.adaptiveGuess;

    /// The cap is the constraint that actually decides quality, so the planner
    /// must never produce a file that exceeds it — a file over the cap is
    /// re-encoded by WhatsApp regardless of how carefully it was conformed.
    void expectWithinCap(Duration clip) {
      final plan = ConformPlan.build(
        source: source().copyForDuration(clip),
        preset: CrispPresets.adaptive,
        encoder: VideoEncoder.mediaCodec,
        budgetKbps: model.videoBitrateBudgetKbps(clip),
        clipDuration: clip,
        audioEncoder: 'aac',
      );
      final bytes =
          (plan.videoBitrateKbps + 128) * 1000 * clip.inSeconds / 8;
      expect(
        bytes,
        lessThanOrEqualTo(model.maxFileSizeBytes.toDouble()),
        reason: '${clip.inSeconds}s at ${plan.videoBitrateKbps}kbps is '
            '${(bytes / 1048576).toStringAsFixed(1)}MB, over the 16MB cap',
      );
    }

    for (final secs in [10, 15, 30, 45, 60, 90]) {
      test('${secs}s stays inside the 16MB cap', () {
        expectWithinCap(Duration(seconds: secs));
      });
    }

    test('short clips spend the budget instead of under-shooting', () {
      final clip = const Duration(seconds: 10);
      final plan = ConformPlan.build(
        source: source().copyForDuration(clip),
        preset: CrispPresets.adaptive,
        encoder: VideoEncoder.mediaCodec,
        budgetKbps: model.videoBitrateBudgetKbps(clip),
        clipDuration: clip,
        audioEncoder: 'aac',
      );
      // The old behaviour capped everything at 2300kbps and then stepped down
      // to 720p — throwing away most of the budget on the clips that could
      // most afford to use it.
      expect(plan.videoBitrateKbps, greaterThan(4000));
      expect(plan.outputHeight, 1920);
    });

    test('long clips step down rather than smear', () {
      final clip = const Duration(seconds: 90);
      final plan = ConformPlan.build(
        source: source().copyForDuration(clip),
        preset: CrispPresets.adaptive,
        encoder: VideoEncoder.mediaCodec,
        budgetKbps: model.videoBitrateBudgetKbps(clip),
        clipDuration: clip,
        audioEncoder: 'aac',
      );
      expect(plan.outputHeight, lessThan(1920));
    });

    test('splitting is what buys quality back', () {
      // The same 90 seconds, as three clips instead of one.
      final whole = model.videoBitrateBudgetKbps(const Duration(seconds: 90));
      final third = model.videoBitrateBudgetKbps(const Duration(seconds: 30));
      expect(third, greaterThan(whole * 2));
    });

    test('clip counts follow the 90 second limit', () {
      expect(model.clipCountFor(const Duration(seconds: 60)), 1);
      expect(model.clipCountFor(const Duration(seconds: 90)), 1);
      expect(model.clipCountFor(const Duration(seconds: 91)), 2);
      expect(model.clipCountFor(const Duration(minutes: 5)), 4);
    });
  });

  group('hardware encoders', () {
    test('no -level is sent to encoders that reject it', () {
      expect(VideoEncoder.mediaCodec.acceptsLevelFlag, isFalse);
      expect(VideoEncoder.videoToolbox.acceptsLevelFlag, isFalse);
      expect(VideoEncoder.x264.acceptsLevelFlag, isTrue);
    });
  });
}
