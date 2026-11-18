import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
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

/// 4.4 Files: a breadcrumb, folders first, long press to select with the
/// action bar at the bottom, paste in the folder moved to, and a plus for a
/// new folder or an upload from the phone.
class TvFilesTab extends ConsumerStatefulWidget {
  const TvFilesTab({super.key, required this.tv});

  final TvController tv;

  @override
  ConsumerState<TvFilesTab> createState() => _TvFilesTabState();
}

class _TvFilesTabState extends ConsumerState<TvFilesTab> {
  var _path = filesRoot;
  List<TvFileEntry>? _entries;
  String? _error;
  var _loading = false;
  final _selected = <String>{};
  _Clipboard? _clipboard;
  var _busy = false;

  /// Set by Stop after this file: a batch ends once the file in flight is
  /// done. The engine has no way to stop a file half way.
  var _stopBatch = false;

  TvController get tv => widget.tv;

  @override
  void initState() {
    super.initState();
    unawaited(_open(filesRoot));
  }

  /// The newest folder asked for: an older listing that lands later is
  /// dropped.
  var _request = 0;

  Future<void> _open(String path) async {
    if (!mounted) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await tv.client.call(
      TvCalls.filesList,
      TvCalls.pathArgs(tv.id, path),
    );
    if (!mounted || request != _request) return;
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
    setState(() {
      _busy = true;
      _stopBatch = false;
    });
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
        if (_stopBatch) break;
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
          name: baseName(from),
        );
        if (result['ok'] != true) break;
        done++;
      }
      // A cut that did not finish stays on the clipboard, to paste again.
      if (clip.cut && done == clip.paths.length && mounted) {
        setState(() => _clipboard = null);
      }
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
          : 'They are deleted from the ${tv.noun}. This cannot be undone.',
      action: 'Delete',
      destructive: true,
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
      title: 'New folder in ${_crumbLabel(_path, phone: tv.isPhone)}',
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
    var result = await tv.transfer(
      command,
      args(),
      quiet: true,
      name: baseName(target),
    );
    if (TvCalls.isConflict(result) && mounted) {
      final replace = await confirm(
        context,
        title: 'Replace $target?',
        body:
            '${baseName(target)} already exists there. Replacing it '
            'cannot be undone.',
        action: 'Replace',
        destructive: true,
      );
      if (!replace) return false;
      result = await tv.transfer(
        command,
        args(overwrite: true),
        quiet: true,
        name: baseName(target),
      );
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
        if (_stopBatch) break;
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
    if (mounted) setState(_selected.clear);
  }

  Future<void> _upload() async {
    final phone = ref.read(phoneFilesProvider);
    final picked = await phone.pick();
    if (picked.isEmpty || !mounted) return;
    await _working(() async {
      var done = 0;
      try {
        for (final f in picked) {
          if (_stopBatch) break;
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
    await SheetTemplate.show<void>(
      context,
      builder: (_) => SheetTemplate(
        title: e.name,
        subtitle: 'Details',
        children: (_) => [
          SelectableText(
            [
              'Path: $path',
              for (final entry in result.entries)
                if (entry.key != 'ok') '${entry.key}: ${entry.value}',
            ].join('\n'),
            key: const ValueKey('file-info-text'),
            style: OmniText.mono,
          ),
        ],
      ),
    );
  }

  Future<void> _fileSheet(TvFileEntry e) async {
    final choice = await SheetTemplate.show<String>(
      context,
      builder: (_) => SheetTemplate(
        title: e.name,
        subtitle: _subtitle(e),
        children: (context) => [
          for (final (value, icon, label) in [
            if (!e.isDir)
              ('download', TvIcons.download, 'Download to the phone'),
            ('copy', TvIcons.copy, 'Copy'),
            ('cut', TvIcons.cut, 'Cut'),
            ('rename', TvIcons.rename, 'Rename'),
            ('info', OmniIcons.info, 'Details'),
            ('delete', OmniIcons.delete, 'Delete'),
          ])
            OmniListRow(
              key: ValueKey('file-$value'),
              icon: icon,
              title: label,
              iconForeground: value == 'delete'
                  ? OmniPalette.of(context).bad
                  : null,
              onTap: () => Navigator.of(context).pop(value),
            ),
        ],
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

  Future<void> _addSheet() async {
    final choice = await SheetTemplate.show<String>(
      context,
      builder: (_) => SheetTemplate(
        title: 'Add to ${_crumbLabel(_path, phone: tv.isPhone)}',
        children: (context) => [
          OmniListRow(
            key: const ValueKey('files-new-folder'),
            icon: TvIcons.newFolder,
            title: 'New folder',
            onTap: () => Navigator.of(context).pop('folder'),
          ),
          OmniListRow(
            key: const ValueKey('files-upload'),
            icon: TvIcons.upload,
            title: 'Upload from the phone',
            subtitle: 'Pick files, they land in this folder',
            onTap: () => Navigator.of(context).pop('upload'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'folder':
        await _newFolder();
      case 'upload':
        await _upload();
    }
  }

  static String _count(int n) => n == 1 ? '1 item' : '$n items';

  static String _subtitle(TvFileEntry e) => [
    if (e.isDir) 'Folder' else formatBytes(e.size),
    formatDate(e.modified),
  ].where((s) => s.isNotEmpty).join(' · ');

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    final entries = _entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              key: const ValueKey('files-list'),
              padding: omniBodyPadding(
                selecting ? OmniSpace.md : OmniInsets.bottom(context),
              ),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _Breadcrumbs(
                        phone: tv.isPhone,
                        path: _path,
                        onOpen: _busy ? null : _open,
                      ),
                    ),
                    OmniIconAction(
                      key: const ValueKey('files-add'),
                      icon: OmniIcons.add,
                      label: 'New folder or upload',
                      onPressed: _busy ? null : _addSheet,
                    ),
                  ],
                ),
                if (selecting) _selectionHeader(),
                if (_clipboard case final clip?) _pasteCard(clip),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.only(bottom: OmniSpace.xs),
                    child: OmniProgressBar(height: 2, semanticLabel: 'Reading'),
                  ),
                TransferProgress(
                  tv: tv,
                  onCancel: _busy && !_stopBatch
                      ? () => setState(() => _stopBatch = true)
                      : null,
                ),
                if (_error != null)
                  TvLoadError(
                    what: 'This folder',
                    reason: _error!,
                    noun: tv.noun,
                    onRetry: _reload,
                  )
                else if (entries == null)
                  const OmniListSkeleton(label: 'Reading the folder')
                else if (entries.isEmpty)
                  const OmniEmptyState(
                    icon: TvIcons.folder,
                    title: 'This folder is empty',
                    message: 'Use the plus to add a folder or upload a file.',
                  )
                else
                  for (final e in entries) _entryRow(e),
              ],
            ),
          ),
        ),
        // The selection's actions, pinned under the list like a page's
        // bottom bar, clear of the system navigation bar.
        if (selecting)
          Padding(
            padding: EdgeInsets.fromLTRB(
              OmniSpace.md,
              OmniSpace.sm,
              OmniSpace.md,
              MediaQuery.paddingOf(context).bottom + OmniSpace.md,
            ),
            child: _actionBar(),
          ),
      ],
    );
  }

  Widget _selectionHeader() => Row(
    children: [
      Expanded(
        child: Text(
          '${_selected.length} selected',
          key: const ValueKey('select-count'),
          style: OmniText.section,
        ),
      ),
      TextButton(
        key: const ValueKey('select-all'),
        onPressed: () => setState(
          () => _selected.addAll([for (final e in _entries!) e.name]),
        ),
        child: const Text('Select all'),
      ),
      TextButton(
        key: const ValueKey('select-clear'),
        onPressed: () => setState(_selected.clear),
        child: const Text('Clear'),
      ),
    ],
  );

  Widget _pasteCard(_Clipboard clip) => OmniCard(
    highlighted: true,
    title: '${clip.cut ? 'Move' : 'Copy'} ${_count(clip.paths.length)} here',
    trailing: TextButton(
      key: const ValueKey('files-paste-cancel'),
      onPressed: () => setState(() => _clipboard = null),
      child: const Text('Cancel'),
    ),
    child: OmniButton(
      key: const ValueKey('files-paste'),
      label: 'Paste in ${_crumbLabel(_path, phone: tv.isPhone)}',
      icon: TvIcons.paste,
      onPressed: _busy ? null : _paste,
    ),
  );

  Widget _entryRow(TvFileEntry e) {
    final selected = _selected.contains(e.name);
    final opensAsFolder = e.isDir || e.type == 'link';
    final icon = switch (e.type) {
      'dir' => TvIcons.folder,
      'link' => TvIcons.link,
      _ => _fileIcon(e.name),
    };
    return OmniListRow(
      key: ValueKey('entry-${e.name}'),
      leading: _selected.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? TvIcons.checked : TvIcons.unchecked,
                  color: selected
                      ? OmniPalette.of(context).accent
                      : OmniPalette.of(context).muted,
                  fill: selected ? 1 : 0,
                  semanticLabel: selected ? 'Selected' : 'Not selected',
                ),
                const SizedBox(width: OmniSpace.sm),
                OmniIconBox(icon: icon),
              ],
            ),
      icon: icon,
      title: e.name,
      subtitle: _subtitle(e),
      trailing: _selected.isEmpty
          ? OmniIconAction(
              key: ValueKey('entry-menu-${e.name}'),
              icon: OmniIcons.more,
              label: 'More for ${e.name}',
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
      'apk' => TvIcons.apk,
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' => TvIcons.image,
      'mp4' || 'mkv' || 'avi' || 'mov' || 'webm' => TvIcons.video,
      'mp3' || 'aac' || 'flac' || 'wav' || 'ogg' => TvIcons.audio,
      'zip' || 'tar' || 'gz' || '7z' => TvIcons.archive,
      'txt' || 'log' || 'json' || 'xml' => TvIcons.text,
      _ => TvIcons.file,
    };
  }

  /// The bar of the mockup: copy, cut, download, rename and delete for what
  /// is selected.
  Widget _actionBar() {
    final chosen = _selectedEntries;
    Widget action(
      String key,
      IconData icon,
      String label,
      VoidCallback? onTap, {
      bool danger = false,
    }) {
      final color = onTap == null
          ? OmniPalette.of(context).muted
          : danger
          ? OmniPalette.of(context).bad
          : OmniPalette.of(context).text;
      return Expanded(
        child: Semantics(
          button: true,
          enabled: onTap != null,
          label: label,
          excludeSemantics: true,
          onTap: onTap,
          child: InkWell(
            key: ValueKey('select-$key'),
            borderRadius: BorderRadius.circular(OmniRadii.button),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: OmniSpace.target + 4,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(height: OmniSpace.xs / 2),
                  Text(label, style: OmniText.caption.copyWith(color: color)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final palette = OmniPalette.of(context);
    return Material(
      key: const ValueKey('select-bar'),
      color: palette.sheet,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadii.card),
        side: BorderSide(color: palette.line),
      ),
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.all(OmniSpace.xs),
        child: Row(
          children: [
            action(
              'copy',
              TvIcons.copy,
              'Copy',
              _busy ? null : () => _copy(chosen, cut: false),
            ),
            action(
              'cut',
              TvIcons.cut,
              'Cut',
              _busy ? null : () => _copy(chosen, cut: true),
            ),
            action(
              'download',
              TvIcons.download,
              'Download',
              _busy ? null : () => _download(chosen),
            ),
            action(
              'rename',
              TvIcons.rename,
              'Rename',
              _busy || chosen.length != 1 ? null : () => _rename(chosen.single),
            ),
            action(
              'delete',
              OmniIcons.delete,
              'Delete',
              _busy ? null : () => _delete(chosen),
              danger: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// What a folder is called in the breadcrumb: the shared storage reads
/// "Storage", the device's root "TV" or "Phone".
String _crumbLabel(String path, {bool phone = false}) => switch (path) {
  '/' => phone ? 'Phone' : 'TV',
  filesRoot => 'Storage',
  _ => baseName(path),
};

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({
    required this.path,
    required this.onOpen,
    this.phone = false,
  });

  final bool phone;

  final String path;
  final void Function(String path)? onOpen;

  @override
  Widget build(BuildContext context) {
    final crumbs = <String>['/'];
    if (path == filesRoot || path.startsWith('$filesRoot/')) {
      crumbs.add(filesRoot);
      final rest = path.substring(filesRoot.length).split('/');
      var at = filesRoot;
      for (final p in rest.where((p) => p.isNotEmpty)) {
        at = joinPath(at, p);
        crumbs.add(at);
      }
    } else {
      var at = '';
      for (final p in path.split('/').where((p) => p.isNotEmpty)) {
        at = '$at/$p';
        crumbs.add(at);
      }
    }
    // Reversed so a deep path keeps its last folder in view, and shrink
    // wrapped so a short one still starts at the left.
    return SizedBox(
      height: OmniSpace.target,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: ListView(
          key: const ValueKey('breadcrumbs'),
          scrollDirection: Axis.horizontal,
          reverse: true,
          shrinkWrap: true,
          children: [
            for (final (i, target) in crumbs.indexed.toList().reversed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (i > 0)
                    Icon(
                      OmniIcons.chevron,
                      size: 16,
                      color: OmniPalette.of(context).muted,
                    ),
                  TextButton(
                    key: ValueKey('crumb-$target'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(
                        OmniSpace.target,
                        OmniSpace.target,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: OmniSpace.sm,
                      ),
                      foregroundColor: i == crumbs.length - 1
                          ? OmniPalette.of(context).text
                          : OmniPalette.of(context).muted,
                      disabledForegroundColor: i == crumbs.length - 1
                          ? OmniPalette.of(context).text
                          : OmniPalette.of(context).muted,
                      textStyle: OmniText.caption.copyWith(
                        fontWeight: i == crumbs.length - 1
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                    onPressed: onOpen == null || i == crumbs.length - 1
                        ? null
                        : () => onOpen!(target),
                    child: Text(_crumbLabel(target, phone: phone)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
