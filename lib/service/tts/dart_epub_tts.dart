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

  /// Parse [bookPath] (an epub zip) and position at the narration cursor.
  /// Positioning order:
  /// 1. the continuously-synced cursor (see [syncCursor]) — an exact index
  ///    with no text ambiguity,
  /// 2. a LOCAL text match of [lastSentence] around the cursor (the JS and
  ///    Dart splitters can differ slightly at the same spot),
  /// 3. a global text match — only when no cursor exists yet,
  /// 4. an estimate from [progressHint] (book reading percentage).
  /// A global text match is never used when a cursor exists: chapter
  /// headers and TOC entries duplicate sentence texts early in the book,
  /// and matching one of those restarts narration chapters behind.
  static Future<DartEpubTts?> load(String bookPath, String? lastSentence,
      {double? progressHint}) async {
    try {
      final sentences = await _ensureParsed(bookPath);
      if (sentences == null) return null;

      final haveCursor = _syncedBookPath == bookPath &&
          _syncedIndex > 0 &&
          _syncedIndex < sentences.length;

      var index = -1;
      if (lastSentence != null && lastSentence.trim().isNotEmpty) {
        final target = _normalize(lastSentence);
        if (target.isNotEmpty) {
          if (haveCursor) {
            // search forward from just before the cursor (narration is
            // monotonic); a backward scan could latch onto a duplicate
            // header/TOC entry sitting between the match and the cursor
            final from = _syncedIndex > 1 ? _syncedIndex - 1 : 0;
            for (var i = from; i < sentences.length; i++) {
              if (_sentenceMatches(sentences[i], target)) {
                index = i + 1;
                AnxLog.info(
                    'DartTTS fallback: local match at $i (cursor $_syncedIndex)');
                break;
              }
            }
          } else {
            // no cursor at all (fallback engaged before any sync): a global
            // search is the only option
            for (var i = 0; i < sentences.length; i++) {
              if (_sentenceMatches(sentences[i], target)) {
                index = i + 1;
                AnxLog.info('DartTTS fallback: global match at $i');
                break;
              }
            }
          }
        }
      }
      if (index < 0 && haveCursor) {
        index = _syncedIndex;
        AnxLog.info('DartTTS fallback: using synced cursor $index');
      }
      if (index < 0 && progressHint != null && progressHint > 0) {
        index = (progressHint * sentences.length).floor();
        AnxLog.info(
            'DartTTS fallback: estimated index $index from progress $progressHint');
      }
      if (index < 0) index = 0;
      if (index > sentences.length) index = sentences.length;

      AnxLog.info(
          'DartTTS fallback ready: ${sentences.length} sentences, start at $index');
      return DartEpubTts._(sentences, index);
    } catch (e) {
      AnxLog.severe('DartTTS fallback load failed: $e');
      return null;
    }
  }

  /// Keep a running cursor while narration flows through the normal
  /// (WebView) path, so switching to the fallback mid-book resumes at the
  /// right position even if sentence texts are split differently.
  /// Lazy: the first call parses the book in the background.
  static Future<void> syncCursor(String bookPath, String sentence) async {
    if (sentence.trim().isEmpty) return;
    try {
      final sentences = await _ensureParsed(bookPath);
      if (sentences == null) return;
      if (_syncedBookPath != bookPath) {
        _syncedBookPath = bookPath;
        _syncedIndex = 0;
      }
      final target = _normalize(sentence);
      if (target.isEmpty) return;
      // narration is monotonic: search forward from the cursor first
      for (var i = _syncedIndex; i < sentences.length; i++) {
        if (_sentenceMatches(sentences[i], target)) {
          _syncedIndex = i + 1;
          return;
        }
      }
      // a small backward window covers re-speaks and splitter lag; never
      // wrap to the book start — duplicate headers/TOC entries there would
      // drag the cursor chapters behind
      final from = _syncedIndex > 120 ? _syncedIndex - 120 : 0;
      for (var i = from; i < _syncedIndex; i++) {
        if (_sentenceMatches(sentences[i], target)) {
          _syncedIndex = i + 1;
          return;
        }
      }
      // no text match at all (splitters diverged): assume narration still
      // advanced one sentence so the cursor keeps roughly pace
      if (_syncedIndex < sentences.length - 1) _syncedIndex++;
    } catch (_) {}
  }

  /// Tolerant match: exact, containment either way, or shared 12-char
  /// prefix — the JS and Dart splitters can merge/split sentences
  /// differently at the same position in the book.
  static bool _sentenceMatches(String candidate, String normTarget) {
    final n = _normalize(candidate);
    if (n == normTarget) return true;
    if (normTarget.length >= 6 && n.length >= 6) {
      if (n.contains(normTarget) || normTarget.contains(n)) return true;
    }
    final prefixLen = normTarget.length < 12 ? normTarget.length : 12;
    if (prefixLen >= 8 && n.startsWith(normTarget.substring(0, prefixLen))) {
      return true;
    }
    return false;
  }

  static int _syncedIndex = 0;
  static String? _syncedBookPath;

  static Future<List<String>?> _ensureParsed(String bookPath) async {
    if (_cachedBookPath == bookPath && _cachedSentences != null) {
      return _cachedSentences;
    }
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

    final sentences = <String>[];
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
    return sentences;
  }

  /// Next sentence, or '' at the end of the book.
  String next() {
    if (_index >= _sentences.length) return '';
    final s = _sentences[_index];
    _index++;
    return s;
  }

  /// Narration position as a fraction of the whole book — used to sync the
  /// reader UI back to the spoken position when the screen wakes (the
  /// fallback narrates without touching the frozen webview, so the visible
  /// page would otherwise stay where the screen turned off).
  double get positionFraction =>
      _sentences.isEmpty ? 0 : (_index / _sentences.length).clamp(0.0, 1.0);

  /// Peek at upcoming sentences without advancing the cursor; used by the
  /// online-TTS prefetcher when the WebView is frozen. Each sentence gets a
  /// synthetic cfi carrying its absolute index — the online pipeline's
  /// dedup keys on cfi, and a text-hash key collided on repeated sentences,
  /// starving the buffer (narration died mid-chapter). Highlighting skips
  /// these synthetic cfis.
  List<Map<dynamic, dynamic>> peekList(int count, {int offset = 0}) {
    final out = <Map<dynamic, dynamic>>[];
    final start = _index + offset;
    for (var i = start; i < start + count && i < _sentences.length; i++) {
      out.add(<dynamic, dynamic>{
        'text': _sentences[i],
        'cfi': 'dart-tts://$_cachedBookPath#$i',
      });
    }
    return out;
  }

  static void reset() {
    _cachedSentences = null;
    _cachedBookPath = null;
    _syncedIndex = 0;
    _syncedBookPath = null;
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
