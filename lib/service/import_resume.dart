import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Durable record of an in-flight folder import so it survives an app
/// restart: on the next launch the pending task is detected, the floating
/// progress pill reappears, and the remaining files continue importing.
class PendingImport {
  const PendingImport({
    required this.treeUri,
    required this.subDirName,
    required this.fileNames,
    required this.doneNames,
    this.failedNames = const [],
  });

  final String treeUri;
  final String subDirName;

  /// every file the import will process (SAF document names)
  final List<String> fileNames;

  /// files already imported (an md5-based book row exists on the shelf)
  final Set<String> doneNames;
  final List<String> failedNames;

  int get remaining => fileNames.where((f) => !doneNames.contains(f)).length;

  Map<String, Object?> toJson() => {
        'treeUri': treeUri,
        'subDirName': subDirName,
        'fileNames': fileNames,
        'doneNames': doneNames.toList(),
        'failedNames': failedNames,
      };

  static PendingImport? fromJson(Map<String, Object?> json) {
    final treeUri = json['treeUri'] as String?;
    final subDirName = json['subDirName'] as String?;
    final fileNames = (json['fileNames'] as List?)?.cast<String>();
    final doneNames = (json['doneNames'] as List?)?.cast<String>();
    if (treeUri == null || subDirName == null || fileNames == null) {
      return null;
    }
    return PendingImport(
      treeUri: treeUri,
      subDirName: subDirName,
      fileNames: fileNames,
      doneNames: doneNames?.toSet() ?? {},
      failedNames: (json['failedNames'] as List?)?.cast<String>() ?? [],
    );
  }

  static const _prefKey = 'pending_folder_import';

  static Future<void> save(PendingImport task) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(task.toJson()));
  }

  static Future<PendingImport?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return fromJson(jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
  }
}
