import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/appearance.dart';
import '../../state/house.dart' show houseShownProvider;
import '../../state/house_providers.dart' show houseModeProvider;
import '../../state/providers.dart';
import '../automations/scenes.dart' show ScenesPage;
import '../automations/waiting_page.dart' show openWaitingForApproval;
import '../boards/usb_board.dart' show showUsbBoardSheet;
import '../design/design.dart';
import '../devices/device_text.dart';
import '../fun/your_home_page.dart' show YourHomePage;
import '../home/home_data.dart';
import '../home/home_presence.dart';
import '../home/mode_picker.dart' show showModePicker;
import '../shell/shell.dart';
import '../tags/tags_page.dart' show TagsPage;
import '../help/screen_help.dart';
import '../onboarding/home_setup.dart' show HomeSetupRow;
import 'agent_access.dart';
import 'alerts_page.dart';
import 'appearance_page.dart';
import 'backup_page.dart';
import 'developer_page.dart';
import 'hub_page.dart';
import 'home_location_page.dart' show HomeLocationPage, HomeLocationRow;
import 'phone_access.dart';
import 'places_page.dart';
import 'rooms_page.dart';
import 'shake_scene.dart';
import 'variables_page.dart';
import 'whats_new.dart';
import 'away_lighting_page.dart' show SmartHomeSettingsRows;

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
  SettingsPlace('Home location', OmniIcons.sun, HomeLocationPage.new),
  SettingsPlace('Rooms', OmniIcons.room, RoomsPage.new),
  SettingsPlace('NFC tags', OmniIcons.tag, TagsPage.new),
  SettingsPlace('Scenes', OmniIcons.scene, ScenesPage.new),
  SettingsPlace('Phone setup', OmniIcons.settings, PhoneAccessPage.new),
  SettingsPlace('Appearance', OmniIcons.color, AppearancePage.new),
  SettingsPlace('Permissions', OmniIcons.permissions, PhoneAccessPage.new),
  SettingsPlace('Hubs', OmniIcons.hub, HubPage.new),
  SettingsPlace('Home runs on', OmniIcons.server, HubPage.new),
  SettingsPlace('Backup and restore', OmniIcons.backup, BackupPage.new),
  SettingsPlace('Your activity', OmniIcons.automations, YourHomePage.new),
  SettingsPlace('Variables', OmniIcons.level, VariablesPage.new),
  SettingsPlace('Developer', OmniIcons.developer, DeveloperScreen.new),
];

/// The engine's own status, for Home runs on and the Developer engine tab.
/// It reads again when automations or things change anywhere (the CLI, an
/// agent, another phone), so the loaded count stays true.
final engineStatusProvider = FutureProvider<Json>((ref) async {
  Timer? again;
  final sub = ref
      .watch(engineClientProvider)
      .events
      .where((e) => engineStatusEvents.contains(e['event']))
      .listen(
        (_) => again ??= Timer(DevicesNotifier.settle, ref.invalidateSelf),
      );
  ref.onDispose(() {
    sub.cancel();
    again?.cancel();
  });
  return (await ref.watch(engineApiProvider).engineStatus()).or(const {});
});

/// The events after which the engine's status may read differently.
const engineStatusEvents = {'automation.changed', deviceChangedEvent};

