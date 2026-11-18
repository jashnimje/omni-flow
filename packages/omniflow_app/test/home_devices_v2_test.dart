import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/devices/device_sections.dart';
import 'package:omniflow_app/ui/devices/open_device.dart';
import 'package:omniflow_app/ui/devices/weather_page.dart';

import 'fake_engine.dart';
import 'home_devices_test.dart' show bulb, household, lamp, phone, sensor;
import 'screen_harness.dart';
import 'tv_fixtures.dart';

/// Design v2, batch 1: what Home, the device pages, the light page and
/// the TV put in front, and what waits in a collapsed section.

String _at(int minutesAgo) => DateTime.now()
    .subtract(Duration(minutes: minutesAgo))
    .toUtc()
    .toIso8601String();

/// A history with one change in plain words and two without: a key no
/// capability names, and an empty value.
Map<String, Object?> _history(String plainKey, Object plainValue) => {
  'ok': true,
  'entries': [
    {'at': _at(1), 'key': plainKey, 'value': plainValue, 'by': 'user'},
    {'at': _at(2), 'key': 'sceneId', 'value': 0, 'by': 'user'},
    {'at': _at(3), 'key': 'dimming', 'value': null, 'by': 'user'},
  ],
};

Map<String, Object?> _plug() => {
  'id': 'kettle',
  'name': 'Kettle',
  'driver': 'shelly_plus_switch',
  'host': '192.168.1.9',
  'settings': const <String, Object?>{},
  'state': {'output': true},
  'capabilities': [
    {'id': 'power', 'type': 'toggle', 'label': 'Power', 'stateKey': 'output'},
  ],
};

Map<String, Object?> _weather() => {
  'id': 'weather_at_home',
  'name': 'Weather at home',
  'driver': 'weather',
  'host': '',
  'settings': const <String, Object?>{},
  'state': {'temperature': 24.4, 'condition': 'Partly cloudy'},
  'capabilities': const <Object?>[],
};

/// A colour bulb with white, colour and effects, as a WiZ lists one.
Map<String, Object?> colourBulb() => FakeEngine.lamp(
  state: const {'state': true, 'dimming': 60, 'temp': 2700},
  extra: [
    {
      'id': 'color_temp',
      'type': 'color_temp',
      'label': 'White temperature',
      'stateKey': 'temp',
      'params': {
        'value': {'type': 'number', 'min': 2200, 'max': 6500, 'unit': 'K'},
      },
    },
    {
      'id': 'rgb',
      'type': 'color_rgb',
      'label': 'Colour',
      'params': {
        'r': {'type': 'number', 'min': 0, 'max': 255},
        'g': {'type': 'number', 'min': 0, 'max': 255},
        'b': {'type': 'number', 'min': 0, 'max': 255},
      },
    },
    {
      'id': 'scene',
      'type': 'action',
      'label': 'Scene',
      'params': {
        'scene': {
          'type': 'string',
          'choices': [
            {
              'value': 'ocean',
              'label': 'Ocean',
              'group': 'dynamic',
              'groupLabel': 'Dynamic',
              'icon': 'waves',
            },
          ],
        },
      },
    },
  ],
);

bool _open(WidgetTester tester, String key) =>
    tester
        .widget<Semantics>(
          find
              .descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byWidgetPredicate(
                  (w) => w is Semantics && w.properties.expanded != null,
                ),
              )
              .first,
        )
        .properties
        .expanded ??
    false;

/// Activity is there, below [above], closed on first open. Opened, it
/// lists [plain] (or says nothing happened) and none of [hidden].
Future<void> _expectActivity(
  WidgetTester tester,
  String id, {
  required Finder above,
  String? plain,
  List<String> hidden = const ['sceneId', 'null', 'dimming'],
}) async {
  final section = find.byKey(ValueKey('device-activity-$id'));
  expect(section, findsOneWidget);
  expect(_open(tester, 'device-activity-$id'), isFalse);
  expect(find.byKey(ValueKey('activity-$id-0')), findsNothing);
  expect(
    tester.getTopLeft(section).dy,
    greaterThan(tester.getBottomLeft(above.first).dy),
    reason: 'Activity sits below the controls',
  );
  await openSectionKey(tester, 'device-activity-$id');
  if (plain == null) {
    expect(find.byKey(ValueKey('activity-none-$id')), findsOneWidget);
  } else {
    expect(
      find.descendant(of: section, matching: find.text(plain)),
      findsOneWidget,
    );
  }
  for (final h in hidden) {
    expect(
      find.descendant(of: section, matching: find.textContaining(h)),
      findsNothing,
      reason: h,
    );
  }
}

