import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../api/plain_error.dart' show plainError;
import '../../state/clock.dart' show hour12Provider;
import '../../state/providers.dart';
import '../add/guided_steps_page.dart';
import '../add/pair_sheet.dart';
import '../automations/sun_lighting_page.dart' show FollowSunSwitch;
import '../automations/automations.dart';
import '../boards/pin_sheet.dart';
import '../design/automation_look.dart' show AutomationBadge;
import '../design/design.dart';
import 'host_key_sheet.dart';
import '../../state/reload_home.dart';
import '../home/home_data.dart';
import '../settings/developer_page.dart';
import '../shell/shell.dart';
import '../../api/smart_home_calls.dart' show isSmartLight;
import '../tags/write_tag_sheet.dart';
import 'device_text.dart';
import '../../api/screen_calls.dart';

/// The parts the device and sensor pages share: the favourite star and the
/// more menu, the offline help, "Used in", the recent history and the
/// device section with Remove.

/// The newest state changes of one device, reloaded when its state moves.
final deviceHistoryProvider = FutureProvider.family<List<HistoryEntry>, String>(
  (ref, id) async =>
      (await ref.watch(engineApiProvider).history(id, limit: historyFirst)).or(
        const [],
      ),
);

/// How many changes a device page reads first.
const historyFirst = 20;

/// The most changes one read asks for, which is how many the engine keeps.
const historyMost = 500;

/// How many older changes each Earlier reads, once those read are shown.
const historyPage = 50;

/// The live row of [id] from the devices list, or null. It rebuilds the
/// page only when this device's row changes, not on every other device's
/// state report.
DeviceView? liveDevice(WidgetRef ref, String id) {
  final json = ref.watch(
    devicesProvider.select(
      (v) => v.value?.where((d) => d['id'] == id).firstOrNull,
    ),
  );
  return json == null ? null : DeviceView(json);
}

Future<void> _reloadDevices(WidgetRef ref) => reloadHome(ref);

class FavouriteStar extends ConsumerWidget {
  const FavouriteStar({super.key, required this.device});

  final DeviceView device;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OmniIconAction(
    key: ValueKey('device-star-${device.id}'),
    icon: OmniIcons.star,
    label: device.favourite ? 'Remove from favourites' : 'Add to favourites',
    selected: device.favourite,
    onPressed: () async {
      final done = await ref
          .read(engineApiProvider)
          .organizeDevice(device.id, favourite: !device.favourite);
      if (done.ok) await _reloadDevices(ref);
    },
  );
}

/// The ⋯ menu: setup, pairing, pins, links and the rest, by what the
/// device is.
class DeviceMenu extends ConsumerWidget {
  const DeviceMenu({super.key, required this.device, required this.onRemove});

  final DeviceView device;
  final VoidCallback onRemove;

  Future<void> _askWifiName(WidgetRef ref) async {
    final granted = await ref.read(wifiNamePermissionProvider)();
    showMessage(
      granted
          ? 'OmniFlow can read the Wi-Fi name now'
          : 'Without location access Android hides the Wi-Fi name, so '
                'Wi-Fi places cannot tell where you are',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = device;
    return PopupMenuButton<String>(
      key: ValueKey('device-menu-${d.id}'),
      tooltip: 'More for ${d.name}',
      icon: Icon(OmniIcons.more, color: OmniPalette.of(context).muted),
      onSelected: (choice) => switch (choice) {
        'pair' => showPairDevice(context, d.json),
        'setup' => openSetup(context, d.json),
        'write-tag' => writeTag(context, ref, d.json),
        'wifi-name' => _askWifiName(ref),
        'remove' => onRemove(),
        final other => _openSheet(context, d, pins: other == 'pins'),
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'setup', child: Text('Setup steps')),
        if (d.driver == 'nfc_tag')
          const PopupMenuItem(
            value: 'write-tag',
            child: Text('Write to a tag'),
          ),
        if (d.driver == 'phone')
          const PopupMenuItem(
            value: 'wifi-name',
            child: Text('Read the Wi-Fi name'),
          ),
        if (d.json['board'] == true)
          const PopupMenuItem(value: 'pins', child: Text('Pins')),
        if (pairsInApp(d.json))
          const PopupMenuItem(value: 'pair', child: Text('Pair')),
        const PopupMenuItem(value: 'link', child: Text('Link to…')),
        const PopupMenuItem(value: 'remove', child: Text('Remove')),
      ],
    );
  }
}

