// Crisp calibration harness.
//
// The product's core claim — that a pre-conformed file survives WhatsApp
// better than an untouched one — is an empirical claim. This is the instrument
// that tests it.
//
// The loop is deliberately half-manual, because the interesting half cannot be
// automated: only a real phone can post a real Status.
//
//   1. dart tool/calibrate.dart prepare <video>   -> builds one file per preset
//   2. post every file in outbox/ to WhatsApp Status
//   3. view them from a SECOND device and save what it received
//   4. drop those files into inbox/ under the same names
//   5. dart tool/calibrate.dart score <runDir>    -> ranks what survived
//
// Step 3 matters more than it looks. What you want to measure is what a
// *viewer* receives, not what your own phone kept locally — those are not the
// same file, and scoring the local copy would flatter every preset equally.

import 'dart:convert';
import 'dart:io';

import 'package:crisp/engine/capabilities.dart';
import 'package:crisp/engine/conform_plan.dart';
import 'package:crisp/engine/io/process_runner.dart';
import 'package:crisp/engine/media_info.dart';
import 'package:crisp/engine/metrics.dart';
import 'package:crisp/engine/pipeline.dart';
import 'package:crisp/engine/presets.dart';
import 'package:crisp/engine/target_spec.dart';
import 'package:crisp/engine/whatsapp_model.dart';
import 'package:crisp/engine/whatsapp_simulator.dart';

const _runsDir = 'calibration';

Future<void> main(List<String> argv) async {
  if (argv.isEmpty) {
    _usage();
    exit(64);
  }

  await ProcessRunner.assertAvailable();
  final pipeline = const CrispPipeline(ProcessRunner());

  switch (argv.first) {
    case 'prepare':
      await _prepare(pipeline, argv.skip(1).toList());
    case 'score':
      await _score(pipeline, argv.skip(1).toList());
    case 'simulate':
      await _simulate(pipeline, argv.skip(1).toList());
    case 'slice':
      await _slice(pipeline, argv.skip(1).toList());
    case 'synth':
      await _synth(argv.skip(1).toList());
    case 'presets':
      _listPresets();
    default:
      _usage();
      exit(64);
  }
}

void _usage() {
  stdout.writeln('''
Crisp calibration harness

  dart tool/calibrate.dart prepare <video> [--encoder vt|x264]
      Conform <video> with every preset into calibration/<run>/outbox/.

  dart tool/calibrate.dart score <runDir>
      Score everything in <runDir>/inbox/ against the original source.

  dart tool/calibrate.dart simulate <runDir> --profile fixed|adaptive
      Fill inbox/ with a GUESS at what WhatsApp would return. Not evidence —
      a rehearsal, so presets can be screened without burning Status posts.

  dart tool/calibrate.dart slice <video>
      Extract the preview sample and report how it had to be done. Use this
      when a particular video misbehaves in the app.

  dart tool/calibrate.dart synth [--out <dir>]
      Generate synthetic clips that stress specific failure modes.

  dart tool/calibrate.dart presets
      List the presets and what each one is testing.
''');
}

void _listPresets() {
  for (final p in CrispPresets.all) {
    final spec = p.spec;
    final geometry = p.passthrough
        ? 'source untouched'
        : '${spec.maxShortEdge}x${spec.maxLongEdge} @ ${spec.videoBitrateKbps}kbps';
    stdout.writeln('\n${p.id}  —  ${p.label}');
    stdout.writeln('  $geometry');
    if (p.sharpenAmount > 0 || p.denoiseStrength > 0) {
      stdout.writeln('  sharpen ${p.sharpenAmount}  denoise ${p.denoiseStrength}');
    }
    stdout.writeln('  ${p.rationale}');
  }
  stdout.writeln('');
}

