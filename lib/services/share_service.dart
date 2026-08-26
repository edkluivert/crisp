import 'dart:io';

import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

/// Why a save did not happen, in terms the UI can act on.
///
/// A bare thrown string cannot distinguish "they said no this time" from "they
/// said never, and the only way back is Settings" — and those need different
/// responses. Collapsing them is how apps end up re-prompting for a permission
/// the OS will never show again.
enum SaveOutcome {
  saved,

  /// Declined this time. Asking again later is legitimate.
  denied,

  /// Declined permanently, or blocked by policy. The system will not show the
  /// prompt again; only Settings can change it.
  blocked,

  failed,
}

class SaveResult {
  const SaveResult(this.outcome, [this.detail]);

  final SaveOutcome outcome;
  final String? detail;

  bool get ok => outcome == SaveOutcome.saved;
}

/// Getting the finished file out of the app.
///
/// Neither platform lets an app post to Status directly — there is no public
/// API for it on Android or iOS — so the best available handoff is the system
/// share sheet, from which the user picks WhatsApp and then "My status". That
/// extra tap is not an oversight; it is the ceiling of what is possible.
///
/// Saving to the gallery therefore matters as much as sharing: it is the route
/// for anyone who would rather post later, or who cannot find the share target.
class ShareService {
  const ShareService();

  /// Sharing needs no permission on either platform — the share sheet is the
  /// user's own act of consent, and the file lives in our own sandbox.
  Future<void> shareFile(String path, {String? text}) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('nothing to share — the file is gone');
    }
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: text),
    );
  }

  /// Writes into the system photo library under an album of our own, so a
  /// conformed copy is never mistaken for the original.
  Future<SaveResult> saveToGallery(
    String path, {
    required bool isVideo,
  }) async {
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          // gal reports a boolean, which cannot tell a soft no from a
          // permanent one. permission_handler can, and the difference decides
          // whether we offer Settings or simply let them try again.
          return SaveResult(
            await _isBlocked() ? SaveOutcome.blocked : SaveOutcome.denied,
          );
        }
      }

      if (isVideo) {
        await Gal.putVideo(path, album: 'Crisp');
      } else {
        await Gal.putImage(path, album: 'Crisp');
      }
      return const SaveResult(SaveOutcome.saved);
    } on GalException catch (e) {
      return switch (e.type) {
        GalExceptionType.accessDenied =>
          SaveResult(await _isBlocked() ? SaveOutcome.blocked : SaveOutcome.denied),
        _ => SaveResult(SaveOutcome.failed, e.type.message),
      };
    } on Object catch (e) {
      return SaveResult(SaveOutcome.failed, e.toString());
    }
  }

  /// Android splits the photo library across permissions that changed meaning
  /// in API 33, and iOS has its own. Any one of them being permanently denied
  /// is enough to mean the prompt will not appear again.
  Future<bool> _isBlocked() async {
    final statuses = await Future.wait([
      Permission.photos.status,
      if (Platform.isAndroid) Permission.videos.status,
      if (Platform.isAndroid) Permission.storage.status,
    ]);
    return statuses.any((s) => s.isPermanentlyDenied || s.isRestricted);
  }

  /// The only route back once a permission is permanently denied.
  Future<void> openSettings() => openAppSettings();
}