Future<void> _openSheet(
  BuildContext context,
  DeviceView d, {
  required bool pins,
}) => showOmniSheet<void>(
  context,
  builder: (_) => pins ? PinSheet(device: d.json) : LinkSheet(fromDevice: d.id),
);

/// Asks before removing [d], then removes it and leaves its page.
Future<void> removeDevice(
  BuildContext context,
  WidgetRef ref,
  DeviceView d,
) async {
  final navigator = Navigator.of(context);
  final api = ref.read(engineApiProvider);
  final ok = await confirm(
    context,
    title: 'Remove ${d.name}?',
    body:
        'Automations and links that use it stop working until it is added '
        'again. Its history is deleted.',
    action: 'Remove',
    destructive: true,
  );
  if (!ok) return;
  final removed = await api.removeDevice(d.id);
  if (!removed.ok) return;
  await _reloadDevices(ref);
  if (navigator.mounted && navigator.canPop()) navigator.pop();
}

/// What a device that stopped answering shows instead of its controls:
/// what happened in plain words, and what to try.
class OfflineHelp extends ConsumerWidget {
  const OfflineHelp({super.key, required this.device});

  final DeviceView device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = device;
    final since = d.lastSeen == null
        ? ''
        : ' since ${when(d.lastSeen!, hour12: ref.watch(hour12Provider))}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniBanner.error(
          'Not answering$since. It may be switched off at the wall, or on '
          'another Wi-Fi.',
          key: ValueKey('offline-${d.id}'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: OmniSpace.sm),
          child: _RetryButton(device: d),
        ),
        OmniListRow(
          key: const ValueKey('device-find'),
          icon: OmniIcons.search,
          title: 'Find it on the network',
          subtitle: 'If its address changed',
          chevron: true,
          onTap: () => showOmniSheet<void>(
            context,
            builder: (_) => _FindAgainSheet(device: d),
          ),
        ),
      ],
    );
  }
}

/// Asks the device again, and says so while it waits.
class _RetryButton extends ConsumerStatefulWidget {
  const _RetryButton({required this.device});

  final DeviceView device;

  @override
  ConsumerState<_RetryButton> createState() => _RetryButtonState();
}

class _RetryButtonState extends ConsumerState<_RetryButton> {
  var _busy = false;