VideoEncoder _encoderFrom(List<String> args) {
  final idx = args.indexOf('--encoder');
  final choice = idx >= 0 && idx + 1 < args.length ? args[idx + 1] : 'vt';
  return switch (choice) {
    'x264' => VideoEncoder.x264,
    'vt' || 'videotoolbox' => VideoEncoder.videoToolbox,
    _ => throw ArgumentError('unknown encoder "$choice" (use vt or x264)'),
  };
}

Future<void> _prepare(CrispPipeline pipeline, List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('prepare needs a source video');
    exit(64);
  }
  final sourcePath = positional.first;
  if (!File(sourcePath).existsSync()) {
    stderr.writeln('no such file: $sourcePath');
    exit(66);
  }
  final encoder = _encoderFrom(args);

  final source = await pipeline.probe(sourcePath);
  final capabilities = await FfmpegCapabilities.detect(pipeline.runner);
  stdout.writeln('Source: ${source.diagnostic}');
  stdout.writeln('Build:  ${capabilities.summary}\n');

  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '')
      .replaceAll('-', '')
      .split('.')
      .first;
  final base = _baseName(sourcePath);
  final runDir = Directory('$_runsDir/$stamp-$base');
  final outbox = Directory('${runDir.path}/outbox')..createSync(recursive: true);
  Directory('${runDir.path}/inbox').createSync(recursive: true);

  // The source is copied in so a run stays scorable after the original moves
  // or is edited. Calibration data with an unreproducible reference is worthless.
  final sourceCopy = '${runDir.path}/source${_extension(sourcePath)}';
  await File(sourcePath).copy(sourceCopy);

  final manifest = <String, dynamic>{
    'createdAt': DateTime.now().toIso8601String(),
    'sourcePath': sourcePath,
    'sourceCopy': sourceCopy,
    'encoder': encoder.name,
    'source': {
      'width': source.displayWidth,
      'height': source.displayHeight,
      'fps': source.fps,
      'durationMs': source.duration.inMilliseconds,
      'codec': source.videoCodec,
      'bitrate': source.effectiveVideoBitrate,
      'sizeBytes': source.sizeBytes,
    },
    'presets': <Map<String, dynamic>>[],
  };

  for (final preset in CrispPresets.all) {
    final outPath = '${outbox.path}/${preset.id}.mp4';
    stdout.write('  ${preset.id.padRight(16)} ');
    final outcome = await pipeline.conform(
      inputPath: sourcePath,
      outputPath: outPath,
      preset: preset,
      encoder: encoder,
      sourceInfo: source,
      canToneMap: capabilities.canToneMap,
      canDenoise: capabilities.canDenoise,
      canSharpen: capabilities.canSharpen,
      audioEncoder: capabilities.audioEncoder,
    );

    if (!outcome.ok) {
      stdout.writeln('FAILED — ${outcome.error}');
      continue;
    }
    final out = outcome.output!;
    stdout.writeln('${out.displayWidth}x${out.displayHeight}  '
        '${(out.sizeBytes / 1048576).toStringAsFixed(2)}MB  '
        '${(out.effectiveVideoBitrate / 1000).round()}kbps  '
        '${outcome.elapsed.inMilliseconds}ms');
    for (final note in outcome.plan?.notes ?? const <String>[]) {
      stdout.writeln('${' ' * 18}· $note');
    }

    (manifest['presets'] as List).add({
      'id': preset.id,
      'label': preset.label,
      'file': '${preset.id}.mp4',
      'width': out.displayWidth,
      'height': out.displayHeight,
      'sizeBytes': out.sizeBytes,
      'bitrate': out.effectiveVideoBitrate,
      'encodeMs': outcome.elapsed.inMilliseconds,
      'plan': outcome.plan?.toString(),
    });
  }

  File('${runDir.path}/manifest.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(manifest),
  );

  stdout.writeln('''
\nRun: ${runDir.path}

Next:
  1. Post every file in ${outbox.path} to WhatsApp Status.
  2. View each one from a second device and save what it received.
  3. Put the saved files in ${runDir.path}/inbox/ named after their preset
     (control.mp4, hd720_tuned.mp4, ...).
  4. dart tool/calibrate.dart score ${runDir.path}
''');
}

