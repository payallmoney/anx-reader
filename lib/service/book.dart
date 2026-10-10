import 'dart:io';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/theme.dart';
import 'package:anx_reader/enums/sync_direction.dart';
import 'package:anx_reader/enums/sync_trigger.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/current_reading_state.dart';
import 'package:anx_reader/page/home_page.dart';
import 'package:anx_reader/page/iap_page.dart';
import 'package:anx_reader/providers/ai_chat.dart';
import 'package:anx_reader/providers/chapter_content_bridge.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:anx_reader/providers/iap.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/toc_search.dart';
import 'package:anx_reader/service/convert_to_epub/txt/convert_from_txt.dart';
import 'package:anx_reader/service/import_reading_gate.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/utils/webView/anx_headless_webview.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/get_path/get_temp_dir.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/utils/import_book.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/utils/webView/gererate_url.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import 'book_player/book_player_server.dart';

AnxHeadlessWebView? headlessInAppWebView;
final allowBookExtensions = ["epub", "mobi", "azw3", "fb2", "txt", "pdf"];

/// import book list. Books already on the user's filesystem are referenced
/// in place; only ephemeral files (picker cache, share attachments, txt
/// conversions) are copied into app storage by [saveBook].
void importBookList(List<File> fileList, BuildContext context, WidgetRef ref) {
  AnxLog.info('importBook fileList: ${fileList.toString()}');

  List<File> supportedFiles = fileList.where((file) {
    return allowBookExtensions
        .contains(file.path.split('.').last.toLowerCase());
  }).toList();

  List<File> unsupportedFiles = fileList.where((file) {
    return !allowBookExtensions
        .contains(file.path.split('.').last.toLowerCase());
  }).toList();

  _checkDuplicatesAndShowDialog(
    supportedFiles,
    unsupportedFiles,
    fileList,
    context,
    ref,
  );
}

/// Expands paths into book files, recursing into subdirectories so that
/// every supported book under a dropped/picked folder is loaded.
/// Unreadable directories are skipped instead of aborting the scan.
Future<List<File>> collectBookFiles(List<String> paths) async {
  final result = <File>[];
  for (final rawPath in paths) {
    if (rawPath.isEmpty) continue;
    final type = FileSystemEntity.typeSync(rawPath, followLinks: true);
    if (type == FileSystemEntityType.directory) {
      await _collectFromDirectory(Directory(rawPath), result);
    } else if (type == FileSystemEntityType.file) {
      result.add(File(rawPath));
    }
  }
  return result;
}

Future<void> _collectFromDirectory(Directory dir, List<File> out) async {
  List<FileSystemEntity> children;
  try {
    children = dir.listSync(followLinks: false);
  } catch (e) {
    AnxLog.warning('Import: cannot list ${dir.path}: $e');
    return;
  }
  for (final entity in children) {
    if (entity is Directory) {
      await _collectFromDirectory(entity, out);
    } else if (entity is File) {
      if (allowBookExtensions
          .contains(entity.path.split('.').last.toLowerCase())) {
        out.add(entity);
      }
    }
  }
}

void _checkDuplicatesAndShowDialog(
    List<File> supportedFiles,
    List<File> unsupportedFiles,
    List<File> fileList,
    BuildContext context,
    WidgetRef ref) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(L10n.of(context).md5Calculating),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(L10n.of(context).md5Calculating),
        ],
      ),
    ),
  );

  try {
    final filePaths = supportedFiles.map((f) => f.path).toList();
    final checkResults = await MD5Service.checkImportFiles(filePaths);

    Navigator.of(context).pop();

    List<File> duplicateFiles = [];
    List<File> uniqueFiles = [];
    Map<String, Book> duplicateInfo = {};

    for (int i = 0; i < supportedFiles.length; i++) {
      final file = supportedFiles[i];
      final result = checkResults[i];

      if (result.isDuplicate && result.duplicateBook != null) {
        duplicateFiles.add(file);
        duplicateInfo[file.path] = result.duplicateBook!;
      } else {
        uniqueFiles.add(file);
      }
    }

    _showImportDialog(
      uniqueFiles,
      duplicateFiles,
      duplicateInfo,
      unsupportedFiles,
      fileList,
      ref,
    );
  } catch (e) {
    Navigator.of(navigatorKey.currentContext!).pop();
    AnxLog.severe('MD5 check failed: $e');
    _showImportDialog(
      supportedFiles,
      [],
      {},
      unsupportedFiles,
      fileList,
      ref,
    );
  }
}

