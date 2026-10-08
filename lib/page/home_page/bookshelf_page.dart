import 'dart:io';
import 'dart:math';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/enums/hint_key.dart';
import 'package:anx_reader/enums/sort_field.dart';
import 'package:anx_reader/enums/sort_order.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/tag.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/tb_groups.dart';
import 'package:anx_reader/providers/book_filters.dart';
import 'package:anx_reader/providers/tags.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/page/search/search_page.dart';
import 'package:anx_reader/utils/color/hash_color.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:anx_reader/utils/saf_tree.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/widgets/bookshelf/book_bottom_sheet.dart';
import 'package:anx_reader/widgets/bookshelf/book_folder.dart';
import 'package:anx_reader/widgets/bookshelf/sync_button.dart';
import 'package:anx_reader/widgets/common/container/filled_container.dart';
import 'package:anx_reader/widgets/common/tag_chip.dart';
import 'package:anx_reader/widgets/hint/hint_banner.dart';
import 'package:anx_reader/widgets/common/anx_segmented_button.dart';
import 'package:anx_reader/widgets/tips/bookshelf_tips.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/custom_draggable.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsx_plus/iconsx_plus.dart';

class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key, this.controller});
  final ScrollController? controller;

  @override
  ConsumerState<BookshelfPage> createState() => BookshelfPageState();
}

