import 'package:flutter/foundation.dart' show mergeSort;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../add/guided_steps_page.dart' show openSetup;
import '../design/design.dart';
import 'capability_control.dart' show CapabilityControl, isHighRiskCapability;
import 'device_controls.dart';
import 'device_sections.dart';
import 'device_text.dart';
import 'smart_home_sections.dart';

/// 3.2: one layout for every simple device. A hero with its main state and
/// the power button, the controls its capabilities need, the automations
/// that use it, its recent history, and its room, settings and Remove.
/// A device that stopped answering shows 8.3's help instead of controls.
class DevicePage extends ConsumerWidget {
  const DevicePage({super.key, required this.id});

  final String id;

  /// Whether [d] is a phone. Its first toggle is the torch, so its hero
  /// shows the screen and battery rather than a power button.
  static bool _isPhone(DeviceView d) => kindOf(d) == DeviceKind.phone;

  /// The capabilities the hero and the sliders already cover.
  static bool _shownAbove(DeviceView d, Json cap) => switch (cap['type']) {
    'toggle' => !_isPhone(d) && cap['id'] == d.capabilityOf('toggle')?['id'],
    'level' || 'color_temp' || 'color_rgb' => true,
    _ => false,
  };

  static int _rank(Json cap) => switch (cap['type']) {
    'toggle' => 0,
    'event' => 2,
    _ => 1,
  };

  static String _heroTitle(DeviceView d) {
    if (_isPhone(d)) {
      return switch (d.state['screen_on']) {
        true => 'Screen on',
        false => 'Screen off',
        _ => 'Screen not read yet',
      };
    }
    if (!d.hasPower) return stateLine(d);
    final on = powerOf(d);
    if (on == null) return 'Not read yet';
    if (!on) return 'Off';
    final level = d.capabilityOf('level');
    final v = level == null ? null : d.state[level['stateKey']];
    return v is num ? 'On · ${formatValue(v, rangeOf(level!).unit)}' : 'On';
  }

  static String? _phoneSubtitle(DeviceView d) {
    final battery = d.state['battery'];
    final parts = [
      if (battery is num)
        'Battery ${formatValue(battery, '%')}'
            '${d.state['charging'] == true ? ', charging' : ''}',
      if (d.room != null) d.room!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String? _heroSubtitle(DeviceView d) {
    if (_isPhone(d)) return _phoneSubtitle(d);
    final temp = d.capabilityOf('color_temp');
    final v = temp == null ? null : d.state[temp['stateKey']];
    final k = v is num ? kelvinOf(v, rangeOf(temp!).unit) : null;
    final parts = [
      if (k != null && powerOf(d) == true)
        switch (warmthWord(k)) {
          'warm' => 'Warm white',
          'cool' => 'Cool white',
          _ => 'Neutral white',
        },
      if (d.room != null) d.room!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = liveDevice(ref, id);
    if (d == null) return const OmniPage(title: 'Device', body: SizedBox());
    ref.listen(
      devicesProvider.select(
        (v) => v.value?.where((j) => j['id'] == id).firstOrNull?['state'],
      ),
      (_, _) => ref.invalidate(deviceHistoryProvider(id)),
    );
    final phone = _isPhone(d);
    final others = [
      for (final c in d.capabilities)
        if (!_shownAbove(d, c) && !(phone && c['type'] == 'sensor')) c,
    ];
    // A phone has many events and actions: its switches (the torch, Do
    // Not Disturb) go first so they are not buried under the events.
    if (phone) mergeSort(others, compare: (a, b) => _rank(a) - _rank(b));
    final readings = [
      if (phone)
        for (final c in d.capabilities)
          if (c['type'] == 'sensor') c,
    ];
    final lit = phone ? d.state['screen_on'] == true : shownOn(ref, d);
    return OmniPage(
      title: d.name,
      actions: [
        FavouriteStar(device: d),
        DeviceMenu(device: d, onRemove: () => removeDevice(context, ref, d)),
      ],
      body: ListView(
        key: ValueKey('device-page-$id'),
        padding: const EdgeInsets.only(top: OmniSpace.xs),
        children: [
          // What the engine says the device refuses commands without (a
          // WiZ bulb's home key), with the setup step that asks for it.
          if (d.json['problem'] case {'message': final String message})
            OmniBanner.warning(
              message,
              key: ValueKey('device-problem-$id'),
              actionLabel: 'Add it',
              onAction: () => openSetup(context, d.json),
            ),
          if (!d.online)
            OfflineHelp(device: d)
          else ...[
            if (d.capabilities.any(isHighRiskCapability))
              OmniBanner.warning(
                'Some controls run commands on ${d.host ?? d.name}. OmniFlow '
                'asks before each one.',
                key: ValueKey('high-risk-$id'),
              ),
            OmniHeroCard(
              key: ValueKey('device-hero-$id'),
              title: _heroTitle(d),
              subtitle: _heroSubtitle(d),
              tone: lit ? HeroTone.accent : HeroTone.plain,
              trailing: d.hasPower && !phone
                  ? OmniPowerButton(
                      key: ValueKey('device-power-$id'),
                      on: lit,
                      label: '${d.name} power',
                      onPressed: () => togglePower(ref, d),
                    )
                  : null,
            ),
            LightControls(device: d),
            if (others.isNotEmpty) ...[
              const OmniSectionHeader('Controls'),
              for (final c in others)
                CapabilityControl(device: d.json, capability: c),
            ],
            if (readings.isNotEmpty) ...[
              const OmniSectionHeader('Readings'),
              for (final c in readings)
                CapabilityControl(device: d.json, capability: c),
            ],
          ],
          if (d.online) DeviceSmartSections(device: d),
          UsedInSection(device: d),
          if (d.online) RecentSection(device: d),
          DeviceSection(device: d),
        ],
      ),
    );
  }
}
