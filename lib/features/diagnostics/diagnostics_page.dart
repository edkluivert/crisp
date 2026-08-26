import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme.dart';
import '../../services/diagnostics.dart';

/// The report, on screen and shareable.
///
/// Shown in full rather than summarised. A user forwarding this is doing us a
/// favour, and hiding what they are about to send would be both rude and a good
/// way to have them not send it.
class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key, required this.diagnostics});

  final Diagnostics diagnostics;

  @override
  Widget build(BuildContext context) {
    final report = diagnostics.render();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  const SnackBar(content: Text('Report copied')),
                );
            },
          ),
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share),
            onPressed: () => _share(context, report),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(CrispTheme.space4),
              child: Row(
                children: [
                  Icon(
                    diagnostics.hasFailure
                        ? Icons.error_outline
                        : Icons.info_outline,
                    size: 16,
                    color: diagnostics.hasFailure
                        ? CrispTheme.warn
                        : CrispTheme.textMuted,
                  ),
                  const SizedBox(width: CrispTheme.space2),
                  Expanded(
                    child: Text(
                      diagnostics.hasFailure
                          ? 'Send this to whoever is fixing it — it has the '
                              'command that failed and what ffmpeg said.'
                          : 'No failure recorded. This is what the last run did.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(CrispTheme.space4),
                child: SelectableText(
                  report,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.4,
                    color: CrispTheme.textPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shared as a file rather than as message text: these reports run to
  /// hundreds of lines, and most messaging apps mangle or truncate a paste that
  /// long.
  Future<void> _share(BuildContext context, String report) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/crisp-diagnostics.txt');
      await file.writeAsString(report);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: 'Crisp diagnostics'),
      );
    } on Object catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not share: $e')));
    }
  }
}
