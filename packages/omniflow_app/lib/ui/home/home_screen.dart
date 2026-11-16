import 'dart:async';

import 'package:flutter/material.dart';

import '../automations/sun_lighting_page.dart' show RoomFollowSunSwitch;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../../state/reload_home.dart';
import '../design/design.dart';
import '../devices/device_controls.dart';
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
import 'run_section.dart';
import 'suggestion_card.dart';
import 'tile_look.dart';
import 'home_hero.dart';
import 'home_notices.dart';
import 'home_presence.dart';
import 'energy_card.dart' show SmartHomeCards;
import '../help/screen_help.dart';
import '../onboarding/home_setup.dart' show openHomeSetup;

/// The things Home shows as tiles: not the phone, people or places.
List<DeviceView> tileDevices(List<Json> devices) => [
  for (final j in devices)
    if (j['driver'] != 'phone' && !presenceDrivers.contains(j['driver']))
      DeviceView(j),
];

/// Whether Home shows the first run or the empty home: the list loaded
/// and nothing in it is a tile.
bool homeIsEmpty(WidgetRef ref) => switch (ref.watch(devicesProvider).value) {
  final list? => tileDevices(list).isEmpty,
  null => false,
};

/// Whether Home is the first run (8.1), which stands alone.
bool homeShowsFirstRun(WidgetRef ref) =>
    homeIsEmpty(ref) && ref.watch(firstRunDoneProvider).value == false;

/// 1.1: the daily overview. A greeting, what is on, status chips, what to
/// run (scenes and manual automations), favourites, one tile grid per room,
/// and one row for every device that is offline. With nothing added it is
/// the first run (8.1) or the empty home (8.2).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final list = devices.value;
    if (list == null && devices.hasError) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: EngineSilent(onRetry: () => ref.invalidate(devicesProvider)),
          ),
        ),
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

class _Overview extends ConsumerWidget {
  const _Overview({required this.devices});

  /// Null while the list loads.
  final List<Json>? devices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = devices == null
        ? const <DeviceView>[]
        : [for (final j in devices!) DeviceView(j)];
    final tiles = devices == null ? null : tileDevices(devices!);
    final person = personOf(all);
    final presence = person == null ? null : Presence.of(person.json);
    final summaries = ref.watch(summariesProvider).value;
    final scenes = ref.watch(scenesProvider).value ?? const [];
    final rooms = ref.watch(roomsProvider).value ?? const [];
    final drivers = ref.watch(driversProvider).value ?? const {};
    final now = DateTime.now();
    final name = person?.name;
    final shown = watchPresence(ref, all);
    final status = [
      switch (shown) {
        PresenceShown.home => 'Home',
        PresenceShown.away => 'Away',
        _ => null,
      },
      if (ref.watch(houseModeProvider).value?.name case final mode?)
        '$mode mode',
    ].whereType<String>().join(' · ');
    final offline = tiles?.where((d) => !d.online).toList() ?? const [];
    final title = name == null ? greeting(now) : '${greeting(now)}, $name';
    return OmniTabPage(
      title: title,
      heroTitle: true,
      padded: false,
      actions: [
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
          label: 'What needs you',
          onPressed: () => showNeedsYou(context, ref),
        ),
        const ScreenHelpButton(HelpScreen.home),
      ],
      body: RefreshIndicator(
        onRefresh: () => reloadHome(ref),
        child: ListView(
          key: const ValueKey('home-list'),
          padding: EdgeInsets.fromLTRB(
            OmniSpace.screen,
            0,
            OmniSpace.screen,
            OmniInsets.fabClearance(context),
          ),
          children: [
            HomeHero(title: title, subtitle: status.isEmpty ? null : status),
            if (tiles == null)
              const _Loading()
            else ...[
              HomeNotices(devices: all),
              const HomeHelpers(),
              const SuggestionCard(),
              const SmartHomeCards(),
              _StatusChips(
                tiles: tiles,
                presence: shown == PresenceShown.notSetUp ? null : presence,
                person: person,
              ),
              RunSection(items: runItems(scenes, summaries)),
              ..._favourites(context, ref, tiles, drivers),
              for (final g in _roomGroups(
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
      if (favourites.isEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(2, 0, 2, OmniSpace.xs),
          child: Text(
            'Star a device on its page, or tap Edit, to keep it here.',
            style: OmniText.caption,
          ),
        )
      else
        TileGrid(devices: favourites, drivers: drivers),
    ];
  }

  static List<({String title, List<DeviceView> devices})> _roomGroups(
    List<DeviceView> tiles,
    List<Room> rooms,
  ) {
    final byRoom = <String?, List<DeviceView>>{};
    for (final d in tiles) {
      byRoom.putIfAbsent(d.roomId ?? d.room, () => []).add(d);
    }
    final out = <({String title, List<DeviceView> devices})>[];
    for (final r in rooms) {
      final ds = byRoom.remove(r.id);
      if (ds != null) {
        out.add((title: r.name, devices: ds..sort(byOrderThenName)));
      }
    }
    final none = byRoom.remove(null);
    for (final e in byRoom.entries) {
      out.add((
        title: e.value.first.room ?? e.key!,
        devices: e.value..sort(byOrderThenName),
      ));
    }
    if (none != null) {
      out.add((title: 'Not in a room', devices: none..sort(byOrderThenName)));
    }
    return out;
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    final columns = OmniWidth.of(context).tileColumns;
    return Column(
      children: [
        const SizedBox(height: OmniSpace.lg),
        for (var r = 0; r < 2; r++)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.gap),
            child: _Row([
              for (var c = 0; c < columns; c++) const OmniTileSkeleton(),
            ], columns: columns),
          ),
      ],
    );
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
          if (i > 0) const SizedBox(width: OmniSpace.gap),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final columns = OmniWidth.of(context).tileColumns;
    return Column(
      children: [
        for (var i = 0; i < devices.length; i += columns)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.gap),
            child: _Row([
              for (final d in devices.skip(i).take(columns))
                _tile(context, ref, d),
            ], columns: columns),
          ),
      ],
    );
  }
}