  Future<void> _retry() async {
    final d = widget.device;
    setState(() => _busy = true);
    final read = await ref.read(engineApiProvider).refreshDevice(d.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (read.ok) {
      showMessage('${d.name} answered');
      await ref.read(devicesProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) => OmniButton.ghost(
    key: const ValueKey('device-retry'),
    label: _busy ? 'Asking it' : 'Try again',
    icon: OmniIcons.retry,
    onPressed: _busy ? null : _retry,
  );
}

/// What only someone debugging a device needs, folded away inside More
/// settings: its ids, every change as the engine stored it (the ones
/// Activity leaves out too) and the messages sent to it.
class DeveloperDetails extends ConsumerWidget {
  const DeveloperDetails({super.key, required this.device});

  final DeviceView device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = device;
    final palette = OmniPalette.of(context);
    final entries = ref.watch(deviceHistoryProvider(d.id)).value ?? const [];
    final names = automationNames(ref);
    final hour12 = ref.watch(hour12Provider);
    return OmniDisclosure(
      key: const ValueKey('device-advanced'),
      storageId: 'device-advanced-${d.id}',
      icon: OmniIcons.developer,
      title: 'Developer details',
      summary: 'Ids and the messages sent to it',
      children: [
        OmniListRow(
          icon: OmniIcons.info,
          title: 'Id',
          value: d.id,
          valueColor: palette.muted,
        ),
        if (d.json['stableId'] case final String stable)
          OmniListRow(
            icon: OmniIcons.device,
            title: 'Hardware id',
            value: stable,
            valueColor: palette.muted,
          ),
        if (entries.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpace.md,
              OmniSpace.md,
              OmniSpace.md,
              OmniSpace.xs,
            ),
            child: Text('Raw changes', style: OmniText.captionOf(context)),
          ),
          for (final (i, e) in entries.take(20).indexed)
            OmniListRow(
              key: ValueKey('device-raw-$i'),
              title: RecentSection.describe(e, d, names, hour12: hour12),
            ),
        ],
        OmniListRow(
          key: const ValueKey('device-packets'),
          icon: OmniIcons.packets,
          title: 'See what was sent',
          chevron: true,
          divider: false,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DeveloperScreen(filter: d.host ?? d.id),
            ),
          ),
        ),
      ],
    );
  }
}

/// The names of the automations by id, so a change says "by Good night"
/// rather than an id.
Map<String, String> automationNames(WidgetRef ref) => {
  for (final a
      in ref.watch(summariesProvider).value ?? const <AutomationSummary>[])
    a.id: a.name,
};

/// The one line under a device's Automations section.
String? usedInSummary(List<AutomationSummary>? used) => switch (used) {
  null => null,
  [] => 'Not used yet',
  [_] => 'Used in 1',
  final all => 'Used in ${all.length}',
};

/// A device page's collapsed sections, in the standard order and always
/// below its controls: the automations that use it, what happened to it
/// in plain words, and its room, name, settings and Remove.
/// [activityTop] goes first inside Activity (a sensor's day chart).
List<OmniDisclosure> deviceSections(
  WidgetRef ref,
  DeviceView d, {
  Widget? activityTop,
}) {
  final entries = ref.watch(deviceHistoryProvider(d.id)).value;
  final plain = entries == null
      ? null
      : DeviceActivitySection.plainEntries(entries, d, automationNames(ref));
  return [
    OmniDisclosure(
      key: ValueKey('device-automations-${d.id}'),
      storageId: 'device-automations-${d.id}',
      icon: OmniIcons.automations,
      title: 'Automations',
      summary: usedInSummary(ref.watch(usedInProvider(d.id)).value),
      children: [UsedInSection(device: d, header: false)],
    ),
    OmniDisclosure(
      key: ValueKey('device-activity-${d.id}'),
      storageId: 'device-activity-${d.id}',
      icon: OmniIcons.history,
      title: 'Activity',
      summary: plain == null
          ? null
          : DeviceActivitySection.summaryOf([for (final p in plain) p.$2]),
      children: [
        ?activityTop,
        DeviceActivitySection(device: d),
      ],
    ),
    OmniDisclosure(
      key: ValueKey('device-more-${d.id}'),
      storageId: 'device-more-${d.id}',
      icon: OmniIcons.tune,
      title: 'More settings',
      summary: isSmartLight(d)
          ? 'Room, name, follow the sun'
          : 'Room, name and Remove',
      children: [DeviceSection(device: d)],
    ),
  ];
}

/// What happened to a device, newest first, in plain words ("Turned on
/// by you", "Brightness 60% by Good night"). A change with no plain
/// description (a key no capability names, an empty value) is left out
/// here and shown only under Developer details, Raw changes.
class DeviceActivitySection extends ConsumerStatefulWidget {
  const DeviceActivitySection({super.key, required this.device});

  final DeviceView device;

  /// How many changes Activity lists.
  static const shown = 8;

