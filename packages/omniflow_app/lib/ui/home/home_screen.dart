import 'dart:async';

import 'package:flutter/material.dart';

import '../automations/sun_lighting_page.dart' show RoomFollowSunSwitch;
import '../automations/test_run.dart' show RunPage;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/clock.dart';
import '../../state/device_features.dart';
import '../../state/providers.dart';
import '../../state/house.dart' show houseInViewProvider;
import '../../state/reload_home.dart';
import '../design/design.dart';
import '../devices/device_controls.dart';
import '../devices/device_sections.dart' show askRoomName;
import '../../api/house_calls.dart' show RoomLights;
import '../../state/house_providers.dart'
    show houseApiProvider, roomLightsProvider;
import '../devices/device_text.dart';
import '../devices/devices_screen.dart';
import '../devices/open_device.dart';
import '../settings/places_page.dart';
import '../shell/shell.dart';
import 'empty_home.dart';
import 'first_run.dart';
import 'home_data.dart';
import 'home_helpers.dart';
import 'quick_sheet.dart';
import 'room_tile.dart' show RoomTileRow;
import 'timer_strip.dart' show TimerStrip;
import 'run_section.dart';
import 'home_activity.dart';
import 'tile_look.dart';
import 'home_hero.dart';
import 'home_notices.dart';
import 'mode_picker.dart' show ModeChip;
import 'home_presence.dart';
import 'energy_card.dart' show HomeEnergySection;
import '../add/add_page.dart' show openAddThing;
import '../devices/weather_page.dart' show WeatherCard;
import '../help/screen_help.dart';
import '../onboarding/home_setup.dart' show openHomeSetup;

/// The things Home shows as tiles: everything Devices lists, the phone
/// too, so a phone with no room is under "Not in a room" on both. People
/// and places live in Settings, Places and people.
List<DeviceView> tileDevices(List<Json> devices) => listedDevices(devices);

/// Whether Home shows the first run or the empty home: the list loaded
/// and nothing in it is a tile but this phone, which is always there.
bool homeIsEmpty(WidgetRef ref) => switch (ref.watch(devicesProvider).value) {
  final list? => tileDevices(list).every((d) => d.driver == 'phone'),
  null => false,
};

/// Whether Home is the first run (8.1), which stands alone. It asks for
/// what the background service needs, so a device without one skips it.
bool homeShowsFirstRun(WidgetRef ref) =>
    ref.watch(deviceFeaturesProvider).backgroundService &&
    homeIsEmpty(ref) &&
    ref.watch(firstRunDoneProvider).value == false;

/// 1.1: the daily overview. In front: the greeting, the mode and presence
/// chips, at most one notice, favourites, scenes, one tile grid per room
/// and one row for every device that is offline. Behind collapsed
/// sections at the end: Activity, Energy and Ideas for you. With nothing
/// added it is the first run (8.1) or the empty home (8.2).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final list = devices.value;
    if (list == null && devices.hasError) {
      return TabPage(
        title: 'Home',
        actions: _homeActions(context, ref),
        state: OmniLoad.error(
          engineSilent,
          () => ref.invalidate(devicesProvider),
        ),
        children: (_) => const [],
      );
    }
    if (homeIsEmpty(ref)) {
      if (homeShowsFirstRun(ref)) {
        return FirstRunScreen(
          onDone: () async {
            await ref.read(firstRunStoreProvider).markDone();
            ref.invalidate(firstRunDoneProvider);
            if (context.mounted) unawaited(openHomeSetup(context));
          },
        );
      }
      return const EmptyHome();
    }
    return _Overview(devices: list);
  }
}

