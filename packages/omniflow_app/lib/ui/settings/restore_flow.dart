import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/screen_calls.dart';
import '../../state/providers.dart';
import '../add/guided_steps_page.dart' show openSetup;
import '../design/design.dart';
import '../onboarding/home_setup.dart' show SetupStep;
import '../tags/tag_page.dart' show whenText;

/// A backup file the app can read itself: one it wrote in this install.
typedef FoundBackup = ({
  String path,
  String name,
  DateTime? at,
  int things,
  int automations,
  Json backup,
});

/// The parsed backup in [text], or null when it is not one.
Json? backupOf(String text) {
  try {
    final json = jsonDecode(text);
    return json is Map && json['schema'] == 'omniflow.backup'
        ? Map<String, Object?>.from(json)
        : null;
  } on FormatException {
    return null;
  }
}

/// The newest backup in the backup folder that this install can read.
/// Android hides and locks the files an earlier install wrote, so after a
/// reinstall there is none, and only the system file picker reaches them.
Future<FoundBackup?> newestBackup(PhoneFiles files) async {
  final dir = await files.downloadsDir();
  if (dir == null) return null;
  final candidates = <(File, DateTime)>[];
  try {
    await for (final e in Directory(dir).list()) {
      final name = e.uri.pathSegments.last;
      if (e is! File ||
          !name.startsWith('omniflow-backup') ||
          !name.endsWith('.json')) {
        continue;
      }
      candidates.add((e, await e.lastModified()));
    }
  } on FileSystemException {
    return null;
  }
  candidates.sort((a, b) => b.$2.compareTo(a.$2));
  for (final (file, modified) in candidates) {
    final Json? backup;
    try {
      backup = backupOf(await file.readAsString());
    } on FileSystemException {
      continue;
    }
    if (backup == null) continue;
    int count(String key) => (backup![key] as List?)?.length ?? 0;
    return (
      path: file.path,
      name: file.uri.pathSegments.last,
      at: DateTime.tryParse('${backup['exportedAt']}')?.toLocal() ?? modified,
      things: count('things'),
      automations: count('automations'),
      backup: backup,
    );
  }
  return null;
}

/// "From 20 Nov 14:05: 8 things, 1 automation".
String foundBackupWords(FoundBackup found, {DateTime? now}) {
  String n(int count, String one) => '$count ${count == 1 ? one : '${one}s'}';
  final when = found.at == null
      ? ''
      : 'From ${whenText(found.at!, now: now)}: ';
  return '$when${n(found.things, 'thing')}, ${n(found.automations, 'automation')}';
}

/// A backup the user picks with the system file picker, which reaches
/// Download, Drive and any other app's files, also those an earlier install
/// wrote. Null when they cancel, after [onError] when it is not a backup.
Future<Json?> pickBackup(
  WidgetRef ref, {
  required void Function(String message) onError,
}) async {
  final files = await ref.read(phoneFilesProvider).pick();
  if (files.isEmpty) return null;
  final file = files.first;
  final String text;
  try {
    text = await File(file.path).readAsString();
  } on FileSystemException {
    onError(
      '${file.name} could not be read. Pick it again from where it is '
      'saved.',
    );
    return null;
  }
  final backup = backupOf(text);
  if (backup == null) onError('${file.name} is not an OmniFlow backup.');
  return backup;
}

/// Shows what [backup] changes, and on Restore brings it in. The import's
/// result, or null when the user said no or it failed ([onError] says why).
Future<Json?> restoreBackup(
  BuildContext context,
  WidgetRef ref,
  Json backup, {
  required void Function(bool busy) onBusy,
  required void Function(String message) onError,
}) async {
  final engine = ref.read(engineClientProvider);
  onBusy(true);
  final plan = await engine.call(BackupCalls.import, {
    'backup': backup,
    'mode': 'merge',
    'dryRun': true,
  });
  onBusy(false);
  if (plan['ok'] != true) {
    onError(errorMessage(plan));
    return null;
  }
  if (!context.mounted) return null;
  final ok = await confirm(
    context,
    title: 'Restore this backup?',
    body:
        '${restoreSummary(plan)} Things and automations you have that are '
        'not in the backup stay as they are.',
    action: 'Restore',
  );
  if (!ok) return null;
  onBusy(true);
  final done = await engine.call(BackupCalls.import, {
    'backup': backup,
    'mode': 'merge',
  });
  onBusy(false);
  if (done['ok'] != true) {
    onError(errorMessage(done));
    return null;
  }
  return done;
}

