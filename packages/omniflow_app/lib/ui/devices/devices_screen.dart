import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../add/add_page.dart';
import '../design/design.dart';
import '../home/home_data.dart';
import '../shell/shell.dart';
import 'device_text.dart';
import 'open_device.dart';

enum DevicesView { byRoom, byType, problems }

/// Which way Devices groups its list. Home's problem chip opens it on
/// Problems.
class DevicesViewNotifier extends Notifier<DevicesView> {
  @override
  DevicesView build() => DevicesView.byRoom;

  void show(DevicesView view) => state = view;
}

final devicesViewProvider = NotifierProvider<DevicesViewNotifier, DevicesView>(
  DevicesViewNotifier.new,
);

/// Whether a device needs the user: offline, or waiting to be paired.
StatusKind? statusOf(DeviceView d) {
  if (!d.online) return StatusKind.problem;
  if (d.json['paired'] == false) return StatusKind.warning;
  if (d.json.containsKey('online')) return StatusKind.online;
  return null;
}

bool hasProblem(DeviceView d) {
  final s = statusOf(d);
  return s == StatusKind.problem || s == StatusKind.warning;
}

/// The things Devices lists: everything except people and places, which
/// live in Settings, Places and people.
List<DeviceView> listedDevices(List<Json> devices) => [
  for (final j in devices)
    if (!presenceDrivers.contains(j['driver'])) DeviceView(j),
];

/// The type group a device is listed under in By type.
String typeGroup(DeviceView d, Map<String, Json> drivers) {
  switch (kindOf(d)) {
    case DeviceKind.tv:
      return 'TVs';
    case DeviceKind.tag:
      return 'Tags';
    case DeviceKind.board:
      return 'Boards';
    case DeviceKind.phone:
      return 'Phones';
    case DeviceKind.sensor:
      return 'Sensors';
    case DeviceKind.person || DeviceKind.place:
      return 'People and places';
    case DeviceKind.simple:
      return switch (drivers[d.driver]?['category']) {
        'lighting' => 'Lights',
        'power' => 'Plugs and switches',
        'computer' => 'Computers',
        'media' => 'TVs',
        'zigbee' => 'Zigbee',
        _ =>
          d.capabilityOf('level') != null ||
                  d.capabilityOf('color_temp') != null
              ? 'Lights'
              : d.hasPower
              ? 'Plugs and switches'
              : 'Other',
      };
  }
}

/// The user's order first, then by name.
int byOrderThenName(DeviceView a, DeviceView b) {
  const last = 1 << 20;
  final order = (a.order ?? last).compareTo(b.order ?? last);
  return order != 0
      ? order
      : a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// Devices grouped into named sections, rooms in their order.
List<({String title, List<DeviceView> devices})> groupDevices(
  List<DeviceView> devices,
  DevicesView view,
  List<Room> rooms,
  Map<String, Json> drivers,
) {
  final groups = <String, List<DeviceView>>{};
  switch (view) {
    case DevicesView.byRoom:
      for (final r in rooms) {
        groups[r.name] = [];
      }
      for (final d in devices) {
        groups.putIfAbsent(d.room ?? 'Not in a room', () => []).add(d);
      }
      final none = groups.remove('Not in a room');
      if (none != null) groups['Not in a room'] = none;
    case DevicesView.byType:
      for (final d in devices) {
        groups.putIfAbsent(typeGroup(d, drivers), () => []).add(d);
      }
    case DevicesView.problems:
      final problems = devices.where(hasProblem).toList();
      if (problems.isNotEmpty) groups['Needs a look'] = problems;
  }
  return [
    for (final e in groups.entries)
      if (e.value.isNotEmpty)
        (title: e.key, devices: e.value..sort(byOrderThenName)),
  ];
}

/// 3.1: every thing, by room, by type or only the ones with a problem,
/// each opening its page.
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(devicesViewProvider);
    final devices = ref.watch(devicesProvider);
    final drivers = ref.watch(driversProvider).value ?? const {};
    final rooms = ref.watch(roomsProvider).value ?? const [];
    final listed = devices.value == null ? null : listedDevices(devices.value!);
    final problems = listed?.where(hasProblem).length ?? 0;
    return OmniTabPage(
      title: 'Devices',
      actions: [
        OmniIconAction(
          key: const ValueKey('devices-search'),
          icon: OmniIcons.search,
          label: 'Search and commands',
          onPressed: () =>
              ref.read(shellControllerProvider).open(const SearchLink()),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OmniSegmented<DevicesView>(
            key: const ValueKey('devices-view'),
            segments: [
              const OmniSegment(DevicesView.byRoom, 'By room'),
              const OmniSegment(DevicesView.byType, 'By type'),
              OmniSegment(
                DevicesView.problems,
                'Problems',
                count: problems == 0 ? null : problems,
              ),
            ],
            selected: view,
            onChanged: ref.read(devicesViewProvider.notifier).show,
          ),
          Expanded(
            child: switch ((devices, listed)) {
              (_, final list?) => _DeviceList(
                devices: list,
                view: view,
                rooms: rooms,
                drivers: drivers,
              ),
              (AsyncError(), _) => EngineSilent(
                onRetry: () => ref.invalidate(devicesProvider),
              ),
              _ => const _ListSkeleton(),
            },
          ),
        ],
      ),
    );
  }
}