Future<void> _pumpDevice(WidgetTester tester, FakeEngine engine, String id) =>
    pumpScreen(
      tester,
      engine,
      DeviceRoute(id: id),
      overrides: [
        phoneFilesProvider.overrideWithValue(FakePhoneFiles()),
        tvPollProvider.overrideWithValue(const Duration(hours: 1)),
      ],
    );

void main() {
  group('every device page keeps its history collapsed, in plain words', () {
    testWidgets('a light', (tester) async {
      final engine = FakeEngine()
        ..devices = [lamp()]
        ..answers['device.history'] = _history('state', true);
      await _pumpDevice(tester, engine, 'desk_lamp');
      await _expectActivity(
        tester,
        'desk_lamp',
        above: find.byKey(const ValueKey('slider-desk_lamp.brightness')),
        plain: 'Turned on by you',
      );
      // The raw changes are under More settings, Developer details.
      expect(find.textContaining('sceneId'), findsNothing);
      await openSectionKey(tester, 'device-more-desk_lamp');
      await openSectionKey(tester, 'device-advanced');
      expect(find.textContaining('sceneId 0'), findsOneWidget);
    });

    testWidgets('a plug', (tester) async {
      final engine = FakeEngine()
        ..devices = [_plug()]
        ..answers['device.history'] = _history('output', false);
      await _pumpDevice(tester, engine, 'kettle');
      await _expectActivity(
        tester,
        'kettle',
        above: find.byKey(const ValueKey('device-hero-kettle')),
        plain: 'Turned off by you',
      );
    });

    testWidgets('a sensor, with its day chart inside Activity', (tester) async {
      final engine = FakeEngine()
        ..devices = [sensor()]
        ..answers['device.history'] = _history('value', 21.5);
      await _pumpDevice(tester, engine, 'room_temp');
      expect(
        find.byKey(const ValueKey('sensor-chart-room_temp')),
        findsNothing,
      );
      await _expectActivity(
        tester,
        'room_temp',
        above: find.byKey(const ValueKey('sensor-automate-room_temp')),
        plain: 'Value 21.5 by you',
      );
    });

    testWidgets('a phone', (tester) async {
      final engine = FakeEngine()
        ..devices = [phone()]
        ..answers['device.history'] = _history('battery', 70);
      await _pumpDevice(tester, engine, 'this_phone');
      // No capability names battery, so nothing reads in plain words.
      await _expectActivity(
        tester,
        'this_phone',
        above: find.byKey(const ValueKey('device-hero-this_phone')),
        hidden: const ['battery', 'sceneId', 'null'],
      );
    });

    testWidgets('the weather', (tester) async {
      final engine = FakeEngine()
        ..devices = [_weather()]
        ..answers['device.history'] = _history('temperature', 24);
      await pumpScreen(
        tester,
        engine,
        const WeatherPage(id: 'weather_at_home'),
      );
      await _expectActivity(
        tester,
        'weather_at_home',
        above: find.byKey(const ValueKey('weather-rain')),
        hidden: const ['temperature', 'sceneId', 'null'],
      );
    });

    testWidgets('a TV, under its remote', (tester) async {
      final engine = tvEngine()
        ..answers['device.history'] = _history('power', 'on');
      await _pumpDevice(tester, engine, tvId);
      await _expectActivity(
        tester,
        tvId,
        above: find.byKey(const ValueKey('key-24')),
        hidden: const ['power', 'sceneId', 'null'],
      );
    });

    testWidgets('an offline device keeps Try again in front and the three '
        'sections under it', (tester) async {
      final engine = FakeEngine()
        ..devices = [bulb()]
        ..answers['device.history'] = _history('state', false);
      await _pumpDevice(tester, engine, 'hall_bulb');
      expect(find.byKey(const ValueKey('device-retry')), findsOneWidget);
      expect(find.byKey(const ValueKey('device-find')), findsOneWidget);
      for (final s in ['automations', 'activity', 'more']) {
        final key = 'device-$s-hall_bulb';
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: s);
        expect(_open(tester, key), isFalse, reason: s);
      }
      await _expectActivity(
        tester,
        'hall_bulb',
        above: find.byKey(const ValueKey('device-find')),
        plain: 'Turned off by you',
      );
    });
  });

  group('the plain words of a change', () {
    final d = DeviceView(colourBulb());
    HistoryEntry e(String key, Object? value, {String? by}) => HistoryEntry(
      at: DateTime(2026, 11, 19, 14, 43),
      key: key,
      value: value,
      by: by,
    );

    test('say what happened, then who, by name', () {
      String? words(HistoryEntry x) =>
          DeviceActivitySection.plain(x, d, const {'r1': 'Good night'});
      expect(words(e('state', true, by: 'user')), 'Turned on by you');
      expect(words(e('state', false, by: 'r1')), 'Turned off by Good night');
      expect(words(e('dimming', 60, by: 'user')), 'Brightness 60% by you');
      expect(words(e('temp', 2700)), 'Warmth 2700 K');
      // An id nobody named is left out, never shown.
      expect(words(e('state', true, by: 'rule_7')), 'Turned on');
    });

    test('leave out a key no capability names and an empty value', () {
      expect(DeviceActivitySection.plain(e('sceneId', 0), d, const {}), null);
      expect(
        DeviceActivitySection.plain(e('dimming', null), d, const {}),
        null,
      );
    });

    test('count today only in the summary', () {
      final now = DateTime(2026, 11, 19, 18);
      HistoryEntry on(DateTime at) =>
          HistoryEntry(at: at, key: 'state', value: true);
      expect(DeviceActivitySection.summaryOf(const []), 'Nothing yet');
      expect(
        DeviceActivitySection.summaryOf([
          on(DateTime(2026, 11, 19, 9)),
          on(DateTime(2026, 11, 19, 10)),
          on(DateTime(2026, 11, 18, 23)),
        ], now: now),
        '2 changes today',
      );
      expect(
        DeviceActivitySection.summaryOf([
          on(DateTime(2026, 11, 18, 23)),
        ], now: now),
        'Nothing today',
      );
    });
  });

  group('the light page', () {
    testWidgets('White, Colour and Effects are one switch between '
        'Brightness and Warmth, with four named whites', (tester) async {
      final engine = FakeEngine()..devices = [colourBulb()];
      await _pumpDevice(tester, engine, 'desk_lamp');
      final modes = find.byKey(const ValueKey('light-mode-desk_lamp'));
      expect(modes, findsOneWidget);
      for (final label in ['White', 'Colour', 'Effects']) {
        expect(
          find.descendant(of: modes, matching: find.text(label)),
          findsOneWidget,
        );
      }
      final brightness = find.byKey(
        const ValueKey('slider-desk_lamp.brightness'),
      );
      final warmth = find.byKey(const ValueKey('slider-desk_lamp.color_temp'));
      expect(
        tester.getTopLeft(modes).dy,
        greaterThan(tester.getTopLeft(brightness).dy),
      );
      expect(
        tester.getTopLeft(warmth).dy,
        greaterThan(tester.getTopLeft(modes).dy),
      );
      for (final name in ['Candle', 'Warm', 'Neutral', 'Daylight']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('Cool'), findsNothing);
    });
  });

  group('Home', () {
    testWidgets('Add is a + in the top bar, and nothing floats', (
      tester,
    ) async {
      await pumpApp(tester, household());
      final add = find.byKey(const ValueKey('add-device'));
      expect(add, findsOneWidget);
      expect(tester.widget(add), isA<OmniIconAction>());
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('with nothing starred Favourites keeps Edit and no hint', (
      tester,
    ) async {
      final engine = FakeEngine()
        ..devices = [
          {...lamp(), 'favourite': false},
        ];
      await pumpApp(tester, engine);
      expect(find.text('Favourites'), findsOneWidget);
      expect(find.textContaining('Star a device'), findsNothing);
      expect(find.byKey(const ValueKey('chip-tv-lounge_tv')), findsNothing);
    });

    testWidgets('Activity and Energy wait in sections at the end', (
      tester,
    ) async {
      final engine = household()
        ..answers['energy.summary'] = {
          'ok': true,
          'devices': [
            {
              'id': 'kettle',
              'name': 'Kettle',
              'todayKwh': 0.75,
              'weekKwh': 3.5,
              'watts': 1800,
              'days': const <Object?>[],
            },
          ],
        };
      await pumpApp(tester, engine);
      final activity = find.byKey(const ValueKey('home-activity'));
      final energy = find.byKey(const ValueKey('home-energy'));
      await tester.ensureVisible(activity);
      expect(_open(tester, 'home-activity'), isFalse);
      expect(
        tester.getTopLeft(activity).dy,
        greaterThan(tester.getTopLeft(find.text('Favourites')).dy),
      );
      expect(find.byKey(const ValueKey('home-energy-kettle')), findsNothing);
      await openSectionKey(tester, 'home-energy');
      expect(energy, findsOneWidget);
      expect(find.byKey(const ValueKey('home-energy-kettle')), findsOneWidget);
    });

    testWidgets('above 130% text the tiles are one a row', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpApp(tester, household());
      final width = tester
          .getSize(find.byKey(const ValueKey('home-list')))
          .width;
      final tile = tester.getSize(
        find.byKey(const ValueKey('tile-desk_lamp')).first,
      );
      expect(tile.width, greaterThan(width * 0.8));
    });
  });

  group('Devices', () {
    testWidgets('more than one device not answering folds into one section '
        'at the end', (tester) async {
      final engine = FakeEngine()
        ..devices = [
          lamp(),
          bulb(),
          {...bulb(), 'id': 'porch', 'name': 'Porch light'},
        ];
      await pumpApp(tester, engine);
      await openTab(tester, 'Devices');
      final section = find.byKey(const ValueKey('devices-not-answering'));
      expect(section, findsOneWidget);
      expect(find.text('2 devices'), findsOneWidget);
      expect(find.byKey(const ValueKey('device-row-hall_bulb')), findsNothing);
      expect(
        tester.getTopLeft(section).dy,
        greaterThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('device-row-desk_lamp')))
              .dy,
        ),
      );
      await openSectionKey(tester, 'devices-not-answering');
      expect(
        find.byKey(const ValueKey('device-row-hall_bulb')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('device-row-porch')), findsOneWidget);
    });

    testWidgets('one device not answering stays in view at the end', (
      tester,
    ) async {
      final engine = FakeEngine()..devices = [lamp(), bulb()];
      await pumpApp(tester, engine);
      await openTab(tester, 'Devices');
      expect(find.byKey(const ValueKey('devices-not-answering')), findsNothing);
      expect(find.text('Not answering'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('device-row-hall_bulb')),
        findsOneWidget,
      );
    });

    testWidgets('Add is a + in the top bar', (tester) async {
      await pumpApp(tester, household());
      await openTab(tester, 'Devices');
      expect(find.byKey(const ValueKey('devices-add')), findsOneWidget);
    });
  });

  group('the TV', () {
    testWidgets('the remote is in front, More buttons and TV tools are '
        'collapsed, and a tool opens as its own page', (tester) async {
      final engine = tvEngine();
      await pumpTv(tester, engine);
      for (final code in [19, 20, 21, 22, 23, 4, 3, 164, 25, 85, 24]) {
        expect(find.byKey(ValueKey('key-$code')), findsOneWidget);
      }
      expect(_open(tester, 'tv-more-buttons'), isFalse);
      expect(_open(tester, 'tv-tools'), isFalse);
      expect(find.byKey(const ValueKey('key-8')), findsNothing);
      expect(find.byKey(const ValueKey('tv-more-system')), findsNothing);
      await openSectionKey(tester, 'tv-more-buttons');
      expect(find.byKey(const ValueKey('key-8')), findsOneWidget);
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('tv-tools')),
        find.byKey(const ValueKey('tv-remote')),
        const Offset(0, -300),
      );
      await openSectionKey(tester, 'tv-tools');
      for (final t in ['system', 'files', 'settings', 'console']) {
        expect(find.byKey(ValueKey('tv-more-$t')), findsOneWidget, reason: t);
      }
      expect(find.text('TV settings'), findsOneWidget);
      await openTvTab(tester, 'Console');
      expect(find.byKey(const ValueKey('tv-tool-console')), findsOneWidget);
      // The live header comes along.
      expect(find.byKey(const ValueKey('tv-volume')), findsOneWidget);
    });
  });

  group('at 200% text nothing overflows', () {
    testWidgets('the light page, open', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final engine = FakeEngine()
        ..devices = [colourBulb()]
        ..answers['device.history'] = _history('state', true);
      await _pumpDevice(tester, engine, 'desk_lamp');
      await openSectionKey(tester, 'device-activity-desk_lamp');
      await openSectionKey(tester, 'device-more-desk_lamp');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the TV remote and its sections', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpTv(tester, tvEngine());
      await openSectionKey(tester, 'tv-more-buttons');
      expect(tester.takeException(), isNull);
    });
  });
}