/// Home's header actions: search, what needs you, help and Add (the +,
/// so nothing floats over the tiles). They stay on the error state too.
/// From [largeTextScale] Help and Add move into a More menu, so the
/// greeting keeps the room to wrap and the bell's count stays clear.
List<Widget> _homeActions(BuildContext context, WidgetRef ref) {
  final n = needsYouCount(ref);
  final large =
      MediaQuery.textScalerOf(context).scale(16) / 16 >= largeTextScale;
  return [
    OmniIconAction(
      key: const ValueKey('open-search'),
      icon: OmniIcons.search,
      label: 'Search and commands',
      onPressed: () =>
          ref.read(shellControllerProvider).open(const SearchLink()),
    ),
    OmniIconAction(
      key: const ValueKey('open-alerts'),
      icon: OmniIcons.notifications,
      label: n == 0 ? 'What needs you' : 'What needs you, $n',
      badge: n,
      onPressed: () => showNeedsYou(context, ref),
    ),
    if (large)
      PopupMenuButton<_HomeMore>(
        key: const ValueKey('home-more'),
        tooltip: 'More',
        icon: Icon(OmniIcons.more, color: OmniPalette.of(context).muted),
        onSelected: (choice) => switch (choice) {
          _HomeMore.help => showScreenHelp(context, HelpScreen.home),
          _HomeMore.add => openAddThing(context),
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            key: ValueKey('home-more-help'),
            value: _HomeMore.help,
            child: Text('Help'),
          ),
          PopupMenuItem(
            key: ValueKey('home-more-add'),
            value: _HomeMore.add,
            child: Text('Add a device'),
          ),
        ],
      )
    else ...[
      const ScreenHelpButton(HelpScreen.home),
      OmniIconAction(
        key: const ValueKey('add-device'),
        icon: OmniIcons.add,
        label: 'Add a device',
        onPressed: () => openAddThing(context),
      ),
    ],
  ];
}

enum _HomeMore { help, add }

/// From this text size Home's top bar keeps only search and the bell, and
/// the rest is under More.
const largeTextScale = 1.3;

class _Overview extends ConsumerStatefulWidget {
  const _Overview({required this.devices});

  /// Null while the list loads.
  final List<Json>? devices;

  @override
  ConsumerState<_Overview> createState() => _OverviewState();
}

class _OverviewState extends ConsumerState<_Overview> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Another house is another Home, so it opens at its top.
    ref.listen(houseInViewProvider.select((h) => h.value), (before, after) {
      if (before != after && _scroll.hasClients) _scroll.jumpTo(0);
    });
    final devices = widget.devices;
    final all = devices == null
        ? const <DeviceView>[]
        : [for (final j in devices) DeviceView(j)];
    final tiles = devices == null ? null : tileDevices(devices);
    final person = personOf(all);
    final presence = person == null ? null : Presence.of(person.json);
    final summaries = ref.watch(summariesProvider).value;
    final scenesRead = ref.watch(scenesProvider);
    final scenes = scenesRead.value ?? const [];
    final rooms = ref.watch(roomsProvider).value ?? const [];
    final drivers = ref.watch(driversProvider).value ?? const {};
    final now = DateTime.now();
    final name = person?.name;
    final shown = watchPresence(ref, all);
    final offline = tiles?.where((d) => !d.online).toList() ?? const [];
    final title = name == null ? greeting(now) : '${greeting(now)}, $name';
    return TabPage.custom(
      title: title,
      heroTitle: true,
      actions: _homeActions(context, ref),
      // The hero stays over the tile skeleton while the list loads, so
      // the body draws its own loading shape.
      body: (context, padding) => RefreshIndicator(
        onRefresh: () => reloadHome(ref),
        child: ListView(
          key: const ValueKey('home-list'),
          controller: _scroll,
          padding: padding,
          children: [
            HomeHero(title: title),
            if (tiles == null) ...[
              const SizedBox(height: OmniSpace.lg),
              OmniTileGridSkeleton(
                count: OmniWidth.of(context).tileColumns * 2,
                columns: OmniWidth.of(context).tileColumns,
              ),
            ] else ...[
              HomeNotices(devices: all),
              _StatusChips(
                presence: shown == PresenceShown.notSetUp ? null : presence,
                person: person,
                // Not set up at all has its own notice above. This is a
                // house the engine cannot place the person in.
                notSetUp:
                    person != null &&
                    shown != PresenceShown.notSetUp &&
                    presence?.home == null,
              ),
              const TimerStrip(),
              const WeatherCard(),
              ..._favourites(context, ref, tiles, drivers),
              RunSection(
                items: runItems(scenes, summaries),
                loading: !scenesRead.hasValue && !scenesRead.hasError,
              ),
              const RoomTileRow(),
              for (final g in roomGroups(
                tiles.where((d) => d.online).toList(),
                rooms,
              )) ...[
                OmniSectionHeader(
                  g.title,
                  actionLabel: 'All',
                  onAction: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RoomDevicesPage(
                        title: g.title,
                        ids: [for (final d in g.devices) d.id],
                      ),
                    ),
                  ),
                ),
                TileGrid(devices: g.devices, drivers: drivers),
              ],
              if (offline.isNotEmpty) OfflineRow(devices: offline),
              const SizedBox(height: OmniSpace.lg),
              HomeActivitySection(devices: tiles),
              const HomeEnergySection(),
              const HomeIdeasSection(),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _favourites(
    BuildContext context,
    WidgetRef ref,
    List<DeviceView> tiles,
    Map<String, Json> drivers,
  ) {
    final favourites = tiles.where((d) => d.favourite).toList()
      ..sort(byOrderThenName);
    return [
      OmniSectionHeader(
        'Favourites',
        actionLabel: 'Edit',
        onAction: () => showFavourites(context, tiles),
      ),
      // With none starred the header and its Edit stay, so the way to add
      // one is still there, and no hint sits in front.
      if (favourites.isNotEmpty)
        TileGrid(devices: favourites, drivers: drivers),
    ];
  }
}

/// One row of equal height tiles, [columns] wide, the last row padded out
/// so its tiles keep the same width.
class _Row extends StatelessWidget {
  const _Row(this.children, {required this.columns});

  final List<Widget> children;
  final int columns;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < columns; i++) ...[
          if (i > 0) const SizedBox(width: OmniSpace.md),
          Expanded(child: i < children.length ? children[i] : const SizedBox()),
        ],
      ],
    ),
  );
}

