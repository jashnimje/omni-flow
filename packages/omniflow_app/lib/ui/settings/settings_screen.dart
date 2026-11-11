import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../automations/scenes.dart' show ScenesPage;
import '../design/design.dart';
import '../devices/device_text.dart';
import '../home/home_data.dart';
import '../shell/shell.dart';
import '../tags/tags_page.dart' show TagsPage;
import 'agent_access.dart';
import 'developer_page.dart';
import 'hubs_page.dart';
import 'phone_access.dart';
import 'places_page.dart';
import 'rooms_page.dart';

/// A place in Settings that search can open.
class SettingsPlace {
  const SettingsPlace(this.title, this.icon, this.page);

  final String title;
  final IconData icon;
  final Widget Function() page;

  void open(BuildContext context, WidgetRef ref) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => page()));
}

final settingsPlaces = [
  SettingsPlace('Places and people', OmniIcons.place, PlacesPage.new),
  SettingsPlace('Rooms', OmniIcons.room, RoomsPage.new),
  SettingsPlace('NFC tags', OmniIcons.tag, TagsPage.new),
  SettingsPlace('Scenes', OmniIcons.scene, ScenesPage.new),
  SettingsPlace(
    'Running in the background',
    OmniIcons.settings,
    PhoneAccessPage.new,
  ),
  SettingsPlace('Permissions', OmniIcons.permissions, PhoneAccessPage.new),
  SettingsPlace('Hubs', OmniIcons.hub, HubsPage.new),
  SettingsPlace('Developer', OmniIcons.developer, DeveloperScreen.new),
];

/// The engine's own status, for Hubs and the Developer engine tab.
final engineStatusProvider = FutureProvider<Json>(
  (ref) async =>
      (await ref.watch(engineApiProvider).engineStatus()).or(const {}),
);

/// 7.1: the home (places, rooms, tags, scenes), this phone (background
/// running, permissions, hubs), what agents made that waits for approval,
/// and the developer tools.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  static String _count(int? n, String one, String many) =>
      n == null ? '' : '$n ${n == 1 ? one : many}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = [
      for (final j in ref.watch(devicesProvider).value ?? const <Json>[])
        DeviceView(j),
    ];
    final person = personOf(devices);
    final presence = person == null ? null : Presence.of(person.json);
    final rooms = ref.watch(roomsProvider).value;
    final scenes = ref.watch(scenesProvider).value;
    final summaries = ref.watch(summariesProvider).value;
    final access = ref.watch(phoneAccessStateProvider).value;
    final hub = ref.watch(engineStatusProvider).value;
    final hubError = ref.watch(hubErrorProvider);
    final tags = devices.where((d) => d.driver == 'nfc_tag').length;
    final waiting = summaries?.where((a) => a.needsApproval).toList();
    final shell = ref.read(shellControllerProvider);
    return OmniTabPage(
      title: 'Settings',
      body: ListView(
        key: const ValueKey('settings-list'),
        padding: const EdgeInsets.only(bottom: OmniSpace.xl),
        children: [
          const OmniSectionHeader('Home'),
          OmniListRow(
            key: const ValueKey('settings-places'),
            icon: OmniIcons.place,
            title: 'Places and people',
            subtitle: switch (presence?.home) {
              true => 'Home · you are here',
              false => 'Home · you are away',
              null => 'Where you are, and how OmniFlow knows',
            },
            chevron: true,
            onTap: () => _push(context, const PlacesPage()),
          ),
          OmniListRow(
            key: const ValueKey('settings-rooms'),
            icon: OmniIcons.room,
            title: 'Rooms',
            subtitle: _count(rooms?.length, 'room', 'rooms'),
            chevron: true,
            onTap: () => _push(context, const RoomsPage()),
          ),
          OmniListRow(
            key: const ValueKey('settings-tags'),
            icon: OmniIcons.tag,
            title: 'NFC tags',
            subtitle: _count(tags, 'tag', 'tags'),
            chevron: true,
            onTap: () => _push(context, const TagsPage()),
          ),
          OmniListRow(
            key: const ValueKey('settings-scenes'),
            icon: OmniIcons.scene,
            title: 'Scenes',
            subtitle: _count(scenes?.length, 'scene', 'scenes'),
            chevron: true,
            onTap: () => _push(context, const ScenesPage()),
          ),
          const OmniSectionHeader('This phone'),
          OmniListRow(
            key: const ValueKey('settings-background'),
            icon: OmniIcons.settings,
            title: 'Running in the background',
            subtitle: switch (access) {
              null => 'Checking',
              PhoneAccessState(running: false) => 'Off · automations wait',
              PhoneAccessState(batteryUnrestricted: false) =>
                'On · battery saver can stop it',
              PhoneAccessState(batteryUnrestricted: true) =>
                'On · battery saver off for OmniFlow',
              _ => 'On',
            },
            dot: access == null
                ? null
                : access.backgroundOk
                ? StatusKind.online
                : StatusKind.warning,
            onTap: () => _push(context, const PhoneAccessPage()),
          ),
          OmniListRow(
            key: const ValueKey('settings-permissions'),
            icon: OmniIcons.permissions,
            title: 'Permissions',
            subtitle: 'location, nearby devices, NFC, notifications',
            chevron: true,
            onTap: () => _push(context, const PhoneAccessPage()),
          ),
          OmniListRow(
            key: const ValueKey('settings-hubs'),
            icon: OmniIcons.hub,
            title: 'Hubs',
            subtitle: hubError != null
                ? 'The hub did not start'
                : switch (hub?['hubRunning']) {
                    true => 'This phone runs the hub',
                    false => 'The hub is stopped',
                    _ => 'What runs your automations',
                  },
            dot: hubError != null || hub?['hubRunning'] == false
                ? StatusKind.warning
                : null,
            chevron: true,
            onTap: () => _push(context, const HubsPage()),
          ),
          const OmniSectionHeader('Claude and agents'),
          const AgentAccessRow(),
          OmniListRow(
            key: const ValueKey('settings-waiting'),
            icon: OmniIcons.agent,
            title: 'Waiting for approval',
            subtitle: waiting == null
                ? ''
                : waiting.isEmpty
                ? 'Nothing waiting'
                : _count(waiting.length, 'automation', 'automations'),
            value: waiting == null || waiting.isEmpty
                ? null
                : '${waiting.length}',
            chevron: true,
            onTap: () => waiting != null && waiting.length == 1
                ? shell.open(ReviewLink(waiting.single.id))
                : shell.select(ShellTab.automations),
          ),
          const OmniSectionHeader('Advanced'),
          OmniListRow(
            key: const ValueKey('settings-developer'),
            icon: OmniIcons.developer,
            title: 'Developer',
            subtitle: 'packets, run log, drivers, engine',
            chevron: true,
            onTap: () => shell.open(const DeveloperLink()),
          ),
          OmniListRow(
            key: const ValueKey('settings-about'),
            icon: OmniIcons.about,
            title: 'About',
            subtitle: 'OmniFlow $appVersion · licences',
            chevron: true,
            divider: false,
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'OmniFlow',
              applicationVersion: appVersion,
            ),
          ),
        ],
      ),
    );
  }
}

/// The version in pubspec.yaml.
const appVersion = '0.1.0';
