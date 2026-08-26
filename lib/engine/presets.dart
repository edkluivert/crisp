import 'target_spec.dart';

/// The starting hypotheses.
///
/// These bitrates and pixel caps are informed guesses, not measurements —
/// WhatsApp publishes none of it and the numbers drift between releases. That
/// is the point of the calibration harness: race them against a real round
/// trip and let the winner be an observed fact rather than folklore. Expect
/// this list to be edited, and expect the winner to change.
class CrispPresets {
  const CrispPresets._();

  /// Posting straight from the gallery. Everything else has to beat this.
  static const control = Preset.control();

  /// Full-height vertical at a bitrate high enough that we are clearly not the
  /// bottleneck. If WhatsApp accepts 1080p, this establishes the ceiling.
  static const hd1080Rich = Preset(
    id: 'hd1080_rich',
    label: '1080p, rich',
    rationale: 'Tests whether WhatsApp keeps 1080p at all, and what it does to '
        'a stream more generous than its own ceiling.',
    spec: TargetSpec(
      maxLongEdge: 1920,
      maxShortEdge: 1080,
      videoBitrateKbps: 4500,
    ),
  );

  /// The same geometry at a bitrate close to what a 1080p ceiling would plausibly
  /// be. If the rich variant gets mangled and this one does not, the ceiling
  /// sits between them.
  static const hd1080Matched = Preset(
    id: 'hd1080_matched',
    label: '1080p, matched',
    rationale: 'Aimed just under a plausible 1080p ceiling, so the downstream '
        're-encode has as little to change as possible.',
    spec: TargetSpec(
      maxLongEdge: 1920,
      maxShortEdge: 1080,
      videoBitrateKbps: 2800,
    ),
  );

  /// Pre-filtered version of the matched preset. Isolates how much the unsharp
  /// and denoise passes are worth once bitrate is held constant.
  static const hd1080Tuned = Preset(
    id: 'hd1080_tuned',
    label: '1080p, tuned',
    rationale: 'Matched bitrate plus denoise and pre-sharpen. Measures what the '
        'pre-filtering alone buys, with geometry and bitrate held constant.',
    spec: TargetSpec(
      maxLongEdge: 1920,
      maxShortEdge: 1080,
      videoBitrateKbps: 2800,
    ),
    sharpenAmount: 0.6,
    denoiseStrength: 1.0,
  );

  /// If WhatsApp caps Status at 720p, handing it 720p means it has no reason to
  /// rescale, and rescaling is the single most destructive thing it does.
  static const hd720Matched = Preset(
    id: 'hd720_matched',
    label: '720p, matched',
    rationale: 'Assumes a 720p Status cap. Arriving pre-sized removes the '
        'rescale entirely.',
    spec: TargetSpec(
      maxLongEdge: 1280,
      maxShortEdge: 720,
      videoBitrateKbps: 2200,
    ),
  );

  static const hd720Tuned = Preset(
    id: 'hd720_tuned',
    label: '720p, tuned',
    rationale: 'The 720p bet with pre-filtering. Sharpening is more aggressive '
        'here because downscaling softens before the encoder even starts.',
    spec: TargetSpec(
      maxLongEdge: 1280,
      maxShortEdge: 720,
      videoBitrateKbps: 2200,
    ),
    sharpenAmount: 0.9,
    denoiseStrength: 1.5,
  );

  /// Aimed at the gap: full 1080p, but at a bitrate modest enough that a
  /// pass-through rule would plausibly wave it through untouched. This is the
  /// preset that wins if — and only if — the pass-through zone is real.
  static const hd1080Edge = Preset(
    id: 'hd1080_edge',
    label: '1080p, at the threshold',
    rationale: 'Full resolution at a deliberately modest bitrate, aiming to '
        'land inside a pass-through zone rather than trigger a re-encode.',
    spec: TargetSpec(
      maxLongEdge: 1920,
      maxShortEdge: 1080,
      videoBitrateKbps: 2300,
    ),
    sharpenAmount: 0.5,
    denoiseStrength: 1.0,
  );

