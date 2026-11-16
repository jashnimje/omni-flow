import 'package:flutter/material.dart';

import '../../state/clock.dart' show hour12Provider;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/house.dart' show houseShownProvider, newHomePlace;
import '../../state/providers.dart';
import '../add/add_by_hand_page.dart';
import '../design/design.dart';
import 'phone_access.dart';
import '../automations/form_parts.dart' show showFormSheet, DurationInput;
import '../add/room_field.dart' show showOrganizeSheet;
import '../devices/device_text.dart';
import '../home/home_presence.dart';

/// The places that have inputs, as zone.list reports them.
/// Read again whenever a place or device changes anywhere (the CLI, an
/// agent, another phone), not only from this screen.
final zonesProvider = FutureProvider<List<Json>>((ref) async {
  ref.watch(deviceChangesProvider);
  return (await ref.watch(engineApiProvider).zones()).or(const []);
});

/// The home place: the zone named home, else the first one.
Json? homeZone(List<Json> zones) =>
    zones.where((z) => z['id'] == 'home').firstOrNull ?? zones.firstOrNull;

String sourceWord(PresenceSource s) => switch (s) {
  PresenceSource.wifi => 'Wi-Fi',
  PresenceSource.ble => 'the Bluetooth beacon',
  PresenceSource.hub => 'a hub',
  PresenceSource.manual => 'you',
  PresenceSource.unknown => 'nothing yet',
};

/// 7.2: where you are, since when and what saw you; how OmniFlow knows
/// (each home Wi-Fi network, a Bluetooth beacon, being seen by a hub), each
/// with a switch; the wait before away; and the people.
class PlacesPage extends ConsumerStatefulWidget {
  const PlacesPage({super.key});

  @override
  ConsumerState<PlacesPage> createState() => _PlacesPageState();
}

class _PlacesPageState extends ConsumerState<PlacesPage> {
  /// Networks switched off this visit, so they can be switched back on.
  final _offNetworks = <String>{};
  Json? _offBeacon;

  Future<void> _save(Json zone) async {
    final saved = await ref.read(engineApiProvider).saveZone(zone);
    if (saved.ok) {
      ref.invalidate(zonesProvider);
      await ref.read(devicesProvider.notifier).refresh();
    }
  }

  Json _zoneJson(
    Json zone, {
    Set<String>? ssids,
    Object? ble = _keep,
    int? awayAfterMs,
  }) {
    final wifi = zone['wifi'] is Map
        ? Map<String, Object?>.from(zone['wifi'] as Map)
        : <String, Object?>{};
    final nextSsids =
        ssids ?? {...(wifi['ssids'] as List? ?? const []).cast<String>()};
    final bssids = (wifi['bssids'] as List? ?? const []).cast<String>();
    return {
      'id': zone['id'],
      'name': zone['name'] ?? zone['id'],
      if (nextSsids.isNotEmpty || bssids.isNotEmpty)
        'wifi': {
          'ssids': nextSsids.toList(),
          'bssids': bssids,
          'required': wifi['required'] == true,
          'awayAfterMs': ?awayAfterMs ?? wifi['awayAfterMs'],
        },
      if (identical(ble, _keep) && zone['ble'] != null) 'ble': zone['ble'],
      if (!identical(ble, _keep) && ble != null) 'ble': ble,
    };
  }

  static const _keep = Object();

  Future<void> _setNetwork(Json zone, String ssid, bool on) async {
    final ssids = {
      ...((zone['wifi'] as Map?)?['ssids'] as List? ?? const []).cast<String>(),
    };
    if (on) {
      ssids.add(ssid);
      _offNetworks.remove(ssid);
    } else {
      ssids.remove(ssid);
      _offNetworks.add(ssid);
    }
    await _save(_zoneJson(zone, ssids: ssids));
  }

  Future<void> _addCurrentWifi(Json zone, String ssid) async {
    final ssids = {
      ...((zone['wifi'] as Map?)?['ssids'] as List? ?? const []).cast<String>(),
      ssid,
    };
    await _save(_zoneJson(zone, ssids: ssids));
  }