class _DeviceList extends ConsumerWidget {
  const _DeviceList({
    required this.devices,
    required this.view,
    required this.rooms,
    required this.drivers,
  });

  final List<DeviceView> devices;
  final DevicesView view;
  final List<Room> rooms;
  final Map<String, Json> drivers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (devices.isEmpty) {
      return OmniEmptyState(
        icon: OmniIcons.devices,
        title: 'No devices yet',
        message: 'Add a light, a plug, a TV or a board to see it here.',
        action: OmniButton(
          key: const ValueKey('devices-add-empty'),
          label: 'Add something',
          icon: OmniIcons.add,
          expand: false,
          onPressed: () => openAddThing(context),
        ),
      );
    }
    final groups = groupDevices(devices, view, rooms, drivers);
    if (groups.isEmpty) {
      return const OmniEmptyState(
        icon: AreaIcons.ok,
        title: 'Nothing needs a look',
        message: 'Every device is answering.',
      );
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(devicesProvider.notifier).refresh(),
      child: ListView(
        key: const ValueKey('devices-list'),
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          for (final g in groups) ...[
            OmniSectionHeader(g.title, trailingText: '${g.devices.length}'),
            for (final d in g.devices)
              OmniListRow(
                key: ValueKey('device-row-${d.id}'),
                icon: iconOf(d, drivers),
                title: d.name,
                subtitle: rowSubtitle(
                  d,
                  shortDriverName(drivers[d.driver], d.driver),
                ),
                dot: statusOf(d),
                onTap: () => openDevice(context, d.id),
              ),
          ],
        ],
      ),
    );
  }
}

/// The engine did not answer the device list. Home shows it too.
class EngineSilent extends StatelessWidget {
  const EngineSilent({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => OmniEmptyState(
    icon: AreaIcons.offline,
    title: 'OmniFlow is not answering',
    message:
        'The part of the app that talks to your devices stopped. Try '
        'again, or restart the app if it keeps happening.',
    action: OmniButton(
      key: const ValueKey('engine-retry'),
      label: 'Try again',
      icon: OmniIcons.retry,
      expand: false,
      onPressed: onRetry,
    ),
  );
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading devices',
    child: Column(
      children: [
        for (var i = 0; i < 5; i++)
          Container(
            height: 52,
            margin: const EdgeInsets.only(bottom: OmniSpace.sm),
            decoration: BoxDecoration(
              color: OmniColors.card,
              borderRadius: BorderRadius.circular(OmniRadii.card),
            ),
          ),
      ],
    ),
  );
}
