import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/providers.dart';
import '../../state/reload_home.dart';
import '../design/design.dart';
import 'restore_flow.dart';
import '../../api/screen_calls.dart';

/// Opens Android's share sheet for a file: Save to Drive, Gmail, Files.
/// Tests stand in for it.
final shareFileProvider = Provider<Future<void> Function(String path)>(
  (ref) => (path) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: 'application/json')],
        subject: 'OmniFlow backup',
      ),
    );
  },
);

/// Where "Back up now" saves, as the Files app shows it.
final backupFolder = Platform.isAndroid
    ? 'Download/OmniFlow'
    : Platform.isIOS
    ? 'Files, OmniFlow'
    : 'Downloads/OmniFlow';

/// `omniflow-backup-2026-11-20-1405.json`: one name per minute, so a new
/// backup never writes over a file an earlier install made, which Android
/// does not let this install change.
String backupFileName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'omniflow-backup-${now.year}-${two(now.month)}-${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}.json';
}

/// Keeps a copy of the whole home in a file, and brings one back: things,
/// rooms, places, tags, automations and variables. Keys and passwords
/// never go in the file, so a restored device asks for its own again.
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  var _busy = false;
  String? _saved;
  String? _error;
  Json? _restored;

  /// Backs up, then offers the file to Drive or any app that takes it.
  Future<void> _exportAndShare() async {
    final path = await _export();
    if (path == null || !mounted) return;
    await ref.read(shareFileProvider)(path);
  }

  /// Writes the backup file and says where. Its path, or null when it
  /// could not be made.
  Future<String?> _export() async {
    setState(() {
      _busy = true;
      _error = null;
      _saved = null;
    });
    final r = await ref.read(engineClientProvider).call(BackupCalls.export);
    if (!mounted) return null;
    if (r['ok'] != true) {
      setState(() {
        _busy = false;
        _error = errorMessage(r);
      });
      return null;
    }
    final downloads = await ref.read(phoneFilesProvider).downloadsDir();
    final dir = downloads ?? (await getApplicationDocumentsDirectory()).path;
    final file = File('$dir/${backupFileName(DateTime.now())}');
    try {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(r['backup']),
      );
      await ref.read(phoneFilesProvider).announce(file.path);
    } on FileSystemException catch (e) {
      if (!mounted) return null;
      setState(() {
        _busy = false;
        _error = 'The file could not be written: ${e.message}';
      });
      return null;
    }
    if (!mounted) return null;
    setState(() {
      _busy = false;
      _saved = downloads == null
          ? 'Saved to ${file.path}'
          : 'Saved ${file.uri.pathSegments.last} in $backupFolder';
    });
    return file.path;
  }

  Future<void> _restore() async {
    void fail(String message) {
      if (mounted) setState(() => _error = message);
    }

    setState(() {
      _error = null;
      _restored = null;
    });
    final backup = await pickBackup(ref, onError: fail);
    if (backup == null || !mounted) return;
    final done = await restoreBackup(
      context,
      ref,
      backup,
      onBusy: (busy) {
        if (mounted) setState(() => _busy = busy);
      },
      onError: fail,
    );
    if (done == null || !mounted) return;
    setState(() => _restored = done);
    await reloadHome(ref);
  }

  @override
  Widget build(BuildContext context) {
    final restored = _restored;
    return FormPage.instant(
      title: 'Backup and restore',
      children: (context) => [
        Text(
          'A backup holds your things, rooms, places, tags, automations and '
          'variables. Keys and passwords stay on this phone, so after a '
          'restore a device that needs one asks for it again.',
          style: OmniText.captionOf(context),
        ),
        const SizedBox(height: OmniSpace.md),
        OmniListRow(
          key: const ValueKey('backup-export'),
          icon: OmniIcons.backup,
          title: 'Back up now',
          subtitle: 'saves a file in $backupFolder',
          onTap: _busy ? null : _export,
        ),
        OmniListRow(
          key: const ValueKey('backup-share'),
          icon: OmniIcons.upload,
          title: 'Back up to Google Drive or another app',
          subtitle:
              'saves the file, then opens Share: pick Drive, Gmail, Files',
          onTap: _busy ? null : _exportAndShare,
        ),
        OmniListRow(
          key: const ValueKey('backup-restore'),
          icon: OmniIcons.download,
          title: 'Restore from a file',
          subtitle:
              'pick it in $backupFolder, Drive or any app. Shows what '
              'changes first',
          subtitleLines: 2,
          onTap: _busy ? null : _restore,
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: OmniSpace.lg),
            child: OmniProgressBar(
              key: ValueKey('backup-busy'),
              semanticLabel: 'Working on the backup',
            ),
          ),
        if (_error case final e?)
          OmniBanner.error(e, key: const ValueKey('backup-error')),
        if (_saved case final saved?)
          OmniBanner.info(saved, key: const ValueKey('backup-saved')),
        if (restored != null) RestoreResult(restored),
      ],
    );
  }
}
