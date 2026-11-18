import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../automations/automations.dart';
import '../design/design.dart';
import '../home/home_data.dart';
import 'device_sections.dart';
import 'device_text.dart';
import 'open_device.dart' show DeviceGone;

/// The last 24 hours of a sensor's first reading key, oldest first.
final sensorDayProvider =
    FutureProvider.family<List<HistoryEntry>, ({String id, String key})>((
      ref,
      arg,
    ) async {
      final since = DateTime.now().subtract(const Duration(hours: 24));
      final reply = await ref
          .watch(engineApiProvider)
          .history(arg.id, key: arg.key, limit: 500, since: since);
      return reply.or(const []).reversed.toList();
    });

/// 3.3: a thing that only reports. Its reading with the unit and age, a
/// 24 hour chart with the low and high and a way to start an automation
/// from it in front, then the collapsed sections every device page has.
class SensorPage extends ConsumerWidget {
  const SensorPage({super.key, required this.id});

  final String id;

  static String? _readingKey(DeviceView d) => d.capabilities
      .where((c) => c['type'] == 'sensor' && c['stateKey'] is String)
      .map((c) => c['stateKey'] as String)
      .where((k) => d.state[k] is num)
      .followedBy(
        d.capabilities
            .where((c) => c['type'] == 'sensor' && c['stateKey'] is String)
            .map((c) => c['stateKey'] as String),
      )
      .firstOrNull;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = liveDevice(ref, id);
    if (d == null) {
      return DeviceGone(loading: ref.watch(devicesProvider).isLoading);
    }
    final key = _readingKey(d);
    if (key != null) {
      ref.listen(
        devicesProvider.select(
          (v) => v.value?.where((j) => j['id'] == id).firstOrNull?['state'],
        ),
        (_, _) => ref.invalidate(sensorDayProvider((id: id, key: key))),
      );
    }
    final drivers = ref.watch(driversProvider).value ?? const {};
    final driver = shortDriverName(drivers[d.driver], d.driver);
    final day = key == null
        ? const <HistoryEntry>[]
        : ref.watch(sensorDayProvider((id: id, key: key))).value ?? const [];
    final values = [
      for (final e in day)
        if (e.value is num) (e.value as num).toDouble(),
    ];
    final updated = d.lastSeen == null ? null : 'updated ${ago(d.lastSeen!)}';
    // The day's chart is history, so it sits in Activity with the rest.
    final sections = deviceSections(
      ref,
      d,
      activityTop: Padding(
        padding: const EdgeInsets.symmetric(vertical: OmniSpace.sm),
        child: values.length < 2
            ? Text(
                'The chart fills in as readings arrive',
                key: ValueKey('sensor-chart-empty-$id'),
                style: OmniText.captionOf(context),
              )
            : DayChart(key: ValueKey('sensor-chart-$id'), values: values),
      ),
    );
    return DetailPage(
      key: ValueKey('sensor-page-$id'),
      title: d.name,
      actions: [
        FavouriteStar(device: d),
        DeviceMenu(device: d, onRemove: () => removeDevice(context, ref, d)),
      ],
      banners: [if (!d.online) OfflineHelp(device: d)],
      hero: OmniHeroCard(
        key: ValueKey('sensor-hero-$id'),
        title: sensorReading(d) ?? 'No reading yet',
        subtitle: [driver, ?updated].join(' · '),
        tone: d.online ? HeroTone.accent : HeroTone.plain,
        footer: values.length < 2
            ? null
            : 'Last 24 h · low ${_one(values.reduce(_min))} · '
                  'high ${_one(values.reduce(_max))}',
      ),
      children: (context) => [
        OmniButton.ghost(
          key: ValueKey('sensor-automate-$id'),
          label: 'Make an automation from this',
          icon: OmniIcons.add,
          onPressed: () => openRuleEditor(
            context,
            spec: key == null
                ? null
                : {
                    'name': '',
                    'when': [
                      {
                        'on': '$id.$key',
                        'crosses': {
                          'above': switch (d.state[key]) {
                            final num v => v.round(),
                            _ => 0,
                          },
                        },
                      },
                    ],
                    'then': const <Object?>[],
                  },
          ),
        ),
      ],
      sections: (_) => sections,
    );
  }

  static double _min(double a, double b) => a < b ? a : b;
  static double _max(double a, double b) => a > b ? a : b;
  static String _one(double v) => v.toStringAsFixed(1);
}

/// Up to 24 bars of a day's readings, each the average of its share.
class DayChart extends StatelessWidget {
  const DayChart({super.key, required this.values});

  final List<double> values;

  static List<double> bars(List<double> values, {int count = 24}) {
    if (values.length <= count) return values;
    final out = <double>[];
    for (var i = 0; i < count; i++) {
      final start = i * values.length ~/ count;
      final end = (i + 1) * values.length ~/ count;
      final slice = values.sublist(start, end);
      out.add(slice.reduce((a, b) => a + b) / slice.length);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final shown = bars(values);
    final low = shown.reduce((a, b) => a < b ? a : b);
    final high = shown.reduce((a, b) => a > b ? a : b);
    final span = high - low;
    return Semantics(
      label: 'Chart of the last 24 hours',
      child: SizedBox(
        height: 54,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final v in shown)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: FractionallySizedBox(
                    heightFactor: span == 0
                        ? 0.6
                        : 0.25 + 0.75 * (v - low) / span,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: OmniPalette.of(context).accentLine,
                        borderRadius: BorderRadius.circular(OmniShape.xs),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
