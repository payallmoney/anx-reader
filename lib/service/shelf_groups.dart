import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One-time migration: adopt books left ungrouped by older versions into a
/// shelf folder derived from their `file/<name>/` storage path. Runs at most
/// once ever — afterwards shelf folders are purely virtual and freely
/// editable, so the storage layout must never override manual organisation.
Future<void> reconcileShelfGroups({void Function()? onChanged}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('shelf_layout_reconciled') ?? false) return;

    final db = await DBHelper().database;
    final books = await db.query('tb_books',
        where: 'is_deleted = 0', columns: ['id', 'file_path', 'group_id']);
    if (books.isEmpty) return;

    final byDir = <String, List<Map<String, Object?>>>{};
    for (final book in books) {
      final filePath = (book['file_path'] as String?) ?? '';
      final match = RegExp(r'^file/([^/]+)/').firstMatch(filePath);
      if (match == null) continue;
      byDir.putIfAbsent(match.group(1)!, () => []).add(book);
    }

    var changed = false;
    final now = DateTime.now().toIso8601String();
    final touched = <String>[];
    for (final entry in byDir.entries) {
      final groupName = _sanitizeGroupName(entry.key);
      if (groupName.isEmpty) continue;

      final existing = await db.query('tb_groups',
          where: 'name = ? AND is_deleted = 0',
          whereArgs: [groupName],
          limit: 1);
      int groupId;
      if (existing.isNotEmpty) {
        groupId = existing.first['id'] as int;
      } else {
        // group ids reuse a member book's id (app convention)
        groupId = entry.value.first['id'] as int;
        final byId = await db.query('tb_groups',
            where: 'id = ?', whereArgs: [groupId], limit: 1);
        if (byId.isNotEmpty) {
          await db.update('tb_groups',
              {'name': groupName, 'is_deleted': 0, 'update_time': now},
              where: 'id = ?',
              whereArgs: [groupId]);
        } else {
          await db.insert('tb_groups', {
            'id': groupId,
            'name': groupName,
            'parent_id': 0,
            'is_deleted': 0,
            'create_time': now,
            'update_time': now,
          });
        }
      }

      for (final book in entry.value) {
        final currentGroupId = (book['group_id'] as int?) ?? 0;
        if (currentGroupId == groupId) continue;
        if (currentGroupId != 0) {
          // respect manual folder assignments that are still alive
          final alive = await db.query('tb_groups',
              where: 'id = ? AND is_deleted = 0',
              whereArgs: [currentGroupId],
              limit: 1);
          if (alive.isNotEmpty) continue;
        }
        await db.update('tb_books',
            {'group_id': groupId, 'update_time': now},
            where: 'id = ?',
            whereArgs: [book['id']]);
        changed = true;
        touched.add('${entry.key}#${book['id']}');
      }
    }

    if (changed) {
      AnxLog.info(
          'Shelf groups reconciled from storage layout: ${touched.join(', ')}');
      onChanged?.call();
    }
    // never run again: folders are virtual from now on
    await prefs.setBool('shelf_layout_reconciled', true);
  } catch (e) {
    AnxLog.severe('Shelf group reconcile failed: $e');
  }
}

String _sanitizeGroupName(String folderName) => folderName
    .replaceAll(RegExp(r'[<>:"/\|?*#%&@$^+=\[\]{}`~;!]'), '_')
    .trim();