/// Every device that is offline, as one row at the bottom of Home rather
/// than a grid of grey tiles. It opens the device when there is one, and
/// Devices' Problems list when there are more.
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
              ? '${devices.length} offline'
              : '${one.name} offline',
          subtitle: one == null
              ? devices.map((d) => d.name).join(', ')
              : 'Tap to see what to try',
          dot: StatusKind.warning,
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

/// Where you are and what the TV plays. Each chip opens what it names.
/// Offline devices have their own row at the bottom.
class _StatusChips extends ConsumerWidget {
  const _StatusChips({
    required this.tiles,
    required this.presence,
    required this.person,
  });

  final List<DeviceView> tiles;
  final Presence? presence;
  final DeviceView? person;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = tiles.where(
      (d) => kindOf(d) == DeviceKind.tv && TvState.ofDevice(d.json).isOn,
    );
    final chips = <Widget>[
      if (presence?.home case final bool home)
        OmniStatusChip(
          key: const ValueKey('chip-presence'),
          label: home ? 'You are home' : 'You are away',
          dot: home ? StatusKind.online : StatusKind.offline,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const PlacesPage())),
        ),
      for (final tv in playing)
        OmniStatusChip(
          key: ValueKey('chip-tv-${tv.id}'),
          icon: OmniIcons.tv,
          label: switch (TvState.ofDevice(tv.json)) {
            TvState(app: final String app, playing: 'playing') =>
              '${appName(app)} playing',
            TvState(app: final String app) => '${appName(app)} on ${tv.name}',
            _ => '${tv.name} is on',
          },
          onTap: () => openDevice(context, tv.id),
        ),
    ];
    if (chips.isEmpty) return const SizedBox(height: OmniSpace.xs);
    return Wrap(
      spacing: OmniSpace.sm,
      runSpacing: OmniSpace.xs,
      children: chips,
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
          return OmniSheet(
            title: 'Favourites',
            subtitle: 'Starred devices show first on Home',
            children: [
              for (final d in live)
                OmniListRow(
                  key: ValueKey('favourite-${d.id}'),
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
        return OmniSheet(
          title: 'Needs you',
          children: [
            if (waiting.isEmpty && offline.isEmpty)
              const OmniEmptyState(
                icon: AreaIcons.ok,
                title: 'Nothing needs you',
                message:
                    'Every automation is running and every device answers.',
                padding: EdgeInsets.symmetric(vertical: 24),
              ),
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
                  shell.open(
                    a.needsApproval ? ReviewLink(a.id) : AutomationLink(a.id),
                  );
                },
              ),
            for (final d in offline)
              OmniListRow(
                key: ValueKey('needs-device-${d.id}'),
                icon: AreaIcons.offline,
                title: '${d.name} is offline',
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

/// One room's devices as rows, from Home's "All".
class RoomDevicesPage extends ConsumerWidget {
  const RoomDevicesPage({super.key, required this.title, required this.ids});

  final String title;
  final List<String> ids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers = ref.watch(driversProvider).value ?? const {};
    final devices = [
      for (final j in ref.watch(devicesProvider).value ?? const <Json>[])
        if (ids.contains(j['id'])) DeviceView(j),
    ]..sort(byOrderThenName);
    return OmniPage(
      title: title,
      body: ListView(
        children: [
          for (final d in devices)
            OmniListRow(
              key: ValueKey('room-row-${d.id}'),
              icon: iconOf(d, drivers),
              title: d.name,
              subtitle: rowSubtitle(
                d,
                shortDriverName(drivers[d.driver], d.driver),
              ),
              dot: statusOf(d),
              onTap: () => openDevice(context, d.id),
              onLongPress: () => showQuickSheet(context, d.id),
            ),
          RoomFollowSunSwitch(ids: ids),
        ],
      ),
    );
  }
}
