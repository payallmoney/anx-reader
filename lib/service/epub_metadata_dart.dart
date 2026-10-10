import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Pure-Dart epub metadata extraction, designed to run inside an isolate
/// (`Isolate.run`): the zip parse, OPF read and cover base64 encoding all
/// happen on a background thread, so imports keep flowing while the user
/// reads — the main thread (and the reader's webview) is untouched.
///
/// Returns a map shaped like the webview onMetadata payload, or null when
/// the file cannot be parsed (caller falls back to the webview path).
Map<String, String?>? extractEpubMetadataDart((String, String, bool) args) {
  final (path, coverDir, skipCover) = args;
  try {
    final bytes = File(path).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);

    ArchiveFile? fileByPath(String p) {
      final n = p.toLowerCase();
      for (final f in archive.files) {
        final fn = f.name.toLowerCase();
        if (fn == n || fn.endsWith('/$n')) return f;
      }
      return null;
    }

    final container = fileByPath('META-INF/container.xml');
    if (container == null) return null;
    final m = RegExp(r'full-path="([^"]+)"')
        .firstMatch(utf8.decode(container.content as List<int>));
    final opfPath = m?.group(1);
    if (opfPath == null) return null;
    final opfFile = fileByPath(opfPath);
    if (opfFile == null) return null;
    final opf = utf8.decode(opfFile.content as List<int>, allowMalformed: true);

    String? tagText(String tag) {
      final t = RegExp('<dc:$tag[^>]*>([\\s\\S]*?)</dc:$tag>')
          .firstMatch(opf)
          ?.group(1);
      if (t == null) return null;
      return _decodeEntities(t).replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    final title = tagText('title');
    final author = tagText('creator');

    // parse manifest items once: id -> (href, mediaType, properties)
    final items = <String, List<String>>{};
    for (final item in RegExp(r'<item\b[^>]*>').allMatches(opf)) {
      final tag = item.group(0)!;
      String? attr(String name) =>
          RegExp('$name="([^"]+)"').firstMatch(tag)?.group(1) ??
          RegExp("$name='([^']+)'").firstMatch(tag)?.group(1);
      final id = attr('id');
      if (id != null) {
        items[id] = [attr('href') ?? '', attr('media-type') ?? '', attr('properties') ?? ''];
      }
    }

    String? coverRef;
    // 1. explicit cover-image property
    for (final v in items.values) {
      if (v[2].contains('cover-image')) {
        coverRef = v[0];
        break;
      }
    }
    // 2. meta name="cover" content="id"
    coverRef ??= RegExp(
            '<meta\\b[^>]*name="cover"[^>]*content="([^"]+)"',
            caseSensitive: false)
        .firstMatch(opf)
        ?.group(1);
    // 3. any manifest image whose href mentions cover
    if (coverRef == null || !items.containsKey(coverRef)) {
      for (final v in items.values) {
        if (v[1].startsWith('image/') && v[0].toLowerCase().contains('cover')) {
          coverRef = v[0];
          break;
        }
      }
    }

    // the cover is the single most expensive item (image entry extraction
    // + file write) — reading-mode imports skip it and backfill later
    String cover = '';
    final href = skipCover ? null : coverRef;
    if (href != null && items.containsKey(href)) {
      final mediaType = items[href]![1];
      final full = opfDir(opfPath, href);
      final cf = fileByPath(full);
      if (cf != null && mediaType.startsWith('image/')) {
        final ext = mediaType.split('/').last.split(';').first;
        // write the cover straight from the zip entry here in the isolate:
        // returning multi-MB data URIs to the main isolate copies them and
        // forces a decode there (visible UI stutter during imports)
        final fileName = 'iso_${DateTime.now().microsecondsSinceEpoch}.$ext';
        File(p.join(coverDir, fileName))
            .writeAsBytesSync(cf.content as List<int>);
        cover = 'cover/$fileName';
      }
    }

    return {
      'title': (title == null || title.isEmpty) ? null : title,
      'author': (author == null || author.isEmpty) ? null : author,
      'description': '',
      'cover': cover,
    };
  } catch (_) {
    return null;
  }
}

String opfDir(String opfPath, String href) {
  final dir = opfPath.contains('/')
      ? opfPath.substring(0, opfPath.lastIndexOf('/'))
      : '';
  return dir.isEmpty ? href : '$dir/$href';
}

String _decodeEntities(String s) {
  return s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    return code == null ? '' : String.fromCharCode(code);
  }).replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return code == null ? '' : String.fromCharCode(code);
  });
}
