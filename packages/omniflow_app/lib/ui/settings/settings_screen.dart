import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/appearance.dart';
import '../../state/device_features.dart';
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
import '../onboarding/home_setup.dart' show HomeSetupRow, setupProgressProvider;
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
  const SettingsPlace(
    this.title,
    this.icon,
    this.page, {
    required this.section,
    this.keywords = const [],
    this.shownOn = _everywhere,
  });

  static bool _everywhere(DeviceFeatures _) => true;

  final String title;
  final IconData icon;
  final Widget Function() page;

  /// Where it sits, as its heading reads: "Settings, Your home", or
  /// "Automations" for Scenes, which is not a setting.
  final String section;

  /// Other words that find it, such as "city" for Home location.
  final List<String> keywords;

  /// Whether the device has what the page needs.
  final bool Function(DeviceFeatures features) shownOn;

  /// Whether every word of [query] starts a word of the title or keywords.
  bool matches(String query) {
    final words = [
      for (final t in [title, ...keywords])
        ...t.toLowerCase().split(RegExp(r'\s+')),
    ];
    final asked = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    return asked.isNotEmpty &&
        asked.every((q) => words.any((w) => w.startsWith(q)));
  }

  void open(BuildContext context, WidgetRef ref) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => page()));
}

const _yourHome = 'Settings, Your home';
const _thisPhone = 'Settings, This phone';
const _yourData = 'Settings, Your data';
const _more = 'Settings, More settings';

final settingsPlaces = [
  SettingsPlace(
    'Places and people',
    OmniIcons.place,
    PlacesPage.new,
    section: _yourHome,
    keywords: ['presence', 'wifi', 'away'],
  ),
  SettingsPlace(
    'Home location',
    OmniIcons.sun,
    HomeLocationPage.new,
    section: _yourHome,
    keywords: ['city', 'sunrise', 'sunset', 'address', 'where'],
  ),
  SettingsPlace('Rooms', OmniIcons.room, RoomsPage.new, section: _yourHome),
  SettingsPlace(
    'Scenes',
    OmniIcons.scene,
    ScenesPage.new,
    section: 'Automations',
  ),
  SettingsPlace(
    'Appearance',
    OmniIcons.color,
    AppearancePage.new,
    section: _thisPhone,
    keywords: ['theme', 'light', 'dark', 'colours', 'colors', 'black'],
  ),
  SettingsPlace(
    'Phone setup',
    OmniIcons.settings,
    PhoneAccessPage.new,
    section: _thisPhone,
    keywords: ['battery', 'background'],
    shownOn: _hasService,
  ),
  SettingsPlace(
    'Permissions',
    OmniIcons.permissions,
    PhoneAccessPage.new,
    section: _thisPhone,
    shownOn: _hasService,
  ),
  SettingsPlace(
    'Backup and restore',
    OmniIcons.backup,
    BackupPage.new,
    section: _yourData,
  ),
  SettingsPlace(
    'Your activity',
    OmniIcons.automations,
    YourHomePage.new,
    section: _yourData,
  ),
  SettingsPlace(
    'NFC tags',
    OmniIcons.tag,
    TagsPage.new,
    section: _more,
    shownOn: (f) => f.nfc,
  ),
  SettingsPlace(
    'Saved values',
    OmniIcons.level,
    VariablesPage.new,
    section: _more,
    keywords: ['variables'],
  ),
  SettingsPlace(
    'Hubs',
    OmniIcons.hub,
    HubPage.new,
    section: _more,
    shownOn: _hasHubMode,
  ),
  SettingsPlace(
    'Home runs on',
    OmniIcons.server,
    HubPage.new,
    section: _more,
    shownOn: _hasHubMode,
  ),
  SettingsPlace(
    'Developer',
    OmniIcons.developer,
    DeveloperScreen.new,
    section: 'Settings, For developers',
  ),
];

bool _hasService(DeviceFeatures f) => f.backgroundService;
bool _hasHubMode(DeviceFeatures f) => f.hubMode;