/// 7.1: this house (places, location, mode, rooms, tags, alerts and the
/// smart home settings, all for the house in view), this phone
/// (background running, permissions, hubs), what agents made that waits
/// for approval, your data and activity, and the developer tools.
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
    final zones = ref.watch(zonesProvider).value;
    final rooms = ref.watch(roomsProvider).value;
    final summaries = ref.watch(summariesProvider).value;
    final access = ref.watch(phoneAccessStateProvider).value;
    final appearance = ref.watch(appearanceProvider).value;
    final tags = devices.where((d) => d.driver == 'nfc_tag').length;
    final waiting = summaries?.where((a) => a.needsApproval).toList();
    final shell = ref.read(shellControllerProvider);
    final house = ref.watch(houseShownProvider);
    final mode = ref.watch(houseModeProvider).value;
    return TabPage(
      title: 'Settings',
      actions: const [ScreenHelpButton(HelpScreen.settings)],
      fab: false,
      children: (context) => [
        OmniSectionHeader(
          house == null ? 'This house' : 'This house · ${house.name}',
        ),
        const HomeSetupRow(),
        OmniListRow(
          key: const ValueKey('settings-places'),
          icon: OmniIcons.place,
          title: 'Places and people',
          subtitle: switch (presenceShown(presence, zones)) {
            PresenceShown.home => 'Home · you are here',
            PresenceShown.away => 'Home · you are away',
            PresenceShown.notSetUp => '$presenceNotSetUp. Tap to set it up',
            _ => 'Where you are, and how OmniFlow knows',
          },
          chevron: true,
          onTap: () => _push(context, const PlacesPage()),
        ),
        const HomeLocationRow(),
        if (mode != null)
          OmniListRow(
            key: const ValueKey('settings-mode'),
            icon: OmniIcons.home,
            title: 'House mode',
            subtitle: mode.followPresence
                ? '${mode.name} · follows who is home'
                : mode.name,
            chevron: true,
            onTap: () => showModePicker(context, ref),
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
          key: const ValueKey('settings-variables'),
          icon: OmniIcons.level,
          title: 'Variables',
          subtitle: 'Values automations set, to see or clear',
          chevron: true,
          onTap: () => _push(context, const VariablesPage()),
        ),
        const AlertsSettingsRow(),
        const SmartHomeSettingsRows(),
        const OmniSectionHeader('This phone'),
        const HomeRunsOnRow(),
        const ShakeSceneRow(),
        OmniListRow(
          key: const ValueKey('settings-background'),
          icon: OmniIcons.settings,
          title: 'Phone setup',
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
          chevron: true,
          onTap: () => _push(context, const PhoneAccessPage()),
        ),
        OmniListRow(
          key: const ValueKey('settings-appearance'),
          icon: OmniIcons.color,
          title: 'Appearance',
          subtitle: appearance == null
              ? 'Colours and background'
              : AppearancePage.summary(appearance),
          chevron: true,
          onTap: () => _push(context, const AppearancePage()),
        ),
        OmniListRow(
          key: const ValueKey('settings-usb'),
          icon: OmniIcons.board,
          title: 'Boards on USB',
          subtitle: 'Set up a board, or install firmware on it',
          chevron: true,
          onTap: () => showUsbBoardSheet(context),
        ),
        const OmniSectionHeader('Agents'),
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
              : openWaitingForApproval(context),
        ),
        const OmniSectionHeader('Your data'),
        OmniListRow(
          key: const ValueKey('settings-backup'),
          icon: OmniIcons.backup,
          title: 'Backup and restore',
          subtitle: 'Keep a copy of the whole home in a file',
          chevron: true,
          onTap: () => _push(context, const BackupPage()),
        ),
        OmniListRow(
          key: const ValueKey('settings-activity'),
          icon: OmniIcons.automations,
          title: 'Your activity',
          subtitle: 'What ran this week, your streak and achievements',
          chevron: true,
          onTap: () => _push(context, const YourHomePage()),
        ),
        const OmniSectionHeader('Advanced'),
        OmniListRow(
          key: const ValueKey('settings-developer'),
          icon: OmniIcons.developer,
          title: 'Developer',
          subtitle: 'Packets, run log, drivers, engine',
          chevron: true,
          onTap: () => shell.open(const DeveloperLink()),
        ),
        OmniListRow(
          key: const ValueKey('settings-about'),
          icon: OmniIcons.about,
          title: 'About',
          subtitle: 'OmniFlow $appVersion · what is new, licences',
          chevron: true,
          divider: false,
          onTap: () => _push(context, const AboutPage()),
        ),
      ],
    );
  }
}