void _showImportDialog(
  List<File> uniqueFiles,
  List<File> duplicateFiles,
  Map<String, Book> duplicateInfo,
  List<File> unsupportedFiles,
  List<File> fileList,
  WidgetRef ref,
) {
  BuildContext context = navigatorKey.currentContext!;

  Widget bookItem(
    String filePath,
    Widget icon, {
    bool isDuplicate = false,
    String? duplicateTitle,
    String? errorMessage,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: icon,
            ),
            Expanded(
              child: Text(
                path.basename(filePath),
                style: TextStyle(
                  fontWeight: FontWeight.w300,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (errorMessage != null)
              IconButton(
                icon: const Icon(Icons.info_outline, size: 16),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(L10n.of(context).commonError),
                      content: SelectableText(errorMessage),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(L10n.of(context).commonOk),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
        if (isDuplicate && duplicateTitle != null)
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 2),
            child: Text(
              L10n.of(context).duplicateOf(duplicateTitle),
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ),
        if (errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 2),
            child: Text(
              'Error: ${errorMessage.length > 50 ? "${errorMessage.substring(0, 50)}..." : errorMessage}',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.red,
              ),
            ),
          ),
      ],
    );
  }

  final supportedFiles = [...uniqueFiles, ...duplicateFiles];
  bool skipDuplicates = true;

  showDialog(
      context: context,
      builder: (BuildContext context) {
        String currentHandlingFile = '';
        List<String> errorFiles = [];
        bool finished = false;
        Map<String, String> errorMessages = {};

        return StatefulBuilder(builder: (context, setState) {
          return AlertDialog(
            title: Text(L10n.of(context).importNBooksSelected(fileList.length)),
            contentPadding: const EdgeInsets.all(16),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(L10n.of(context)
                      .importSupportTypes(allowBookExtensions.join(' / '))),

                  const SizedBox(height: 10),

                  // show unique files
                  for (var file in uniqueFiles)
                    file.path == currentHandlingFile
                        ? bookItem(
                            file.path,
                            Container(
                              padding: const EdgeInsets.all(3),
                              width: 20,
                              height: 20,
                              child: const CircularProgressIndicator(),
                            ))
                        : bookItem(
                            file.path,
                            errorFiles.contains(file.path)
                                ? const Icon(Icons.error)
                                : const Icon(Icons.done),
                            errorMessage: errorFiles.contains(file.path)
                                ? errorMessages[file.path]
                                : null,
                          ),

                  // show unsupported files
                  if (unsupportedFiles.isNotEmpty) ...[
                    Divider(),
                    SizedBox(height: 10),
                    Text(L10n.of(context)
                        .importNBooksNotSupport(unsupportedFiles.length))
                  ],
                  for (var file in unsupportedFiles)
                    bookItem(file.path, const Icon(Icons.error)),

                  // show duplicate files
                  if (duplicateFiles.isNotEmpty) ...[
                    Divider(),
                    const SizedBox(height: 10),
                    Text(L10n.of(context).duplicateFile),
                  ],
                  for (var file in duplicateFiles)
                    if (skipDuplicates)
                      bookItem(
                        file.path,
                        const Icon(Icons.double_arrow_rounded),
                        isDuplicate: true,
                        duplicateTitle: duplicateInfo[file.path]?.title,
                      )
                    else
                      file.path == currentHandlingFile
                          ? bookItem(
                              file.path,
                              Container(
                                padding: const EdgeInsets.all(3),
                                width: 20,
                                height: 20,
                                child: const CircularProgressIndicator(),
                              ),
                              isDuplicate: true,
                              duplicateTitle: duplicateInfo[file.path]?.title,
                            )
                          : bookItem(
                              file.path,
                              errorFiles.contains(file.path)
                                  ? const Icon(Icons.error)
                                  : const Icon(Icons.done),
                              isDuplicate: true,
                              duplicateTitle: duplicateInfo[file.path]?.title,
                              errorMessage: errorFiles.contains(file.path)
                                  ? errorMessages[file.path]
                                  : null,
                            ),

                  // select skip duplicates
                  if (duplicateFiles.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Checkbox(
                          value: skipDuplicates,
                          onChanged: (value) {
                            setState(() {
                              skipDuplicates = value ?? true;
                            });
                          },
                        ),
                        Expanded(
                          child: Text(L10n.of(context).skipDuplicateFiles),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  for (var file in supportedFiles) {
                    file.deleteSync();
                  }
                },
                child: Text(L10n.of(context).commonCancel),
              ),
              if (uniqueFiles.isNotEmpty ||
                  (duplicateFiles.isNotEmpty && !skipDuplicates))
                TextButton(
                    onPressed: () async {
                      if (finished) {
                        Navigator.of(context).pop('dialog');
                        return;
                      }

                      List<File> filesToImport = [...uniqueFiles];
                      if (!skipDuplicates) {
                        filesToImport.addAll(duplicateFiles);
                      }

                      for (var file in filesToImport) {
                        AnxToast.show(path.basename(file.path));
                        setState(() {
                          currentHandlingFile = file.path;
                        });
                        try {
                          await importBook(file, ref);
                          setState(() {
                            currentHandlingFile = '';
                          });
                        } catch (e, stackTrace) {
                          AnxLog.severe('Failed to import ${file.path}: $e');
                          AnxLog.severe('Stack trace: $stackTrace');
                          setState(() {
                            errorFiles.add(file.path);
                            errorMessages[file.path] = e.toString();
                          });
                        }
                      }

                      // duplicate files stay untouched on the user's disk
                      // when skipDuplicates is true; otherwise they are
                      // re-imported in place

                      setState(() {
                        finished = true;
                      });
                      ref.read(syncProvider.notifier).syncData(
                          SyncDirection.upload, ref,
                          trigger: SyncTrigger.auto);
                    },
                    child: Text(finished
                        ? L10n.of(context).commonOk
                        : L10n.of(context).importImportNBooks(
                            uniqueFiles.length +
                                (skipDuplicates ? 0 : duplicateFiles.length) -
                                errorFiles.length))),
            ],
          );
        });
      });
}

