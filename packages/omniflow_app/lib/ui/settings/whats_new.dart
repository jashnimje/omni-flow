import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../state/providers.dart';
import '../design/design.dart';

/// The version in pubspec.yaml.
const appVersion = '0.2.0';

/// What each version brought, newest first. It ships in the app so it
/// reads the same with no network.
const releaseNotes = <({String version, String date, List<String> notes})>[
  (
    version: '0.2.0',
    date: '10 Nov 2026',
    notes: [
      'Scenes sit in Automations now, next to what they belong with, and '
          'Settings is grouped by your home, this phone, agents and your data.',
      'Back up to Google Drive or another app from Settings, Backup and '
          'restore, and restore from a file in Download or Drive.',
      'Rules can start at sunrise or sunset, and send a web request.',
      'Variables, the SSH host key of a computer, Duplicate on a rule, and '
          'Make an automation with it on a device page.',
      'Agents keep to the access you gave them in every tool.',
    ],
  ),
  (
    version: '0.1.0',
    date: '9 Nov 2026',
    notes: [
      'The first OmniFlow: devices, rules, scenes, places, NFC tags, the TV '
          'control centre, boards over USB and agents over adb.',
    ],
  ),
];

/// The last version whose notes were shown, in a file next to the app's
/// own data. Tests stand in for it.
abstract interface class SeenVersion {
  Future<String?> read();
  Future<void> write(String version);
}

class FileSeenVersion implements SeenVersion {
  const FileSeenVersion();

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/seen_version');

  @override
  Future<String?> read() async {
    try {
      return (await (await _file()).readAsString()).trim();
    } on FileSystemException {
      return null;
    } on Object {
      // No storage here at all (tests, the desktop): nothing to announce.
      return appVersion;
    }
  }

  @override
  Future<void> write(String version) async {
    try {
      await (await _file()).writeAsString(version);
    } on Object {
      // Shown again next time: harmless.
    }
  }
}

final seenVersionProvider = Provider<SeenVersion>(
  (ref) => const FileSeenVersion(),
);

/// After an update, shows what it brought, once. A first install shows
/// nothing: everything is new then. Versions before 0.2.0 kept no record,
/// so a phone with a home set up already ([hasHome]) counts as updated.
Future<void> showWhatsNewAfterUpdate(
  BuildContext context,
  SeenVersion seen, {
  Future<bool> Function()? hasHome,
}) async {
  final last = await seen.read();
  await seen.write(appVersion);
  if (last == appVersion || !context.mounted) return;
  if (last == null && !(await hasHome?.call() ?? false)) return;
  if (!context.mounted) return;
  final notes = releaseNotes.where((r) => r.version == appVersion).firstOrNull;
  if (notes == null) return;
  await showOmniSheet<void>(
    context,
    builder: (sheet) => OmniSheet(
      title: 'New in OmniFlow ${notes.version}',
      children: [
        for (final n in notes.notes) _Note(n),
        const SizedBox(height: OmniSpace.md),
        OmniButton(
          key: const ValueKey('whats-new-ok'),
          label: 'Got it',
          onPressed: () => Navigator.of(sheet).pop(),
        ),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: OmniSpace.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 6, right: 10),
          child: Icon(Icons.circle, size: 6, color: OmniColors.accent),
        ),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

/// About: the version, every version's notes, and the licences.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) => OmniPage(
    title: 'About',
    body: ListView(
      children: [
        OmniListRow(
          key: const ValueKey('about-version'),
          icon: OmniIcons.about,
          title: 'OmniFlow $appVersion',
          subtitle: 'Runs on this phone. Nothing leaves it unless you send it.',
        ),
        OmniListRow(
          key: const ValueKey('about-licences'),
          icon: OmniIcons.info,
          title: 'Licences',
          chevron: true,
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'OmniFlow',
            applicationVersion: appVersion,
          ),
        ),
        for (final r in releaseNotes) ...[
          OmniSectionHeader('What is new in ${r.version} · ${r.date}'),
          for (final n in r.notes) _Note(n),
        ],
        const SizedBox(height: OmniSpace.xl),
      ],
    ),
  );
}

/// Runs [showWhatsNewAfterUpdate] once the first frame is up.
void whatsNewOnStart(BuildContext context, WidgetRef ref) {
  final seen = ref.read(seenVersionProvider);
  Future<bool> hasHome() async {
    try {
      final devices = await ref.read(devicesProvider.future);
      // The phone itself is always there: anything more is a home.
      return devices.any((d) => d['driver'] != 'phone');
    } on Object {
      return false;
    }
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (context.mounted) {
      showWhatsNewAfterUpdate(context, seen, hasHome: hasHome);
    }
  });
}
