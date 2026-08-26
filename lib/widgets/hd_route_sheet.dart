import 'package:flutter/material.dart';

import '../app/theme.dart';

/// The two taps inside WhatsApp that make the whole product work.
///
/// Status posts go through WhatsApp's harshest compressor, but *forwarded*
/// media re-uses the already-uploaded file untouched — that is why forwards
/// are instant even on bad networks. So the route around the Status crush is:
/// send the file to your own chat (which uses the far gentler chat-HD encode),
/// then forward that message to My status. The paid "HD status" services do
/// exactly this with a server-side bot in the middle; this sheet is the same
/// trick with the middleman removed.
///
/// The sheet exists because the route is two taps in someone else's app, and
/// an instruction delivered *after* the share sheet opens arrives too late.
/// Show the map first, then open the door.
class HdRouteSheet extends StatelessWidget {
  const HdRouteSheet._();

  /// Resolves true when the user chose to continue to the share sheet.
  static Future<bool> show(BuildContext context) async {
    final proceed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: CrispTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(CrispTheme.radiusLg)),
      ),
      builder: (_) => const HdRouteSheet._(),
    );
    return proceed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            CrispTheme.space5, CrispTheme.space3, CrispTheme.space5, CrispTheme.space5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: CrispTheme.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: CrispTheme.space5),
            Text('Post in HD', style: text.headlineSmall),
            const SizedBox(height: CrispTheme.space2),
            Text(
              'Two taps inside WhatsApp. Your video never meets the Status '
              'compressor.',
              style: text.bodySmall,
            ),
            const SizedBox(height: CrispTheme.space6),
            const _Step(
              number: '1',
              icon: Icons.person_outline,
              title: 'Send it to yourself',
              detail: 'Pick WhatsApp, then choose You at the top of the list. '
                  'If it asks about quality, pick HD.',
            ),
            const _StepConnector(),
            const _Step(
              number: '2',
              icon: Icons.shortcut,
              title: 'Forward it to your status',
              detail: 'Long-press what you just sent, then '
                  'Forward → My status.',
            ),
            const SizedBox(height: CrispTheme.space5),
            Container(
              padding: const EdgeInsets.all(CrispTheme.space3),
              decoration: BoxDecoration(
                color: CrispTheme.good.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(CrispTheme.radius),
                border:
                    Border.all(color: CrispTheme.good.withValues(alpha: 0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.bolt, size: 18, color: CrispTheme.good),
                  const SizedBox(width: CrispTheme.space3),
                  Expanded(
                    child: Text(
                      'Why this works: forwarding re-uses the file WhatsApp '
                      'already uploaded, so Status never re-compresses it.',
                      style: text.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: CrispTheme.space5),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.ios_share, size: 20),
              label: const Text('Open WhatsApp'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final String number;
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: CrispTheme.accent.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: const TextStyle(
              color: CrispTheme.accent,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: CrispTheme.space4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(icon, size: 16, color: CrispTheme.textMuted),
                  const SizedBox(width: CrispTheme.space2),
                  Text(title, style: text.titleMedium),
                ],
              ),
              const SizedBox(height: CrispTheme.space1),
              Text(detail, style: text.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

/// The thin line joining the step badges, so the two steps read as one path
/// rather than two unrelated cards.
class _StepConnector extends StatelessWidget {
  const _StepConnector();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 15),
      child: Container(
        width: 2,
        height: CrispTheme.space5,
        margin: const EdgeInsets.symmetric(vertical: CrispTheme.space1),
        color: CrispTheme.border,
      ),
    );
  }
}