Future<void> importBook(File file, WidgetRef ref,
    {String? precomputedMd5, String? storageSubDir, int? groupId}) async {
  // keep the original file name for converted/templated outputs so no
  // numeric suffix sneaks into the stored file name
  final preferredName = path.basenameWithoutExtension(file.path);
  String? md5 = precomputedMd5 ?? await MD5Service.calculateFileMd5(file.path);

  if (file.path.split('.').last == 'txt') {
    // txt is not directly readable by the reader pipeline; the converted
    // epub lands in the app temp dir and is imported into app storage by
    // saveBook. The original txt on the user's disk is never touched; the
    // streamed copy inside app storage is just an intermediate file.
    final tempFile = await convertFromTxt(file);
    if (path.isWithin(getBasePath('file'), file.path) ||
        await isAppTempFile(file.path)) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
    file = tempFile;
    md5 = precomputedMd5 ?? await MD5Service.calculateFileMd5(file.path);
  }

  await getBookMetadata(file,
      md5: md5,
      ref: ref,
      storageSubDir: storageSubDir,
      preferredName: preferredName,
      groupId: groupId);
  ref.read(bookListProvider.notifier).refresh();
}

Future<void> pushToReadingPage(
  WidgetRef ref,
  BuildContext context,
  Book book, {
  String? cfi,
  String? heroTag,
}) async {
  if (book.isDeleted) {
    AnxToast.show(L10n.of(context).bookDeleted);
    return;
  }

  if (!File(book.fileFullPath).existsSync()) {
    ref.read(syncProvider.notifier).downloadBook(book);
    return;
  }

  if (EnvVar.enableInAppPurchase) {
    final iapAsync = ref.read(iapProvider);
    final isFeatureAvailable = iapAsync.maybeWhen(
      data: (state) => state.isFeatureAvailable,
      orElse: () => ref.read(iapProvider.notifier).cachedFeatureAvailable(),
    );

    if (!isFeatureAvailable) {
      Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (context) => const IAPPage(),
        ),
      );
      return;
    }
  }
  ref.read(aiChatProvider.notifier).clear();
  final initialThemes = await themeDao.selectThemes();
  ref.read(currentReadingProvider.notifier).start(
        CurrentReadingState(
          book: book,
          cfi: cfi,
        ),
      );

  final currentReading = ref.read(currentReadingProvider.notifier);
  final chapterContentBridge = ref.read(chapterContentBridgeProvider.notifier);
  final tocSearch = ref.read(tocSearchProvider.notifier);

  await Navigator.push(
    navigatorKey.currentContext!,
    CupertinoPageRoute(
      builder: (c) => ReadingPage(
        key: readingPageKey,
        book: book,
        cfi: cfi,
        initialThemes: initialThemes,
        heroTag: heroTag,
      ),
    ),
  ).then((_) {
    AnxLog.info('ReadingPage: poped: ${book.title}');
    currentReading.finish();
    chapterContentBridge.state = null;
    tocSearch.clear();
    AnxLog.info('Pop successfully ReadingPage: ${book.title}');
  });
}