class BookshelfPageState extends ConsumerState<BookshelfPage>
    with AutomaticKeepAliveClientMixin {
  late final _scrollController = widget.controller ?? ScrollController();
  final _gridViewKey = GlobalKey();
  bool _dragging = false;
  final GlobalKey _tagButtonKey = GlobalKey();
  final TextEditingController _editTagController = TextEditingController();

  // multi-select mode for batch operations (delete)
  bool _selectMode = false;
  final Set<int> _selectedBookIds = {};

  void _enterSelectMode(int bookId) {
    setState(() {
      _selectMode = true;
      _selectedBookIds
        ..clear()
        ..add(bookId);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedBookIds.clear();
    });
  }

  void _toggleSelected(int bookId) {
    setState(() {
      if (!_selectedBookIds.remove(bookId)) {
        _selectedBookIds.add(bookId);
      }
    });
  }

  Future<void> _deleteSelectedBooks(List<List<Book>> books) async {
    if (_selectedBookIds.isEmpty) return;
    final count = _selectedBookIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L10n.of(dialogContext).commonDelete),
        content:
            Text(L10n.of(dialogContext).deleteBooksRemoveOnly(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L10n.of(dialogContext).commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(L10n.of(dialogContext).commonConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    for (final id in _selectedBookIds.toList()) {
      try {
        final book = await bookDao.selectBookById(id);
        // removing from the library only; files are never deleted
        await bookDao.updateBook(
            book.copyWith(isDeleted: true, updateTime: DateTime.now()));
      } catch (e) {
        AnxLog.warning('multi delete: book $id failed: $e');
      }
    }
    ref.read(bookListProvider.notifier).refresh();
    _exitSelectMode();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _editTagController.dispose();
    super.dispose();
  }

  Future<void> _importBook() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
    } catch (e) {
      if (!mounted) return;
      AnxToast.show(L10n.of(context).filePickerFailed(e.toString()));
      return;
    }

    if (result == null) {
      return;
    }

    List<PlatformFile> files = result.files;
    AnxLog.info('importBook files: ${files.toString()}');
    // Books are referenced in place; picker cache copies are imported into
    // app storage by saveBook when they have no durable original.
    final fileList = files.map((file) => File(file.path!)).toList();

    if (!mounted) return;
    importBookList(fileList, context, ref);
  }

  Future<void> _importFolder() async {
    String? directoryPath;

    // On Android, file_picker converts the SAF tree uri into a plain path
    // that scoped storage forbids listing; pick the raw tree uri instead
    // and enumerate through the native SAF channel.
    if (AnxPlatform.isAndroid) {
      final treeUri = await SafTree.pickDirectory();
      if (treeUri == null) {
        return;
      }
      await _importSafTree(treeUri);
      return;
    }

    try {
      directoryPath = await FilePicker.platform.getDirectoryPath();
    } catch (e) {
      if (!mounted) return;
      AnxToast.show(L10n.of(context).filePickerFailed(e.toString()));
      return;
    }

    if (directoryPath == null) {
      return;
    }

    if (SafTree.isTreeUri(directoryPath)) {
      await _importSafTree(directoryPath);
      return;
    }

    final dir = Directory(directoryPath);
    if (!await dir.exists()) {
      if (!mounted) return;
      AnxToast.show(L10n.of(context).importFolderNotAccessible);
      return;
    }

    final files = await collectBookFiles([directoryPath]);
    if (files.isEmpty) {
      if (!mounted) return;
      AnxToast.show(L10n.of(context).importFolderNoBooks);
      return;
    }

    if (!mounted) return;
    importBookList(files, context, ref);
  }

  Future<void> _importSafTree(String treeUri) async {
    SafTreeListing listing;
    try {
      listing = await SafTree.listBookFiles(treeUri);
    } catch (e) {
      if (!mounted) return;
      AnxToast.show(L10n.of(context).importFolderNotAccessible);
      return;
    }
    if (listing.files.isEmpty) {
      if (!mounted) return;
      AnxToast.show(L10n.of(context).importFolderNoBooks);
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(listing.rootName),
        content: Text(L10n.of(dialogContext)
            .importImportNBooks(listing.files.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L10n.of(dialogContext).commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(L10n.of(dialogContext)
                .importImportNBooks(listing.files.length)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // books from the picked folder are stored under a subdirectory named
    // after the folder itself
    final subDirName = sanitizeShelfDirName(listing.rootName);
    final subDir = shelfSubDir(subDirName);
    final destDir = destDirForShelfSubDir(subDirName);
    await Directory(destDir).create(recursive: true);

    var imported = 0;
    var failed = 0;
    final importedMd5s = <String>[];
    SmartDialog.showLoading(
        msg: L10n.of(context).importCopyingBooks(0, listing.files.length));
    try {
      for (var i = 0; i < listing.files.length; i++) {
        if (!mounted) break;
        final entry = listing.files[i];
        SmartDialog.showLoading(
            msg: L10n.of(context).importCopyingBooks(i + 1, listing.files.length));
        try {
          final copied =
              await SafTree.copyToDir(entry.uri, entry.name, destDir);
          await importBook(
            File(copied.path),
            ref,
            precomputedMd5: copied.md5,
            storageSubDir: subDir,
          );
          importedMd5s.add(copied.md5);
          imported++;
        } catch (e) {
          failed++;
          AnxLog.severe('SAF import: failed ${entry.name}: $e');
        }
      }
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
    if (!mounted) return;
    await _groupImportedBooks(subDirName, importedMd5s);
    if (failed > 0) {
      AnxToast.show(
          '${L10n.of(context).serviceImportSuccess} ($imported), failed: $failed');
    }
  }

  /// Put a batch of imported books into a shelf folder named after the
  /// source folder; the folder is created when missing. Group ids follow
  /// the app convention of reusing a member book's id.
  Future<void> _groupImportedBooks(
      String groupName, List<String> md5s) async {
    await groupImportedBooks(groupName, md5s, ref);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final statusFilter = ref.watch(readingStatusFilterNotifierProvider);
    final selectedTags = ref.watch(tagSelectionProvider);
    final tagsAsync = ref.watch(tagListProvider);

    Widget buildFilterBar() {
      final statusChips = [
        _StatusChip(
          label: L10n.of(context).bookshelfFilterFinished,
          selected: statusFilter == ReadingStatusFilter.finished,
          onTap: () {
            ref
                .read(readingStatusFilterNotifierProvider.notifier)
                .toggle(ReadingStatusFilter.finished);
            ref.read(bookListProvider.notifier).refresh();
          },
        ),
        _StatusChip(
          label: L10n.of(context).bookshelfFilterReading,
          selected: statusFilter == ReadingStatusFilter.reading,
          onTap: () {
            ref
                .read(readingStatusFilterNotifierProvider.notifier)
                .toggle(ReadingStatusFilter.reading);
            ref.read(bookListProvider.notifier).refresh();
          },
        ),
        _StatusChip(
          label: L10n.of(context).bookshelfFilterNotStarted,
          selected: statusFilter == ReadingStatusFilter.notStarted,
          onTap: () {
            ref
                .read(readingStatusFilterNotifierProvider.notifier)
                .toggle(ReadingStatusFilter.notStarted);
            ref.read(bookListProvider.notifier).refresh();
          },
        ),
      ];

      Future<void> showTagEditDialog(Tag tag) async {
        await TagChip.showEditDialog(
          context: context,
          initialName: tag.name,
          initialColor: tag.color ?? hashColor(tag.name),
          onRename: (newName) async {
            await ref
                .read(tagListProvider.notifier)
                .updateTag(tag.id, newName: newName);
            ref.read(bookListProvider.notifier).refresh();
          },
          onColorChange: (color) async {
            await ref
                .read(tagListProvider.notifier)
                .updateTag(tag.id, color: color);
            ref.read(bookListProvider.notifier).refresh();
          },
          onDelete: () async {
            await ref.read(tagListProvider.notifier).deleteTag(tag.id);
            if (selectedTags.contains(tag.id)) {
              ref.read(tagSelectionProvider.notifier).toggle(tag.id);
            }
            ref.read(bookListProvider.notifier).refresh();
          },
        );
      }

      Future<void> showTagMenu() async {
        final tags = tagsAsync.when(
          data: (value) => value,
          loading: () => const <Tag>[],
          error: (_, __) => const <Tag>[],
        );

        if (!context.mounted) return;

        final renderBox =
            _tagButtonKey.currentContext?.findRenderObject() as RenderBox?;
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox?;
        if (renderBox == null || overlay == null) return;

        final position = RelativeRect.fromRect(
          Rect.fromPoints(
            renderBox.localToGlobal(Offset.zero, ancestor: overlay),
            renderBox.localToGlobal(
              renderBox.size.bottomRight(Offset.zero),
              ancestor: overlay,
            ),
          ),
          Offset.zero & overlay.size,
        );

        final liveSelected = {...selectedTags};

        final boxMaxWidth = max(MediaQuery.of(context).size.width * 0.8, 500.0);

        await showMenu<int>(
          color: Colors.transparent,
          shadowColor: Colors.transparent,
          context: context,
          position: position,
          constraints: BoxConstraints(maxHeight: 360, maxWidth: boxMaxWidth),
          items: [
            PopupMenuItem<int>(
              enabled: false,
              padding: EdgeInsets.zero,
              child: Align(
                alignment: Alignment.topRight,
                child: FilledContainer(
                  constraints:
                      BoxConstraints(maxHeight: 340, maxWidth: boxMaxWidth),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: StatefulBuilder(
                    builder: (context, setStateMenu) {
                      return SingleChildScrollView(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (tags.isEmpty)
                              Text(
                                L10n.of(context).tagsEmptyHint,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            // "No tag" virtual option - only show when there are tags
                            if (tags.isNotEmpty)
                              TagChip(
                                label: L10n.of(context).noTagFilter,
                                color: Colors.grey,
                                selected: liveSelected.contains(kNoTagFilterId),
                                onTap: () {
                                  setStateMenu(() {
                                    if (liveSelected.contains(kNoTagFilterId)) {
                                      liveSelected.remove(kNoTagFilterId);
                                    } else {
                                      // Mutual exclusion: clear other tags when selecting "no tag"
                                      liveSelected.clear();
                                      liveSelected.add(kNoTagFilterId);
                                    }
                                  });
                                  ref
                                      .read(tagSelectionProvider.notifier)
                                      .toggle(kNoTagFilterId);
                                  ref.read(bookListProvider.notifier).refresh();
                                },
                                dense: false,
                              ),
                            for (final tag in tags)
                              TagChip(
                                label: tag.name,
                                color: tag.color,
                                selected: liveSelected.contains(tag.id),
                                onTap: () {
                                  setStateMenu(() {
                                    if (liveSelected.contains(tag.id)) {
                                      liveSelected.remove(tag.id);
                                    } else {
                                      // Mutual exclusion: clear "no tag" when selecting a regular tag
                                      liveSelected.remove(kNoTagFilterId);
                                      liveSelected.add(tag.id);
                                    }
                                  });
                                  ref
                                      .read(tagSelectionProvider.notifier)
                                      .toggle(tag.id);
                                  ref.read(bookListProvider.notifier).refresh();
                                },
                                onLongPress: () {
                                  Navigator.of(context).pop();
                                  Future.microtask(
                                      () => showTagEditDialog(tag));
                                },
                                dense: false,
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      }

      final selectedTagWidgets = tagsAsync.when(
        data: (tags) {
          final tagMap = {for (final t in tags) t.id: t};
          final List<Widget> chips = [];

          // Display "no tag" chip
          if (selectedTags.contains(kNoTagFilterId)) {
            chips.add(Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TagChip(
                label: L10n.of(context).noTagFilter,
                color: Colors.grey,
                selected: true,
                onTap: () {
                  ref
                      .read(tagSelectionProvider.notifier)
                      .toggle(kNoTagFilterId);
                  ref.read(bookListProvider.notifier).refresh();
                },
                dense: true,
              ),
            ));
          }

          // Display regular tag chips
          chips.addAll(selectedTags
              .where((id) => id != kNoTagFilterId)
              .map((id) => tagMap[id])
              .whereType<Tag>()
              .map((tag) => Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: TagChip(
                      label: tag.name,
                      color: tag.color,
                      selected: true,
                      onTap: () {
                        ref.read(tagSelectionProvider.notifier).toggle(tag.id);
                        ref.read(bookListProvider.notifier).refresh();
                      },
                      dense: true,
                    ),
                  )));

          return Row(children: chips);
        },
        loading: () => const SizedBox.shrink(),
        error: (_, __) => const SizedBox.shrink(),
      );

      return Container(
        height: 40,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 5),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ...statusChips,
                    selectedTagWidgets,
                  ],
                ),
              ),
            ),
            IconButton(
              key: _tagButtonKey,
              icon: const Icon(EvaIcons.pricetags_outline, size: 22),
              tooltip: L10n.of(context).bookshelfFilterTagsTooltip,
              onPressed: showTagMenu,
            ),
            IconButton(
              icon: const Icon(EvaIcons.list_outline, size: 22),
              tooltip: L10n.of(context).bookshelfSelectMode,
              onPressed: () {
                setState(() {
                  _selectMode = !_selectMode;
                  if (!_selectMode) _selectedBookIds.clear();
                });
              },
            ),
          ],
        ),
      );
    }

    // batch action bar shown instead of the filter bar while selecting
    Widget buildSelectBar(List<List<Book>> books) {
      final allBookIds = books
          .where((group) => group.length == 1)
          .map((group) => group.first.id)
          .toSet();
      final allSelected = _selectedBookIds.length >= allBookIds.length &&
          allBookIds.length > 0 &&
          allBookIds.every(_selectedBookIds.contains);
      return Container(
        height: 40,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 5),
        child: Row(
          children: [
            Expanded(
              child: Text(
                L10n.of(context).bookshelfSelectedCount(_selectedBookIds.length),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            IconButton(
              icon: Icon(allSelected
                  ? EvaIcons.minus_circle_outline
                  : EvaIcons.checkmark_circle_2_outline),
              tooltip: L10n.of(context).webdavSelectAll,
              onPressed: () {
                setState(() {
                  if (allSelected) {
                    _selectedBookIds.clear();
                  } else {
                    _selectedBookIds
                      ..clear()
                      ..addAll(allBookIds);
                  }
                });
              },
            ),
            IconButton(
              icon: const Icon(EvaIcons.trash_2_outline, size: 22),
              tooltip: L10n.of(context).commonDelete,
              onPressed: _selectedBookIds.isEmpty
                  ? null
                  : () => _deleteSelectedBooks(books),
            ),
            IconButton(
              icon: const Icon(EvaIcons.close_outline, size: 22),
              onPressed: _exitSelectMode,
            ),
          ],
        ),
      );
    }

    void handleBottomSheet(BuildContext context, Book book) {
      showBottomSheet(
        context: context,
        builder: (context) => BookBottomSheet(book: book),
      );
    }

    List<int> lockedIndices = [];

    Widget buildBookshelfBody = ref.watch(bookListProvider).when(
          data: (books) {
            for (int i = 0; i < books.length; i++) {
              // folder can't be dragged
              if (books[i].length != 1) {
                lockedIndices.add(i);
              }
            }
            return books.isEmpty
                ? const Center(child: BookshelfTips())
                : ReorderableBuilder(
                    // lock all index of books
                    lockedIndices: lockedIndices,
                    enableDraggable: true,
                    longPressDelay: const Duration(milliseconds: 300),
                    onReorder: (ReorderedListFunction reorderedListFunction) {},
                    scrollController: _scrollController,
                    onDragStarted: (index) {
                      if (books[index].length == 1) {
                        handleBottomSheet(context, books[index].first);
                        // add other books to lockedIndices
                        for (int i = 0; i < books.length; i++) {
                          if (i != index) {
                            lockedIndices.add(i);
                          }
                        }
                      }
                    },
                    onDragEnd: (index) {
                      // remove all books from lockedIndices
                      lockedIndices = [];
                      for (int i = 0; i < books.length; i++) {
                        if (books[i].length != 1) {
                          lockedIndices.add(i);
                        }
                      }
                      setState(() {});
                    },
                    children: [
                      ...books.map(
                        (book) {
                          final topLevelKey = ValueKey<String>(
                            book.first.id.toString(),
                          );
                          if (book.length == 1 && _selectMode) {
                            final selected =
                                _selectedBookIds.contains(book.first.id);
                            return GestureDetector(
                              key: topLevelKey,
                              onTap: () => _toggleSelected(book.first.id),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: Opacity(
                                        opacity: selected ? 1 : 0.55,
                                        child: BookFolder(books: book),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 4,
                                    right: 4,
                                    child: Icon(
                                      selected
                                          ? EvaIcons.checkmark_circle_2
                                          : EvaIcons.radio_button_off_outline,
                                      size: 24,
                                      color: selected
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
                                          : Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }
                          return book.length == 1
                              ? CustomDraggable(
                                  key: topLevelKey,
                                  data: book.first,
                                  child: BookFolder(books: book),
                                )
                              : BookFolder(
                                  key: topLevelKey,
                                  books: book,
                                );
                        },
                      ),
                    ],
                    builder: (children) {
                      return LayoutBuilder(builder: (context, constraints) {
                        return Column(
                          children: [
                            HintBanner(
                                icon: const Icon(Icons.copy),
                                hintKey: HintKey.dragAndDropToCreateFolder,
                                margin: EdgeInsets.fromLTRB(20, 0, 20, 5),
                                child: Text(L10n.of(context)
                                    .dragAndDropToCreateFolderHint)),
                            Expanded(
                              child: GridView(
                                key: _gridViewKey,
                                controller: _scrollController,
                                padding:
                                    const EdgeInsets.fromLTRB(20, 12, 20, 80),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: constraints.maxWidth ~/
                                      Prefs().bookCoverWidth,
                                  childAspectRatio: 1 / 2.1,
                                  mainAxisSpacing: 30,
                                  crossAxisSpacing: 20,
                                ),
                                children: children,
                              ),
                            ),
                          ],
                        );
                      });
                    });
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(child: Text(error.toString())),
        );

    Widget body = Builder(builder: (context) {
      final books = ref.watch(bookListProvider).whenOrNull(
                data: (books) => books,
              ) ??
          const <List<Book>>[];
      return Column(
        children: [
          _selectMode ? buildSelectBar(books) : buildFilterBar(),
          Expanded(
          child: DropTarget(
            onDragDone: (detail) async {
              // dropped items may include directories; expand them
              // recursively so every book in subdirectories is loaded
              final files = await collectBookFiles(
                  detail.files.map((file) => file.path).toList());
              if (!mounted) return;
              importBookList(files, context, ref);
              setState(() {
                _dragging = false;
              });
            },
            onDragEntered: (detail) {
              setState(() {
                _dragging = true;
              });
            },
            onDragExited: (detail) {
              setState(() {
                _dragging = false;
              });
            },
            child: Stack(
              children: [
                buildBookshelfBody,
                if (_dragging)
                  Container(
                    color: Theme.of(context).colorScheme.surface.withAlpha(90),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            EvaIcons.arrowhead_down_outline,
                            size: 48,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          Text(
                            L10n.of(context).bookshelfDragging,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      );
    });

    PreferredSizeWidget appBar = AppBar(
      forceMaterialTransparency: true,
      title: Container(
          height: 34,
          constraints: const BoxConstraints(maxWidth: 400),
          child: InkWell(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SearchPage(),
                ),
              );
            },
            child: FilledContainer(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              color: Theme.of(context).colorScheme.surface.withAlpha(80),
              child: Row(
                children: [
                  const Icon(Icons.search, color: Colors.grey),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(L10n.of(context).searchBooksOrNotes,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: Theme.of(context).hintColor),
                        overflow: TextOverflow.ellipsis),
                  )
                ],
              ),
            ),
          )),
      actions: [
        const SyncButton(),
        PopupMenuButton(
          icon: const Icon(Icons.add),
          initialValue: 0,
          onSelected: (value) {
            if (value == 0) {
              _importBook();
            } else if (value == 1) {
              _importFolder();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 0,
              child: Text(L10n.of(context).importFiles),
            ),
            PopupMenuItem(
              value: 1,
              child: Text(L10n.of(context).importFromFolder),
            ),
          ],
        ),
        IconButton(
            icon: const Icon(Icons.sort),
            onPressed: () {
              showMenu(
                context: context,
                position: RelativeRect.fromLTRB(
                  MediaQuery.of(context).size.width,
                  MediaQuery.of(context).padding.top + kToolbarHeight,
                  0.0,
                  0.0,
                ),
                items: [
                  for (var sortField in SortFieldEnum.values)
                    PopupMenuItem(
                        child: Text(
                          sortField.getL10n(context),
                          style: TextStyle(
                            color: sortField == Prefs().sortField
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        onTap: () {
                          Prefs().sortField = sortField;
                          ref.read(bookListProvider.notifier).refresh();
                        }),
                  PopupMenuItem(
                    enabled: false,
                    child: StatefulBuilder(builder: (_, setState) {
                      return Row(
                        children: [
                          Expanded(
                            child: AnxSegmentedButton<SortOrderEnum>(
                              onSelectionChanged: (value) {
                                Prefs().sortOrder = value.first;
                                ref.read(bookListProvider.notifier).refresh();
                                setState(() {});
                              },
                              segments: SortOrderEnum.values
                                  .map(
                                    (e) => SegmentButtonItem(
                                      value: e,
                                      label: e.getL10n(
                                          navigatorKey.currentContext!),
                                    ),
                                  )
                                  .toList(),
                              selected: {Prefs().sortOrder},
                            ),
                          ),
                        ],
                      );
                    }),
                  )
                ],
              );
            }),
      ],
    );

    return Container(
        decoration: Prefs().eInkMode
            ? null
            : BoxDecoration(
                gradient: RadialGradient(
                  tileMode: TileMode.clamp,
                  center: Alignment.topRight,
                  radius: 1,
                  colors: [
                    Theme.of(context).colorScheme.primary.withAlpha(5),
                    Theme.of(context).scaffoldBackgroundColor,
                  ],
                ),
              ),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: appBar,
          body: body,
        ));
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        labelPadding: const EdgeInsets.all(0),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        checkmarkColor: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}


/// Put a batch of imported books into a shelf folder named after the
/// source folder; the folder is created when missing. Group ids follow
/// the app convention of reusing a member book's id.
Future<void> groupImportedBooks(
    String groupName, List<String> md5s, WidgetRef ref) async {
  if (groupName.isEmpty || md5s.isEmpty) return;
  try {
    final db = await DBHelper().database;
    final bookIds = <int>[];
    for (final md5 in md5s) {
      // importBook returns before the webview metadata callback inserts
      // the row, so wait for the book to appear; txt conversion can be
      // slow, allow up to ~15s per book
      for (var i = 0; i < 75; i++) {
        final book = await bookDao.getBookByMd5(md5);
        if (book != null && !book.isDeleted) {
          bookIds.add(book.id);
          break;
        }
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    if (bookIds.isEmpty) {
      AnxLog.warning('SAF import: no books found for grouping');
      return;
    }

    final existing = await db.query('tb_groups',
        where: 'name = ? AND is_deleted = 0',
        whereArgs: [groupName],
        limit: 1);
    int groupId;
    if (existing.isNotEmpty) {
      groupId = existing.first['id'] as int;
    } else {
      groupId = bookIds.first;
      final now = DateTime.now().toIso8601String();
      // the id may already be taken by a leftover group row from an
      // earlier import (re-imported books keep their ids); revive that
      // row instead of failing the whole insert
      final byId = await db.query('tb_groups',
          where: 'id = ?', whereArgs: [groupId], limit: 1);
      if (byId.isNotEmpty) {
        await db.update(
          'tb_groups',
          {'name': groupName, 'is_deleted': 0, 'update_time': now},
          where: 'id = ?',
          whereArgs: [groupId],
        );
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
    for (final id in bookIds) {
      await db.update(
        'tb_books',
        {'group_id': groupId, 'update_time': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    AnxLog.info(
        'SAF import: grouped ${bookIds.length} books into "$groupName" (id $groupId)');
    ref.invalidate(groupDaoProvider);
    ref.read(bookListProvider.notifier).refresh();
  } catch (e) {
    AnxLog.severe('SAF import: group assignment failed: $e');
  }
}

/// Storage subdirectory for books imported from a folder named
/// [folderName]; sanitised the same way everywhere.
String sanitizeShelfDirName(String folderName) => folderName
    .replaceAll(RegExp(r'[<>:"/\|?*#%&@$^+=\[\]{}`~;!]'), '_')
    .trim();

String shelfSubDir(String sanitizedFolderName) =>
    sanitizedFolderName.isEmpty ? 'file' : 'file/$sanitizedFolderName';

String destDirForShelfSubDir(String sanitizedFolderName) =>
    getBasePath(shelfSubDir(sanitizedFolderName));

/// Shared core of the SAF folder import: stream every supported book from
/// the picked tree into file/<folder>/ and group them on the shelf.
/// Used by the shelf UI and by the adb automation hook.
Future<int> importSafTreeCore(String treeUri, WidgetRef ref) async {
  final listing = await SafTree.listBookFiles(treeUri);
  final subDirName = sanitizeShelfDirName(listing.rootName);
  final subDir = shelfSubDir(subDirName);
  final destDir = destDirForShelfSubDir(subDirName);
  await Directory(destDir).create(recursive: true);

  var imported = 0;
  final importedMd5s = <String>[];
  for (final entry in listing.files) {
    try {
      final copied = await SafTree.copyToDir(entry.uri, entry.name, destDir);
      await importBook(
        File(copied.path),
        ref,
        precomputedMd5: copied.md5,
        storageSubDir: subDir,
      );
      importedMd5s.add(copied.md5);
      imported++;
    } catch (e) {
      AnxLog.severe('SAF import: failed ${entry.name}: $e');
    }
  }
  await groupImportedBooks(subDirName, importedMd5s, ref);
  return imported;
}