  /// Deliberately frugal. If a lean file scores as well as a rich one, the
  /// ceiling is low and every extra bit we send is thrown away — which would
  /// make the product mostly about geometry and pre-filtering, not bitrate.
  static const hd720Lean = Preset(
    id: 'hd720_lean',
    label: '720p, lean',
    rationale: 'Well under any plausible ceiling. Tests whether sending less '
        'survives better than sending more.',
    spec: TargetSpec(
      maxLongEdge: 1280,
      maxShortEdge: 720,
      videoBitrateKbps: 1400,
    ),
    sharpenAmount: 0.9,
    denoiseStrength: 1.5,
  );

  /// Folk recipe B, from a circulating Windows .bat "HD Status Optimizer":
  /// CRF 18 under a 4 Mbps ceiling, high profile, level 4.1. Note that it
  /// directly contradicts folk recipe A (hd720Web) on profile — one of them
  /// is wrong, and only the race can say which. Desktop harness only: the
  /// phone's hardware encoders cannot do CRF, so if this wins, the app
  /// approximates it with bitrate targeting.
  static const hd1080CrfCap = Preset(
    id: 'hd1080_crf_cap',
    label: '1080p, CRF capped',
    rationale: 'Folk recipe B: quality-targeted CRF 18 held under a 4 Mbps '
        'ceiling. Races the claim that Status rewards this exact shape.',
    spec: TargetSpec(
      maxLongEdge: 1920,
      maxShortEdge: 1080,
      videoBitrateKbps: 4000,
      rateMode: RateMode.quality,
      crf: 18,
      level: '4.1',
      maxrateKbpsOverride: 4000,
      bufsizeKbpsOverride: 8000,
      audio: AudioSpec(bitrateKbps: 160),
    ),
  );

  /// Identical to hd1080Rich in every respect except the H.264 profile.
  /// If WhatsApp keys any gentler treatment on profile (the recurring
  /// "already web-optimized" folklore), this pair is the experiment that
  /// shows it: same geometry, same bitrate, only the profile differs.
  static const hd1080Baseline = Preset(
    id: 'hd1080_baseline',
    label: '1080p, baseline profile',
    rationale: 'A/B against hd1080_rich: identical 4500 kbps and geometry, '
        'baseline profile instead of high. Any score gap is the profile.',
    spec: TargetSpec(
      maxLongEdge: 1920,
      maxShortEdge: 1080,
      videoBitrateKbps: 4500,
      profile: 'baseline',
    ),
  );

  /// The commonly-circulated "WhatsApp preferred" envelope, verbatim:
  /// baseline profile, 720p, mid-3s bitrate, AAC. Exists so the folklore is
  /// tested rather than argued about.
  static const hd720Web = Preset(
    id: 'hd720_web',
    label: '720p, web envelope',
    rationale: 'The folk recipe (baseline, 720p, ~3.5 Mbps) as commonly '
        'circulated. Raced so the claim gets measured, not repeated.',
    spec: TargetSpec(
      maxLongEdge: 1280,
      maxShortEdge: 720,
      videoBitrateKbps: 3500,
      profile: 'baseline',
    ),
  );

