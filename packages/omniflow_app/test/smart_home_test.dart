import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/smart_home_calls.dart';
import 'package:omniflow_app/ui/automations/sun_lighting_page.dart';
import 'package:omniflow_app/ui/devices/device_page.dart';
import 'package:omniflow_app/ui/devices/weather_page.dart';
import 'package:omniflow_app/ui/home/energy_card.dart';
import 'package:omniflow_app/ui/settings/away_lighting_page.dart';

import 'fake_engine.dart';
import 'screen_harness.dart';

Map<String, Object?> _weather() => {
  'id': 'weather_at_home',
  'name': 'Weather at home',
  'driver': 'weather',
  'host': '',
  'settings': const <String, Object?>{},
  'state': {
    'temperature': 24.4,
    'feels_like': 26.0,
    'humidity': 60,
    'wind_speed': 9.0,
    'uv_index': 5.0,
    'condition': 'Partly cloudy',
    'rain_expected': true,
    'rain_next_hour': 1.2,
    'rain_chance_next_hour': 70,
    'high_today': 28.0,
    'low_today': 19.0,
    'updated_at': '2026-11-12T09:00:00Z',
  },
  'capabilities': const <Object?>[],
};

Map<String, Object?> _plug() => {
  'id': 'kettle',
  'name': 'Kettle',
  'driver': 'shelly_plus_switch',
  'host': '192.168.1.9',
  'settings': const <String, Object?>{},
  'state': {'output': true, 'apower': 1800.0},
  'capabilities': [
    {'id': 'power', 'type': 'toggle', 'label': 'Power', 'stateKey': 'output'},
  ],
};

Map<String, Object?> _summary() => {
  'ok': true,
  'devices': [
    {
      'id': 'kettle',
      'name': 'Kettle',
      'watts': 1800.0,
      'todayKwh': 0.75,
      'weekKwh': 3.5,
      'todayCost': 6.0,
      'weekCost': 28.0,
      'days': [
        for (var i = 0; i < 7; i++)
          {'date': '2026-11-${(6 + i).toString().padLeft(2, '0')}', 'kwh': 0.5},
      ],
    },
  ],
  'total': {
    'todayKwh': 0.75,
    'weekKwh': 3.5,
    'todayCost': 6.0,
    'weekCost': 28.0,
  },
  'price': {'perKwh': 8.0, 'currency': '₹'},
};

