import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:path/path.dart' as p;

/// Resolve the directory WebDAV downloads are written to.
/// A manually configured path wins; otherwise books land in
/// `<documents>/downloads` inside the app storage root.
Future<Directory> getWebdavDownloadDir() async {
  final custom = Prefs().webdavDownloadPath;
  if (custom != null && custom.isNotEmpty) {
    final dir = Directory(custom);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
  final base = await getAnxDocumentsPath();
  final dir = Directory(p.join(base, 'downloads'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// Human-readable form of the download directory for settings UI.
Future<String> webdavDownloadDirLabel() async =>
    Prefs().webdavDownloadPath ?? p.join(await getAnxDocumentsPath(), 'downloads');