  Future<void> _setBeacon(Json zone, bool on) async {
    if (!on) {
      _offBeacon = Map<String, Object?>.from(zone['ble'] as Map);
      await _save(_zoneJson(zone, ble: null));
      return;
    }
    final ble = _offBeacon ?? await _askBeacon();
    if (ble == null) return;
    _offBeacon = null;
    await _save(_zoneJson(zone, ble: ble));
  }

  Future<Json?> _askBeacon() async {
    final name = await showPromptSheet(
      context,
      title: 'Bluetooth beacon',
      label: 'The name the beacon shows',
      hint: 'Like OMNI_DESK',
      message: 'OmniFlow never uses its address.',
      action: 'Use it',
    );
    return name == null || name.isEmpty ? null : {'matchName': name};
  }

  @override
  Widget build(BuildContext context) {
    final devices = [
      for (final j in ref.watch(devicesProvider).value ?? const <Json>[])
        DeviceView(j),
    ];
    final zones = ref.watch(zonesProvider);
    final person = personOf(devices);
    final presence = person == null ? null : Presence.of(person.json);
    final people = devices.where((d) => d.driver == 'person').toList();
    final phone = devices.where((d) => d.driver == 'phone').firstOrNull;
    final currentSsid = phone?.state['wifi_ssid'];
    // With no place answering yet, the first Wi-Fi or beacon saved makes
    // the home place (zone.save keeps a bare place named home, if one).
    final zone =
        homeZone(zones.value ?? const []) ??
        newHomePlace(ref.watch(houseShownProvider));
    final title = '${zone['name'] ?? 'Home'}';
    final wifi = zone['wifi'] is Map ? zone['wifi'] as Map : const {};
    final ssids = (wifi['ssids'] as List? ?? const []).cast<String>();
    final ble = zone['ble'] is Map ? zone['ble'] as Map : null;
    final exitMs = (ble?['exitDwellMs'] as num?)?.toInt();
    final awayMs = (wifi['awayAfterMs'] as num?)?.toInt() ?? _defaultAwayMs;
    return DetailPage(
      key: const ValueKey('places-list'),
      title: title,
      actions: [
        if (person != null)
          PopupMenuButton<bool>(
            key: const ValueKey('places-menu'),
            tooltip: 'Say where you are',
            icon: const Icon(OmniIcons.more, color: OmniColors.muted),
            onSelected: (home) async {
              final done = await ref
                  .read(engineApiProvider)
                  .setPresence(home, person: person.id);
              if (done.ok) await ref.read(devicesProvider.notifier).refresh();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: true, child: Text('I am home now')),
              PopupMenuItem(value: false, child: Text('I am away now')),
            ],
          ),
      ],
      hero: OmniHeroCard(
        key: const ValueKey('presence-hero'),
        title: switch (presenceShown(presence, zones.value)) {
          PresenceShown.notSetUp => presenceNotSetUp,
          _ => switch (presence?.home) {
            true => 'You are home',
            false => 'You are away',
            null => 'Not known yet',
          },
        },
        subtitle:
            presence == null ||
                presence.home == null ||
                presenceShown(presence, zones.value) == PresenceShown.notSetUp
            ? 'Add your home Wi-Fi or a beacon below, and OmniFlow can '
                  'tell when you are home'
            : [
                if (presence.since != null)
                  'since ${when(presence.since!, hour12: ref.watch(hour12Provider))}',
                'seen by ${sourceWord(presence.source)}',
              ].join(' · '),
        tone: presence?.home == true ? HeroTone.accent : HeroTone.plain,
      ),
      children: (context) => [
        if (ssids.isNotEmpty &&
            ref.watch(phoneAccessStateProvider).value?.locationAlways == false)
          OmniBanner.warning(
            key: const ValueKey('wifi-needs-always'),
            'With the screen off, Android hides the Wi-Fi name from '
            'OmniFlow, so arriving home goes unnoticed until you open it. '
            'Allow location all the time to fix it.',
            actionLabel: 'Allow',
            onAction: () async {
              await ref.read(phoneAccessProvider).askLocationAlways();
              ref.invalidate(phoneAccessStateProvider);
            },
          ),
        const OmniSectionHeader('How OmniFlow knows you are here'),
        if (zones.isLoading && zones.value == null)
          const OmniListSkeleton(rows: 2, label: 'Loading your places')
        else ...[
          for (final ssid in {...ssids, ..._offNetworks})
            OmniListRow(
              key: ValueKey('network-$ssid'),
              icon: OmniIcons.wifi,
              title: 'Wi-Fi $ssid',
              subtitle: 'this phone joins it',
              trailing: Switch(
                value: ssids.contains(ssid),
                onChanged: (on) => _setNetwork(zone, ssid, on),
              ),
            ),
          if (currentSsid is String &&
              currentSsid.isNotEmpty &&
              !ssids.contains(currentSsid) &&
              !_offNetworks.contains(currentSsid))
            OmniListRow(
              key: const ValueKey('network-add-current'),
              icon: OmniIcons.add,
              title: 'Use $currentSsid',
              subtitle: 'the Wi-Fi this phone is on now',
              onTap: () => _addCurrentWifi(zone, currentSsid),
            ),
          OmniListRow(
            key: const ValueKey('presence-beacon'),
            icon: OmniIcons.bluetooth,
            title: 'Bluetooth beacon',
            subtitle: ble == null
                ? 'a small beacon near the door or desk'
                : '${ble['matchName']}',
            trailing: Switch(
              value: ble != null,
              onChanged: (on) => _setBeacon(zone, on),
            ),
          ),
          const OmniListRow(
            key: ValueKey('presence-hub'),
            icon: OmniIcons.hub,
            title: 'Seen by a hub',
            subtitle: 'Coming later',
            value: 'Not yet',
            valueColor: OmniColors.muted,
          ),
        ],
        const SizedBox(height: OmniSpace.md),
        OmniListRow(
          key: const ValueKey('away-wait'),
          icon: OmniIcons.time,
          title: 'Wait before "away"',
          subtitle: ssids.isEmpty
              ? (exitMs == null
                    ? 'Set up Wi-Fi or a beacon first'
                    : 'The beacon stays quiet ${_duration(exitMs)} first')
              : 'Off the Wi-Fi this long first, so a router restart is not '
                    'leaving',
          subtitleLines: 2,
          value: ssids.isEmpty ? null : _duration(awayMs),
          chevron: ssids.isNotEmpty,
          onTap: ssids.isEmpty ? null : () => _editAwayWait(zone, awayMs),
        ),
        const OmniSectionHeader('People'),
        for (final p in people)
          OmniListRow(
            key: ValueKey('person-${p.id}'),
            icon: OmniIcons.person,
            title: p.name,
            subtitle: phone == null ? null : 'this phone',
            value: switch (Presence.of(p.json).home) {
              true => 'home',
              false => 'away',
              null => null,
            },
            chevron: true,
            onTap: () => showOrganizeSheet(context, p.json),
          ),
        if (people.isEmpty)
          OmniListRow(
            key: const ValueKey('add-person'),
            icon: OmniIcons.person,
            title: 'Add a person',
            subtitle: 'Who this phone belongs to',
            chevron: true,
            onTap: () => _addByHand(context, 'person'),
          ),
      ],
    );
  }

  static Future<void> _addByHand(BuildContext context, String driver) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => AddByHandPage(driver: driver)),
      );

  static const _defaultAwayMs = 120000;

  Future<void> _editAwayWait(Json zone, int current) async {
    var ms = current;
    final picked = await showFormSheet<int>(
      context,
      title: 'Wait before "away"',
      subtitle:
          'How long the phone is off your Wi-Fi before you count as gone. '
          '0 leaves at once.',
      result: () => ms >= 0 && ms <= 3600000 ? ms : null,
      whyNot: () => 'Up to 1 hour',
      build: (context, setState) => [
        DurationInput(
          label: 'Wait',
          ms: ms,
          onChanged: (v) => setState(() => ms = v),
        ),
      ],
    );
    if (picked == null || picked == current) return;
    await _save(_zoneJson(zone, awayAfterMs: picked));
  }

  static String _duration(int ms) {
    final s = ms ~/ 1000;
    return s < 60 ? '$s s' : '${s ~/ 60} min';
  }
}
