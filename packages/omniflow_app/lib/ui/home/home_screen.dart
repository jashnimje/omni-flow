import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../../state/reload_home.dart';
import '../automations/scenes.dart' show openScenes, runScene, sceneIconFor;
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
import 'quick_sheet.dart';

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

/// 1.1: the daily overview. A greeting, what is on, status chips, scenes,
/// favourites and one tile grid per room. With nothing added it is the
/// first run (8.1) or the empty home (8.2).
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
    // An offline device's last state is not "on" now.
    final on = tiles?.where((d) => d.online && isLit(d)).length;
    final active = summaries
        ?.where((a) => a.enabled && a.approved && !a.isScene)
        .length;
    final status = [
      switch (presence?.home) {
        true => 'Home',
        false => 'Away',
        null => null,
      },
      if (on != null) '$on on',
      if (active != null) '$active automation${active == 1 ? '' : 's'} active',
    ].whereType<String>().join(' · ');
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () => reloadHome(ref),
          child: ListView(
            key: const ValueKey('home-list'),
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 96),
            children: [
              OmniScreenTitle(
                name == null ? greeting(now) : '${greeting(now)}, $name',
                subtitle: status.isEmpty ? null : status,
                actions: [
                  OmniIconAction(
                    key: const ValueKey('open-search'),
                    icon: OmniIcons.search,
                    label: 'Search and commands',
                    onPressed: () => ref
                        .read(shellControllerProvider)
                        .open(const SearchLink()),
                  ),
                  OmniIconAction(
                    key: const ValueKey('open-alerts'),
                    icon: OmniIcons.notifications,
                    label: 'What needs you',
                    onPressed: () => showNeedsYou(context, ref),
                  ),
                ],
              ),
              if (tiles == null)
                const _Loading()
              else ...[
                _StatusChips(tiles: tiles, presence: presence, person: person),
                if (scenes.isNotEmpty) ...[
                  OmniSectionHeader(
                    'Scenes',
                    actionLabel: 'Edit',
                    onAction: () => openScenes(context),
                  ),
                  _SceneRow(scenes: scenes),
                ],
                ..._favourites(context, ref, tiles, drivers),
                for (final g in _roomGroups(tiles, rooms)) ...[
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
              ],
            ],
          ),
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
          padding: EdgeInsets.fromLTRB(2, 0, 2, 4),
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
  Widget build(BuildContext context) => const Column(
    children: [
      SizedBox(height: OmniSpace.lg),
      _Pair(OmniTileSkeleton(), OmniTileSkeleton()),
      SizedBox(height: OmniSpace.gap),
      _Pair(OmniTileSkeleton(), OmniTileSkeleton()),
    ],
  );
}

class _Pair extends StatelessWidget {
  const _Pair(this.left, [this.right]);

  final Widget left;
  final Widget? right;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: left),
        const SizedBox(width: OmniSpace.gap),
        Expanded(child: right ?? const SizedBox()),
      ],
    ),
  );
}

/// Two tiles a row. A tap switches a device with power on or off, or
/// opens one without. A long press opens the quick sheet.
class TileGrid extends ConsumerWidget {
  const TileGrid({super.key, required this.devices, required this.drivers});

  final List<DeviceView> devices;
  final Map<String, Json> drivers;

  Widget _tile(BuildContext context, WidgetRef ref, DeviceView d) {
    final toggles = d.hasPower && d.online;
    final lit = isLit(d);
    return OmniTile(
      key: ValueKey('tile-${d.id}'),
      icon: iconOf(d, drivers),
      name: d.name,
      state: stateLine(d),
      on: lit,
      offline: !d.online,
      level: tileLevel(d),
      tapHint: toggles ? (lit ? 'Turns it off' : 'Turns it on') : 'Opens it',
      onTap: () => toggles ? togglePower(ref, d) : openDevice(context, d.id),
      onLongPress: () => showQuickSheet(context, d.id),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    children: [
      for (var i = 0; i < devices.length; i += 2)
        Padding(
          padding: const EdgeInsets.only(bottom: OmniSpace.gap),
          child: _Pair(
            _tile(context, ref, devices[i]),
            i + 1 < devices.length ? _tile(context, ref, devices[i + 1]) : null,
          ),
        ),
    ],
  );
}

/// Where you are, what the TV plays, and what is offline. Each chip opens
/// what it names.
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
    final offline = tiles.where((d) => !d.online).toList();
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
      if (offline.length == 1)
        OmniStatusChip(
          key: const ValueKey('chip-offline'),
          label: '${offline.single.name} offline',
          dot: StatusKind.warning,
          onTap: () => openDevice(context, offline.single.id),
        )
      else if (offline.length > 1)
        OmniStatusChip(
          key: const ValueKey('chip-offline'),
          label: '${offline.length} devices offline',
          dot: StatusKind.warning,
          onTap: () {
            ref.read(devicesViewProvider.notifier).show(DevicesView.problems);
            ref.read(shellControllerProvider).select(ShellTab.devices);
          },
        ),
    ];
    if (chips.isEmpty) return const SizedBox(height: OmniSpace.xs);
    return Wrap(spacing: 6, children: chips);
  }
}

class _SceneRow extends ConsumerWidget {
  const _SceneRow({required this.scenes});

  final List<Scene> scenes;

  Widget _button(BuildContext context, WidgetRef ref, Scene s) {
    final radius = BorderRadius.circular(OmniRadii.button);
    return Semantics(
      button: true,
      label: 'Run ${s.name}',
      excludeSemantics: true,
      onTap: () => _run(ref, s),
      child: Material(
        key: ValueKey('scene-${s.id}'),
        color: OmniColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: const BorderSide(color: OmniColors.line),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: () => _run(ref, s),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.all(OmniSpace.gap),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(sceneIconFor(s.icon), size: 22, color: OmniColors.text),
                  const SizedBox(height: 2),
                  Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: OmniColors.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _run(WidgetRef ref, Scene s) async {
    if (s.id case final id?) await runScene(ref, id, s.name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (scenes.length <= 4) {
      return Row(
        children: [
          for (var i = 0; i < scenes.length; i++) ...[
            if (i > 0) const SizedBox(width: OmniSpace.sm),
            Expanded(child: _button(context, ref, scenes[i])),
          ],
          for (var i = scenes.length; i < 4; i++) ...[
            const SizedBox(width: OmniSpace.sm),
            const Expanded(child: SizedBox()),
          ],
        ],
      );
    }
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: scenes.length,
        separatorBuilder: (_, _) => const SizedBox(width: OmniSpace.sm),
        itemBuilder: (_, i) =>
            SizedBox(width: 82, child: _button(context, ref, scenes[i])),
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
        ],
      ),
    );
  }
}