  /// [e] as a sentence, or null when it has no plain description.
  static String? plain(
    HistoryEntry e,
    DeviceView d,
    Map<String, String> names,
  ) {
    switch (e.answering) {
      case false:
        return stopped;
      case true:
        return answeringAgain;
      case null:
    }
    final cap = d.capabilities.where((c) => c['stateKey'] == e.key).firstOrNull;
    if (cap == null) return null;
    final label = switch (cap['label']) {
      final String l when l.trim().isNotEmpty => l.trim(),
      _ => null,
    };
    final type = cap['type'];
    final unit = rangeOf(cap).unit;
    final what = switch ((type, e.value)) {
      ('toggle', true) => 'Turned on',
      ('toggle', false) => 'Turned off',
      (_, null) => null,
      _ when label == null => null,
      ('color_temp', final num n) => 'Warmth ${_kelvin(n, unit)}',
      (_, final num n) => '$label ${formatValue(n, unit)}',
      (_, final bool b) => '$label ${b ? 'on' : 'off'}',
      (_, final String t) when t.trim().isNotEmpty => '$label ${t.trim()}',
      _ => null,
    };
    if (what == null) return null;
    final by = switch (e.by) {
      'user' => ' by you',
      final String id when names[id] != null => ' by ${names[id]}',
      _ => '',
    };
    return '$what$by';
  }

  static String _kelvin(num n, String unit) =>
      formatValue((kelvinOf(n, unit) ?? n).round(), 'K');

  /// The entries of [entries] with a plain description, each with it.
  static List<(String, HistoryEntry)> plainEntries(
    List<HistoryEntry> entries,
    DeviceView d,
    Map<String, String> names,
  ) => [
    for (final e in entries)
      if (plain(e, d, names) case final words?) (words, e),
  ];

  /// Activity's one line: "5 changes today", "Nothing today" or "Nothing
  /// yet", counting only the changes it lists.
  static String summaryOf(List<HistoryEntry> plain, {DateTime? now}) {
    if (plain.isEmpty) return 'Nothing yet';
    final today = (now ?? DateTime.now()).toLocal();
    final count = plain.where((e) {
      final at = e.at.toLocal();
      return at.year == today.year &&
          at.month == today.month &&
          at.day == today.day;
    }).length;
    return switch (count) {
      0 => 'Nothing today',
      1 => '1 change today',
      final n => '$n changes today',
    };
  }

  static const stopped = 'Stopped answering';
  static const answeringAgain = 'Answering again';

  /// A device that is not answering, as Activity's first line, when the
  /// history does not already start with it stopping: a device the hub
  /// does not poll only goes quiet, so the line comes from when it was
  /// last seen.
  static String? stoppedLine(DeviceView d, List<HistoryEntry> entries) {
    if (d.online) return null;
    final last = entries.where((e) => e.answering != null).firstOrNull;
    return last?.answering == false ? null : stopped;
  }

  /// [head] (the newest page, read again on every change) in front of
  /// [kept] (what Earlier read before), without repeats. A change that
  /// came in since sits in [head] before [kept]'s newest entry.
  static List<HistoryEntry> merged(
    List<HistoryEntry> head,
    List<HistoryEntry>? kept,
  ) {
    if (kept == null || kept.isEmpty) return head;
    final first = kept.first;
    final at = head.indexWhere((e) => _same(e, first));
    final newer = at >= 0
        ? head.take(at)
        : head.where((e) => e.at.isAfter(first.at));
    return [...newer, ...kept];
  }

  static bool _same(HistoryEntry a, HistoryEntry b) =>
      a.at.isAtSameMomentAs(b.at) &&
      a.key == b.key &&
      a.by == b.by &&
      '${a.value}' == '${b.value}';