/// The tiles of a room, as many a row as the screen is wide (two on a
/// phone, three on a foldable, four on a tablet). Tapping a tile opens
/// its device, growing out of the tile. Tapping its icon switches a
/// device with power, or wakes and sleeps a TV. A long press opens the
/// quick sheet.
class TileGrid extends ConsumerWidget {
  const TileGrid({super.key, required this.devices, required this.drivers});

  final List<DeviceView> devices;
  final Map<String, Json> drivers;

  Widget _tile(BuildContext context, WidgetRef ref, DeviceView d) {
    final tv = kindOf(d) == DeviceKind.tv;
    final toggles = d.online && hasMainPower(d);
    final lit = tv ? isLit(d) : toggles && shownOn(ref, d);
    return Builder(
      builder: (tileContext) => OmniTile(
        key: ValueKey('tile-${d.id}'),
        iconKey: ValueKey('tile-power-${d.id}'),
        icon: iconOf(d, drivers),
        name: d.name,
        reading: tileReading(d),
        state: tileState(d),
        on: lit,
        offline: !d.online,
        pending: powerPending(ref, d),
        level: tileLevel(d),
        tint: tileTint(d),
        tapHint: 'Opens it',
        iconLabel: toggles ? '${lit ? 'Turn off' : 'Turn on'} ${d.name}' : null,
        onIconTap: toggles
            ? () => tv ? toggleTv(ref, d) : togglePower(ref, d)
            : null,
        onTap: () => openDevice(context, d.id, source: tileContext),
        onLongPress: () => showQuickSheet(context, d.id),
      ),
    );
  }

  /// From this text size Home's tiles stack in one column, so names and
  /// readings are never cut.
  static const oneColumnFrom = 1.3;

  /// How many tiles a row holds here.
  static int columnsOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(16) / 16 > oneColumnFrom
      ? 1
      : OmniWidth.of(context).tileColumns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final columns = columnsOf(context);
    return Column(
      children: [
        for (var i = 0; i < devices.length; i += columns)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.md),
            child: _Row([
              for (final d in devices.skip(i).take(columns))
                _tile(context, ref, d),
            ], columns: columns),
          ),
      ],
    );
  }
}

/// Every device that is not answering, as one row at the bottom of Home
/// rather than a grid of grey tiles. It opens the device when there is
/// one, and Devices' Needs a look list when there are more.
class OfflineRow extends ConsumerWidget {
  const OfflineRow({super.key, required this.devices});

  final List<DeviceView> devices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final one = devices.length == 1 ? devices.single : null;
    return Padding(
      padding: const EdgeInsets.only(top: OmniSpace.sm),
      child: OmniCard(
        key: const ValueKey('home-offline'),
        padding: EdgeInsets.zero,
        child: OmniListRow(
          icon: AreaIcons.offline,
          title: one == null
              ? '${devices.length} not answering'
              : '${one.name} is not answering',
          subtitle: one == null
              ? devices.map((d) => d.name).join(', ')
              : 'Tap to see what to try',
          dot: StatusKind.offline,
          chevron: true,
          divider: false,
          onTap: () {
            if (one != null) {
              openDevice(context, one.id);
              return;
            }
            ref.read(devicesViewProvider.notifier).show(DevicesView.problems);
            ref.read(shellControllerProvider).select(ShellTab.devices);
          },
        ),
      ),
    );
  }
}

