import 'dart:async';
import 'dart:io';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:anx_reader/utils/saf_tree.dart';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

String documentPath = '';

/// Check if a path is accessible (can read and write)
Future<bool> _isPathAccessible(String path) async {
  try {
    final dir = Directory(path);
    if (!dir.existsSync()) return false;

    // Try to create and delete a test file to verify write permission
    final testFile = File('$path${Platform.pathSeparator}.anx_permission_test');
    await testFile.writeAsString('test');
    await testFile.delete();
    return true;
  } catch (e) {
    AnxLog.warning('Path not accessible: $path, error: $e');
    return false;
  }
}

Future<String> getAnxDocumentsPath() async {
  // Check for custom storage path first
  if (AnxPlatform.isWindows || AnxPlatform.isAndroid) {
    final customPath = Prefs().customStoragePath;
    if (customPath != null) {
      // Verify the path is still accessible (permission may have been revoked)
      if (await _isPathAccessible(customPath)) {
        return customPath;
      } else {
        // Permission lost, clear the custom path
        AnxLog.warning(
            'Custom storage path no longer accessible, resetting to default');
        Prefs().customStoragePath = null;
      }
    }
  }

  // Android: default to a user-visible folder when all-files access is
  // granted, so imported books (and txt-converted epubs) live somewhere the
  // user can see and manage with any file explorer
  if (AnxPlatform.isAndroid) {
    if (await SafTree.hasAllFilesAccess()) {
      const publicDir = '/storage/emulated/0/AnxReader';
      try {
        final dir = Directory(publicDir);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return publicDir;
      } catch (e) {
        AnxLog.warning('Cannot use public storage dir: $e');
      }
    }
  }

  final directory = await getApplicationDocumentsDirectory();
  switch (AnxPlatform.type) {
    case AnxPlatformEnum.android:
    case AnxPlatformEnum.ohos:
      return directory.path;
    case AnxPlatformEnum.windows:
    case AnxPlatformEnum.linux:
      return (await getApplicationSupportDirectory()).path;
    case AnxPlatformEnum.macos:
      return (await getApplicationSupportDirectory()).path;
    case AnxPlatformEnum.ios:
      return (await getApplicationSupportDirectory()).path;
  }
}

Future<Directory> getAnxDocumentDir() async {
  return Directory(await getAnxDocumentsPath());
}

void initBasePath() async {
  // move existing library data out of the app-private folder when the
  // storage root just switched to a user-visible directory
  unawaited(migrateFromPrivateStorageIfNeeded());

  Directory appDocDir = await getAnxDocumentDir();
  documentPath = appDocDir.path;
  debugPrint('documentPath: $documentPath');
  final fileDir = getFileDir();
  final coverDir = getCoverDir();
  final fontDir = getFontDir();
  final bgimgDir = getBgimgDir();
  if (!fileDir.existsSync()) {
    fileDir.createSync(recursive: true);
  }
  if (!coverDir.existsSync()) {
    coverDir.createSync(recursive: true);
  }
  if (!fontDir.existsSync()) {
    fontDir.createSync(recursive: true);
  }
  if (!bgimgDir.existsSync()) {
    bgimgDir.createSync(recursive: true);
  }
}

/// One-time copy of library folders from the app-private documents
/// directory into the (new) storage root, e.g. after the user granted
/// all-files access and the default root became /storage/emulated/0/AnxReader.
/// Source files are kept; the private copy can be cleared manually later.
Future<void> migrateFromPrivateStorageIfNeeded() async {
  try {
    if (!AnxPlatform.isAndroid) return;
    final newRoot = await getAnxDocumentsPath();
    final privateRoot = (await getApplicationDocumentsDirectory()).path;
    if (newRoot == privateRoot) return;

    final newFileDir = Directory(
        '$newRoot${Platform.pathSeparator}file');
    // only migrate on the very first run in the new root
    if (await newFileDir.exists()) {
      final hasContent = await newFileDir.list().isEmpty == false;
      if (hasContent) return;
    }

    var migrated = 0;
    for (final name in ['file', 'cover', 'font', 'bgimg']) {
      final srcDir = Directory('$privateRoot${Platform.pathSeparator}$name');
      if (!await srcDir.exists()) continue;
      final dstDir = Directory('$newRoot${Platform.pathSeparator}$name');
      await for (final entity in srcDir.list(recursive: false)) {
        if (entity is! File && entity is! Directory) continue;
        final rel = entity.path.substring(srcDir.path.length);
        final target = '$newRoot${Platform.pathSeparator}$name$rel';
        try {
          if (entity is File) {
            final t = File(target);
            if (!await t.exists()) {
              await t.create(recursive: true);
              await entity.copy(target);
              migrated++;
            }
          } else if (entity is Directory) {
            final targetDir = Directory(target);
            if (!await targetDir.exists()) {
              await _copyDirRecursive(entity, targetDir);
              migrated++;
            }
          }
        } catch (e) {
          AnxLog.warning('storage migration: skip ${entity.path}: $e');
        }
      }
    }
    if (migrated > 0) {
      AnxLog.info('storage migration: copied $migrated items to $newRoot');
    }
  } catch (e) {
    AnxLog.warning('storage migration failed: $e');
  }
}

Future<void> _copyDirRecursive(Directory src, Directory dst) async {
  await dst.create(recursive: true);
  await for (final entity in src.list()) {
    final target = '${dst.path}${Platform.pathSeparator}'
        '${entity.path.split(Platform.pathSeparator).last}';
    if (entity is Directory) {
      await _copyDirRecursive(entity, Directory(target));
    } else if (entity is File) {
      final t = File(target);
      if (!await t.exists()) {
        await entity.copy(target);
      }
    }
  }
}

String getBasePath(String path) {
  // the path that in database using "/"
  path.replaceAll("/", Platform.pathSeparator);
  return '$documentPath${Platform.pathSeparator}$path';
}

Directory getFontDir({String? path}) {
  path ??= documentPath;
  return Directory('$path${Platform.pathSeparator}font');
}

Directory getCoverDir({String? path}) {
  path ??= documentPath;
  return Directory('$path${Platform.pathSeparator}cover');
}

Directory getFileDir({String? path}) {
  path ??= documentPath;
  return Directory('$path${Platform.pathSeparator}file');
}

Directory getBgimgDir({String? path}) {
  path ??= documentPath;
  return Directory('$path${Platform.pathSeparator}bgimg');
}
