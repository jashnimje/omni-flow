import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show DeviceView, Json;
import '../../api/home_location_calls.dart';
import '../../api/smart_home_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../settings/home_location_page.dart'
    show homeLocationProvider, openHomeLocation;

DeviceView? _weatherThing(WidgetRef ref, [String? id]) {
  final list = ref.watch(devicesProvider).value ?? const <Json>[];
  final j = list
      .where(
        (j) => id == null
            ? j['driver'] == SmartHomeCalls.weatherDriver
            : j['id'] == id,
      )
      .firstOrNull;
  return j == null ? null : DeviceView(j);
}

void openWeather(BuildContext context, String id) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => WeatherPage(id: id)));

/// Home's weather tile: the temperature and the sky, once a weather thing
/// is added. A tap opens the weather page.
class WeatherCard extends ConsumerWidget {
  const WeatherCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thing = _weatherThing(ref);
    if (thing == null) return const SizedBox.shrink();
    final w = WeatherView(thing.state);
    return OmniCard(
      key: const ValueKey('home-weather'),
      onTap: () => openWeather(context, thing.id),
      child: Semantics(
        button: true,
        label: 'Weather: ${w.line}',
        hint: 'Opens the weather',
        excludeSemantics: true,
        child: Row(
          children: [
            const Icon(OmniIcons.sun, color: OmniColors.accent),
            const SizedBox(width: OmniSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(thing.name, style: OmniText.caption),
                  Text(w.line, style: OmniText.bodyStrong),
                ],
              ),
            ),
            if (w.high != null && w.low != null)
              Text(
                '${WeatherView.degrees(w.high)} / ${WeatherView.degrees(w.low)}',
                style: OmniText.caption,
              ),
          ],
        ),
      ),
    );
  }
}

/// The weather at home: now, the next hour of rain and today's range.
class WeatherPage extends ConsumerWidget {
  const WeatherPage({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thing = _weatherThing(ref, id);
    final w = WeatherView(thing?.state ?? const {});
    String number(double? v, String unit) =>
        v == null ? '-' : '${v.round()}$unit';
    return OmniPage(
      title: thing?.name ?? 'Weather',
      actions: [
        OmniIconAction(
          key: const ValueKey('weather-refresh'),
          icon: OmniIcons.retry,
          label: 'Read the weather again',
          onPressed: () =>
              callEngine(ref, SmartHomeCalls.weatherRefresh, {'id': id}),
        ),
      ],
      body: ListView(
        key: const ValueKey('weather-page'),
        children: [
          if (w.problem != null)
            OmniBanner.info(
              w.problem!,
              key: const ValueKey('weather-problem'),
              actionLabel: ref.watch(homeLocationProvider).value?.isSet == false
                  ? 'Set home location'
                  : null,
              onAction: () => openHomeLocation(context),
            ),
          OmniHeroCard(
            key: const ValueKey('weather-hero'),
            title: WeatherView.degrees(w.temperature),
            subtitle: [
              ?w.condition,
              if (w.feelsLike != null)
                'feels like ${WeatherView.degrees(w.feelsLike)}',
            ].join(', '),
          ),
          const OmniSectionHeader('Next hour'),
          OmniListRow(
            key: const ValueKey('weather-rain'),
            title: w.rainExpected ? 'Rain is likely' : 'Rain is unlikely',
            subtitle:
                '${w.rainChance == null ? '-' : '${w.rainChance!.round()}%'} '
                'chance, ${w.rainMm == null ? '-' : '${w.rainMm} mm'}',
          ),
          const OmniSectionHeader('Today'),
          OmniListRow(
            title: 'High and low',
            value:
                '${WeatherView.degrees(w.high)} / ${WeatherView.degrees(w.low)}',
          ),
          OmniListRow(title: 'Humidity', value: number(w.humidity, '%')),
          OmniListRow(title: 'Wind', value: number(w.wind, ' km/h')),
          OmniListRow(
            title: 'UV index',
            value: w.uv == null ? '-' : w.uv!.toStringAsFixed(1),
          ),
          if (w.updated case final at?)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.md),
              child: Text(
                'Updated ${TimeOfDay.fromDateTime(at.toLocal()).format(context)}. '
                'From Open-Meteo, read every hour near your home.',
                style: OmniText.caption,
              ),
            ),
        ],
      ),
    );
  }
}

/// The Add page's row for the weather at home.
class AddWeatherRow extends ConsumerWidget {
  const AddWeatherRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final existing = _weatherThing(ref);
    return OmniListRow(
      key: const ValueKey('manual-weather'),
      icon: OmniIcons.sun,
      title: 'Weather at home',
      subtitle: existing == null
          ? 'Rain, temperature and UV, for automations'
          : 'Added',
      chevron: existing == null,
      onTap: existing == null
          ? () async {
              final home = await HomeLocationApi(ref.read(engineClientProvider))
                  .read();
              if (home != null && !home.isSet) {
                if (!context.mounted) return;
                showMessage('The weather needs to know where home is first');
                openHomeLocation(context);
                return;
              }
              final r = await callEngine(ref, SmartHomeCalls.weatherAdd);
              if (r['ok'] != true) return;
              ref.invalidate(devicesProvider);
              showMessage('Added the weather at home');
            }
          : () => openWeather(context, existing.id),
    );
  }
}