/// The house mode and where you are. Each chip opens what it names.
/// Offline devices have their own row at the bottom.
class _StatusChips extends ConsumerWidget {
  const _StatusChips({
    required this.presence,
    required this.person,
    this.notSetUp = false,
  });

  final Presence? presence;
  final DeviceView? person;

  /// Nothing can tell where the person is, so the chip says so.
  final bool notSetUp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chips = <Widget>[
      if (ref.watch(houseModeProvider).value != null) const ModeChip(),
      if (presence?.home case final bool home)
        OmniStatusChip(
          key: const ValueKey('chip-presence'),
          label: home ? 'You are home' : 'You are away',
          dot: home ? StatusKind.online : StatusKind.offline,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const PlacesPage())),
        )
      else if (notSetUp)
        OmniStatusChip(
          key: const ValueKey('chip-presence'),
          label: presenceNotSetUp,
          dot: StatusKind.warning,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const PlacesPage())),
        ),
    ];
    if (chips.isEmpty) return const SizedBox(height: OmniSpace.xs);
    return Padding(
      padding: const EdgeInsets.only(bottom: OmniSpace.sm),
      child: Wrap(
        spacing: OmniSpace.sm,
        runSpacing: OmniSpace.xs,
        children: chips,
      ),
    );
  }
}

