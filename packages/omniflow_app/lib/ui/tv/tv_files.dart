import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../device_sheets.dart' show confirm;
import 'tv_controller.dart';
import 'tv_widgets.dart';

const filesRoot = '/sdcard';

String joinPath(String dir, String name) =>
    dir.endsWith('/') ? '$dir$name' : '$dir/$name';

String parentOf(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.substring(0, i);
}

String baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// A name the TV can take for a file: no slash, NUL or line break.
String? fileNameError(String name) {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a name';
  if (n == '.' || n == '..') return 'Not a usable name';
  if (RegExp('[/\u0000\n\r]').hasMatch(n)) return 'No slashes or line breaks';
  return null;
}

typedef _Clipboard = ({List<String> paths, bool cut});

class TvFilesTab extends ConsumerStatefulWidget {
  const TvFilesTab({super.key, required this.tv});

  final TvController tv;

  @override
  ConsumerState<TvFilesTab> createState() => _TvFilesTabState();
}

class _TvFilesTabState extends ConsumerState<TvFilesTab>
    with AutomaticKeepAliveClientMixin {
  var _path = filesRoot;
  List<TvFileEntry>? _entries;
  String? _error;
  var _loading = false;
  final _selected = <String>{};
  _Clipboard? _clipboard;
  var _busy = false;

  TvController get tv => widget.tv;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_open(filesRoot));
  }

  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await tv.client.call(
      TvCalls.filesList,
      TvCalls.pathArgs(tv.id, path),
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result['ok'] == true) {
        final listing = TvCalls.listingOf(result);
        _path = listing.path.isEmpty ? path : listing.path;
        _entries =
            listing.entries
                .where((e) => e.name != '.' && e.name != '..')
                .toList()
              ..sort(_order);
        _selected.clear();
      } else if (_entries == null) {
        _error = errorMessage(result);
      } else {
        showMessage(errorMessage(result));
      }
    });
  }

  static int _order(TvFileEntry a, TvFileEntry b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  Future<void> _reload() => _open(_path);

  List<TvFileEntry> get _selectedEntries => [
    for (final e in _entries ?? const <TvFileEntry>[])
      if (_selected.contains(e.name)) e,
  ];

  Future<T> _working<T>(Future<T> Function() work) async {
    setState(() => _busy = true);
    try {
      return await work();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggle(TvFileEntry e) => setState(() {
    if (!_selected.remove(e.name)) _selected.add(e.name);
  });

  void _copy(List<TvFileEntry> entries, {required bool cut}) {
    setState(() {
      _clipboard = (
        paths: [for (final e in entries) joinPath(_path, e.name)],
        cut: cut,
      );
      _selected.clear();
    });
    showMessage(
      '${cut ? 'Cut' : 'Copied'} ${_count(entries.length)}. '
      'Open a folder and paste',
    );
  }

  /// A name not taken in this folder, for pasting a copy next to its
  /// original.
  String _freeName(String name) {
    final taken = {for (final e in _entries ?? const <TvFileEntry>[]) e.name};
    if (!taken.contains(name)) return name;
    final dot = name.lastIndexOf('.');
    final (stem, ext) = dot > 0
        ? (name.substring(0, dot), name.substring(dot))
        : (name, '');
    for (var i = 1; ; i++) {
      final candidate = i == 1 ? '$stem copy$ext' : '$stem copy $i$ext';
      if (!taken.contains(candidate)) return candidate;
    }
  }

  Future<void> _paste() async {
    final clip = _clipboard;
    if (clip == null) return;
    await _working(() async {
      var done = 0;
      for (final from in clip.paths) {
        if (clip.cut && parentOf(from) == _path) continue;
        if (_path == from || _path.startsWith('$from/')) {
          showMessage('Cannot put ${baseName(from)} inside itself');
          continue;
        }
        // A move names the folder, so the engine puts the item inside it
        // and refuses when the name is taken, instead of nesting it in a
        // folder of the same name.
        final to = clip.cut
            ? _path
            : joinPath(_path, _freeName(baseName(from)));
        final result = await tv.transfer(
          clip.cut ? TvCalls.filesMove : TvCalls.filesCopy,
          TvCalls.fromToArgs(tv.id, from, to),
        );
        if (result['ok'] != true) break;
        done++;
      }
      if (clip.cut) setState(() => _clipboard = null);
      if (done > 0) {
        showMessage('${clip.cut ? 'Moved' : 'Copied'} ${_count(done)}');
      }
    });
    await _reload();
  }

  Future<void> _delete(List<TvFileEntry> entries) async {
    if (entries.isEmpty) return;
    final dirs = entries.any((e) => e.isDir);
    final ok = await confirm(
      context,
      title: entries.length == 1
          ? 'Delete ${entries.single.name}?'
          : 'Delete ${_count(entries.length)}?',
      body: dirs
          ? 'Folders are deleted with everything in them. This cannot be '
                'undone.'
          : 'They are deleted from the TV. This cannot be undone.',
      action: 'Delete',
    );
    if (!ok) return;
    final result = await _working(
      () => tv.transfer(
        TvCalls.filesDelete,
        TvCalls.deleteArgs(tv.id, [
          for (final e in entries) joinPath(_path, e.name),
        ], dirs: dirs),
      ),
    );
    if (result['ok'] == true) showMessage('Deleted ${_count(entries.length)}');
    await _reload();
  }

  Future<void> _rename(TvFileEntry entry) async {
    final name = await askText(
      context,
      title: 'Rename ${entry.name}',
      label: 'New name',
      initial: entry.name,
      action: 'Rename',
      validate: fileNameError,
    );
    if (name == null || name.trim() == entry.name) return;
    final result = await tv.call(
      TvCalls.filesRename,
      TvCalls.renameArgs(tv.id, joinPath(_path, entry.name), name.trim()),
    );
    if (result['ok'] == true) await _reload();
  }

  Future<void> _newFolder() async {
    final name = await askText(
      context,
      title: 'New folder in ${baseName(_path)}',
      label: 'Folder name',
      action: 'Create',
      validate: fileNameError,
    );
    if (name == null) return;
    final result = await tv.call(
      TvCalls.filesMkdir,
      TvCalls.pathArgs(tv.id, joinPath(_path, name.trim())),
    );
    if (result['ok'] == true) await _reload();
  }

  /// Runs a transfer, and when its target exists asks before running it
  /// again with overwrite. False when it failed or the user kept the file.
  Future<bool> _transferAsking(
    String command,
    Json Function({bool overwrite}) args,
    String target,
  ) async {
    var result = await tv.transfer(command, args(), quiet: true);
    if (TvCalls.isConflict(result) && mounted) {
      final replace = await confirm(
        context,
        title: 'Replace $target?',
        body:
            '${baseName(target)} already exists there. Replacing it '
            'cannot be undone.',
        action: 'Replace',
      );
      if (!replace) return false;
      result = await tv.transfer(command, args(overwrite: true), quiet: true);
    }
    if (result['ok'] != true) showMessage(errorMessage(result));
    return result['ok'] == true;
  }

  Future<void> _download(List<TvFileEntry> entries) async {
    final files = entries.where((e) => !e.isDir).toList();
    const skipped = 'Folders are skipped. Open one to download its files';
    if (files.isEmpty) {
      showMessage(skipped);
      return;
    }
    final dir = await ref.read(phoneFilesProvider).downloadsDir();
    if (dir == null) {
      showMessage('This phone has no Downloads folder OmniFlow can write to');
      return;
    }
    await _working(() async {
      var done = 0;
      for (final f in files) {
        final to = joinPath(dir, f.name);
        final ok = await _transferAsking(
          TvCalls.filesDownload,
          ({overwrite = false}) => TvCalls.downloadArgs(
            tv.id,
            joinPath(_path, f.name),
            to,
            overwrite: overwrite,
          ),
          to,
        );
        if (!ok) break;
        done++;
      }
      if (done > 0) {
        showMessage(
          [
            'Saved ${_count(done)} to $dir',
            if (files.length < entries.length) skipped,
          ].join('. '),
        );
      }
    });
    setState(_selected.clear);
  }

  Future<void> _upload() async {
    final phone = ref.read(phoneFilesProvider);
    final picked = await phone.pick();
    if (picked.isEmpty || !mounted) return;
    await _working(() async {
      var done = 0;
      try {
        for (final f in picked) {
          final to = joinPath(_path, f.name);
          final ok = await _transferAsking(
            TvCalls.filesUpload,
            ({overwrite = false}) =>
                TvCalls.uploadArgs(tv.id, f.path, to, overwrite: overwrite),
            to,
          );
          if (!ok) break;
          done++;
        }
      } finally {
        await phone.cleanup();
      }
      if (done > 0) showMessage('Uploaded ${_count(done)}');
    });
    await _reload();
  }

  Future<void> _details(TvFileEntry e) async {
    final path = joinPath(_path, e.name);
    final result = await tv.call(
      TvCalls.filesStat,
      TvCalls.pathArgs(tv.id, path),
    );
    if (result['ok'] != true || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(e.name),
        content: SelectableText(
          [
            'Path: $path',
            for (final entry in result.entries)
              if (entry.key != 'ok') '${entry.key}: ${entry.value}',
          ].join('\n'),
          key: const ValueKey('file-info-text'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _fileSheet(TvFileEntry e) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(e.name),
              subtitle: Text(
                [
                  formatBytes(e.size),
                  formatDate(e.modified),
                ].where((s) => s.isNotEmpty).join('  '),
              ),
            ),
            const Divider(height: 1),
            for (final (value, icon, label) in [
              if (!e.isDir) ('download', Icons.download, 'Download to phone'),
              ('copy', Icons.copy, 'Copy'),
              ('cut', Icons.content_cut, 'Cut'),
              ('rename', Icons.drive_file_rename_outline, 'Rename'),
              ('info', Icons.info_outline, 'Details'),
              ('delete', Icons.delete_outline, 'Delete'),
            ])
              ListTile(
                key: ValueKey('file-$value'),
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.of(context).pop(value),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'download':
        await _download([e]);
      case 'copy':
        _copy([e], cut: false);
      case 'cut':
        _copy([e], cut: true);
      case 'rename':
        await _rename(e);
      case 'info':
        await _details(e);
      case 'delete':
        await _delete([e]);
    }
  }

  static String _count(int n) => n == 1 ? '1 item' : '$n items';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final selecting = _selected.isNotEmpty;
    final entries = _entries;
    return Column(
      children: [
        _Breadcrumbs(path: _path, onOpen: _busy ? null : _open),
        if (selecting) _selectionBar() else _toolbar(),
        if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
        TransferProgress(tv: tv),
        Expanded(
          child: _error != null
              ? TvEmpty(text: _error!, onRetry: _reload)
              : entries == null
              ? const Center(child: CircularProgressIndicator())
              : entries.isEmpty
              ? const TvEmpty(text: 'This folder is empty')
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.builder(
                    key: const ValueKey('files-list'),
                    itemCount: entries.length,
                    itemBuilder: (context, i) => _entryTile(entries[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _entryTile(TvFileEntry e) {
    final selected = _selected.contains(e.name);
    final opensAsFolder = e.isDir || e.type == 'link';
    return ListTile(
      key: ValueKey('entry-${e.name}'),
      selected: selected,
      leading: selected
          ? const Icon(Icons.check_circle)
          : Icon(switch (e.type) {
              'dir' => Icons.folder,
              'link' => Icons.link,
              _ => _fileIcon(e.name),
            }),
      title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (!e.isDir) formatBytes(e.size),
          formatDate(e.modified),
        ].where((s) => s.isNotEmpty).join('  '),
      ),
      trailing: _selected.isEmpty
          ? IconButton(
              key: ValueKey('entry-menu-${e.name}'),
              tooltip: 'More for ${e.name}',
              icon: const Icon(Icons.more_vert),
              onPressed: _busy ? null : () => _fileSheet(e),
            )
          : null,
      onTap: _busy
          ? null
          : () {
              if (_selected.isNotEmpty) {
                _toggle(e);
              } else if (opensAsFolder) {
                _open(joinPath(_path, e.name));
              } else {
                _fileSheet(e);
              }
            },
      onLongPress: _busy ? null : () => _toggle(e),
    );
  }

  static IconData _fileIcon(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return switch (ext) {
      'apk' => Icons.android,
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' => Icons.image_outlined,
      'mp4' || 'mkv' || 'avi' || 'mov' || 'webm' => Icons.movie_outlined,
      'mp3' || 'aac' || 'flac' || 'wav' || 'ogg' => Icons.audiotrack_outlined,
      'zip' || 'tar' || 'gz' || '7z' => Icons.archive_outlined,
      'txt' || 'log' || 'json' || 'xml' => Icons.description_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  Widget _toolbar() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Row(
      children: [
        IconButton(
          key: const ValueKey('files-up'),
          tooltip: 'Up one folder',
          onPressed: _path == '/' || _busy
              ? null
              : () => _open(parentOf(_path)),
          icon: const Icon(Icons.arrow_upward),
        ),
        IconButton(
          key: const ValueKey('files-refresh'),
          tooltip: 'Refresh',
          onPressed: _busy ? null : _reload,
          icon: const Icon(Icons.refresh),
        ),
        const Spacer(),
        if (_clipboard case final clip?)
          TextButton.icon(
            key: const ValueKey('files-paste'),
            onPressed: _busy ? null : _paste,
            onLongPress: () => setState(() => _clipboard = null),
            icon: const Icon(Icons.content_paste),
            label: Text('Paste ${clip.paths.length}'),
          ),
        IconButton(
          key: const ValueKey('files-new-folder'),
          tooltip: 'New folder',
          onPressed: _busy ? null : _newFolder,
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
        IconButton(
          key: const ValueKey('files-upload'),
          tooltip: 'Upload from the phone',
          onPressed: _busy ? null : _upload,
          icon: const Icon(Icons.upload),
        ),
      ],
    ),
  );

  Widget _selectionBar() {
    final chosen = _selectedEntries;
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('select-clear'),
            tooltip: 'Clear the selection',
            onPressed: () => setState(_selected.clear),
            icon: const Icon(Icons.close),
          ),
          Text('${chosen.length}', key: const ValueKey('select-count')),
          const Spacer(),
          IconButton(
            key: const ValueKey('select-all'),
            tooltip: 'Select all',
            onPressed: () => setState(
              () => _selected.addAll([for (final e in _entries!) e.name]),
            ),
            icon: const Icon(Icons.select_all),
          ),
          IconButton(
            key: const ValueKey('select-copy'),
            tooltip: 'Copy',
            onPressed: () => _copy(chosen, cut: false),
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            key: const ValueKey('select-cut'),
            tooltip: 'Cut',
            onPressed: () => _copy(chosen, cut: true),
            icon: const Icon(Icons.content_cut),
          ),
          IconButton(
            key: const ValueKey('select-download'),
            tooltip: 'Download to the phone',
            onPressed: _busy ? null : () => _download(chosen),
            icon: const Icon(Icons.download),
          ),
          if (chosen.length == 1)
            IconButton(
              key: const ValueKey('select-rename'),
              tooltip: 'Rename',
              onPressed: _busy ? null : () => _rename(chosen.single),
              icon: const Icon(Icons.drive_file_rename_outline),
            ),
          IconButton(
            key: const ValueKey('select-delete'),
            tooltip: 'Delete',
            onPressed: _busy ? null : () => _delete(chosen),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.path, required this.onOpen});

  final String path;
  final void Function(String path)? onOpen;

  @override
  Widget build(BuildContext context) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    final crumbs = <(String, String)>[('/', '/')];
    for (var i = 0; i < parts.length; i++) {
      crumbs.add((parts[i], '/${parts.sublist(0, i + 1).join('/')}'));
    }
    return SizedBox(
      height: 44,
      child: ListView(
        key: const ValueKey('breadcrumbs'),
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final (i, (label, target)) in crumbs.indexed.toList().reversed)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (i > 0) const Icon(Icons.chevron_right, size: 18),
                TextButton(
                  key: ValueKey('crumb-$target'),
                  onPressed: onOpen == null || i == crumbs.length - 1
                      ? null
                      : () => onOpen!(target),
                  child: i == 0
                      ? const Icon(
                          Icons.storage,
                          size: 18,
                          semanticLabel: 'Root',
                        )
                      : Text(label),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