Future<void> _score(CrispPipeline pipeline, List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('score needs a run directory');
    exit(64);
  }
  final runDir = Directory(args.first);
  if (!runDir.existsSync()) {
    stderr.writeln('no such run: ${runDir.path}');
    exit(66);
  }

  final manifestFile = File('${runDir.path}/manifest.json');
  if (!manifestFile.existsSync()) {
    stderr.writeln('${runDir.path} has no manifest.json — was it made by prepare?');
    exit(66);
  }
  final manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final referencePath = manifest['sourceCopy'] as String;
  final reference = await pipeline.probe(referencePath);

  final inbox = Directory('${runDir.path}/inbox');
  final returned = inbox.existsSync()
      ? inbox.listSync().whereType<File>().where((f) {
          final n = _baseName(f.path);
          return CrispPresets.byId(n) != null;
        }).toList()
      : <File>[];

  if (returned.isEmpty) {
    stderr.writeln('''
Nothing to score. Put the files WhatsApp gave back into
  ${inbox.path}
named after their preset, e.g. control.mp4, hd720_tuned.mp4.
''');
    exit(1);
  }

  stdout.writeln('Reference: $reference\n');

  final rows = <_Row>[];
  for (final file in returned..sort((a, b) => a.path.compareTo(b.path))) {
    final id = _baseName(file.path);
    final preset = CrispPresets.byId(id)!;
    stdout.write('  scoring ${id.padRight(16)} ');
    final info = await pipeline.probe(file.path);
    final score = await pipeline.score(
      referencePath: referencePath,
      distortedPath: file.path,
      referenceInfo: reference,
    );
    if (score == null) {
      stdout.writeln('metric failed');
      continue;
    }
    stdout.writeln(score.toString());
    rows.add(_Row(preset: preset, returned: info, score: score));
  }

  if (rows.isEmpty) {
    stderr.writeln('\nNo files scored.');
    exit(1);
  }

  rows.sort((a, b) => b.score.ssim.compareTo(a.score.ssim));
  final control = rows.where((r) => r.preset.passthrough).firstOrNull;

  final simulated = File('${runDir.path}/$_simulatedMarker').existsSync();

  final report = StringBuffer()
    ..writeln('# Calibration report')
    ..writeln();
  if (simulated) {
    report
      ..writeln('> **Simulated run — not evidence.** The inbox was filled by '
          '`calibrate simulate`, not by WhatsApp. Useful for screening presets '
          'against a theory; useless as proof that the theory is right.')
      ..writeln();
  }
  report
    ..writeln('Source: `${manifest['sourcePath']}`  ')
    ..writeln('Reference: ${reference.displayWidth}x${reference.displayHeight} '
        '@ ${reference.fps.toStringAsFixed(2)}fps, '
        '${(reference.effectiveVideoBitrate / 1000).round()}kbps  ')
    ..writeln('Encoder: `${manifest['encoder']}`  ')
    ..writeln('Scored: ${DateTime.now().toIso8601String()}')
    ..writeln()
    ..writeln('| Preset | Returned | SSIM | SSIM dB | PSNR dB | vs control |')
    ..writeln('|---|---|---|---|---|---|');

  for (final r in rows) {
    final delta = control == null || identical(r, control)
        ? '—'
        : _signed(r.score.ssimDb - control.score.ssimDb, 'dB');
    report.writeln('| `${r.preset.id}` '
        '| ${r.returned.displayWidth}x${r.returned.displayHeight} '
        '${(r.returned.sizeBytes / 1048576).toStringAsFixed(2)}MB '
        '| ${r.score.ssim.toStringAsFixed(5)} '
        '| ${r.score.ssimDb.toStringAsFixed(2)} '
        '| ${r.score.psnrDb.toStringAsFixed(2)} '
        '| $delta |');
  }

  report
    ..writeln()
    ..writeln('## What this run says')
    ..writeln();

  final winner = rows.first;
  if (control != null && winner.preset.passthrough) {
    report.writeln(
        '**No preset beat the untouched control.** Either the presets are '
        'aimed wrong, or this source was already inside WhatsApp\'s limits and '
        'there was nothing to gain. Try a larger, higher-bitrate source before '
        'concluding the approach fails.');
  } else if (control != null) {
    final gain = winner.score.ssimDb - control.score.ssimDb;
    report.writeln(
        '**${winner.preset.id} won**, ${gain.toStringAsFixed(2)}dB of SSIM '
        'ahead of posting the original untouched. ${winner.preset.rationale}');
  } else {
    report.writeln('**${winner.preset.id} scored highest.** No control was '
        'returned, so there is no baseline to compare against — post the '
        'control next time or these numbers only rank presets relative to '
        'each other.');
  }

  final resolutions = rows.map((r) => '${r.returned.displayWidth}x${r.returned.displayHeight}').toSet();
  report
    ..writeln()
    ..writeln('Returned resolutions seen: ${resolutions.join(', ')}. '
        'If every preset came back at the same size regardless of what was '
        'sent, that size is WhatsApp\'s cap and presets above it are wasting '
        'bitrate.');

  final reportFile = File('${runDir.path}/report.md')
    ..writeAsStringSync(report.toString());
  stdout.writeln('\n${report.toString()}');
  stdout.writeln('Written to ${reportFile.path}');
}


