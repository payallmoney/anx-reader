import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:anx_reader/utils/log/common.dart';

/// Pure-Dart narration fallback for frozen WebViews.
///
/// When the screen is off, Android suspends the WebView renderer: no JS
/// runs at all, so neither the normal ttsNext() call nor the JS-side
/// fallback can make progress and narration stalls at chapter boundaries
/// (or anywhere the next sentence needs the WebView). This class parses
/// the epub file directly in Dart and serves sentences from memory,
/// keeping narration alive without any WebView involvement.
class DartEpubTts {
  DartEpubTts._(this._sentences, this._index);

  final List<String> _sentences;
  int _index;

  /// Parse [bookPath] (an epub zip) and position after [lastSentence]
  /// (the last sentence the normal chain returned, so narration resumes
  /// where it stopped instead of restarting the book).
  static Future<DartEpubTts?> load(
      String bookPath, String? lastSentence) async {
    try {
      List<String> sentences;
      if (_cachedBookPath == bookPath && _cachedSentences != null) {
        sentences = _cachedSentences!;
      } else {
        final bytes = await File(bookPath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);

        final container = _archiveFile(archive, 'META-INF/container.xml');
        if (container == null) return null;
        final opfPath = _rootfilePath(utf8.decode(container));
        if (opfPath == null) return null;
        final opfBytes = _archiveFile(archive, opfPath);
        if (opfBytes == null) return null;
        final opf = utf8.decode(opfBytes);
        final opfDir = opfPath.contains('/')
            ? opfPath.substring(0, opfPath.lastIndexOf('/'))
            : '';

        final hrefs = _spineHrefs(opf);
        if (hrefs.isEmpty) return null;

        sentences = <String>[];
        for (final href in hrefs) {
          final full = opfDir.isEmpty ? href : '$opfDir/$href';
          final data = _archiveFile(archive, full);
          if (data == null) continue;
          final html = utf8.decode(data, allowMalformed: true);
          sentences.addAll(_splitChapter(html));
        }
        if (sentences.isEmpty) return null;
        _cachedSentences = sentences;
        _cachedBookPath = bookPath;
      }

      var index = 0;
      if (lastSentence != null && lastSentence.trim().isNotEmpty) {
        final target = _normalize(lastSentence);
        if (target.isNotEmpty) {
          for (var i = 0; i < sentences.length; i++) {
            final n = _normalize(sentences[i]);
            if (n == target || (target.length >= 6 && n.contains(target))) {
              index = i + 1;
              break;
            }
          }
        }
      }
      AnxLog.info(
          'DartTTS fallback ready: ${sentences.length} sentences, start at $index');
      return DartEpubTts._(sentences, index);
    } catch (e) {
      AnxLog.severe('DartTTS fallback load failed: $e');
      return null;
    }
  }

  /// Next sentence, or '' at the end of the book.
  String next() {
    if (_index >= _sentences.length) return '';
    final s = _sentences[_index];
    _index++;
    return s;
  }

  static void reset() {
    _cachedSentences = null;
    _cachedBookPath = null;
  }

  static List<String>? _cachedSentences;
  static String? _cachedBookPath;
}

List<int>? _archiveFile(Archive archive, String path) {
  final normalized = path.toLowerCase();
  for (final f in archive.files) {
    final n = f.name.toLowerCase();
    if (n == normalized || n.endsWith('/$normalized')) {
      return f.content as List<int>;
    }
  }
  return null;
}

String? _rootfilePath(String containerXml) {
  final m = RegExp(r'full-path="([^"]+)"').firstMatch(containerXml);
  return m?.group(1);
}

/// hrefs of the spine documents in reading order.
List<String> _spineHrefs(String opf) {
  final manifest = <String, String>{};
  for (final m in RegExp(r'<item\b[^>]*>')
      .allMatches(opf)
      .map((m) => m.group(0) ?? '')) {
    final id = RegExp(r'id="([^"]+)"').firstMatch(m)?.group(1);
    final href = RegExp(r'href="([^"]+)"').firstMatch(m)?.group(1);
    if (id != null && href != null) {
      manifest[id] = href;
    }
  }
  final hrefs = <String>[];
  for (final m in RegExp(r'<itemref\b[^>]*>')
      .allMatches(opf)
      .map((m) => m.group(0) ?? '')) {
    final idref = RegExp(r'idref="([^"]+)"').firstMatch(m)?.group(1);
    if (idref != null && manifest[idref] != null) {
      hrefs.add(manifest[idref]!);
    }
  }
  return hrefs;
}

/// Extract narration sentences from one chapter's xhtml: block elements
/// preferred, same terminator rules as the JS splitter.
List<String> _splitChapter(String html) {
  final body = RegExp(r'<body[^>]*>([\s\S]*)</body>', caseSensitive: false)
          .firstMatch(html)
          ?.group(1) ??
      html;
  final withoutNoise = body
      .replaceAll(
          RegExp(r'<(style|script)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
          '')
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

  final sentences = <String>[];
  void push(String text) {
    final t = _decodeEntities(text).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return;
    sentences.addAll(_splitSentences(t));
  }

  final blocks = RegExp(
          r'<(p|h[1-6]|li|blockquote|td|th|dd|dt|caption)[^>]*>([\s\S]*?)</\1>',
          caseSensitive: false)
      .allMatches(withoutNoise)
      .toList();
  if (blocks.isNotEmpty) {
    for (final b in blocks) {
      push(b.group(2) ?? '');
    }
    // loose top-level text that is not inside a block element
    push(withoutNoise
        .replaceAll(
            RegExp(r'<(p|h[1-6]|li|blockquote|td|th|dd|dt|caption)[^>]*>[\s\S]*?</\1>',
                caseSensitive: false),
            '')
        .replaceAll(RegExp(r'<[^>]+>'), ' '));
  } else {
    push(withoutNoise.replaceAll(RegExp(r'<[^>]+>'), ' '));
  }
  return sentences;
}

const _terminators = '。！？.!?…；;';
const _quotes = '"\'\u201c\u201d\u2019\u2018」』';

/// Same rules as the JS-side scanner: split after terminators, keep
/// trailing quotes attached, latin '.' only before whitespace/end.
List<String> _splitSentences(String text) {
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    final isTerm = _terminators.contains(ch);
    if (!isTerm) continue;
    var j = i + 1;
    while (j < text.length && _quotes.contains(text[j])) {
      j++;
    }
    if (ch == '.' && j < text.length && text[j] != ' ') continue;
    out.add(text.substring(start, j));
    start = j;
    i = j - 1;
  }
  if (start < text.length) out.add(text.substring(start));
  return out.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
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

String _normalize(String s) => s.replaceAll(RegExp(r'\s+'), '').trim();