/// Every Home device with a star to keep it in Favourites.
Future<void> showFavourites(BuildContext context, List<DeviceView> tiles) =>
    showOmniSheet<void>(
      context,
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final live = tileDevices(ref.watch(devicesProvider).value ?? const [])
            ..sort(byOrderThenName);
          final drivers = ref.watch(driversProvider).value ?? const {};
          return SheetTemplate(
            title: 'Favourites',
            subtitle: 'Starred devices show first on Home',
            children: (context) => [
              for (final d in live)
                OmniListRow(
                  key: ValueKey('favourite-${d.id}'),
                  icon: iconOf(d, drivers),
                  title: d.name,
                  subtitle: d.room,
                  trailing: OmniIconAction(
                    icon: OmniIcons.star,
                    label: d.favourite
                        ? 'Remove ${d.name} from favourites'
                        : 'Add ${d.name} to favourites',
                    selected: d.favourite,
                    onPressed: () async {
                      final done = await ref
                          .read(engineApiProvider)
                          .organizeDevice(d.id, favourite: !d.favourite);
                      if (done.ok) {
                        await ref.read(devicesProvider.notifier).refresh();
                      }
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );

/// How many things the bell lists: automations waiting or failing, and
/// devices that stopped answering.
int needsYouCount(WidgetRef ref) {
  final waiting = [
    for (final a in ref.watch(summariesProvider).value ?? const [])
      if (a.needsApproval || (a.enabled && a.lastRun?.ok == false)) a,
  ];
  final offline = tileDevices(ref.watch(devicesProvider).value ?? const [])
      .where((d) => !d.online);
  return waiting.length + offline.length;
}

/// The bell: automations waiting for review or failing, and devices that
/// stopped answering.
Future<void> showNeedsYou(BuildContext context, WidgetRef ref) {
  final shell = ref.read(shellControllerProvider);
  return showOmniSheet<void>(
    context,
    builder: (sheet) => Consumer(
      builder: (context, ref, _) {
        final waiting = [
          for (final a in ref.watch(summariesProvider).value ?? const [])
            if (a.needsApproval || (a.enabled && a.lastRun?.ok == false)) a,
        ];
        final offline = tileDevices(
          ref.watch(devicesProvider).value ?? const [],
        ).where((d) => !d.online).toList();
        return SheetTemplate(
          title: 'Needs you',
          state: waiting.isEmpty && offline.isEmpty
              ? const OmniLoad.empty()
              : const OmniLoad.data(),
          empty: const OmniEmptyState(
            icon: AreaIcons.ok,
            title: 'Nothing needs you',
            message: 'Every automation is running and every device answers.',
            padding: EdgeInsets.symmetric(vertical: OmniSpace.xl),
          ),
          children: (context) => [
            for (final a in waiting)
              OmniListRow(
                key: ValueKey('needs-${a.id}'),
                icon: OmniIcons.automations,
                title: a.name,
                subtitle: a.needsApproval
                    ? 'Waiting for you to review it'
                    : 'Last run failed${a.lastRun?.error == null ? '' : ': ${a.lastRun!.error}'}',
                chevron: true,
                onTap: () {
                  Navigator.of(sheet).pop();
                  // A failed run opens what failed, here on Home, with
                  // Run it again. A review still goes to Automations.
                  if (!a.needsApproval && a.lastRun?.run != null) {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => RunPage(
                          automationId: a.id,
                          runId: a.lastRun!.run,
                          name: a.name,
                        ),
                      ),
                    );
                    return;
                  }
                  shell.open(switch (a) {
                    _ when a.needsApproval => ReviewLink(a.id),
                    AutomationSummary(lastRun: LastRun(run: final String r)) =>
                      RunLink(a.id, r),
                    _ => AutomationLink(a.id),
                  });
                },
              ),
            for (final d in offline)
              OmniListRow(
                key: ValueKey('needs-device-${d.id}'),
                icon: AreaIcons.offline,
                title: '${d.name} is not answering',
                subtitle: 'Tap to see what to try',
                chevron: true,
                onTap: () {
                  Navigator.of(sheet).pop();
                  openDevice(context, d.id);
                },
              ),
          ],
        );
      },
    ),
  );
}

/// One room's devices as rows, from Home's "All" and a room tile: rename
/// in the header, the devices, then the room's lights (all on or off, and
/// Follow the sun).
class RoomDevicesPage extends ConsumerWidget {
  const RoomDevicesPage({super.key, required this.title, required this.ids});

  final String title;
  final List<String> ids;

  Future<void> _rename(BuildContext context, WidgetRef ref, Room room) async {
    final name = await askRoomName(context, initial: room.name);
    if (name == null || name == room.name) return;
    final saved = await ref
        .read(engineApiProvider)
        .saveRoom(id: room.id, name: name, order: room.order);
    if (!saved.ok) return;
    ref.invalidate(roomsProvider);
    await ref.read(devicesProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers = ref.watch(driversProvider).value ?? const {};
    final devices = [
      for (final j in ref.watch(devicesProvider).value ?? const <Json>[])
        if (ids.contains(j['id'])) DeviceView(j),
    ]..sort(byOrderThenName);
    final read = ref.watch(devicesProvider);
    // The room these devices share, when they share one.
    final roomIds = devices.map((d) => d.roomId).whereType<String>().toSet();
    final room = roomIds.length == 1
        ? (ref.watch(roomsProvider).value ?? const <Room>[])
              .where((r) => r.id == roomIds.single)
              .firstOrNull
        : null;
    final lights = room == null
        ? null
        : (ref.watch(roomLightsProvider).value ?? const <RoomLights>[])
              .where((l) => l.id == room.id && l.lights > l.offline)
              .firstOrNull;
    return ListPage(
      title: room?.name ?? title,
      actions: [
        if (room != null)
          OmniIconAction(
            key: const ValueKey('room-rename'),
            icon: OmniIcons.edit,
            label: 'Rename ${room.name}',
            onPressed: () => _rename(context, ref, room),
          ),
      ],
      state: OmniLoad.of(
        read,
        error: 'The devices did not load.',
        onRetry: () => ref.invalidate(devicesProvider),
      ),
      children: (context) => [
        if (devices.isEmpty)
          const OmniEmptyState(
            key: ValueKey('room-empty'),
            icon: OmniIcons.room,
            title: 'No devices in this room',
            compact: true,
          )
        else
          OmniSectionHeader('Devices', trailingText: '${devices.length}'),
        for (final d in devices)
          OmniListRow(
            key: ValueKey('room-row-${d.id}'),
            icon: iconOf(d, drivers),
            title: d.name,
            subtitle: rowSubtitle(
              d,
              shortDriverName(drivers[d.driver], d.driver),
              hour12: ref.watch(hour12Provider),
            ),
            dot: statusOf(d),
            onTap: () => openDevice(context, d.id),
            onLongPress: () => showQuickSheet(context, d.id),
          ),
        if (lights != null) ...[
          const OmniSectionHeader('Lights'),
          OmniListRow(
            key: ValueKey('room-lights-${lights.id}'),
            icon: OmniIcons.light,
            title: lights.anyOn ? 'Turn all lights off' : 'Turn all lights on',
            subtitle: lights.summary,
            onTap: () async {
              final r = await ref.read(houseApiProvider).roomLights(
                lights.id,
                'power',
                {'value': !lights.anyOn},
              );
              if (r['ok'] != true) showMessage(errorMessage(r));
              await ref.read(roomLightsProvider.notifier).refresh();
            },
          ),
          RoomFollowSunSwitch(ids: ids),
        ],
      ],
    );
  }
}
