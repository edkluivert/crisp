# Crisp

Post HD photos and video to WhatsApp Status without it turning to mush.

## The premise, stated accurately

You cannot bypass WhatsApp's compressor. It re-encodes every Status upload
on-device before anything leaves the phone, and there is no flag, header or
container trick that opts out. (Sending as a document preserves originals in
*chats*, but Status accepts only photos and videos, so that route is closed.)

What Crisp does instead is **pre-conform**: hand WhatsApp a file already in the
shape it wants, so its transform becomes close to a no-op. The compressor does
its worst damage when it has to *change* things — downscale 4K, resample 12MP,
convert a codec, cut a bitrate tenfold. Every one of those is lossy and they
compound. Arrive pre-sized, pre-coded and pre-rated and there is little left
for it to do.

A second lever matters nearly as much: **pre-compensating for known damage**.
The encoder softens fine detail and eats sensor noise expensively. A light
denoise before scaling and a measured unsharp afterwards survive the round trip
and land sharper than an untouched original would.

## The question the whole product rests on

Pre-conforming only helps if WhatsApp's pipeline is **adaptive** — if a file
already inside its limits is passed through, or re-encoded more gently. If the
pipeline is **fixed**, and every upload gets the same treatment regardless,
then our encode is merely a wasted extra generation of loss before the same
crush lands anyway, and pre-processing can only make things worse.

Both theories are implemented in the harness, and they give opposite answers.
Same source, same presets, the only difference being which theory is simulated:

| Preset | adaptive theory | fixed theory |
|---|---|---|
| `hd1080_edge` | **+1.80 dB** | −0.60 dB |
| `hd720_matched` | +0.28 dB | −0.18 dB |
| `control` (untouched) | — | — |
| `hd720_lean` | −0.91 dB | −1.03 dB |

*(SSIM in dB versus posting the original untouched. Simulated, not measured —
see below.)*

In the adaptive world there is a large, easy win. In the fixed world **there is
no product**, and the honest thing would be to say so rather than ship a
placebo. Everything else — UI, presets, tuning — is downstream of settling
this, which is why the harness was built before a single screen.

Settling it requires a real round trip. Nothing in this repo can answer it, and
no amount of reasoning substitutes for the measurement.

## Layout

```
lib/app/theme.dart   dark surface, one accent
lib/services/        workspace scratch space, share + gallery handoff
lib/features/
  session/             the state machine: pick -> preview -> share
  compare/             the comparison screen
lib/widgets/
  compare_slider.dart  draggable divider over two aligned panes
lib/engine/          pure Dart, zero Flutter imports
  media_info.dart      what a file actually is (ffprobe JSON)
  target_spec.dart     the shape we want it in; presets as hypotheses
  presets.dart         the candidates to race
  conform_plan.dart    source + preset -> concrete dimensions and bitrate
  ffmpeg_command.dart  builds argument lists, runs nothing
  ffmpeg_runner.dart   the one seam between pipeline and platform
  metrics.dart         SSIM/PSNR parsing
  pipeline.dart        probe, conform, measure
  io/process_runner.dart  desktop only — real binaries, real processes
tool/calibrate.dart  the harness
```

The engine imports no Flutter, deliberately. The desktop harness and the phone
run byte-identical argument lists through the same planner; only `FfmpegRunner`
differs — `Process` on desktop, FFmpegKit on device. If those two diverged,
calibrating on a Mac would tell us nothing about what ships.

Presets are **hypotheses, not settings**. The bitrates and pixel caps in
`presets.dart` are informed guesses; WhatsApp publishes none of it and the
numbers drift between releases. They exist to be raced, and the winner is
expected to change.

## The forward route

A second discovery changes the product's shape. Status posts go through
WhatsApp's harshest compressor, but **forwarded media re-uses the already
uploaded file untouched** — which is why forwards are instant on bad networks.
The commercial "HD status" services exploit exactly this: a server-side bot
sends your video back to you in a chat, and you forward it to My status. The
Status compressor never runs.

