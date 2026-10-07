import 'dart:io';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/remote_file.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:anx_reader/service/sync/sync_client_factory.dart';
import 'package:anx_reader/utils/get_path/webdav_download_dir.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:path/path.dart' as p;

/// Browse the WebDAV storage and download selected files into the
/// configured download directory, keeping the folder layout under
/// the sync data root (`/anx/data`).
class WebdavBrowserPage extends StatefulWidget {
  const WebdavBrowserPage({super.key, this.initialPath = '/anx/data'});

  final String initialPath;

  @override
  State<WebdavBrowserPage> createState() => _WebdavBrowserPageState();
}

class _WebdavBrowserPageState extends State<WebdavBrowserPage> {
  SyncClientBase? _client;
  String _path = '';
  List<RemoteFile> _entries = [];
  final Set<String> _selected = {};
  bool _loading = true;
  String? _error;

  static const String _dataRoot = '/anx/data';

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    SyncClientFactory.initializeCurrentClient();
    _client = SyncClientFactory.currentClient;
    if (_client == null) {
      setState(() {
        _loading = false;
        _error = 'WebDAV is not configured';
      });
      return;
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _client!.readDir(_path);
      entries.sort((a, b) {
        if ((a.isDir ?? false) != (b.isDir ?? false)) {
          return (a.isDir ?? false) ? -1 : 1;
        }
        return (a.name ?? '').compareTo(b.name ?? '');
      });
      // the first entry often is the directory itself
      final filtered =
          entries.where((e) => (e.name ?? '') != p.basename(_path)).toList();
      setState(() {
        _entries = filtered;
        _selected.removeWhere((name) => !filtered.any((e) => e.name == name));
      });
    } catch (e) {
      AnxLog.severe('WebDAV browser: readDir failed: $e');
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  void _open(RemoteFile entry) {
    final name = entry.name ?? '';
    if (name.isEmpty) return;
    setState(() {
      _path = _path == '/' ? '/$name' : '$_path/$name';
      _selected.clear();
    });
    _load();
  }

  void _up() {
    if (_path == '/' || _path.isEmpty) return;
    final parent = p.dirname(_path);
    setState(() {
      _path = parent == '' ? '/' : parent;
      _selected.clear();
    });
    _load();
  }

  void _toggle(String name) {
    setState(() {
      if (_selected.contains(name)) {
        _selected.remove(name);
      } else {
        _selected.add(name);
      }
    });
  }

  bool get _allFilesSelected {
    final files = _entries.where((e) => !(e.isDir ?? false)).toList();
    return files.isNotEmpty &&
        files.every((e) => _selected.contains(e.name ?? ''));
  }

  void _toggleSelectAll() {
    final files = _entries
        .where((e) => !(e.isDir ?? false))
        .map((e) => e.name ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    setState(() {
      if (_allFilesSelected) {
        _selected.clear();
      } else {
        _selected.addAll(files);
      }
    });
  }

  String _remoteFullPath(String name) =>
      _path == '/' ? '/$name' : '$_path/$name';

  /// path of a downloaded file relative to the download directory:
  /// keep the structure below /anx/data, plain file name above it
  String _relativeDestination(String remoteFullPath) {
    if (remoteFullPath.startsWith('$_dataRoot/')) {
      return remoteFullPath.substring(_dataRoot.length + 1);
    }
    return p.basename(remoteFullPath);
  }

  Future<void> _downloadSelected() async {
    if (_selected.isEmpty) return;
    final client = _client;
    if (client == null) return;

    final downloadDir = await getWebdavDownloadDir();
    var success = 0;
    var fail = 0;
    final names = _selected.toList();
    SmartDialog.showLoading(msg: '${L10n.of(context).webdavDownloading} 0/${names.length}');
    try {
      for (var i = 0; i < names.length; i++) {
        if (!mounted) break;
        SmartDialog.showLoading(
            msg:
                '${L10n.of(context).webdavDownloading} ${i + 1}/${names.length}');
        final remote = _remoteFullPath(names[i]);
        final rel = _relativeDestination(remote);
        final localPath = p.join(downloadDir.path, rel);
        try {
          await Directory(p.dirname(localPath)).create(recursive: true);
          await client.downloadFile(remote, localPath);
          success++;
        } catch (e) {
          fail++;
          AnxLog.severe('WebDAV browser: download failed $remote: $e');
        }
      }
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
    if (!mounted) return;
    AnxToast.show(L10n.of(context)
        .webdavBatchDownloadFinishedReport(success, fail));
    setState(() {
      _selected.clear();
    });
  }

  String _formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    var v = bytes.toDouble();
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = _entries.where((e) => !(e.isDir ?? false)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.of(context).webdavBrowserTitle),
        actions: [
          IconButton(
            tooltip: L10n.of(context).webdavSelectAll,
            onPressed: files.isEmpty ? null : _toggleSelectAll,
            icon: Icon(
              _allFilesSelected
                  ? Icons.indeterminate_check_box
                  : Icons.check_box_outline_blank,
            ),
          ),
          IconButton(
            tooltip: L10n.of(context).webdavRefresh,
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            elevation: 1,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.folder_open),
              title: Text(_path,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis),
              trailing: _path == '/' || _path.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: _up,
                      tooltip: MaterialLocalizations.of(context)
                          .backButtonTooltip,
                    ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? ListView(children: [
                        const SizedBox(height: 40),
                        Icon(Icons.cloud_off,
                            size: 48, color: theme.disabledColor),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        TextButton(
                          onPressed: _load,
                          child: Text(L10n.of(context).webdavRefresh),
                        ),
                      ])
                    : _entries.isEmpty
                        ? Center(
                            child:
                                Text(L10n.of(context).webdavBrowserEmpty),
                          )
                        : ListView.builder(
                            itemCount: _entries.length,
                            itemBuilder: (context, index) {
                              final entry = _entries[index];
                              final name = entry.name ?? '';
                              final isDir = entry.isDir ?? false;
                              return ListTile(
                                leading: isDir
                                    ? const Icon(Icons.folder)
                                    : Checkbox(
                                        value: _selected.contains(name),
                                        onChanged: (_) => _toggle(name),
                                      ),
                                title: Text(name,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: isDir
                                    ? null
                                    : Text(_formatSize(entry.size),
                                        style: theme.textTheme.bodySmall),
                                onTap: isDir ? () => _open(entry) : () => _toggle(name),
                              );
                            },
                          ),
          ),
        ],
      ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : BottomAppBar(
              child: Row(
                children: [
                  Expanded(
                    child: FutureBuilder<String>(
                      future: webdavDownloadDirLabel(),
                      builder: (context, snapshot) => Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(L10n.of(context).webdavDownloadDirLabel,
                              style: theme.textTheme.bodySmall),
                          Text(
                            snapshot.data ?? '',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.primaryColor),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _downloadSelected,
                    icon: const Icon(Icons.download),
                    label: Text(L10n.of(context)
                        .webdavDownloadSelected(_selected.length)),
                  ),
                ],
              ),
            ),
    );
  }
}

Future<void> openWebdavBrowser([String path = '/anx/data']) async {
  await Navigator.push(
    navigatorKey.currentContext!,
    MaterialPageRoute(
      builder: (_) => WebdavBrowserPage(initialPath: path),
    ),
  );
}