Future<void> _slice(CrispPipeline pipeline, List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('slice needs a video');
    exit(64);
  }
  final path = args.first;
  final source = await pipeline.probe(path);
  final capabilities = await FfmpegCapabilities.detect(pipeline.runner);
  stdout.writeln('Source: ${source.diagnostic}');

  final out = '${Directory.systemTemp.path}/crisp_slice.mp4';
  final started = DateTime.now();
  final reencoded = await WhatsAppSimulator.extractSlice(
    runner: pipeline.runner,
    inputPath: path,
    outputPath: out,
    sourceDuration: source.duration,
    pipeline: pipeline,
    encoder: capabilities.encoder!,
  );
  final elapsed = DateTime.now().difference(started);

  final slice = await pipeline.probe(out);
  stdout.writeln(reencoded
      ? 'Stream copy was unusable — re-encoded instead (${elapsed.inMilliseconds}ms)'
      : 'Stream copy worked (${elapsed.inMilliseconds}ms)');
  stdout.writeln('Slice:  ${slice.diagnostic}');
  stdout.writeln('At:     $out');
}

const _simulatedMarker = 'SIMULATED.txt';

Future<void> _simulate(CrispPipeline pipeline, List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('simulate needs a run directory');
    exit(64);
  }
  final runDir = Directory(positional.first);
  if (!runDir.existsSync()) {
    stderr.writeln('no such run: ${runDir.path}');
    exit(66);
  }

  final idx = args.indexOf('--profile');
  final profileName =
      idx >= 0 && idx + 1 < args.length ? args[idx + 1] : 'adaptive';
  final model = switch (profileName) {
    'adaptive' => WhatsAppModel.adaptiveGuess,
    'fixed' => WhatsAppModel.fixedGuess,
    _ => throw ArgumentError('unknown profile "$profileName"'),
  };

  final encoder = _encoderFrom(args);
  final capabilities = await FfmpegCapabilities.detect(pipeline.runner);
  final simulator = WhatsAppSimulator(
    pipeline: pipeline,
    model: model,
    encoder: encoder,
    audioEncoder: capabilities.audioEncoder,
  );

  final outbox = Directory('${runDir.path}/outbox');
  final inbox = Directory('${runDir.path}/inbox')..createSync(recursive: true);

  stdout.writeln('Simulating the "${model.label}" theory. '
      'These numbers are a rehearsal, not a measurement.\n');

  final staged = outbox.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in staged) {
    final name = file.path.split(Platform.pathSeparator).last;
    stdout.write('  ${name.padRight(22)} ');
    final before = await pipeline.probe(file.path);
    final after = await simulator.simulate(
      inputPath: file.path,
      outputPath: '${inbox.path}/$name',
      inputInfo: before,
    );
    stdout.writeln(model.passesThrough(before)
        ? 'passed through untouched'
        : 're-encoded to ${after.displayWidth}x${after.displayHeight} '
            '@ ${model.forcedBitrateKbps}kbps');
  }

  File('${runDir.path}/$_simulatedMarker').writeAsStringSync(
    'Inbox filled by `calibrate simulate --profile $profileName` on '
    '${DateTime.now().toIso8601String()}.\n\n'
    'These files did NOT come from WhatsApp. They are the output of a guessed\n'
    'model of what WhatsApp might do, and prove nothing about the real thing.\n'
    'Delete this file and the inbox before recording a real round trip.\n',
  );

  stdout.writeln('\nInbox filled. Marked simulated in ${runDir.path}/$_simulatedMarker');
  stdout.writeln('Score it with: dart tool/calibrate.dart score ${runDir.path}');
}