void updateBookRating(Book book, double rating) {
  book.rating = rating;
  bookDao.updateBook(book);
}

Future<void> resetBookCover(Book book) async {
  File file = File(book.fileFullPath);
  getBookMetadata(file);
}

/// Whether [filePath] lives inside the app's temp/cache directory, i.e. it
/// has no durable original on the user's disk (picker copies, share
/// attachments, converted files) and must be imported into app storage.
Future<bool> isAppTempFile(String filePath) async {
  final tempDir = await getAnxTempDir();
  final dir = path.dirname(filePath);
  return path.equals(dir, tempDir.path) || path.isWithin(tempDir.path, dir);
}

Future<void> saveBook(
  File file,
  String title,
  String author,
  String description,
  String? md5,
  String cover, {
  Book? provideBook,
  String? storageSubDir,
  String? preferredName,
  int? groupId,
}) async {
  // Extract original filename (without extension)
  final fileNameWithoutExt = path.basenameWithoutExtension(file.path);

  // Use original filename if title is invalid
  final effectiveTitle =
      (title == 'Unknown' || title.trim().isEmpty) ? fileNameWithoutExt : title;

  final newBookName =
      '${effectiveTitle.length > 20 ? effectiveTitle.substring(0, 20) : effectiveTitle}-${DateTime.now().millisecondsSinceEpoch}'
          // Strip characters that some WebDAV servers (e.g. Jianguoyun) reject (#989)
          .replaceAll(RegExp(r'[<>:"/\\|?*#%&@$^+=\[\]{}`~;!]'), '_')
          .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
          .trim();

  final extension = file.path.split('.').last;

  // Books already on the user's filesystem are referenced in place: the
  // database records the original absolute path (preserving the full
  // multi-level directory structure) and nothing is copied. Files that only
  // exist in the app's temp/cache directory (system picker copies, share
  // attachments, converted txt) have no durable original and are still
  // imported into app storage under the given subdirectory layout.
  final subDir = storageSubDir ?? 'file';
  // prefer the original file name (folder imports) so no numeric suffix is
  // added; fall back to title-timestamp for classic single-file imports
  final storedName = (preferredName != null && preferredName.trim().isNotEmpty)
      ? preferredName
          .replaceAll(RegExp(r'[<>:"/\\|?*#%&@$^+=\[\]{}`~;!]'), '_')
          .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
          .trim()
      : newBookName;
  String dbFilePath;
  if (path.isWithin(getBasePath(subDir), file.path)) {
    // already streamed into the destination folder by the SAF import:
    // keep the original file name, no re-copy
    dbFilePath = '$subDir/${path.basename(file.path)}';
  } else if (await isAppTempFile(file.path)) {
    var nameToUse = storedName;
    var skipCopy = false;
    final existing = File(getBasePath('$subDir/$storedName.$extension'));
    if (await existing.exists()) {
      // A file with the same name already exists in this folder import.
      // The md5 never matches for txt books (the stored copy is the
      // converted epub), so treat the same name as the same book and
      // overwrite the stored copy: re-imports stay idempotent and no
      // timestamp suffix is ever added.
      final sameFile = md5 != null &&
          await MD5Service.calculateFileMd5(existing.path) == md5;
      skipCopy = sameFile;
      nameToUse = storedName;
    }
    dbFilePath = '$subDir/$nameToUse.$extension';
    if (!skipCopy) {
      await file.copy(getBasePath(dbFilePath));
    }
    // remove cached file
    file.delete();
  } else {
    dbFilePath = file.path;
  }
  String? dbCoverPath = 'cover/$newBookName';
  // final coverPath = getBasePath(dbCoverPath);

  dbCoverPath = await saveImageToLocal(cover, dbCoverPath);
  if (md5 != null) {
    provideBook ??= await bookDao.getBookByMd5(md5);
  }

  Book book = Book(
    id: provideBook != null ? provideBook.id : -1,
    // group membership is precious: an explicit import assignment wins,
    // otherwise an updating record keeps the folder it already belongs to
    // (a re-import save must never reset a book back to the shelf root)
    groupId: groupId ?? provideBook?.groupId ?? 0,
      // refresh titles that were derived from old timestamped file names
      // (pre-1.15.9 imports stored "title-1730000000000"); a 13-digit run
      // in the title marks those records so re-imports heal them
      title: (provideBook?.title != null &&
              RegExp(r'\d{13}').hasMatch(provideBook!.title))
          ? effectiveTitle
          : provideBook?.title ?? effectiveTitle,
      coverPath: dbCoverPath,
      filePath: dbFilePath,
      lastReadPosition: provideBook?.lastReadPosition ?? '',
      readingPercentage: provideBook?.readingPercentage ?? 0,
      author: provideBook?.author ?? author,
      isDeleted: false,
      rating: provideBook?.rating ?? 0.0,
      md5: md5,
      createTime: provideBook?.createTime ?? DateTime.now(),
      updateTime: DateTime.now());

  book.id = await bookDao.insertBook(book);

  // clean up leftover timestamped copies from pre-1.15.9 imports in the
  // same directory (e.g. "甲书-1730000000000.epub" next to "甲书.epub")
  if (dbFilePath.contains('/')) {
    try {
      final dir = Directory(path.dirname(getBasePath(dbFilePath)));
      final stalePattern = RegExp(r'^(.*)-\d{13}$');
      String norm(String s) => s.replaceAll(RegExp(r'\s+'), '').trim();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final base = path.basenameWithoutExtension(entity.path);
        final m = stalePattern.firstMatch(base);
        if (m == null) continue;
        final legacyBase = m.group(1)!;
        final nLegacy = norm(legacyBase);
        final nNew = norm(storedName);
        final nTitle = norm(effectiveTitle);
        final similar = nLegacy.isNotEmpty &&
            (nNew.contains(nLegacy) ||
                nLegacy.contains(nNew) ||
                nTitle.contains(nLegacy) ||
                nLegacy.contains(nTitle));
        if (similar) {
          await entity.delete();
          AnxLog.info(
              'Import: removed stale copy ${path.basename(entity.path)}');
        }
      }
    } catch (e) {
      AnxLog.warning('Import: stale cleanup failed: $e');
    }
  }

  AnxToast.show(L10n.of(navigatorKey.currentContext!).serviceImportSuccess);
  await headlessInAppWebView?.dispose();
  headlessInAppWebView = null;
  return;
}

