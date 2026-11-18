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
        .watch(engineClientProvider)
        .call(SmartHomeCalls.energySummary, const {});
    return r['ok'] == true ? EnergySummary.of(r) : null;
  } on Object {
    return null;
  }
});

/// Home's weather card and its Energy section, each shown only when there
/// is something to show. On Home the weather sits in front and Energy at
/// the end with the other sections.
class SmartHomeCards extends StatelessWidget {
  const SmartHomeCards({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [WeatherCard(), HomeEnergySection()],
  );
}

/// Whether [summary] has a plug that reports power.
bool showsEnergy(EnergySummary? summary) =>
    summary != null &&
    summary.devices.any((d) => d.watts != null || d.weekKwh > 0);

/// Home's Energy section: today's kWh across the plugs that report power
/// as its summary, each plug's today inside with the week as bars, and a
/// row to the energy page.
class HomeEnergySection extends ConsumerWidget {
  const HomeEnergySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(energySummaryProvider).value;
    if (!showsEnergy(summary)) return const SizedBox.shrink();
    final s = summary!;
    final muted = OmniPalette.of(context).muted;
    return OmniDisclosure(
      key: const ValueKey('home-energy'),
      storageId: 'home-energy',
      icon: OmniIcons.plug,
      title: 'Energy',
      summary: s.todayLine(),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: OmniSpace.sm),
          child: Semantics(
            label: 'The last 7 days of energy',
            child: WeekBars(runs: _weekTotals(s)),
          ),
        ),
        for (final d in s.devices)
          OmniListRow(
            key: ValueKey('home-energy-${d.id}'),
            title: d.name,
            value: EnergySummary.kwh(d.todayKwh),
            valueColor: muted,
          ),
        OmniListRow(
          key: const ValueKey('home-energy-open'),
          icon: OmniIcons.gauge,
          title: 'See all energy',
          subtitle: 'Each plug, the week and the price',
          chevron: true,
          divider: false,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const EnergyPage())),
        ),
      ],
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
                        style: OmniText.captionOf(context),
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
    final read = ref.watch(energySummaryProvider);
    final summary = read.value;
    return DetailPage(
      key: const ValueKey('energy-page'),
      title: 'Energy',
      state: read.hasValue ? const OmniLoad.data() : const OmniLoad.loading(),
      children: (context) => [
        if (summary == null || summary.devices.isEmpty)
          const OmniEmptyState(
            key: ValueKey('energy-none'),
            icon: OmniIcons.plug,
            title: 'No plug reports its power use yet',
            message:
                'Shelly Plus, Shelly Gen1 and Tuya plugs that measure '
                'power show here once read.',
            compact: true,
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
  // The fields are read when Save is tapped, before the sheet's exit ends
  // and these go with it.
  final saved = await SheetTemplate.show<({double? value, String money})>(
    context,
    builder: (sheet) => Owning(
      [price, symbol],
      child: SheetTemplate(
        title: 'Price of one kWh',
        primaryLabel: 'Save',
        primaryKey: const ValueKey('energy-price-save'),
        onPrimary: () => Navigator.of(sheet).pop((
          value: double.tryParse(price.text.trim().replaceAll(',', '.')),
          money: symbol.text.trim(),
        )),
        children: (context) => [
          TextField(
            key: const ValueKey('energy-price-value'),
            controller: price,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Price, such as 8.5'),
          ),
          const SizedBox(height: OmniSpace.md),
          TextField(
            key: const ValueKey('energy-price-currency'),
            controller: symbol,
            decoration: const InputDecoration(
              labelText: 'Money symbol, such as ₹ or \$',
            ),
          ),
        ],
      ),
    ),
  );
  if (saved == null) return;
  final (:value, :money) = saved;
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