  /// The `device.history` read for the page older than [all]. The engine
  /// keeps whole seconds, so it asks up to the end of the oldest second and
  /// [skip]s the entries of that second already held.
  static ({DateTime before, int limit, int skip}) olderPage(
    List<HistoryEntry> all,
  ) {
    final oldest = all.last.at;
    final skip = all.reversed
        .takeWhile((e) => e.at.isAtSameMomentAs(oldest))
        .length;
    return (
      before: oldest.add(const Duration(seconds: 1)),
      limit: (historyPage + skip).clamp(1, historyMost),
      skip: skip,
    );
  }

  @override
  ConsumerState<DeviceActivitySection> createState() =>
      _DeviceActivitySectionState();
}

class _DeviceActivitySectionState extends ConsumerState<DeviceActivitySection> {
  /// How many changes are shown.
  var _shown = DeviceActivitySection.shown;

  /// The changes read so far once Earlier went past the first page, the
  /// first page as it was then followed by the older pages.
  List<HistoryEntry>? _kept;

  /// The engine has nothing older than what is read.
  var _end = false;
  var _reading = false;

  DeviceView get device => widget.device;

  Future<void> _earlier(List<HistoryEntry> all, int plainCount) async {
    setState(() => _shown += DeviceActivitySection.shown * 2);
    if (_shown <= plainCount || _end || _reading || all.isEmpty) return;
    _reading = true;
    final page = DeviceActivitySection.olderPage(all);
    final reply = await ref
        .read(engineApiProvider)
        .history(device.id, limit: page.limit, before: page.before);
    _reading = false;
    if (!mounted) return;
    if (!reply.ok) {
      final failure = reply.failure!;
      showMessage(
        'Could not read older changes. '
        '${plainError(failure.type, failure.message)}',
      );
      return;
    }
    final got = reply.value!;
    setState(() {
      _end = got.length < page.limit;
      _kept = [...all, ...got.skip(page.skip)];
    });
  }

  @override
  Widget build(BuildContext context) {
    final head = ref.watch(deviceHistoryProvider(device.id)).value;
    final entries = head == null
        ? null
        : DeviceActivitySection.merged(head, _kept);
    if (entries == null) {
      return const OmniListSkeleton(rows: 2, label: 'Loading what happened');
    }
    final plain = DeviceActivitySection.plainEntries(
      entries,
      device,
      automationNames(ref),
    );
    final hour12 = ref.watch(hour12Provider);
    final stopped = DeviceActivitySection.stoppedLine(device, entries);
    final seen = device.lastSeen;
    final stoppedRow = stopped == null
        ? null
        : OmniListRow(
            key: ValueKey('activity-stopped-${device.id}'),
            icon: AreaIcons.offline,
            title: stopped,
            value: seen == null ? null : when(seen, hour12: hour12),
            valueColor: OmniPalette.of(context).muted,
            dot: StatusKind.offline,
            divider: plain.isNotEmpty,
          );
    if (plain.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?stoppedRow,
          Padding(
            key: ValueKey('activity-none-${device.id}'),
            padding: const EdgeInsets.symmetric(vertical: OmniSpace.md),
            child: Text(
              'Nothing has changed yet. Changes show here as they happen.',
              style: OmniText.captionOf(context),
            ),
          ),
        ],
      );
    }
    final rows = plain.take(_shown).toList();
    // More to show: rows read but not shown, or a full read that may have
    // older days behind it.
    final more =
        plain.length > rows.length || (!_end && entries.length >= historyFirst);
    return Column(
      key: ValueKey('activity-${device.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?stoppedRow,
        for (final (i, (words, e)) in rows.indexed)
          OmniListRow(
            key: ValueKey('activity-${device.id}-$i'),
            title: words,
            value: when(e.at, hour12: hour12),
            valueColor: OmniPalette.of(context).muted,
            divider: i < rows.length - 1 || more,
          ),
        if (more)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: ValueKey('activity-earlier-${device.id}'),
              onPressed: () => _earlier(entries, plain.length),
              child: const Text('Earlier'),
            ),
          ),
      ],
    );
  }
}

