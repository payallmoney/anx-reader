import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/tb_group.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/tb_groups.dart';
import 'package:anx_reader/widgets/bookshelf/book_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Folder contents dialog. Shelf folders are purely virtual: this dialog
/// shows the folder's direct member books plus its subfolders, and offers
/// free organisation — rename, create subfolders, move books into any
/// folder (or out to the shelf), and dissolve. Nothing here touches the
/// book files on disk.
class BookOpenedFolder extends ConsumerStatefulWidget {
  const BookOpenedFolder({
    super.key,
    required this.books,
    required this.groupName,
    required this.groupId,
  });

  final List<Book> books;
  final String groupName;
  final int groupId;

  @override
  ConsumerState<BookOpenedFolder> createState() => _BookOpenedFolderState();
}

class _BookOpenedFolderState extends ConsumerState<BookOpenedFolder> {
  bool isEditing = false;
  bool isEditingName = false;
  List<Book> books = [];
  List<TbGroup> subFolders = [];
  late TextEditingController _nameController;
  String currentGroupName = "";

  @override
  void initState() {
    super.initState();
    books = widget.books;
    currentGroupName = widget.groupName;
    _nameController = TextEditingController(text: currentGroupName);
    _loadSubFolders();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadSubFolders() async {
    if (widget.groupId <= 0) return;
    final children =
        await ref.read(groupDaoProvider.notifier).getChildGroups(widget.groupId);
    if (!mounted) return;
    setState(() {
      subFolders = children;
    });
  }

  Future<void> _updateGroupName() async {
    if (widget.groupId <= 0) return;

    try {
      final group = await ref.read(groupDaoProvider.notifier).getGroup(widget.groupId);
      if (group == null) return;
      final updatedGroup = group.copyWith(name: _nameController.text);
      await ref.read(groupDaoProvider.notifier).updateGroup(updatedGroup);

      setState(() {
        currentGroupName = _nameController.text;
        isEditingName = false;
      });
    } catch (e) {
      setState(() {
        isEditingName = false;
      });
    }
  }

  Future<void> _createSubFolder() async {
    if (widget.groupId <= 0) return;
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L10n.of(dialogContext).bookshelfNewFolder),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: L10n.of(dialogContext).bookshelfFolderNameHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(L10n.of(dialogContext).commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, nameController.text),
            child: Text(L10n.of(dialogContext).commonConfirm),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await ref
        .read(groupDaoProvider.notifier)
        .insertNamedGroup(name.trim(), widget.groupId);
    await _loadSubFolders();
  }

