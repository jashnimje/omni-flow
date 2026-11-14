import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'capability_control.dart' show CapabilityControl, isHighRiskCapability;
import 'device_controls.dart';
import 'device_sections.dart';
import 'device_text.dart';

/// 3.2: one layout for every simple device. A hero with its main state and
/// the power button, the controls its capabilities need, the automations
/// that use it, its recent history, and its room, settings and Remove.
/// A device that stopped answering shows 8.3's help instead of controls.
class DevicePage extends ConsumerWidget {
  const DevicePage({super.key, required this.id});

  final String id;

  /// The capabilities the hero and the sliders already cover.
  static bool _shownAbove(DeviceView d, Json cap) => switch (cap['type']) {
    'toggle' => cap['id'] == d.capabilityOf('toggle')?['id'],
    'level' || 'color_temp' || 'color_rgb' => true,
    _ => false,
  };

  static String _heroTitle(DeviceView d) {
    if (!d.hasPower) return stateLine(d);
    final on = powerOf(d);
    if (on == null) return 'Not read yet';
    if (!on) return 'Off';
    final level = d.capabilityOf('level');
    final v = level == null ? null : d.state[level['stateKey']];
    return v is num ? 'On · ${formatValue(v, rangeOf(level!).unit)}' : 'On';
  }

  static String? _heroSubtitle(DeviceView d) {
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
    final others = [
      for (final c in d.capabilities)
        if (!_shownAbove(d, c)) c,
    ];
    final lit = shownOn(ref, d);
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
              trailing: d.hasPower
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
          ],
          UsedInSection(device: d),
          if (d.online) RecentSection(device: d),
          DeviceSection(device: d),
        ],
      ),
    );
  }
}
