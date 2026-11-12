import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../state/providers.dart';
import '../design/design.dart';

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

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _error = null;
      _saved = null;
    });
    final r = await ref.read(engineClientProvider).call('config.export');
    if (!mounted) return;
    if (r['ok'] != true) {
      setState(() {
        _busy = false;
        _error = errorMessage(r);
      });
      return;
    }
    final dir =
        await ref.read(phoneFilesProvider).downloadsDir() ??
        (await getApplicationDocumentsDirectory()).path;
    final day = DateTime.now().toIso8601String().substring(0, 10);
    final file = File('$dir/omniflow-backup-$day.json');
    try {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(r['backup']),
      );
    } on FileSystemException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'The file could not be written: ${e.message}';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _saved = file.path;
    });
  }

  Future<void> _restore() async {
    final files = await ref.read(phoneFilesProvider).pick(extensions: ['json']);
    if (files.isEmpty || !mounted) return;
    Object? backup;
    try {
      backup = jsonDecode(await File(files.first.path).readAsString());
    } on FormatException {
      setState(() => _error = '${files.first.name} is not an OmniFlow backup.');
      return;
    }
    final engine = ref.read(engineClientProvider);
    setState(() {
      _busy = true;
      _error = null;
      _restored = null;
    });
    final plan = await engine.call('config.import', {
      'backup': backup,
      'mode': 'merge',
      'dryRun': true,
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (plan['ok'] != true) {
      setState(() => _error = errorMessage(plan));
      return;
    }
    final ok = await confirm(
      context,
      title: 'Restore this backup?',
      body:
          '${_summary(plan)} Things and automations you have that are not in '
          'the backup stay as they are.',
      action: 'Restore',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final done = await engine.call('config.import', {
      'backup': backup,
      'mode': 'merge',
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (done['ok'] == true) {
        _restored = done;
      } else {
        _error = errorMessage(done);
      }
    });
    if (done['ok'] == true) {
      await ref.read(devicesProvider.notifier).refresh();
    }
  }

  /// "It adds 3 items and changes 1 item."
  static String _summary(Json plan) {
    int count(String key) => [
      for (final v in (plan[key] as Map? ?? const {}).values) ...?(v as List?),
    ].length;
    final add = count('add');
    final change = count('replace');
    if (add == 0 && change == 0) return 'Everything in it is here already.';
    String items(int n) => '$n ${n == 1 ? 'item' : 'items'}';
    if (change == 0) return 'It adds ${items(add)}.';
    if (add == 0) return 'It changes ${items(change)}.';
    return 'It adds ${items(add)} and changes ${items(change)}.';
  }

  @override
  Widget build(BuildContext context) {
    final restored = _restored;
    final secrets = [
      for (final s in (restored?['needsSecrets'] as List? ?? const []))
        if (s is Map) s,
    ];
    final waiting = (restored?['waitForApproval'] as List? ?? const []);
    return OmniPage(
      title: 'Backup and restore',
      body: ListView(
        children: [
          const Text(
            'A backup holds your things, rooms, places, tags, automations and '
            'variables. Keys and passwords stay on this phone, so after a '
            'restore each device that had one asks for it again.',
            style: OmniText.caption,
          ),
          const SizedBox(height: OmniSpace.md),
          OmniListRow(
            key: const ValueKey('backup-export'),
            icon: OmniIcons.download,
            title: 'Back up now',
            subtitle: 'saves a file in Download',
            onTap: _busy ? null : _export,
          ),
          OmniListRow(
            key: const ValueKey('backup-restore'),
            icon: OmniIcons.upload,
            title: 'Restore from a file',
            subtitle: 'shows what changes before anything does',
            onTap: _busy ? null : _restore,
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(OmniSpace.lg),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error case final e?)
            OmniBanner.error(e, key: const ValueKey('backup-error')),
          if (_saved case final path?)
            OmniBanner.info(
              'Saved to $path',
              key: const ValueKey('backup-saved'),
            ),
          if (restored != null) ...[
            const OmniBanner.info(
              'Restored.',
              key: ValueKey('backup-restored'),
            ),
            if (waiting.isNotEmpty)
              OmniBanner.warning(
                '${waiting.length} high-risk '
                '${waiting.length == 1 ? 'automation waits' : 'automations wait'} '
                'for your approval, in Settings, Waiting for approval.',
                key: const ValueKey('backup-waiting'),
              ),
            if (secrets.isNotEmpty) ...[
              const OmniSectionHeader('These need their keys again'),
              for (final s in secrets)
                OmniListRow(
                  key: ValueKey('backup-secret-${s['id']}'),
                  icon: OmniIcons.permissions,
                  title: '${s['name'] ?? s['id']}',
                  subtitle: s['pair'] == true
                      ? 'pair it again from its page'
                      : 'enter its key again from its page',
                ),
            ],
          ],
          const SizedBox(height: OmniSpace.xl),
        ],
      ),
    );
  }
}