/// The automations that read or drive a device, the same on every device
/// page and in the TV's more sheet. Each row says what the automation does
/// with it, and while it is offline, what that means.
class UsedInSection extends ConsumerWidget {
  const UsedInSection({super.key, required this.device, this.header = true});

  final DeviceView device;

  /// Whether it carries its own "Automations that use it" heading. Off
  /// inside a page's Automations section, which already names it.
  final bool header;

  /// What [a] does with [d]: a step on it, or it starts or checks on it.
  static String roleOf(AutomationSummary a, DeviceView d) {
    final drives = a.controls.isEmpty || a.controls.contains(d.id);
    if (d.online) {
      return drives ? 'Has a step on it' : 'Starts or checks on it';
    }
    return drives
        ? 'Steps on it fail while it is not answering'
        : 'Does not start or check it while it is not answering';
  }

  /// A new rule that already turns [d] on, when it can be, so only the
  /// trigger is left to pick.
  static Json _startWith(DeviceView d) {
    final toggle = d.capabilityOf('toggle');
    final wake = d.capabilities.where((c) => c['id'] == 'wake').firstOrNull;
    final step = toggle != null
        ? {
            'do': '${d.id}.${toggle['id']}',
            'params': {'value': true},
          }
        : wake != null
        ? {'do': '${d.id}.wake'}
        : null;
    return {
      'name': '${d.name} automation',
      'then': [?step],
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final used = ref.watch(usedInProvider(device.id)).value;
    if (used == null) return const SizedBox();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header) const OmniSectionHeader('Automations that use it'),
        if (used.isEmpty)
          OmniListRow(
            key: ValueKey('used-in-new-${device.id}'),
            icon: OmniIcons.add,
            title: 'Make an automation with it',
            subtitle: 'No automation uses it yet',
            chevron: true,
            onTap: () => openRuleEditor(context, spec: _startWith(device)),
          ),
        for (final a in used)
          OmniListRow(
            key: ValueKey('used-in-${a.id}'),
            // The automation's own look, as on its card.
            leading: AutomationBadge(
              icon: automationIconFor(a),
              color: a.color,
              size: 32,
            ),
            title: a.name,
            subtitle: roleOf(a, device),
            chevron: true,
            onTap: () =>
                ref.read(shellControllerProvider).open(AutomationLink(a.id)),
          ),
      ],
    );
  }
}

/// "19:02 turned on by Arrive home", newest first.
class RecentSection extends ConsumerWidget {
  const RecentSection({super.key, required this.device});

  final DeviceView device;

  static String describe(
    HistoryEntry e,
    DeviceView d,
    Map<String, String> names, {
    bool hour12 = false,
  }) {
    final cap = d.capabilities.where((c) => c['stateKey'] == e.key).firstOrNull;
    final type = cap?['type'];
    final value = e.value;
    final what = switch ((type, value)) {
      ('toggle', true) => 'turned on',
      ('toggle', false) => 'turned off',
      ('level' || 'color_temp', final num n) =>
        '${'${cap!['label']}'.toLowerCase()} ${formatValue(n, rangeOf(cap).unit)}',
      (_, final bool b) => '${cap?['label'] ?? e.key} ${b ? 'on' : 'off'}',
      _ => '${cap?['label'] ?? e.key} $value',
    };
    final by = switch (e.by) {
      null => '',
      'user' => ' by you',
      final id => ' by ${names[id] ?? id}',
    };
    return '${when(e.at, hour12: hour12)} $what$by';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(deviceHistoryProvider(device.id)).value;
    if (entries == null || entries.isEmpty) return const SizedBox();
    final names = <String, String>{
      for (final a
          in ref.watch(summariesProvider).value ?? const <AutomationSummary>[])
        a.id: a.name,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OmniSectionHeader('Recent'),
        for (final e in entries.take(8))
          OmniListRow(
            title: describe(
              e,
              device,
              names,
              hour12: ref.watch(hour12Provider),
            ),
          ),
      ],
    );
  }
}

