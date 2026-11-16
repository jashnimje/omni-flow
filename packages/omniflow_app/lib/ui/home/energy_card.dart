import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show DeviceView;
import '../../api/smart_home_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../devices/weather_page.dart';
import '../fun/week_bars.dart';

/// How often the energy card reads `energy.summary` again while shown.
const energyRefresh = Duration(minutes: 1);

/// `energy.summary`, read again every [energyRefresh] and when a device is
/// added or removed. A plug's reading moving does not re-read it: power
/// pushes come every few seconds and the totals barely move between them.
/// Null when the engine has no energy commands, as an older hub.
final energySummaryProvider = FutureProvider.autoDispose<EnergySummary?>((
  ref,
) async {
  ref.listen(
    devicesProvider.select((v) => v.value?.map((d) => d['id']).join(',')),
    (before, now) {
      // Not when the list first loads: that read is this one.
      if (before != null && before != now) ref.invalidateSelf();
    },
  );
  final again = Timer(energyRefresh, ref.invalidateSelf);
  ref.onDispose(again.cancel);
  try {
    final r = await ref
        .read(engineClientProvider)
        .call(SmartHomeCalls.energySummary, const {});
    return r['ok'] == true ? EnergySummary.of(r) : null;
  } on Object {
    return null;
  }
});

/// Home's weather and energy cards, each shown only when there is
/// something to show.
class SmartHomeCards extends StatelessWidget {
  const SmartHomeCards({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [WeatherCard(), EnergyCard()],
  );
}

/// Whether [summary] has a plug that reports power.
bool showsEnergy(EnergySummary? summary) =>
    summary != null &&
    summary.devices.any((d) => d.watts != null || d.weekKwh > 0);

/// Today's kWh across the plugs that report power, the top user, and the
/// week as bars. A tap opens the energy page.
class EnergyCard extends ConsumerWidget {
  const EnergyCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(energySummaryProvider).value;
    if (!showsEnergy(summary)) return const SizedBox.shrink();
    final s = summary!;
    final top = s.devices.first;
    final week = _weekTotals(s);
    return OmniCard(
      key: const ValueKey('home-energy'),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const EnergyPage())),
      child: Semantics(
        button: true,
        label:
            'Energy: ${s.todayLine()}. Most used by ${top.name}, '
            '${EnergySummary.kwh(top.todayKwh)}',
        hint: 'Opens Energy',
        excludeSemantics: true,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Energy', style: OmniText.caption),
                  const SizedBox(height: 2),
                  Text(s.todayLine(), style: OmniText.bodyStrong),
                  Text(
                    'Most: ${top.name}, ${EnergySummary.kwh(top.todayKwh)}',
                    style: OmniText.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(width: OmniSpace.md),
            WeekBars(runs: week),
          ],
        ),
      ),
    );
  }
}

/// Each day's total in watt-hours, oldest first, for the bars.
List<int> _weekTotals(EnergySummary s) {
  final days = s.devices.isEmpty ? 0 : s.devices.first.days.length;
  return [
    for (var i = 0; i < days; i++)
      (s.devices.fold(
                0.0,
                (sum, d) => sum + (i < d.days.length ? d.days[i].kwh : 0),
              ) *
              1000)
          .round(),
  ];
}

const _dayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

List<String> _labels(List<EnergyDay> days) => [
  for (final d in days)
    switch (DateTime.tryParse(d.date)) {
      final at? => _dayLetters[at.weekday - 1],
      null => '',
    },
];

/// Today's kWh and the last 7 days for one plug, on its device page.
class EnergySection extends ConsumerWidget {
  const EnergySection({super.key, required this.device});

