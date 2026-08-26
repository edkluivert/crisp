import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme.dart';
import '../../services/share_service.dart';
import '../../widgets/hd_route_sheet.dart';
import 'session_state.dart';

/// The finished file and one way out: WhatsApp.
///
/// This deliberately shows the *output*, not a comparison. The file on screen
/// is byte-for-byte what gets shared, so what you see is a promise rather
/// than a forecast — and the single button keeps the distance between
/// "looks good" and "posted" as short as it can possibly be.
class ResultPage extends StatefulWidget {
  const ResultPage({super.key, required this.result});

  final SessionReady result;

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  final _share = const ShareService();

  VideoPlayerController? _player;
  bool _busy = false;

  SessionReady get _r => widget.result;

  @override
  void initState() {
    super.initState();
    if (_r.kind == MediaKind.video) _initVideo();
  }

  Future<void> _initVideo() async {
    final player = VideoPlayerController.file(File(_r.outputPath));
    await player.initialize();
    await player.setLooping(true);
    await player.play();
    if (!mounted) {
      await player.dispose();
      return;
    }
    setState(() => _player = player);
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  double get _aspect {
    final info = _r.outputInfo;
    if (info.displayHeight == 0) return 9 / 16;
    return info.displayWidth / info.displayHeight;
  }

  /// Media is capped to leave the button on screen — a result page whose only
  /// action lives below the fold defeats its own purpose.
  Widget _media(BuildContext context) {
    final Widget child;
    if (_r.kind == MediaKind.image) {
      child = Image.file(
        File(_r.outputPath),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
    } else if (_player == null || !_player!.value.isInitialized) {
      child = const Center(child: CircularProgressIndicator());
    } else {
      child = AspectRatio(
        aspectRatio: _aspect,
        child: GestureDetector(
          // Tap toggles sound — a status is usually watched with it.
          onTap: () {
            final p = _player!;
            p.setVolume(p.value.volume > 0 ? 0 : 1);
          },
          child: VideoPlayer(_player!),
        ),
      );
    }
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.62,
      ),
      width: double.infinity,
      decoration: BoxDecoration(
        color: CrispTheme.surface,
        borderRadius: BorderRadius.circular(CrispTheme.radiusLg),
        border: Border.all(color: CrispTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final info = _r.outputInfo;
    final mb = (info.sizeBytes / 1048576).toStringAsFixed(1);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ready'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            tooltip: 'Save to gallery',
            icon: const Icon(Icons.download),
            onPressed: _busy ? null : _doSave,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(CrispTheme.space4),
          child: Column(
            children: [
              Expanded(child: Center(child: _media(context))),
              const SizedBox(height: CrispTheme.space3),
              Text(
                '${info.displayWidth}×${info.displayHeight} · $mb MB',
                style: text.bodySmall,
              ),
              if (_r.notes.isNotEmpty) ...[
                const SizedBox(height: CrispTheme.space2),
                Text(
                  _r.notes.join(' · '),
                  textAlign: TextAlign.center,
                  style: text.bodySmall,
                ),
              ],
              const SizedBox(height: CrispTheme.space4),
              FilledButton.icon(
                onPressed: _busy ? null : _toWhatsApp,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.ios_share, size: 20),
                label: const Text('WhatsApp'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Map first, then the share sheet, then a reminder that survives the trip
  /// into WhatsApp and back. The reminder matters — the forward step happens
  /// inside WhatsApp where we cannot help, and people return here having
  /// forgotten it.
  Future<void> _toWhatsApp() async {
    final proceed = await HdRouteSheet.show(context);
    if (!proceed || !mounted) return;
    setState(() => _busy = true);
    try {
      await _share.shareFile(_r.outputPath);
      _say(
        'Step 2: in your own chat, long-press what you sent → Forward → My status',
        action: SnackBarAction(label: 'Got it', onPressed: () {}),
      );
    } on Object catch (e) {
      _say('Could not share: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doSave() async {
    setState(() => _busy = true);
    try {
      final result = await _share.saveToGallery(
        _r.outputPath,
        isVideo: _r.kind == MediaKind.video,
      );
      switch (result.outcome) {
        case SaveOutcome.saved:
          _say('Saved to your gallery, in the Crisp album');
        case SaveOutcome.denied:
          _say('Crisp needs photo library access to save. Tap save to try again.');
        case SaveOutcome.blocked:
          // Re-prompting is pointless here — the system will not ask again —
          // so the only useful thing to offer is the way to Settings.
          _say(
            'Photo access is turned off for Crisp.',
            action: SnackBarAction(
              label: 'Settings',
              onPressed: _share.openSettings,
            ),
          );
        case SaveOutcome.failed:
          _say('Could not save: ${result.detail ?? 'unknown error'}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: action,
        duration: action != null
            ? const Duration(seconds: 8)
            : const Duration(seconds: 4),
      ));
  }
}
