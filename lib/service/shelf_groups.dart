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

    final sw = Stopwatch()..start();
    final db = await DBHelper().database;
    final books = await db.query('tb_books',
        where: 'is_deleted = 0', columns: ['id', 'file_path', 'group_id']);
    if (books.isEmpty) {
      await prefs.setBool('shelf_layout_reconciled', true);
      return;
    }

    final byDir = <String, List<Map<String, Object?>>>{};
    for (final book in books) {
      final filePath = (book['file_path'] as String?) ?? '';
      final match = RegExp(r'^file/([^/]+)/').firstMatch(filePath);
      if (match == null) continue;
      byDir.putIfAbsent(match.group(1)!, () => []).add(book);
    }
    if (byDir.isEmpty) {
      await prefs.setBool('shelf_layout_reconciled', true);
      return;
    }

    // one query for the live folder rows instead of one per book
    final liveGroupIds = (await db.query('tb_groups',
            where: 'is_deleted = 0', columns: ['id', 'name']))
        .map((row) => MapEntry(row['id'] as int, row['name'] as String? ?? ''))
        .toList();

    final now = DateTime.now().toIso8601String();
    final touched = <String>[];

    await db.transaction((txn) async {
      for (final entry in byDir.entries) {
        final groupName = _sanitizeGroupName(entry.key);
        if (groupName.isEmpty) continue;

        int groupId = -1;
        for (final g in liveGroupIds) {
          if (g.value == groupName) {
            groupId = g.key;
            break;
          }
        }
        if (groupId > 0) {
          // folder already exists
        } else {
          // group ids reuse a member book's id (app convention)
          groupId = entry.value.first['id'] as int;
          final byId = await txn.query('tb_groups',
              where: 'id = ?', whereArgs: [groupId], limit: 1);
          if (byId.isNotEmpty) {
            await txn.update('tb_groups',
                {'name': groupName, 'is_deleted': 0, 'update_time': now},
                where: 'id = ?', whereArgs: [groupId]);
          } else {
            await txn.insert('tb_groups', {
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
          if (currentGroupId != 0 &&
              liveGroupIds.any((g) => g.key == currentGroupId)) {
            // respect manual folder assignments that are still alive
            continue;
          }
          await txn.update('tb_books',
              {'group_id': groupId, 'update_time': now},
              where: 'id = ?',
              whereArgs: [book['id']]);
          touched.add('${entry.key}#${book['id']}');
        }
      }
    });

    // never run again: folders are virtual from now on
    await prefs.setBool('shelf_layout_reconciled', true);
    AnxLog.info(
        'Shelf groups reconciled in ${sw.elapsedMilliseconds}ms (${touched.length} books)');
    if (touched.isNotEmpty) {
      onChanged?.call();
    }
  } catch (e) {
    AnxLog.severe('Shelf group reconcile failed: $e');
  }
}

String _sanitizeGroupName(String folderName) => folderName
    .replaceAll(RegExp(r'[<>:"/\|?*#%&@$^+=\[\]{}`~;!]'), '_')
    .trim();