  final DeviceView device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(energySummaryProvider).value;
    final row = summary?.device(device.id);
    if (row == null) return const SizedBox.shrink();
    final bars = [for (final d in row.days) (d.kwh * 1000).round()];
    final cost = summary!.money(row.todayCost);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OmniSectionHeader('Energy'),
        OmniCard(
          key: ValueKey('energy-section-${device.id}'),
          child: Semantics(
            label:
                '${EnergySummary.kwh(row.todayKwh)} today'
                '${cost == null ? '' : ', $cost'}. '
                '${EnergySummary.kwh(row.weekKwh)} in the last 7 days'
                '${row.watts == null ? '' : '. Using ${row.watts!.round()} watts now'}',
            excludeSemantics: true,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${EnergySummary.kwh(row.todayKwh)} today',
                        style: OmniText.bodyStrong,
                      ),
                      Text(
                        [
                          ?cost,
                          '${EnergySummary.kwh(row.weekKwh)} this week',
                          if (row.watts != null) '${row.watts!.round()} W now',
                        ].join(' · '),
                        style: OmniText.caption,
                      ),
                    ],
                  ),
                ),
                WeekBars(
                  runs: bars,
                  height: 40,
                  barWidth: 8,
                  labels: _labels(row.days),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Every plug that reports power, with today and the week, and the price.
class EnergyPage extends ConsumerWidget {
  const EnergyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(energySummaryProvider).value;
    return OmniPage(
      title: 'Energy',
      body: ListView(
        key: const ValueKey('energy-page'),
        children: [
          if (summary == null || summary.devices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: OmniSpace.md),
              child: Text(
                'No plug reports its power use yet. Shelly Plus, Shelly Gen1 '
                'and Tuya plugs that measure power show here once read.',
                style: OmniText.caption,
              ),
            )
          else ...[
            OmniHeroCard(
              title: summary.todayLine(),
              subtitle:
                  '${EnergySummary.kwh(summary.weekKwh)} in the last 7 days'
                  '${summary.money(summary.weekCost) == null ? '' : ', ${summary.money(summary.weekCost)}'}',
            ),
            const OmniSectionHeader('By plug'),
            for (final d in summary.devices)
              OmniListRow(
                key: ValueKey('energy-row-${d.id}'),
                icon: OmniIcons.plug,
                title: d.name,
                subtitle: [
                  '${EnergySummary.kwh(d.weekKwh)} this week',
                  if (d.watts != null) '${d.watts!.round()} W now',
                ].join(' · '),
                value: EnergySummary.kwh(d.todayKwh),
              ),
          ],
          const OmniSectionHeader('Price'),
          OmniListRow(
            key: const ValueKey('energy-price'),
            icon: OmniIcons.edit,
            title: 'Price of one kWh',
            subtitle: summary?.perKwh == null
                ? 'Set it to see what your plugs cost'
                : summary!.money(summary.perKwh),
            chevron: true,
            onTap: () => editEnergyPrice(context, ref, summary),
          ),
        ],
      ),
    );
  }
}

/// Asks for the price of one kWh and its money symbol, and saves them.
Future<void> editEnergyPrice(
  BuildContext context,
  WidgetRef ref,
  EnergySummary? summary,
) async {
  final price = TextEditingController(
    text: summary?.perKwh == null ? '' : '${summary!.perKwh}',
  );
  final symbol = TextEditingController(text: summary?.currency ?? '');
  final saved = await showDialog<bool>(
    context: context,
    // The fields are read below, before the dialog's exit ends and these
    // go with it.
    builder: (context) => Owning(
      [price, symbol],
      child: AlertDialog(
        title: const Text('Price of one kWh'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('energy-price-value'),
              controller: price,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Price, such as 8.5',
              ),
            ),
            TextField(
              key: const ValueKey('energy-price-currency'),
              controller: symbol,
              decoration: const InputDecoration(
                labelText: 'Money symbol, such as ₹ or \$',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('energy-price-save'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  final value = double.tryParse(price.text.trim().replaceAll(',', '.'));
  final money = symbol.text.trim();
  if (saved != true) return;
  final r = await callEngine(
    ref,
    SmartHomeCalls.energyPriceSet,
    SmartHomeCalls.priceArgs(value, money),
  );
  if (r['ok'] == true) ref.invalidate(energySummaryProvider);
}

/// Whether [d]'s driver reports power.
bool reportsEnergy(DeviceView d) =>
    SmartHomeCalls.energyDrivers.contains(d.driver);
