import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../app/theme.dart';
import '../../engine/capabilities.dart';
import '../../engine/io/ffmpeg_kit_runner.dart';
import '../diagnostics/diagnostics_page.dart';
import 'result_page.dart';
import 'session_cubit.dart';
import 'session_state.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SessionCubit, SessionState>(
      // The result is pushed as its own route rather than swapped in place,
      // so backing out returns to the picker with the session intact.
      listenWhen: (prev, next) => prev is! SessionReady && next is SessionReady,
      listener: (context, state) {
        if (state is! SessionReady) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BlocProvider.value(
              value: context.read<SessionCubit>(),
              child: ResultPage(result: state),
            ),
          ),
        );
      },
      builder: (context, state) {
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(CrispTheme.space5),
              child: switch (state) {
                SessionWorking() => _Working(state: state),
                SessionFailed() => _Failed(state: state),
                _ => const _Picker(),
              },
            ),
          ),
        );
      },
    );
  }
}

class _Picker extends StatelessWidget {
  const _Picker();

  Future<void> _pick(BuildContext context) async {
    // compressionQuality is left at 0 on purpose. The picker offers to shrink
    // media on the way in, which would hand us an already-degraded file and
    // quietly defeat the entire point of the app.
    final picked = await FilePicker.pickFile(
      type: FileType.media,
      compressionQuality: 0,
    );
    final path = picked?.path;
    if (path == null || !context.mounted) return;
    await context.read<SessionCubit>().process(path);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        Text('Crisp', style: text.headlineSmall),
        const SizedBox(height: CrispTheme.space2),
        Text(
          'WhatsApp crushes everything you post to Status. Crisp shapes your '
          'file so there is nothing left to crush, then hands it to WhatsApp.',
          style: text.bodySmall,
        ),
        const SizedBox(height: CrispTheme.space8),
        GestureDetector(
          onTap: () => _pick(context),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: CrispTheme.space8),
            decoration: BoxDecoration(
              color: CrispTheme.surface,
              borderRadius: BorderRadius.circular(CrispTheme.radiusLg),
              border: Border.all(color: CrispTheme.border),
            ),
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: CrispTheme.accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.add_photo_alternate_outlined,
                      color: CrispTheme.accent, size: 26),
                ),
                const SizedBox(height: CrispTheme.space4),
                Text('Pick a photo or video', style: text.titleMedium),
                const SizedBox(height: CrispTheme.space1),
                Text('The bigger the original, the more there is to save',
                    style: text.bodySmall),
              ],
            ),
          ),
        ),
        const Spacer(),
        GestureDetector(
          onTap: () {
            final cubit = context.read<SessionCubit>();
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DiagnosticsPage(diagnostics: cubit.diagnostics),
            ));
          },
          behavior: HitTestBehavior.opaque,
          child: const _EncoderStatus(),
        ),
      ],
    );
  }
}

class _Working extends StatelessWidget {
  const _Working({required this.state});

  final SessionWorking state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: CrispTheme.space6),
          Text(state.step, style: text.titleMedium),
          if (state.detail != null) ...[
            const SizedBox(height: CrispTheme.space2),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: CrispTheme.space6),
              child: Text(
                state.detail!,
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.state});

  final SessionFailed state;

  void _openDiagnostics(BuildContext context) {
    final cubit = context.read<SessionCubit>();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DiagnosticsPage(diagnostics: cubit.diagnostics),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.error_outline, color: CrispTheme.warn, size: 32),
          const SizedBox(height: CrispTheme.space4),
          Text(state.message, textAlign: TextAlign.center, style: text.titleMedium),
          if (state.detail != null) ...[
            const SizedBox(height: CrispTheme.space3),
            // Shown in full rather than swallowed: at this stage the failures
            // that matter are ffmpeg's, and hiding them would make the app
            // impossible to debug on a real device.
            Text(state.detail!, textAlign: TextAlign.center, style: text.bodySmall),
          ],
          const SizedBox(height: CrispTheme.space6),
          FilledButton.icon(
            // Offered before "try another file" on purpose: a failure that gets
            // reported is worth more than one the user silently works around.
            onPressed: () => _openDiagnostics(context),
            icon: const Icon(Icons.bug_report_outlined, size: 20),
            label: const Text('View error report'),
          ),
          const SizedBox(height: CrispTheme.space3),
          OutlinedButton(
            onPressed: () => context.read<SessionCubit>().reset(),
            child: const Text('Try another file'),
          ),
        ],
      ),
    );
  }
}

/// Reports which H.264 encoder the bundled ffmpeg build actually exposes.
///
/// Not a debug affordance. Which encoders ship is undocumented and varies by
/// platform and by package variant, so a device where none is available is a
/// real possibility — and the failure would otherwise surface as an opaque
/// error partway through someone's first encode. Better to say so up front,
/// on the one screen they see before committing to anything.
class _EncoderStatus extends StatefulWidget {
  const _EncoderStatus();

  @override
  State<_EncoderStatus> createState() => _EncoderStatusState();
}

class _EncoderStatusState extends State<_EncoderStatus> {
  String? _encoder;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    try {
      final caps = await FfmpegCapabilities.detect(const FfmpegKitRunner());
      if (!mounted) return;
      setState(() {
        _encoder = caps.usable ? caps.summary : null;
        _problem = caps.usable ? null : 'No H.264 encoder in this build';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _problem = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final failed = _problem != null;
    final pending = _encoder == null && _problem == null;

    return Row(
      children: [
        Icon(
          failed ? Icons.error_outline : Icons.memory,
          size: 14,
          color: failed ? CrispTheme.warn : CrispTheme.textMuted,
        ),
        const SizedBox(width: CrispTheme.space2),
        Expanded(
          child: Text(
            pending
                ? 'Checking this device…'
                : failed
                    ? _problem!
                    : 'Encoding with $_encoder',
            style: text.bodySmall?.copyWith(
              color: failed ? CrispTheme.warn : CrispTheme.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}
