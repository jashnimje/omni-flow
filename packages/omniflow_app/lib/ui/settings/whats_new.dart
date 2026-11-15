import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../state/providers.dart';
import '../design/design.dart';

/// The version in pubspec.yaml.
const appVersion = '0.6.0';

/// What each version brought, newest first. It ships in the app so it
/// reads the same with no network.
const releaseNotes = <({String version, String date, List<String> notes})>[
  (
    version: '0.6.0',
    date: '12 Nov 2026',
    notes: [
      'Rules that wait: "when the door has been open for 5 minutes", the '
          'first person home, the last person out, and "every hour at :05".',
      'Your phone can act: speak, vibrate, torch, ringer, media keys, open '
          'an app, set an alarm or timer. And react: before your alarm, calls, '
          'music, your calendar, a shake.',
      'House modes, timers, a room as one light, and "Save how things are '
          'now" as a scene.',
      'Weather at home, lights that follow the sun, away lighting, and '
          'energy use for plugs that measure it.',
      'Type what you want, and suggestions from your habits.',
      'Why did it not run, Try as if, conflict warnings and History with '
          'Restore on every automation.',
    ],
  ),
  (
    version: '0.5.0',
    date: '12 Nov 2026',
    notes: [
      'Control another Android phone: see and record its screen, tap on it, '
          'manage its apps and permissions, and move files both ways. Pair '
          'it with the code from Wireless debugging under Add, Another phone.',
      'Run your home on a Mac mini hub: every phone that connects sees the '
          'same devices and automations, and each phone still tells the hub '
          'where its person is.',
      'Questions and notifications can go to one person, and each phone '
          'shows only its own.',
    ],
  ),
  (
    version: '0.4.0',
    date: '12 Nov 2026',
    notes: [
      'Your home today: what your automations did, the taps they saved you, '
          'your streak and achievements to earn, with a little confetti.',
      'Tiles show the real thing: a light in its own colour and brightness, '
          'a sensor reading, the app on the TV. Tap a tile to open it, tap '
          'its icon to switch it.',
      'A Surprise me tile runs a random scene, and Run tiles spring and tick.',
      'Swipe an automation to turn it off or remove it, with Undo.',
      'Pick the app for "An app opens" from your phone, and do one thing to '
          'each device in a room.',
      'Questions from automations pop up with their buttons showing.',
      'A live mouse pointer on the TV with the new pointer helper.',
      'New devices: Tuya lights and newer Tuya plugs, Hue colours, older '
          'Shelly plugs, Roku and Sonos.',
      'Appearance: teal, your wallpaper colours, or pure black.',
    ],
  ),
  (
    version: '0.3.0',
    date: '12 Nov 2026',
    notes: [
      'Rules read like sentences: tap a blue word to change just that part, '
          'and use what an earlier step found, such as a web reply or your '
          'answer.',
      'Add step, trigger and condition open one searchable library with '
          'suggestions. Search "netflix" to open it on the TV.',
      'Automations can ask you first, or ask a question mid-run, right from '
          'the notification, and tell you when they run.',
      'New steps: ask, get a value, text, calculate, date and time, and '
          'repeat with each.',
      'New triggers: an app opens, a notification arrives, a Bluetooth device '
          'connects, the screen or Do Not Disturb changes.',
      'Run scenes and automations from a home screen widget, a Quick Settings '
          'tile, the share sheet or the app icon, and from the new Run grid on '
          'Home.',
      'Automations take a colour and an icon, and templates are a gallery.',
    ],
  ),
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
        const Padding(
          padding: EdgeInsets.symmetric(vertical: OmniSpace.lg),
          child: Center(child: OmniMark(size: 96)),
        ),
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