int _count(Json result, String change, String kind) =>
    ((result[change] as Map?)?[kind] as List?)?.length ?? 0;

/// "It adds 3 items and changes 1 item."
String restoreSummary(Json plan) {
  int count(String key) =>
      [for (final v in (plan[key] as Map? ?? const {}).values) ...?(v as List?)]
          .length;
  final add = count('add');
  final change = count('replace');
  if (add == 0 && change == 0) return 'Everything in it is here already.';
  String items(int n) => '$n ${n == 1 ? 'item' : 'items'}';
  if (change == 0) return 'It adds ${items(add)}.';
  if (add == 0) return 'It changes ${items(change)}.';
  return 'It adds ${items(add)} and changes ${items(change)}.';
}

/// What came back: "Restored 8 things, 1 room and 1 automation."
String restoredWords(Json done) {
  int all(String kind) => [
    'add',
    'replace',
    'skip',
  ].fold(0, (n, change) => n + _count(done, change, kind));
  final parts = [
    for (final (kind, one) in [
      ('things', 'thing'),
      ('rooms', 'room'),
      ('automations', 'automation'),
    ])
      if (all(kind) case final n when n > 0) '$n ${n == 1 ? one : '${one}s'}',
  ];
  if (parts.isEmpty) return 'Restored. The backup had nothing to bring back.';
  final list = parts.length == 1
      ? parts.single
      : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  return 'Restored $list.';
}

/// What one thing still needs after a restore, in words.
String stillToDoWords(Map<Object?, Object?> need) {
  if (need['pair'] == true) {
    return need['pairing'] == 'adb'
        ? 'Pair again: ${need['category'] == 'media' ? 'the TV' : 'it'} asks '
              'to allow this phone once'
        : 'Pair again: tap to start';
  }
  final labels = [for (final l in need['labels'] as List? ?? const []) '$l'];
  final what = labels.isEmpty ? 'key' : labels.join(' and ');
  return 'Enter its $what again: tap to start';
}

/// The setup steps a backup already answers, so the first run skips them:
/// a person, where home is, a home Wi-Fi network, a device, an automation.
Set<SetupStep> stepsCoveredBy(Json backup) {
  final things = [
    for (final t in backup['things'] as List? ?? const [])
      if (t is Map) t,
  ];
  final home = backup['home'];
  return {
    if (things.any((t) => t['driver'] == 'person')) SetupStep.you,
    if (home is Map && home['location'] != null) SetupStep.home,
    if (things.any(
      (t) =>
          t['driver'] == 'place' &&
          (((t['settings'] as Map?)?['wifi'] as Map?)?['ssids'] as List?)
                  ?.isNotEmpty ==
              true,
    ))
      SetupStep.presence,
    if (things.any(
      (t) => !{'person', 'place', 'phone', 'nfc_tag'}.contains(t['driver']),
    ))
      SetupStep.device,
    if ((backup['automations'] as List?)?.isNotEmpty == true)
      SetupStep.automation,
  };
}

/// The result of a restore: what came back, what waits for approval, and
/// each thing that still needs a key or a pairing, which opens its setup.
class RestoreResult extends StatelessWidget {
  const RestoreResult(this.done, {super.key});

  final Json done;

  @override
  Widget build(BuildContext context) {
    final needs = [
      for (final s in (done['needsSecrets'] as List? ?? const []))
        if (s is Map) s,
    ];
    final waiting = (done['waitForApproval'] as List? ?? const []);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniBanner.info(
          needs.isEmpty && waiting.isEmpty
              ? '${restoredWords(done)} Nothing else needs you.'
              : restoredWords(done),
          key: const ValueKey('backup-restored'),
        ),
        if (waiting.isNotEmpty)
          OmniBanner.warning(
            '${waiting.length} high-risk '
            '${waiting.length == 1 ? 'automation waits' : 'automations wait'} '
            'for your approval, in Settings, Waiting for approval.',
            key: const ValueKey('backup-waiting'),
          ),
        if (needs.isNotEmpty) ...[
          const OmniSectionHeader('Still to do'),
          for (final s in needs)
            OmniListRow(
              key: ValueKey('backup-secret-${s['id']}'),
              icon: OmniIcons.permissions,
              title: '${s['name'] ?? s['id']}',
              subtitle: stillToDoWords(s),
              subtitleLines: 2,
              chevron: true,
              onTap: () => openSetup(context, {
                'id': s['id'],
                'name': s['name'] ?? s['id'],
              }),
            ),
        ],
      ],
    );
  }
}