/// Serializes metadata extraction: Server().setTempFile is a singleton, so
/// two concurrent headless webviews would overwrite each other's temp URL
/// and both stall. A global lock keeps exactly one import webview alive.
Future<void> _metadataLockTail = Future.value();

Future<void> getBookMetadata(
  File file, {
  Book? book,
  String? md5,
  WidgetRef? ref,
  String? storageSubDir,
  String? preferredName,
  int? groupId,
}) {
  // chain onto the previous extraction; errors must not break the chain
  final run = _metadataLockTail
      .catchError((_) {})
      .then((_) => _getBookMetadataLocked(
            file,
            book: book,
            md5: md5,
            ref: ref,
            storageSubDir: storageSubDir,
            preferredName: preferredName,
            groupId: groupId,
          ));
  _metadataLockTail = run;
  return run;
}

Future<void> _getBookMetadataLocked(
  File file, {
  Book? book,
  String? md5,
  WidgetRef? ref,
  String? storageSubDir,
  String? preferredName,
  int? groupId,
}) async {
  // reading comfort first: while a book is open, its webview owns the
  // main thread — park metadata extraction until the reader is closed
  // (bounded, so a forgotten open reader cannot stall an import forever)
  await ImportReadingGate.waitWhileReading();

  String serverFileName = Server().setTempFile(file);

  String cfi = '';

  String bookUrl = "http://127.0.0.1:${Server().port}/$serverFileName";
  AnxLog.info("import start: book url: $bookUrl");

  final importUrl = generateUrl(
    bookUrl,
    cfi,
    importing: true,
  );

  AnxHeadlessWebView webview = AnxHeadlessWebView(
    webViewEnvironment: webViewEnvironment,
    initialUrl: importUrl,
    onLoadStop: (controller, url) async {
      controller.addJavaScriptHandler(
          handlerName: 'onMetadata',
          callback: (args) async {
            Map<String, dynamic> metadata = args[0];
            String title = metadata['title'] ?? 'Unknown';
            dynamic authorData = metadata['author'];
            String author = authorData is String
                ? authorData
                : authorData
                        ?.map((author) =>
                            author is String ? author : author['name'])
                        ?.join(', ') ??
                    'Unknown';

            // base64 cover
            String cover = metadata['cover'] ?? '';
            String description = metadata['description'] ?? '';
            saveBook(
              file,
              title,
              author,
              description,
              md5,
              cover,
              provideBook: book,
              storageSubDir: storageSubDir,
              preferredName: preferredName,
              groupId: groupId,
            );
            ref?.read(bookListProvider.notifier).refresh();
          });
    },
    onConsoleMessage: (controller, message, {required isError}) {
      if (isError) {
        headlessInAppWebView?.dispose();
        headlessInAppWebView = null;
        throw Exception('Webview: $message');
      }
      AnxLog.info('Webview: $message');
    },
  );

  await webview.run();
  headlessInAppWebView = webview;
  // max 30s
  int count = 0;
  while (count < 300) {
    if (headlessInAppWebView == null) {
      return;
    }
    await Future.delayed(const Duration(milliseconds: 100));
    count++;
  }
  await headlessInAppWebView?.dispose();
  headlessInAppWebView = null;
  throw Exception('Import: Get book metadata timeout');
}