/// Synthetic sources that isolate specific failure modes.
///
/// Real footage is the final word, but synthetic clips fail in legible ways: a
/// gradient tells you about banding and nothing else, so when it moves you know
/// exactly what changed.
Future<void> _synth(List<String> args) async {
  final idx = args.indexOf('--out');
  final outDir = Directory(
      idx >= 0 && idx + 1 < args.length ? args[idx + 1] : '$_runsDir/synthetic')
    ..createSync(recursive: true);

  const clips = <String, List<String>>{
    // Fine, moving detail — the first thing a starved encoder smears.
    'detail': ['-f', 'lavfi', '-i', 'testsrc2=size=1080x1920:rate=30:duration=10'],
    // Smooth ramps — exposes banding introduced by chroma and bit-depth loss.
    'gradient': ['-f', 'lavfi', '-i', 'gradients=size=1080x1920:rate=30:duration=10'],
    // Dense, chaotic motion — worst case for motion estimation and bitrate.
    'motion': ['-f', 'lavfi', '-i', 'mandelbrot=size=1080x1920:rate=30'],
  };

  for (final entry in clips.entries) {
    final out = '${outDir.path}/${entry.key}.mp4';
    stdout.write('  ${entry.key.padRight(10)} ');
    final args = [
      '-y', '-hide_banner',
      ...entry.value,
      '-t', '10',
      // Near-lossless master: the synthetic source must not be the bottleneck.
      '-c:v', 'libx264', '-preset', 'slow', '-crf', '12',
      '-pix_fmt', 'yuv420p',
      '-movflags', '+faststart',
      out,
    ];
    final r = await Process.run('ffmpeg', args);
    stdout.writeln(r.exitCode == 0
        ? '${(File(out).lengthSync() / 1048576).toStringAsFixed(2)}MB'
        : 'FAILED — ${r.stderr.toString().trim().split('\n').last}');
  }
  stdout.writeln('\nWritten to ${outDir.path}');
}

class _Row {
  const _Row({
    required this.preset,
    required this.returned,
    required this.score,
  });

  final Preset preset;
  final MediaInfo returned;
  final QualityScore score;
}

String _signed(double v, String unit) =>
    '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}$unit';

String _baseName(String path) {
  final file = path.split(Platform.pathSeparator).last;
  final dot = file.lastIndexOf('.');
  return dot <= 0 ? file : file.substring(0, dot);
}

String _extension(String path) {
  final file = path.split(Platform.pathSeparator).last;
  final dot = file.lastIndexOf('.');
  return dot <= 0 ? '' : file.substring(dot);
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