  /// What ships for the self-chat route.
  ///
  /// On this route WhatsApp's chat-HD encoder re-encodes whatever it is
  /// handed, and that pass is unavoidable — so the worst thing Crisp can do
  /// is compress first and stack two lossy generations. The job here is a
  /// mezzanine: normalise what WhatsApp handles badly (HDR colour, sloppy
  /// downscaling from 4K) at a bitrate high enough to be visually lossless,
  /// and let chat-HD make the one real compression from an ideal input.
  /// wa_spec below remains the target for any route where the file reaches
  /// WhatsApp without a further encode (a bot upload, as WAstatus does).
  static const mezzanine = Preset(
    id: 'mezzanine',
    label: 'Mezzanine',
    rationale: 'Near-lossless 1080p intermediate: fixes HDR and geometry, '
        'leaves the real compression to the single WhatsApp encode.',
    spec: TargetSpec(
      maxLongEdge: 1920,
      maxShortEdge: 1080,
      // High enough that this generation is invisible; clamped to the source
      // bitrate by the planner, so small files are not inflated.
      videoBitrateKbps: 10000,
      profile: 'high',
      level: '4.0',
    ),
  );

  /// The proven spec, mirrored from github.com/Shamanthnp1/WAstatus — a
  /// service whose output was verified to survive Status cleanly. Their
  /// encode: libx264 CRF 23 capped at 3800k/5700k, exact 1080x1920 padded
  /// canvas, high profile level 4.0, GOP 250, 601 colour tags, sei stripped,
  /// isom brand, faststart, AAC 128k 44.1kHz stereo.
  ///
  /// The one thing the phone cannot copy is CRF — the hardware encoders only
  /// take bitrate targets — so the target sits where CRF 23 typically lands
  /// on phone footage, under the same 3800k ceiling. The desktop harness
  /// races the exact CRF form as hd1080_crf_cap.
  static const waSpec = Preset(
    id: 'wa_spec',
    label: 'WhatsApp spec',
    rationale: 'Mirrors a verified-working service: same canvas, ceiling, '
        'profile, GOP and colour tags, so WhatsApp sees the file shape its '
        'own encoder produces.',
    spec: TargetSpec(
      maxLongEdge: 1920,
      maxShortEdge: 1080,
      videoBitrateKbps: 3400,
      maxrateKbpsOverride: 3800,
      bufsizeKbpsOverride: 5700,
      profile: 'high',
      level: '4.0',
      // 250 frames at 30fps. Long GOPs spend fewer bits on keyframes, and
      // the proven spec shows Status does not need the short-GOP insurance.
      gopSeconds: 8.33,
      padToCanvas: true,
      colorPrimaries: 'bt470bg',
      colorMatrix: 'bt470bg',
    ),
  );

  /// What the app ships.
  ///
  /// Unlike the presets above it names no bitrate to hit — only a ceiling. The
  /// figure that matters is derived from the clip's length against the size
  /// cap, because that is the constraint WhatsApp actually enforces. Geometry
  /// follows the bitrate rather than the other way round: a sharp 720p beats a
  /// mushy 1080p at the same file size.
  static const adaptive = Preset(
    id: 'adaptive',
    label: 'Adaptive',
    rationale: 'Spends as much of the 16MB Status budget as the clip length '
        'allows, then picks the largest frame that bitrate can carry.',
    spec: TargetSpec(
      maxLongEdge: 1920,
      maxShortEdge: 1080,
      // A ceiling, not a target. Held at the top of WhatsApp's own observed
      // envelope (~3.5-5 Mbps): a stream that arrives above the ceiling it
      // enforces guarantees a harsh re-encode, so bits past this point are
      // worse than wasted.
      videoBitrateKbps: 5000,
      // Matches the profile WhatsApp's own encoder emits. Costs efficiency
      // versus high (no CABAC, no B-frames) - raced against high-profile
      // presets below so calibration can overturn it.
      profile: 'baseline',
      spendBudget: true,
    ),
    sharpenAmount: 0.4,
    denoiseStrength: 0.8,
  );

  /// Everything raced in a standard calibration run, control first.
  static const List<Preset> all = [
    control,
    hd1080Rich,
    hd1080Matched,
    hd1080Tuned,
    hd1080Edge,
    hd720Matched,
    hd720Tuned,
    hd720Lean,
    hd1080Baseline,
    hd720Web,
    hd1080CrfCap,
    waSpec,
  ];

  static Preset? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}