void main() {
  group('reading the replies', () {
    test('weather words for a tile', () {
      expect(
        WeatherView(_weather()['state']! as Map<String, Object?>).line,
        '24° Partly cloudy, rain likely in the next hour',
      );
      expect(
        const WeatherView({'problem': 'Set where home is'}).line,
        'Set where home is',
      );
    });

    test('energy totals, money and kWh', () {
      final s = EnergySummary.of(_summary());
      expect(s.todayLine(), '0.75 kWh today, ₹6.00');
      expect(s.device('kettle')!.days, hasLength(7));
      expect(EnergySummary.kwh(12.34), '12.3 kWh');
      expect(showsEnergy(s), isTrue);
      expect(showsEnergy(EnergySummary.of(const {'ok': true})), isFalse);
    });

    test('away lighting says what it is doing', () {
      final off = AwayLightView.of(const {'enabled': false}, const {});
      expect(off.status, 'Off');
      final waiting = AwayLightView.of(const {
        'enabled': true,
        'lights': ['desk_lamp'],
      }, const {});
      expect(waiting.status, contains('everyone is away'));
    });
  });

  testWidgets('Home cards show weather and energy only when there is some', (
    tester,
  ) async {
    final engine = FakeEngine();
    await pumpScreen(tester, engine, const Scaffold(body: SmartHomeCards()));
    expect(find.byKey(const ValueKey('home-weather')), findsNothing);
    expect(find.byKey(const ValueKey('home-energy')), findsNothing);

    final shown = FakeEngine()
      ..devices = [FakeEngine.lamp(), _weather(), _plug()]
      ..answers['energy.summary'] = _summary();
    await pumpScreen(tester, shown, const Scaffold(body: SmartHomeCards()));
    expect(find.byKey(const ValueKey('home-weather')), findsOneWidget);
    expect(
      find.text('24° Partly cloudy, rain likely in the next hour'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('home-energy')), findsOneWidget);
    expect(find.text('0.75 kWh today, ₹6.00'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-weather')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weather-page')), findsOneWidget);
    expect(find.text('Rain is likely'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('weather-refresh')));
    await tester.pumpAndSettle();
    expect(shown.callsOf('weather.refresh').single.$2, {
      'id': 'weather_at_home',
    });
  });

  testWidgets('a plug page shows today and the week of energy', (tester) async {
    final engine = FakeEngine()
      ..devices = [_plug()]
      ..answers['energy.summary'] = _summary();
    await pumpScreen(tester, engine, const DevicePage(id: 'kettle'));
    expect(find.byKey(const ValueKey('energy-section-kettle')), findsOneWidget);
    expect(find.text('0.75 kWh today'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('3.50 kWh in the last 7 days')),
      findsOneWidget,
    );
  });

  testWidgets('a light page has Follow the sun, which sets the light', (
    tester,
  ) async {
    final engine = FakeEngine()
      ..answers['sunlight.get'] = {'ok': true, 'targets': <Object?>[]};
    await pumpScreen(tester, engine, const DevicePage(id: 'desk_lamp'));
    final row = find.byKey(const ValueKey('follow-sun-desk_lamp'));
    expect(row, findsOneWidget);
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(engine.callsOf('sunlight.set').single.$2, {
      'targets': ['desk_lamp'],
      'enabled': true,
    });
  });

  testWidgets('the sun page draws today and saves a new range', (tester) async {
    final engine = FakeEngine()
      ..answers['sunlight.get'] = {
        'ok': true,
        'targets': [
          {
            'id': 'desk_lamp',
            'kind': 'light',
            'name': 'Desk lamp',
            'minK': 2200,
            'maxK': 5000,
            'minBrightness': 30,
            'maxBrightness': 100,
            'lights': ['desk_lamp'],
          },
        ],
        'curve': {'minK': 2200, 'maxK': 5000},
        'now': {'kelvin': 4000, 'brightness': 80},
        'preview': [
          for (var h = 0; h < 24; h++)
            {
              'at': DateTime(2026, 11, 12, h).toIso8601String(),
              'kelvin': h > 6 && h < 18 ? 4500 : 2200,
              'brightness': h > 6 && h < 18 ? 90 : 30,
            },
        ],
      };
    await pumpScreen(tester, engine, const SunLightingPage());
    expect(find.byKey(const ValueKey('sun-curve')), findsOneWidget);
    expect(find.textContaining('Now: 4000 K'), findsOneWidget);
    final slider = find.descendant(
      of: find.byKey(const ValueKey('sun-kelvin')),
      matching: find.byType(RangeSlider),
    );
    final box = tester.getRect(slider);
    await tester.dragFrom(
      Offset(box.right - 30, box.center.dy),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sun-save')));
    await tester.pumpAndSettle();
    final args = engine.callsOf('sunlight.set').single.$2;
    expect(args['targets'], ['desk_lamp']);
    expect(args['maxK'] as int, lessThan(5000));
  });

  testWidgets('away lighting picks lights and shows tonight', (tester) async {
    final later = DateTime.now().add(const Duration(hours: 2));
    final engine = FakeEngine()
      ..answers['awaylight.get'] = {
        'ok': true,
        'enabled': true,
        'lights': ['desk_lamp'],
        'away': false,
        'running': false,
      }
      ..answers['awaylight.preview'] = {
        'ok': true,
        'actions': [
          {
            'light': 'desk_lamp',
            'name': 'Desk lamp',
            'at': later.toIso8601String(),
            'on': true,
          },
        ],
      };
    await pumpScreen(tester, engine, const AwayLightingPage());
    expect(find.text('Desk lamp on'), findsOneWidget);
    expect(find.textContaining('Starts when everyone is away'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(engine.callsOf('awaylight.set').single.$2, {'lights': <String>[]});
  });

  testWidgets('Add offers the weather at home', (tester) async {
    final engine = FakeEngine();
    await pumpScreen(tester, engine, const Scaffold(body: AddWeatherRow()));
    await tester.tap(find.byKey(const ValueKey('manual-weather')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('weather.add'), hasLength(1));
    expect(find.text('Added the weather at home'), findsOneWidget);
  });
}
