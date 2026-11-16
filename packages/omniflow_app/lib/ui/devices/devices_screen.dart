import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../add/add_page.dart';
import '../design/design.dart';
import '../home/home_data.dart';
import '../help/screen_help.dart';
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

/// The groups of By type, in the order they show.
const typeGroups = [
  'Lights',
  'Plugs',
  'TVs',
  'Sensors',
  'Boards',
  'Computers',
  'Other',
];

/// The type group a device is listed under in By type, in plain words.
String typeGroup(DeviceView d, Map<String, Json> drivers) {
  switch (kindOf(d)) {
    case DeviceKind.tv:
      return 'TVs';
    case DeviceKind.board:
      return 'Boards';
    case DeviceKind.sensor:
      return 'Sensors';
    case DeviceKind.tag ||
        DeviceKind.phone ||
        DeviceKind.person ||
        DeviceKind.place:
      return 'Other';
    case DeviceKind.simple:
      return switch (drivers[d.driver]?['category']) {
        'lighting' => 'Lights',
        'power' => 'Plugs',
        'computer' => 'Computers',
        'media' => 'TVs',
        'sensor' => 'Sensors',
        _ =>
          d.capabilityOf('level') != null ||
                  d.capabilityOf('color_temp') != null
              ? 'Lights'
              : d.hasPower
              ? 'Plugs'
              : 'Other',
      };
  }
}

/// Whether [d] matches what was typed in Devices' search: its name, room
/// or driver, ignoring case.
bool matchesQuery(DeviceView d, String query, Map<String, Json> drivers) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return [
    d.name,
    d.room ?? '',
    shortDriverName(drivers[d.driver], d.driver),
  ].any((s) => s.toLowerCase().contains(q));
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
      for (final g in typeGroups) {
        groups[g] = [];
      }
      for (final d in devices) {
        groups[typeGroup(d, drivers)]!.add(d);
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
/// with a search field over the list. A row opens its page; on a wide
/// screen the page shows beside the list instead.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  final _search = TextEditingController();
  String? _selected;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(devicesViewProvider);
    final devices = ref.watch(devicesProvider);
    final drivers = ref.watch(driversProvider).value ?? const {};
    final rooms = ref.watch(roomsProvider).value ?? const [];
    final listed = devices.value == null ? null : listedDevices(devices.value!);
    final problems = listed?.where(hasProblem).length ?? 0;
    final twoPanes = OmniWidth.of(context) == OmniWidth.expanded;
    final query = _search.text;
    final list = Column(
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
        if (listed != null && listed.isNotEmpty)
          _SearchField(controller: _search),
        Expanded(
          child: switch ((devices, listed)) {
            (_, final all?) => _DeviceList(
              devices: [
                for (final d in all)
                  if (matchesQuery(d, query, drivers)) d,
              ],
              anyListed: all.isNotEmpty,
              query: query,
              view: view,
              rooms: rooms,
              drivers: drivers,
              selected: twoPanes ? _selected : null,
              onOpen: twoPanes ? (id) => setState(() => _selected = id) : null,
            ),
            (AsyncError(), _) => EngineSilent(
              onRetry: () => ref.invalidate(devicesProvider),
            ),
            _ => const OmniListSkeleton(label: 'Loading devices'),
          },
        ),
      ],
    );
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
        const ScreenHelpButton(HelpScreen.devices),
      ],
      body: !twoPanes
          ? list
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 360, child: list),
                const SizedBox(width: OmniSpace.lg),
                Expanded(
                  child: _DetailPane(
                    key: ValueKey('devices-detail-$_selected'),
                    id: _selected,
                  ),
                ),
              ],
            ),
    );
  }
}

/// Filters the list as you type.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: OmniSpace.sm),
    child: TextField(
      key: const ValueKey('devices-filter'),
      controller: controller,
      textInputAction: TextInputAction.search,
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
      decoration: InputDecoration(
        hintText: 'Find a device',
        prefixIcon: const Icon(OmniIcons.search, color: OmniColors.muted),
        isDense: true,
        suffixIcon: controller.text.isEmpty
            ? null
            : OmniIconAction(
                key: const ValueKey('devices-filter-clear'),
                icon: OmniIcons.close,
                label: 'Clear search',
                onPressed: controller.clear,
              ),
      ),
    ),
  );
}

/// The right pane of a wide Devices: the chosen device's page, with its
/// own back stack, or a prompt to choose one.
class _DetailPane extends StatelessWidget {
  const _DetailPane({super.key, required this.id});

  final String? id;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(OmniRadii.card),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.background,
          border: Border.all(color: palette.line),
          borderRadius: BorderRadius.circular(OmniRadii.card),
        ),
        child: id == null
            ? const OmniEmptyState(
                icon: OmniIcons.devices,
                title: 'Choose a device',
                message: 'Its controls and history show here.',
              )
            : Navigator(
                onGenerateRoute: (settings) => MaterialPageRoute<void>(
                  settings: RouteSettings(name: DeviceLink(id!).location),
                  builder: (_) => DeviceRoute(id: id!),
                ),
              ),
      ),
    );
  }
}

class _DeviceList extends ConsumerWidget {
  const _DeviceList({
    required this.devices,
    required this.anyListed,
    required this.query,
    required this.view,
    required this.rooms,
    required this.drivers,
    this.selected,
    this.onOpen,
  });

  final List<DeviceView> devices;

  /// Whether anything is listed before the search filters it.
  final bool anyListed;
  final String query;
  final DevicesView view;
  final List<Room> rooms;
  final Map<String, Json> drivers;
  final String? selected;

  /// Shows a device beside the list. Null pushes its page.
  final void Function(String id)? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!anyListed) {
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
      return query.trim().isNotEmpty
          ? OmniEmptyState(
              icon: AreaIcons.notFound,
              title: 'No device matches "${query.trim()}"',
              message: 'Try part of its name, its room or its make.',
            )
          : const OmniEmptyState(
              icon: AreaIcons.ok,
              title: 'Nothing needs a look',
              message: 'Every device is answering.',
            );
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(devicesProvider.notifier).refresh(),
      child: ListView(
        key: const ValueKey('devices-list'),
        padding: EdgeInsets.only(bottom: OmniInsets.fabClearance(context)),
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
                selected: selected == d.id,
                onTap: () {
                  // Unfocused first, so coming back does not bring the
                  // keyboard up for the search field again.
                  FocusManager.instance.primaryFocus?.unfocus();
                  onOpen == null ? openDevice(context, d.id) : onOpen!(d.id);
                },
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
