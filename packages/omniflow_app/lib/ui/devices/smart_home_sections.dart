import 'package:flutter/material.dart';

import '../../api/engine_calls.dart' show DeviceView;
import '../../api/smart_home_calls.dart';
import '../design/design.dart';
import '../home/energy_card.dart';
import 'weather_page.dart';

/// What the home helpers add in front on a device page: today's energy on
/// a plug that reports power, and the weather page on the weather thing.
/// "Follow the sun" on a light sits in its More settings.
class DeviceSmartSections extends StatelessWidget {
  const DeviceSmartSections({super.key, required this.device});

  final DeviceView device;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (reportsEnergy(device)) EnergySection(device: device),
      if (device.driver == SmartHomeCalls.weatherDriver)
        OmniListRow(
          key: ValueKey('open-weather-${device.id}'),
          icon: OmniIcons.sun,
          title: 'The weather',
          subtitle: WeatherView(device.state).line,
          chevron: true,
          onTap: () => openWeather(context, device.id),
        ),
    ],
  );
}