The same route needs no server: send the file to your own chat ("Message
yourself", HD quality on), then long-press it and Forward -> My status. The
file passes through the far gentler chat-HD encoder once, and the forward
re-uses that upload as-is. Crisp's pre-conform makes the chat-HD encode close
to a no-op, so the pipeline becomes:

    Crisp conform -> self-chat (HD) -> forward to Status

`HdRouteSheet` walks the user through the two taps, and "Post in HD" on the
compare screen is that flow. The plain share remains as a fallback.

Like everything else here, the forward claim is a **hypothesis until a round
trip confirms it** — post the same clip both ways and view from a second
device. If forwarding turns out to re-encode after all, the sheet comes out
and the plain share goes back to primary.

## The app

Pick a photo or video, and Crisp shows a **damage forecast** rather than a
preview of its own output. That distinction is the whole design.

A preview of what Crisp produces would show the user almost nothing: the output
is meant to look like the source, so a before/after against the original is a
comparison of two near-identical images, and the honest conclusion a user would
draw is that the app does nothing. The value only appears *after* WhatsApp has
had its way with the file — precisely when comparing is no longer possible.

So the comparison screen shows three states, two at a time under a draggable
divider:

| | |
|---|---|
| Your original | the source, untouched |
| Posted directly | what WhatsApp does if you post it yourself |
| With Crisp | what WhatsApp does to our conformed file |

The middle one is the point. We are showing the harm being avoided, not
claiming to have sharpened anyone's video.

Two consequences fall out of that:

* **The forecast is labelled as a forecast.** It comes from
  `WhatsAppModel`, whose numbers are assumptions until calibration replaces
  them. Every screen that shows modelled output carries a notice saying so, and
  it disappears only when `WhatsAppModel.calibrated` becomes true. Presenting a
  guess as a measurement is the one thing this product cannot afford.
* **Only a slice is previewed.** Three encodes of a two-minute clip is a wait
  nobody sits through, so the preview uses a few lossless seconds from the
  middle. The full-length encode starts *after* the preview is on screen, so
  the user spends the wait looking at the result and can back out before
  paying for it.

Sharing is a handoff, not an integration: neither platform exposes an API for
posting to Status, so the app opens the system share sheet and the user picks
WhatsApp, then "My status". Saving to the gallery is an equal-weight second
option, not a fallback.

## Running the harness

```bash
brew install ffmpeg                        # needs ffmpeg + ffprobe on PATH

dart tool/calibrate.dart presets           # what each preset is testing
dart tool/calibrate.dart synth             # synthetic clips per failure mode
dart tool/calibrate.dart prepare <video>   # one conformed file per preset
dart tool/calibrate.dart score <runDir>    # rank what survived
```

`simulate` fills the inbox from a guessed model of WhatsApp, for screening
presets without burning real Status posts:

```bash
dart tool/calibrate.dart simulate <runDir> --profile adaptive
dart tool/calibrate.dart simulate <runDir> --profile fixed
```

Simulated runs drop a `SIMULATED.txt` marker and every report generated from
one says so at the top. They prove nothing about the real product; they only
show which theory a preset set would win in.

### The real loop

1. `prepare` a source — ideally real footage, high bitrate, more than 1080p.
2. Post every file in `outbox/` to Status.
3. **View them from a second device** and save what it received.
4. Drop those into `inbox/`, named after their preset.
5. `score` the run.

Step 3 is not optional pedantry. What matters is what a *viewer* receives, not
what your own phone kept locally — different files. Scoring the local copy
would flatter every preset equally and teach us nothing.

## Awkward sources

Real footage fails in ways synthetic clips do not, and each of these was a
genuine bug rather than a hypothetical:

| Source trait | What went wrong | What happens now |
|---|---|---|
| 10-bit HDR (iPhone default) | Stamped `bt709` on BT.2020 content, so players acted on a lie | Detected; converted when possible, otherwise passed through untagged and reported |
| PQ / HLG transfer | — | Cannot be tone-mapped without `zscale`, which the minimal build lacks. Encodes correctly, colour left as-is, and the UI says so |
| Wide gamut, ordinary curve | Same mis-tagging | Converted with `colorspace` (a core filter — note the value is `bt2020`, not `bt2020-10`, which the filter rejects) |
| Non-square pixels | Scaling stretched the picture | `setsar=1` when SAR is not 1:1 |
| Long keyframe interval | Stream-copied slices ran to the end of the GOP — a 4s request returning 8s, doubling three encodes | Length checked against a tolerance; re-encoded exactly when copy overshoots |
| Any file where copy produces junk | ffmpeg exits zero on some unusable output, so the failure surfaced later and confusingly | Slice is probed and validated, with a re-encode fallback |
| 1080p+ on hardware encoders | `-level 4.0` rejected outright | `-level` only sent to encoders that accept it |
| Audio the build cannot encode | Whole conform died with "conversion failed" and the file was lost | Encoder detected, not assumed; falls back to stream copy, then to silence |
| Any file at all, on Android | Positional filter options were rejected by the phone's FFmpeg 8 while the desktop's FFmpeg 9 accepted them | Every filter argument is written `name=value`, enforced by a test |

`dart tool/calibrate.dart slice <video>` reproduces the sample-extraction step
alone and reports which path it took. It is the first thing to run when a
particular video misbehaves.

Failures carry the file's own characteristics — resolution, codec, pixel
format, bit depth, rotation, SAR — because almost every failure here is caused
by something unusual about the source, and the exception alone does not say
which.

## Android build notes

**`permission_handler` is held at 12, not 13.** Version 13 requires callers to
compile against API 37, which is still a *codename* SDK — the resulting APK
carries `compileSdkVersionCodename`, and shipping against an unreleased platform
is a distribution risk for no benefit. Version 12 needs only 36, which is
Flutter's default, so `compileSdk` stays inherited. `minSdk` is held at 24 for
ffmpeg-kit.

**Ship an App Bundle, not a universal APK.** ffmpeg's native libraries are
per-architecture, and a universal APK stacks all three:

| Build | Size |
|---|---|
| Universal APK | 105 MB |
| arm64-v8a only | 33 MB |
| armeabi-v7a only | 42 MB |
| x86_64 only | 34 MB |

An AAB lets Play deliver only the slice a device needs, so the real download is
about 33 MB. `--split-per-abi` does the same for direct distribution. A 105 MB
universal APK would also sit close to Play's limit for no benefit to anyone.

R8 is safe: the plugin ships `consumer-rules.pro`, so the JNI classes survive
minification. A release build was verified, not assumed.

**One future risk:** `ffmpeg_kit_flutter_new_min` still applies the Kotlin
Gradle Plugin, which Flutter has announced it will stop supporting. It builds
today and warns loudly. Worth watching, since this is the dependency the whole
product rests on.

## Audio

`-c:a aac` was hardcoded, which assumes an encoder the bundled build may not
have. It is detected now, exactly like the video encoder — and the matching is
exact rather than by substring, because `aac` is a substring of both `aac_at`
and `libfdk_aac`, and a build claiming a codec it lacks fails later and more
confusingly than one that admits it.

Detection alone is not enough, because an encoder that exists can still refuse a
particular stream. So a failing conform retries down a ladder:

1. **encode** with whatever AAC encoder was found
2. **stream copy** — lossless and free, and phone audio is nearly always
   already AAC
3. **drop the audio** and keep the video

The picture is the product; losing a whole file over its soundtrack is the
wrong trade. Whichever rung it lands on is recorded in the notes shown on the
comparison screen, so a silent clip is explained rather than mysterious.

## The desktop binary is not the one that ships

This is the trap the project keeps falling into, so it is worth stating plainly:
**the ffmpeg you develop against is not the ffmpeg your users run.**

| | version | zscale | notes |
|---|---|---|---|
| macOS desktop | FFmpeg 9 (Lavc63) | no | `h264_videotoolbox`, `aac_at` |
| iOS build | FFmpeg 8 (Lavc62) | no | `h264_videotoolbox`, `aac` |
| Android build | FFmpeg 8 (Lavc62) | no | `h264_mediacodec`, `aac` |

The version gap is not cosmetic. FFmpeg 9 accepts positional filter arguments
(`hqdn3d=1:0.75:1.5:1.5`); FFmpeg 8 rejects them outright with *"No option name
near '1.00:0.75:1.50:1.50'"*. So the shorthand passed every desktop test and
failed on every phone — the calibration harness could not have caught it, because
the harness runs the wrong binary by construction.

Two defences, since the first one alone would not have worked:

1. **Every filter argument is named**, everywhere — video, image, and simulator.
2. **`test/filter_syntax_test.dart` asserts it** against the generated strings
   rather than by running anything, because running the desktop binary is
   exactly what fails to reproduce the problem. It caught a second instance
   immediately: `tonemap=hable` is positional, and has to be
   `tonemap=tonemap=hable`.

Capabilities are probed rather than assumed for the same reason — encoders,
audio encoders, and now filters. `hqdn3d` and `unsharp` are enhancements: if a
build lacks them they are skipped with a note, never failed over.

## Diagnostics

"Conversion failed" on its own is unactionable, so every ffmpeg and ffprobe
invocation goes through `RecordingRunner` — a decorator on the `FfmpegRunner`
seam, which means both the device and desktop runners get it for free and the
engine above the seam stays unaware.

The report is reachable two ways: a **View error report** button on the failure
screen, and by tapping the encoder line on the home screen (for hangs, or a
result that looks wrong without failing). It contains:

- what the build can do — video encoder, audio encoder, tone mapping, and the
  full list of h264/aac encoders present
- the source file's characteristics — resolution, codec, pixel format, bit
  depth, rotation, SAR, duration, audio codec
- the failure message and detail
- **the exact command that failed**, and the last 25 meaningful lines ffmpeg
  emitted before giving up
- a one-line summary of every call in the session, with timings

Paths are reduced to their filename: the name is what makes a failure
reproducible, the directory tree above it is nobody's business. Progress lines
are stripped, and stderr is kept only for calls that failed — a successful
encode emits hundreds of lines and none are worth storing.

Sharing sends it as a file rather than message text, because these reports run
long enough that most messaging apps truncate a paste.

## Permissions

Sharing needs none: the share sheet is the user's own act of consent and the
file is in our sandbox. Saving to the gallery does.

The distinction the code cares about is **denied** versus **blocked**. A soft
no can be asked again; a permanent one cannot — the OS will never show that
prompt again, and re-prompting is how apps end up looking broken. `gal` reports
only a boolean, so `permission_handler` supplies the difference, and a blocked
save offers a route to Settings instead of a retry that cannot work.

## Constraints worth knowing

**Licensing shapes the encoder choice.** FFmpegKit was retired in April 2025;
the maintained fork is `ffmpeg_kit_flutter_new`. Its GPL variants bundle
x264/x265, which would make the whole app GPLv3 — a problem for App Store
distribution. The LGPL variants can still encode H.264 through the platform
hardware encoders (`h264_videotoolbox`, `h264_mediacodec`), which is both
license-safe and far faster on a phone. That is what ships.

The harness therefore defaults to `h264_videotoolbox` rather than libx264 on
macOS. Measuring x264 output would flatter a pipeline that ships VideoToolbox.
`--encoder x264` is available as a quality ceiling to measure against.

**Calibration is Android-first even though the app is not.** Retrieving what a
viewer actually received means reading files the OS does not hand out freely;
Android permits it, iOS does not.

## Not built yet

- **A real round trip.** Until that exists the premise is untested, the
  forecast is guesswork, and the shipped preset is a placeholder.
- Status duration limits and clip splitting (`TargetSpec.maxClipDuration` is
  modelled but unused, pending a measured limit).
- Image presets are not raced by the harness the way video presets are; the
  photo path ships one preset chosen by reasoning rather than measurement.
- Settings — preset override, output location, quality target.
- Test coverage is thin: `test/filter_syntax_test.dart` guards filter syntax,
  capability degradation and audio fallbacks. Nothing else is covered.
- **HDR tone mapping.** PQ and HLG need `zscale`, absent from the `_min`
  build. Since HDR is the default capture format on recent iPhones this affects
  a lot of real footage. Whether the LGPL `_full` variant carries zimg is
  unverified — worth checking before accepting the limitation, and worth
  weighing against the app-size increase.
- macOS desktop builds fail to codesign: ffmpeg-kit ships its macOS frameworks
  in a flat layout where macOS requires `Versions/A`, so signing rejects them as
  unsealed. iOS and Android are unaffected.
