import 'dart:io';
import 'dart:isolate';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/import_file_check.dart';
import 'package:anx_reader/models/md5_calculating_result.dart';
import 'package:anx_reader/models/md5_statistics.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:crypto/crypto.dart';

class _DigestSink implements Sink<Digest> {
  String? value;

  @override
  void add(Digest data) => value = data.toString();

  @override
  void close() {}
}

class MD5Service {
  /// Compute the file's MD5 on a background isolate, streaming the bytes so
  /// large books neither block the UI nor load fully into memory.
  static Future<String?> calculateFileMd5(String filePath) async {
    try {
      return await Isolate.run(() => _md5OfFileSync(filePath));
    } catch (e) {
      AnxLog.severe('Error calculating MD5 for $filePath: $e');
      return null;
    }
  }

  static String _md5OfFileSync(String filePath) {
    final output = _DigestSink();
    final input = md5.startChunkedConversion(output);
    final raf = File(filePath).openSync();
    try {
      final buffer = List<int>.filled(64 * 1024, 0);
      while (true) {
        final n = raf.readIntoSync(buffer);
        if (n == null || n <= 0) break;
        input.add(buffer.sublist(0, n));
      }
    } finally {
      raf.closeSync();
    }
    input.close();
    return output.value ?? '';
  }

  static Future<Book?> checkDuplicateByMd5(String md5) async {
    return await bookDao.getBookByMd5(md5);
  }

  static Future<MD5CalculationResult> batchCalculateMd5(List<Book> books,
      {Function(int current, int total, String currentFile)?
          onProgress}) async {
    int calculated = 0;
    int skipped = 0;
    int failed = 0;
    List<String> missingFiles = [];

    for (int i = 0; i < books.length; i++) {
      final book = books[i];

      onProgress?.call(i + 1, books.length, book.title);

      if (!await File(book.fileFullPath).exists()) {
        missingFiles.add(book.title);
        skipped++;
        continue;
      }

      final md5 = await calculateFileMd5(book.fileFullPath);
      if (md5 != null) {
        await bookDao.updateBookMd5(book.id, md5);
        calculated++;
      } else {
        failed++;
      }
    }

    return MD5CalculationResult(
      totalBooks: books.length,
      calculated: calculated,
      skipped: skipped,
      failed: failed,
      missingFiles: missingFiles,
    );
  }

  static Future<MD5Statistics> getMd5Statistics() async {
    final allBooks = await bookDao.selectNotDeleteBooks();
    final booksWithoutMd5 = await bookDao.getBooksWithoutMd5();

    int localFilesCount = 0;
    int localFilesWithoutMd5 = 0;

    for (final book in allBooks) {
      if (await File(book.fileFullPath).exists()) {
        localFilesCount++;
        if (book.md5 == null || book.md5!.isEmpty) {
          localFilesWithoutMd5++;
        }
      }
    }

    return MD5Statistics(
      totalBooks: allBooks.length,
      booksWithMd5: allBooks.length - booksWithoutMd5.length,
      booksWithoutMd5: booksWithoutMd5.length,
      localFilesCount: localFilesCount,
      localFilesWithoutMd5: localFilesWithoutMd5,
    );
  }

  static Future<List<ImportFileCheck>> checkImportFiles(
      List<String> filePaths) async {
    List<ImportFileCheck> results = [];

    for (final filePath in filePaths) {
      final md5 = await calculateFileMd5(filePath);
      Book? duplicateBook;

      if (md5 != null) {
        duplicateBook = await checkDuplicateByMd5(md5);
      }

      results.add(ImportFileCheck(
        filePath: filePath,
        md5: md5,
        isDuplicate: duplicateBook != null && !duplicateBook.isDeleted,
        duplicateBook: duplicateBook,
      ));
    }

    return results;
  }
}
