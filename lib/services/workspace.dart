import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Scratch space for one editing session.
///
/// Every intermediate this app makes is disposable, and some of them are large
/// — a slice, two simulations and a full conform can easily be a few hundred
/// megabytes. They live under one directory per session so cleanup is a single
/// recursive delete rather than bookkeeping over individual files.
class Workspace {
  Workspace._(this.root);

  final Directory root;

  static Future<Workspace> create() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(
      '${base.path}/crisp/${DateTime.now().millisecondsSinceEpoch}',
    )..createSync(recursive: true);
    return Workspace._(dir);
  }

  String path(String name) => '${root.path}/$name';

  Future<void> dispose() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  }

  /// Sessions that outlived their process — a crash, or a kill during an
  /// encode. Left to a manual call at startup rather than done implicitly,
  /// because deleting on a timer would race a session still in progress.
  static Future<int> purgeOrphans({Duration olderThan = const Duration(hours: 6)}) async {
    final base = await getTemporaryDirectory();
    final crisp = Directory('${base.path}/crisp');
    if (!crisp.existsSync()) return 0;

    var removed = 0;
    final cutoff = DateTime.now().subtract(olderThan);
    for (final entity in crisp.listSync()) {
      if (entity is! Directory) continue;
      if (entity.statSync().modified.isBefore(cutoff)) {
        await entity.delete(recursive: true);
        removed++;
      }
    }
    return removed;
  }
}
