import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show DeviceView, Json;
import '../../api/smart_home_calls.dart';
import '../../state/providers.dart';
import '../automations/sun_lighting_page.dart';
import '../design/design.dart';
import '../home/energy_card.dart';

/// `awaylight.get` with today's `awaylight.preview`. Null when the engine
/// has neither.
final awayLightProvider = FutureProvider.autoDispose<AwayLightView?>((
  ref,
) async {
  final client = ref.read(engineClientProvider);
  try {
    final settings = await client.call(SmartHomeCalls.awaylightGet, const {});
    if (settings['ok'] != true) return null;
    final preview = await client.call(
      SmartHomeCalls.awaylightPreview,
      const {},
    );
    return AwayLightView.of(
      settings,
      preview['ok'] == true ? preview : const {},
    );
  } on Object {
    return null;
  }
});

/// The Settings rows for the home helpers: lights that follow the sun,
/// away lighting and the price of energy.
class SmartHomeSettingsRows extends StatelessWidget {
  const SmartHomeSettingsRows({super.key});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      OmniListRow(
        key: const ValueKey('settings-sun-lighting'),
        icon: OmniIcons.sun,
        title: 'Follow the sun',
        subtitle: 'Lights warm and dim at night, cool and bright at midday',
        chevron: true,
        onTap: () => openSunLighting(context),
      ),
      OmniListRow(
        key: const ValueKey('settings-away-lighting'),
        icon: OmniIcons.light,
        title: 'Away lighting',
        subtitle: 'Lights that look lived-in while nobody is home',
        chevron: true,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AwayLightingPage()),
        ),
      ),
      OmniListRow(
        key: const ValueKey('settings-energy'),
        icon: OmniIcons.plug,
        title: 'Energy',
        subtitle: 'What your plugs use, and the price of one kWh',
        chevron: true,
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => const EnergyPage())),
      ),
    ],
  );
}

/// Away lighting: the switch, which lights to use, and what it would do
/// tonight.
class AwayLightingPage extends ConsumerWidget {
  const AwayLightingPage({super.key});

  Future<void> _set(WidgetRef ref, {List<String>? lights, bool? on}) async {
    final r = await callEngine(
      ref,
      SmartHomeCalls.awaylightSet,
      SmartHomeCalls.awaylightSetArgs(lights: lights, enabled: on),
    );
    if (r['ok'] == true) ref.invalidate(awayLightProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(awayLightProvider).value;
    final lights = [
      for (final j in ref.watch(devicesProvider).value ?? const <Json>[])
        if (isSmartLight(DeviceView(j)) ||
            (j['category'] == 'lighting' &&
                DeviceView(j).capabilityOf('toggle') != null))
          DeviceView(j),
    ];
    final picked = view?.lights ?? const <String>[];
    final now = DateTime.now();
    final tonight = [
      for (final a in view?.actions ?? const <AwayActionView>[])
        if (a.at.isAfter(now)) a,
    ];
    String time(DateTime t) => TimeOfDay.fromDateTime(t).format(context);
    return OmniPage(
      title: 'Away lighting',
      body: ListView(
        key: const ValueKey('away-lighting-page'),
        children: [
          OmniListRow(
            key: const ValueKey('away-enabled'),
            title: 'Away lighting',
            subtitle: view?.status ?? 'Loading',
            subtitleLines: 2,
            trailing: LabelledSwitch(
              value: view?.enabled ?? false,
              label: 'Away lighting',
              onChanged: view == null ? null : (on) => _set(ref, on: on),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: OmniSpace.xs),
            child: Text(
              'While everyone is away, the lights you pick turn on and off as '
              'they did on the same day last week, each up to 20 minutes '
              'earlier or later. It stops the moment someone gets home.',
              style: OmniText.caption,
            ),
          ),
          const OmniSectionHeader('Lights to use'),
          if (lights.isEmpty)
            const Text('No lights added yet.', style: OmniText.caption),
          for (final l in lights)
            OmniListRow(
              key: ValueKey('away-light-${l.id}'),
              icon: OmniIcons.light,
              title: l.name,
              subtitle: l.room,
              trailing: Checkbox(
                value: picked.contains(l.id),
                semanticLabel: 'Use ${l.name}',
                onChanged: view == null
                    ? null
                    : (on) => _set(
                        ref,
                        lights: [
                          for (final p in picked)
                            if (p != l.id) p,
                          if (on == true) l.id,
                        ],
                      ),
              ),
            ),
          const OmniSectionHeader('Tonight'),
          if (tonight.isEmpty)
            Text(
              picked.isEmpty
                  ? 'Pick lights to see what would happen tonight.'
                  : 'Nothing to replay: these lights did not change on this '
                        'day last week, or not later than now.',
              key: const ValueKey('away-tonight-empty'),
              style: OmniText.caption,
            ),
          for (final (i, a) in tonight.indexed)
            OmniListRow(
              key: ValueKey('away-action-$i'),
              icon: OmniIcons.time,
              title: '${a.name} ${a.on ? 'on' : 'off'}',
              value: time(a.at),
            ),
        ],
      ),
    );
  }
}