/// The inside of a device page's More settings: its room, its name,
/// address and settings, Follow the sun for a light, Developer details,
/// and Remove.
class DeviceSection extends ConsumerWidget {
  const DeviceSection({super.key, required this.device});

  final DeviceView device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = device;
    final address = d.host ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniListRow(
          key: ValueKey('device-room-${d.id}'),
          icon: OmniIcons.room,
          title: 'Room',
          subtitle: d.room ?? 'Not in a room',
          chevron: true,
          onTap: () => pickRoom(context, ref, d),
        ),
        OmniListRow(
          key: ValueKey('device-details-${d.id}'),
          icon: OmniIcons.edit,
          title: 'Name and address',
          subtitle: address.isEmpty ? d.name : address,
          chevron: true,
          onTap: () => _details(context, ref, d),
        ),
        if (usesSsh(d))
          OmniListRow(
            key: ValueKey('device-hostkey-${d.id}'),
            icon: OmniIcons.permissions,
            title: 'SSH host key',
            subtitle: 'Check it, or trust a new one after a reinstall',
            chevron: true,
            onTap: () => showHostKeySheet(context, d),
          ),
        if (d.online && isSmartLight(d)) FollowSunSwitch(device: d),
        DeveloperDetails(device: d),
        const SizedBox(height: OmniSpace.md),
        OmniButton.danger(
          key: ValueKey('device-remove-${d.id}'),
          label: 'Remove ${d.name}',
          icon: OmniIcons.delete,
          onPressed: () => removeDevice(context, ref, d),
        ),
      ],
    );
  }

  Future<void> _details(
    BuildContext context,
    WidgetRef ref,
    DeviceView d,
  ) async {
    final name = ReplaceableText(d.name);
    final settings = await SheetTemplate.show<bool>(
      context,
      builder: (sheet) => Owning(
        [name],
        child: SheetTemplate(
          title: 'Name, address and settings',
          primaryLabel: 'Save name',
          primaryKey: const ValueKey('device-name-save'),
          onPrimary: () async {
            final text = name.text.trim();
            if (text.isEmpty || text == d.name) {
              Navigator.of(sheet).pop(false);
              return;
            }
            final saved = await ref
                .read(engineApiProvider)
                .organizeDevice(d.id, name: text);
            if (saved.ok) await _reloadDevices(ref);
            if (sheet.mounted) Navigator.of(sheet).pop(false);
          },
          children: (context) => [
            TextField(
              key: const ValueKey('device-name-field'),
              controller: name,
              onTap: name.firstTap,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            if (d.host != null)
              OmniListRow(
                icon: OmniIcons.network,
                title: 'Address',
                value: d.host,
                valueColor: OmniPalette.of(context).muted,
              ),
            OmniListRow(
              key: const ValueKey('device-settings'),
              icon: OmniIcons.edit,
              title: 'Change its settings',
              subtitle: 'The setup steps of its driver',
              chevron: true,
              divider: false,
              onTap: () => Navigator.of(sheet).pop(true),
            ),
          ],
        ),
      ),
    );
    if (settings == true && context.mounted) {
      unawaited(openSetup(context, d.json));
    }
  }
}