  Future<void> _openSubFolder(TbGroup folder) async {
    final allBooks = await bookDao.selectNotDeleteBooks();
    if (!mounted) return;
    final members =
        allBooks.where((b) => b.groupId == folder.id).toList();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => BookOpenedFolder(
        books: members,
        groupName: folder.name,
        groupId: folder.id,
      ),
    );
  }

  /// Move [book] into any live folder (or out to the shelf root). The list
  /// is the full folder tree, flattened and indented by depth.
  Future<void> _moveBook(Book book) async {
    final groups = ref.read(groupDaoProvider).value ?? [];

    // depth lookup for indentation
    int depthOf(TbGroup g) {
      var depth = 0;
      var current = g;
      while ((current.parentId ?? 0) != 0 && depth < 10) {
        TbGroup? parent;
        for (final x in groups) {
          if (x.id == current.parentId) {
            parent = x;
            break;
          }
        }
        if (parent == null) break;
        current = parent;
        depth++;
      }
      return depth;
    }

    Widget row(String label, int depth, VoidCallback onTap) => ListTile(
          dense: true,
          contentPadding:
              EdgeInsets.symmetric(horizontal: 16.0 + 16.0 * depth),
          title: Text(label),
          onTap: onTap,
        );

    final target = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(L10n.of(dialogContext).bookshelfMoveToFolder),
        children: [
          row(L10n.of(dialogContext).bookshelfMoveToShelf, 0, () {
            Navigator.pop(dialogContext, 0);
          }),
          ...groups
              .where((g) => g.id != book.groupId && g.id != 0)
              .map((g) => row(g.name, depthOf(g), () {
                    Navigator.pop(dialogContext, g.id);
                  })),
          row(L10n.of(dialogContext).bookshelfNewSubFolder, 0, () async {
            Navigator.pop(dialogContext, -1);
          }),
        ],
      ),
    );
    if (target == null) return;
    if (target == -1) {
      if (widget.groupId > 0) {
        await _createSubFolder();
        final fresh = await ref
            .read(groupDaoProvider.notifier)
            .getChildGroups(widget.groupId);
        if (fresh.isEmpty) return;
        fresh.sort((a, b) => b.id.compareTo(a.id));
        // move into the newly created subfolder
        final newest = fresh.first;
        ref.read(bookListProvider.notifier).moveBook(book, newest.id);
      }
    } else {
      if (target == 0) {
        ref.read(bookListProvider.notifier).removeFromGroup(book);
      } else {
        ref.read(bookListProvider.notifier).moveBook(book, target);
      }
    }
    setState(() {
      if (target == 0) {
        books.removeWhere((b) => b.id == book.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: isEditingName
          ? Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    autofocus: true,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.check),
                  onPressed: _updateGroupName,
                ),
                IconButton(
                  icon: Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _nameController.text = currentGroupName;
                      isEditingName = false;
                    });
                  },
                ),
              ],
            )
          : Row(
              children: [
                // tap the name to rename it
                Expanded(
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        isEditingName = true;
                      });
                    },
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            currentGroupName,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.drive_file_rename_outline,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                ),
                // folder actions: equal-spaced icons in the top-right corner
                _folderActionIcon(
                  tooltip: isEditing
                      ? L10n.of(context).commonCancel
                      : L10n.of(context).commonEdit,
                  icon: isEditing ? Icons.close : Icons.edit_outlined,
                  onTap: () {
                    setState(() {
                      isEditing = !isEditing;
                    });
                  },
                ),
                _folderActionIcon(
                  tooltip: L10n.of(context).commonDissolve,
                  icon: Icons.call_split,
                  onTap: () async {
                    final l10n = L10n.of(context);
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: Text(l10n.commonDissolve),
                        content: Text(l10n.bookshelfDissolveFolderConfirm(
                            currentGroupName, books.length)),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: Text(l10n.commonCancel),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, true),
                            child: Text(l10n.commonConfirm),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true || !mounted) return;
                    ref.read(bookListProvider.notifier).dissolveGroup(books);
                    if (mounted) Navigator.pop(context);
                  },
                ),
                _folderActionIcon(
                  tooltip: L10n.of(context).bookshelfDeleteFolder,
                  icon: Icons.delete_outline,
                  color: Colors.red,
                  onTap: () async {
                    final l10n = L10n.of(context);
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: Text(l10n.bookshelfDeleteFolder),
                        content: Text(l10n.bookshelfDeleteFolderConfirm(
                            currentGroupName, books.length)),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: Text(l10n.commonCancel),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, true),
                            child: Text(l10n.commonDelete),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true || !mounted) return;
                    ref.read(bookListProvider.notifier).dissolveGroup(books);
                    if (mounted) Navigator.pop(context);
                  },
                ),
              ],
            ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.7,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // subfolder chips — virtual folders can nest freely
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ...subFolders.map(
                  (folder) => ActionChip(
                    label: Text(folder.name),
                    onPressed: () => _openSubFolder(folder),
                  ),
                ),
                Tooltip(
                  message: L10n.of(context).bookshelfNewFolder,
                  child: ActionChip(
                    avatar: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 18,
                    ),
                    label: const SizedBox.shrink(),
                    onPressed: _createSubFolder,
                  ),
                ),
              ],
            ),
            if (subFolders.isNotEmpty) const SizedBox(height: 8),
            Flexible(
              child: GridView.builder(
                  shrinkWrap: true,
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: Prefs().bookCoverWidth,
                    childAspectRatio: 1 / 2.2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: books.length,
                  itemBuilder: (context, index) => Stack(
                        children: [
                          BookItem(book: books[index]),
                          isEditing
                              ? Positioned(
                                  left: 0,
                                  top: 0,
                                  child: IconButton(
                                    onPressed: () => _moveBook(books[index]),
                                    icon: Icon(
                                      Icons.drive_file_move_outline,
                                      size: 26,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    ),
                                  ),
                                )
                              : Container(),
                          isEditing
                              ? Positioned(
                                  right: 0,
                                  top: 0,
                                  child: IconButton(
                                    onPressed: () {
                                      ref
                                          .read(bookListProvider.notifier)
                                          .removeFromGroup(books[index]);
                                      books.removeAt(index);
                                      if (books.isEmpty) {
                                        Navigator.pop(context);
                                      }
                                      setState(() {});
                                    },
                                    icon: const Icon(
                                      Icons.remove_circle,
                                      size: 30,
                                      color: Colors.red,
                                    ),
                                  ),
                                )
                              : Container(),
                        ],
                      )),
            ),
          ],
        ),
      ),
    );
  }

  Widget _folderActionIcon({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
    Color? color,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 20, color: color),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      onPressed: onTap,
    );
  }
}