/// The places search can open on a device with [features].
List<SettingsPlace> settingsPlacesFor(DeviceFeatures features) => [
  for (final p in settingsPlaces)
    if (p.shownOn(features)) p,
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

/// Settings (docs/ui/design-v2.md, Settings): three groups in front,
/// Your home (rooms, places and people, home location, house mode), This phone
/// (appearance, alerts, phone setup) and Your data (backup, your
/// activity), then the rarely used rows inside a collapsed More settings
/// with For developers nested in it, and About at the end. "Set up your
/// home" shows in front only until it is done. An automation waiting for
/// approval shows in front only while one waits.
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
    final setupDone = ref.watch(setupProgressProvider)?.complete == true;
    final features = ref.watch(deviceFeaturesProvider);
    final waitingInFront = waiting != null && waiting.isNotEmpty;
    final waitingRow = OmniListRow(
      key: const ValueKey('settings-waiting'),
      icon: OmniIcons.agent,
      title: 'Waiting for approval',
      subtitle: waiting == null
          ? ''
          : waiting.isEmpty
          ? 'Nothing waiting'
          : _count(waiting.length, 'automation', 'automations'),
      value: waitingInFront ? '${waiting.length}' : null,
      chevron: true,
      onTap: () => waiting != null && waiting.length == 1
          ? shell.open(ReviewLink(waiting.single.id))
          : openWaitingForApproval(context),
    );
    return TabPage(
      title: 'Settings',
      actions: const [ScreenHelpButton(HelpScreen.settings)],
      fab: false,
      children: (context) => [
        if (!setupDone) SettingsGroup(children: const [HomeSetupRow()]),
        if (waitingInFront) SettingsGroup(children: [waitingRow]),
        OmniSectionHeader(
          house == null ? 'Your home' : 'Your home · ${house.name}',
        ),
        SettingsGroup(
          children: [
            OmniListRow(
              key: const ValueKey('settings-rooms'),
              icon: OmniIcons.room,
              title: 'Rooms',
              subtitle: _count(rooms?.length, 'room', 'rooms'),
              chevron: true,
              onTap: () => _push(context, const RoomsPage()),
            ),
            OmniListRow(
              key: const ValueKey('settings-places'),
              icon: OmniIcons.place,
              title: 'Places and people',
              subtitle: switch (presenceShown(presence, zones)) {
                PresenceShown.home => 'You are home',
                PresenceShown.away => 'You are away',
                PresenceShown.notSetUp => '$presenceNotSetUp. Tap to set it up',
                _ => 'Where you are, and how OmniFlow knows',
              },
              chevron: true,
              onTap: () => _push(context, const PlacesPage()),
            ),
            HomeLocationRow(divider: mode != null),
            if (mode != null)
              OmniListRow(
                key: const ValueKey('settings-mode'),
                icon: OmniIcons.home,
                title: 'House mode',
                subtitle: mode.followPresence
                    ? '${mode.name} · follows who is home'
                    : mode.name,
                chevron: true,
                divider: false,
                onTap: () => showModePicker(context, ref),
              ),
          ],
        ),
        OmniSectionHeader(
          features.backgroundService ? 'This phone' : 'This device',
        ),
        SettingsGroup(
          children: [
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
            AlertsSettingsRow(divider: features.backgroundService),
            if (features.backgroundService)
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
                divider: false,
                onTap: () => _push(context, const PhoneAccessPage()),
              ),
          ],
        ),
        const OmniSectionHeader('Your data'),
        SettingsGroup(
          children: [
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
              subtitle: 'What ran this week, and your achievements',
              chevron: true,
              divider: false,
              onTap: () => _push(context, const YourHomePage()),
            ),
          ],
        ),
        const SizedBox(height: OmniSpace.sm),
        OmniDisclosure(
          key: const ValueKey('settings-more'),
          icon: OmniIcons.level,
          title: 'More settings',
          summary: 'Tags, saved values, energy, away lighting',
          children: [
            if (features.nfc)
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
              title: 'Saved values',
              subtitle:
                  'What automations remember, such as whether you are '
                  'away. To see, change or clear',
              subtitleLines: 2,
              chevron: true,
              onTap: () => _push(context, const VariablesPage()),
            ),
            const SmartHomeSettingsRows(),
            if (features.hubMode) const HomeRunsOnRow(),
            if (features.shake) const ShakeSceneRow(),
            if (features.usbBoards)
              OmniListRow(
                key: const ValueKey('settings-usb'),
                icon: OmniIcons.board,
                title: 'Plug in a board',
                subtitle:
                    'Set up a small board such as an ESP32 over a USB cable, '
                    'or put the OmniFlow program on it',
                subtitleLines: 2,
                chevron: true,
                onTap: () => showUsbBoardSheet(context),
              ),
            if (setupDone) const HomeSetupRow(),
            OmniDisclosure(
              key: const ValueKey('settings-for-developers'),
              icon: OmniIcons.developer,
              title: 'For developers',
              summary: 'Packets, run log, agents',
              children: [
                OmniListRow(
                  key: const ValueKey('settings-developer'),
                  icon: OmniIcons.developer,
                  title: 'Developer',
                  subtitle: 'Packets, run log, drivers, engine',
                  chevron: true,
                  onTap: () => shell.open(const DeveloperLink()),
                ),
                const AgentAccessRow(),
                if (!waitingInFront) waitingRow,
              ],
            ),
          ],
        ),
        SettingsGroup(
          children: [
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
        ),
      ],
    );
  }
}

/// A group of Settings rows on one rounded card.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => OmniCard(
    padding: const EdgeInsets.symmetric(
      horizontal: OmniSpace.md,
      vertical: OmniSpace.xs,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}