/// Moves [d] to a room, out of every room, or into a new one.
Future<void> pickRoom(BuildContext context, WidgetRef ref, DeviceView d) async {
  final List<Room> rooms =
      ref.read(roomsProvider).value ?? await ref.read(roomsProvider.future);
  if (!context.mounted) return;
  final api = ref.read(engineApiProvider);
  Future<void> move(String room) async {
    if (room == (d.roomId ?? '')) return;
    final moved = await api.organizeDevice(d.id, room: room);
    if (moved.ok) await _reloadDevices(ref);
  }

  final picked = await showPickerSheet<String>(
    context,
    title: 'Room for ${d.name}',
    selected: d.roomId ?? '',
    sections: [
      PickerSection([
        for (final r in rooms)
          PickerItem(
            key: ValueKey('room-pick-${r.id}'),
            value: r.id,
            title: r.name,
            icon: OmniIcons.room,
          ),
        const PickerItem(
          key: ValueKey('room-none'),
          value: '',
          title: 'Not in a room',
          icon: OmniIcons.close,
        ),
      ]),
    ],
    addLabel: 'New room',
    onAdd: () async {
      final name = await askRoomName(context);
      if (name == null) return;
      final saved = await api.saveRoom(name: name);
      if (saved.ok) await move(saved.value ?? '');
    },
  );
  if (picked != null) await move(picked);
}

/// Asks for a room's name. Null when cancelled.
Future<String?> askRoomName(BuildContext context, {String initial = ''}) =>
    showPromptSheet(
      context,
      title: initial.isEmpty ? 'New room' : 'Rename room',
      label: 'Name',
      initial: initial,
    );

/// Looks for [device]'s driver on the network and points [device] at the
/// find the user picks: same id, name, room and settings, so automations
/// that use it keep working and nothing is added twice.
class _FindAgainSheet extends ConsumerStatefulWidget {
  const _FindAgainSheet({required this.device});

  final DeviceView device;

  @override
  ConsumerState<_FindAgainSheet> createState() => _FindAgainSheetState();
}

class _FindAgainSheetState extends ConsumerState<_FindAgainSheet> {
  List<Json>? _found;
  String? _error;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _look();
  }

  Future<void> _look() async {
    setState(() {
      _found = null;
      _error = null;
    });
    final d = widget.device;
    final r = await ref.read(engineClientProvider).call(DeviceCalls.discover, {
      'driver': d.json['driver'],
      'windowMs': 3000,
      'serial': false,
    });
    if (!mounted) return;
    setState(() {
      if (r['ok'] != true) {
        _error = errorMessage(r);
        _found = const [];
        return;
      }
      _found = [
        for (final f in (r['found'] as List? ?? const []))
          if (f is Map) Map<String, Object?>.from(f),
      ];
    });
  }

  Future<void> _use(Json find) async {
    final d = widget.device;
    setState(() => _busy = true);
    // The engine adds it again in place: same name, room and automations.
    final r = await ref
        .read(engineClientProvider)
        .call(DeviceCalls.move, DeviceCalls.moveArgs(d.id, find));
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      setState(() => _error = errorMessage(r));
      return;
    }
    await ref.read(devicesProvider.notifier).refresh();
    if (!mounted) return;
    Navigator.of(context).pop();
    showMessage('${d.name} is at ${find['host']} now');
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    return SheetTemplate(
      title: 'Find ${widget.device.name}',
      subtitle: 'Pick it, and it keeps its name, room and automations.',
      state: found == null ? const OmniLoad.loading() : const OmniLoad.data(),
      secondaryLabel: 'Look again',
      onSecondary: _look,
      children: (context) => [
        if (found!.isEmpty)
          OmniBanner.info(
            _error ??
                'Nothing like it answered. Check it has power and is on this '
                    'Wi-Fi, then look again.',
            key: const ValueKey('find-again-none'),
          )
        else
          for (final f in found)
            OmniListRow(
              key: ValueKey('find-again-${f['host']}'),
              icon: OmniIcons.device,
              title: '${f['name'] ?? f['host']}',
              subtitle: f['host'] == widget.device.host
                  ? '${f['host']} · where it was'
                  : '${f['host']}',
              chevron: true,
              onTap: _busy ? null : () => _use(f),
            ),
        if (_error != null && found.isNotEmpty) OmniBanner.error(_error!),
      ],
    );
  }
}
