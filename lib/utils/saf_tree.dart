import 'dart:io';

import 'package:flutter/services.dart';

class SafFileEntry {
  const SafFileEntry({required this.uri, required this.name, required this.size});

  final String uri;
  final String name;
  final int size;
}

class SafTreeListing {
  const SafTreeListing({required this.rootName, required this.files});

  /// display name of the picked folder, used as the storage subdirectory
  final String rootName;
  final List<SafFileEntry> files;
}

class SafCopyResult {
  const SafCopyResult({required this.path, required this.md5, required this.size});

  final String path;
  final String md5;
  final int size;
}

/// Android SAF tree access.
///
/// Folder pickers on Android return `content://` tree URIs which dart:io
/// cannot read. The native side (MainActivity, channel `saf_tree`)
/// enumerates book files under the tree and streams them directly into a
/// destination directory while computing the MD5 in the same pass.
class SafTree {
  static const MethodChannel _channel =
      MethodChannel('com.anxcye.anx_reader/saf_tree');

  /// Whether [path] is a SAF tree uri returned by the Android picker.
  static bool isTreeUri(String path) => path.startsWith('content://');

  static bool? _cachedAllFilesAccess;

  /// Whether the user granted all-files access, allowing the app to keep
  /// its library in a user-visible folder. Cached per process run.
  static Future<bool> hasAllFilesAccess() async {
    if (_cachedAllFilesAccess != null) return _cachedAllFilesAccess!;
    try {
      final granted =
          await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
      _cachedAllFilesAccess = granted;
      return granted;
    } catch (_) {
      return false;
    }
  }

  /// Open the system page to grant all-files access; returns false when
  /// already granted or unavailable.
  static Future<bool> requestAllFilesAccess() async {
    try {
      final opened =
          await _channel.invokeMethod<bool>('requestAllFilesAccess') ?? false;
      if (opened) _cachedAllFilesAccess = null;
      return opened;
    } catch (_) {
      return false;
    }
  }

  /// Consume the book path handed over via `am start --es auto_tts_path`
  /// for adb-driven narration tests; null when absent.
  static Future<String?> consumeAutoTtsPath() async {
    try {
      return await _channel.invokeMethod<String>('consumeAutoTtsPath');
    } catch (_) {
      return null;
    }
  }

  /// Consume the folder path handed over via `am start --es
  /// auto_import_folder` for adb-driven import tests; null when absent.
  static Future<String?> consumeAutoImportFolder() async {
    try {
      return await _channel.invokeMethod<String>('consumeAutoImportFolder');
    } catch (_) {
      return null;
    }
  }

  /// Open the system folder picker and return the raw SAF tree uri.
  ///
  /// file_picker's getDirectoryPath converts the uri into a plain path
  /// which scoped storage forbids listing, so on Android use this instead.
  static Future<String?> pickDirectory() async {
    return await _channel.invokeMethod<String>('pickDirectory');
  }

  static Future<SafTreeListing> listBookFiles(String treeUri) async {
    final result = await _channel.invokeMethod<dynamic>(
        'listBookFiles', <String, dynamic>{'treeUri': treeUri});
    if (result is! Map) {
      return const SafTreeListing(rootName: 'imported', files: []);
    }
    final files = <SafFileEntry>[];
    for (final e in (result['files'] as List? ?? const [])) {
      final map = e as Map<dynamic, dynamic>;
      files.add(SafFileEntry(
        uri: map['uri'] as String,
        name: map['name'] as String? ?? 'book',
        size: (map['size'] as num?)?.toInt() ?? 0,
      ));
    }
    return SafTreeListing(
      rootName: result['rootName'] as String? ?? 'imported',
      files: files,
    );
  }

  /// Stream one SAF document into [destDir] with its original file name,
  /// computing the MD5 during the copy; no temp file, no name prefix.
  static Future<SafCopyResult> copyToDir(
      String uri, String fileName, String destDir) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'copyToDir', <String, dynamic>{
      'uri': uri,
      'fileName': fileName,
      'destDir': destDir,
    });
    return SafCopyResult(
      path: result!['path'] as String,
      md5: result['md5'] as String,
      size: (result['size'] as num?)?.toInt() ?? 0,
    );
  }
}
