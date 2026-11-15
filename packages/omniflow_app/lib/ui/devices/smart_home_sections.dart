import 'package:flutter/material.dart';

import '../../api/engine_calls.dart' show DeviceView;
import '../../api/smart_home_calls.dart';
import '../automations/sun_lighting_page.dart';
import '../design/design.dart';
import '../home/energy_card.dart';
import 'weather_page.dart';

/// What the home helpers add to a device page: "Follow the sun" on a light,
/// today's energy on a plug that reports power, and the weather page on
/// the weather thing.
class DeviceSmartSections extends StatelessWidget {
  const DeviceSmartSections({super.key, required this.device});

  final DeviceView device;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (isSmartLight(device)) FollowSunSwitch(device: device),
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
