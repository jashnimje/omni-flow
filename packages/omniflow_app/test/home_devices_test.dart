import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/devices/device_page.dart';
import 'package:omniflow_app/ui/devices/sensor_page.dart';
import 'package:omniflow_app/ui/home/first_run.dart';
import 'package:omniflow_app/ui/home/home_data.dart';
import 'package:omniflow_app/ui/settings/developer_page.dart';
import 'package:omniflow_app/ui/settings/phone_access.dart';
import 'package:omniflow_app/ui/settings/places_page.dart';
import 'package:omniflow_app/ui/settings/rooms_page.dart';
import 'package:omniflow_app/ui/tv/tv_page.dart';

import 'fake_engine.dart';

/// Home, Devices, the device and sensor pages, search and Settings, with
/// a household of a lamp, a TV, an offline bulb, a sensor, a phone and a
/// person.

Map<String, Object?> lamp() => {
  ...FakeEngine.lamp(state: const {'state': true, 'dimming': 80}),
  'roomId': 'study',
  'room': 'Study',
  'favourite': true,
  'online': true,
};

Map<String, Object?> tv({String power = 'on'}) => {
  'id': 'lounge_tv',
  'name': 'Lounge TV',
  'driver': 'android_tv_adb',
  'host': '192.168.1.60',
  'roomId': 'lounge',
  'room': 'Lounge',
  'favourite': false,
  'state': {
    'power': power,
    'app': 'com.netflix.ninja',
    'playing': 'playing',
    'volume': 35,
  },
  'capabilities': [
    {'id': 'wake', 'type': 'action', 'label': 'Wake', 'params': {}},
  ],
};

Map<String, Object?> bulb() => {
  ...FakeEngine.lamp(state: const {'state': false}),
  'id': 'hall_bulb',
  'name': 'Hall bulb',
  'host': '192.168.1.41',
  'roomId': 'hall',
  'room': 'Hall',
  'favourite': false,
  'online': false,
  'lastSeen': '2026-11-08T18:20:00',
};

Map<String, Object?> sensor() => {
  'id': 'room_temp',
  'name': 'Room temperature',
  'driver': 'mqtt_sensor',
  'roomId': 'study',
  'room': 'Study',
  'favourite': false,
  'state': {'value': 24.5, 'unit': '°C'},
  'capabilities': [
    {'id': 'value', 'type': 'sensor', 'label': 'Value', 'stateKey': 'value'},
  ],
};

Map<String, Object?> person({bool home = true}) => {
  'id': 'jade',
  'name': 'Jade',
  'driver': 'person',
  'state': {
    'home': home,
    'homeSource': 'wifi',
    'homeSince': '2026-11-08T13:31:00Z',
  },
  'capabilities': const <Object?>[],
};

Map<String, Object?> phone() => {
  'id': 'this_phone',
  'name': 'This phone',
  'driver': 'phone',
  'state': {'wifi_ssid': 'HomeWiFi', 'battery': 74},
  'capabilities': const <Object?>[],
};

FakeEngine household() {
  final engine = FakeEngine()
    ..devices = [lamp(), tv(), bulb(), sensor(), person(), phone()];
  engine.answers.addAll({
    'room.list': {
      'ok': true,
      'rooms': [
        {'id': 'lounge', 'name': 'Lounge', 'order': 0, 'deviceCount': 1},
        {'id': 'study', 'name': 'Study', 'order': 1, 'deviceCount': 2},
        {'id': 'hall', 'name': 'Hall', 'order': 2, 'deviceCount': 1},
      ],
    },
    'driver.list': {
      'ok': true,
      'drivers': [
        {
          'id': 'philips_wiz_udp',
          'name': 'Philips WiZ Light (local UDP)',
          'category': 'lighting',
          'transport': 'udp',
          'builtIn': true,
        },
        {
          'id': 'mqtt_sensor',
          'name': 'MQTT sensor (any topic)',
          'category': 'sensor',
          'transport': 'mqtt',
          'builtIn': true,
        },
      ],
    },
    'scene.list': {
      'ok': true,
      'scenes': [
        {
          'id': 'movie',
          'name': 'Movie',
          'icon': 'movie',
          'actions': [
            {
              'do': 'desk_lamp.power',
              'params': {'value': false},
            },
          ],
        },
      ],
    },
    'automation.list': {
      'ok': true,
      'automations': [
        {
          'id': 'desk_button',
          'name': 'Desk button',
          'source': 'link',
          'enabled': true,
          'approved': true,
          'sentence': [
            {'kind': 'when', 'text': 'When desk button is pressed'},
            {'kind': 'text', 'text': '→'},
            {'kind': 'then', 'text': 'toggle desk lamp'},
          ],
          'devices': ['desk_lamp'],
        },
        {
          'id': 'movie_night',
          'name': 'Movie night',
          'source': 'rule',
          'enabled': true,
          'approved': false,
          'needsApproval': true,
          'sentence': const <Object?>[],
          'devices': const <Object?>[],
        },
      ],
    },
    'device.history': {
      'ok': true,
      'entries': [
        {
          'at': '2026-11-08T13:32:00Z',
          'key': 'state',
          'value': true,
          'by': 'desk_button',
        },
        {
          'at': '2026-11-08T12:40:00Z',
          'key': 'state',
          'value': false,
          'by': 'user',
        },
      ],
    },
  });
  return engine;
}

class FakeAccess implements PhoneAccess {
  FakeAccess(this.state);

  PhoneAccessState state;
  final asked = <String>[];

  @override
  Future<PhoneAccessState> read() async => state;

  @override
  Future<bool> askLocalNetwork() async {
    asked.add('localNetwork');
    return true;
  }

  @override
  Future<bool> askLocation() async {
    asked.add('location');
    return true;
  }

  @override
  Future<bool> askLocationAlways() async {
    asked.add('locationAlways');
    return true;
  }

  @override
  Future<bool> askNotifications() async {
    asked.add('notifications');
    return true;
  }

  @override
  Future<bool> fixBattery() async {
    asked.add('battery');
    state = const PhoneAccessState(batteryUnrestricted: true, running: true);
    return true;
  }

  @override
  Future<void> openAppSettings() async => asked.add('settings');
}

class FakeFirstRun implements FirstRunStore {
  FakeFirstRun(this.isDone);

  bool isDone;

  @override
  Future<bool> done() async => isDone;

  @override
  Future<void> markDone() async => isDone = true;
}

Future<void> pump(
  WidgetTester tester,
  FakeEngine engine, {
  FakeAccess? access,
  FakeFirstRun? firstRun,
}) => pumpApp(
  tester,
  engine,
  overrides: [
    phoneAccessProvider.overrideWithValue(
      access ??
          FakeAccess(
            const PhoneAccessState(
              localNetwork: true,
              localNetworkNeeded: true,
              location: true,
              notifications: true,
              nfc: true,
              batteryUnrestricted: true,
              running: true,
            ),
          ),
    ),
    firstRunStoreProvider.overrideWithValue(firstRun ?? FakeFirstRun(true)),
  ],
);

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  late FakeEngine engine;

  setUp(() => engine = household());

  group('1.1 Home', () {
    testWidgets('greets the person and says what is on', (tester) async {
      await pump(tester, engine);
      expect(find.textContaining(', Jade'), findsOneWidget);
      expect(find.text('Home · 2 on · 1 automation active'), findsOneWidget);
      expect(find.text('You are home'), findsOneWidget);
      expect(find.text('Netflix playing'), findsOneWidget);
      expect(find.text('Hall bulb offline'), findsOneWidget);
    });

    testWidgets('shows scenes, favourites and one grid per room in order', (
      tester,
    ) async {
      await pump(tester, engine);
      expect(find.text('Movie'), findsOneWidget);
      final favourites = tester.getTopLeft(find.text('Favourites')).dy;
      final lounge = tester.getTopLeft(find.text('Lounge')).dy;
      final study = tester.getTopLeft(find.text('Study')).dy;
      final offline = tester.getTopLeft(find.text('Hall bulb offline')).dy;
      expect(favourites < lounge && lounge < study && study < offline, isTrue);
      // The hall's only device is offline, so it has no grid of its own.
      expect(find.text('Hall'), findsNothing);
      expect(find.byKey(const ValueKey('tile-desk_lamp')), findsNWidgets(2));
      expect(find.text('80% · warm'), findsNothing);
      expect(find.text('80%'), findsNWidgets(2));
      expect(find.text('Netflix'), findsOneWidget);
      expect(find.text('Playing · vol 35'), findsOneWidget);
      expect(find.byKey(const ValueKey('tile-hall_bulb')), findsNothing);
      expect(find.text('Hall bulb offline'), findsOneWidget);
      expect(find.text('24.5 °C'), findsOneWidget);
      expect(find.byKey(const ValueKey('tile-jade')), findsNothing);
      expect(find.byKey(const ValueKey('tile-this_phone')), findsNothing);
    });

    testWidgets('a scene runs with one tap', (tester) async {
      await pump(tester, engine);
      await tapKey(tester, 'scene-movie');
      expect(engine.callsOf('scene.run').single.$2, {'id': 'movie'});
    });

    testWidgets('a tile without power opens its page', (tester) async {
      await pump(tester, engine);
      await tapKey(tester, 'tile-room_temp');
      expect(find.byType(SensorPage), findsOneWidget);
      expect(engine.callsOf('device.invoke'), isEmpty);
    });

    testWidgets('the offline row opens the help, not a switch', (tester) async {
      await pump(tester, engine);
      await tapKey(tester, 'home-offline');
      expect(find.byKey(const ValueKey('offline-hall_bulb')), findsOneWidget);
      expect(find.textContaining('switched off at the wall'), findsOneWidget);
      expect(engine.callsOf('device.invoke'), isEmpty);
    });

    testWidgets('several offline devices collapse into one row for Devices', (
      tester,
    ) async {
      engine.devices = [
        lamp(),
        tv(),
        bulb(),
        sensor(),
        person(),
        phone(),
        {...bulb(), 'id': 'porch_bulb', 'name': 'Porch bulb'},
      ];
      await pump(tester, engine);
      expect(find.text('2 offline'), findsOneWidget);
      expect(find.byKey(const ValueKey('tile-porch_bulb')), findsNothing);
      await tapKey(tester, 'home-offline');
      expect(
        find.byKey(const ValueKey('device-row-porch_bulb')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('device-row-desk_lamp')), findsNothing);
    });

    testWidgets('tapping a tile opens it, and its icon switches it', (
      tester,
    ) async {
      await pump(tester, engine);
      await tapKey(tester, 'tile-power-lounge_tv');
      expect(engine.callsOf('tv.key').single.$2, {
        'id': 'lounge_tv',
        'keycode': 223,
      });
      await tester.tap(find.byKey(const ValueKey('tile-desk_lamp')).first);
      await tester.pumpAndSettle();
      expect(find.byType(DevicePage), findsOneWidget);
      expect(engine.callsOf('device.invoke'), isEmpty);
    });

    testWidgets('the presence chip opens places and people', (tester) async {
      await pump(tester, engine);
      await tapKey(tester, 'chip-presence');
      expect(find.byType(PlacesPage), findsOneWidget);
    });

    testWidgets('the bell lists what needs the user', (tester) async {
      await pump(tester, engine);
      await tapKey(tester, 'open-alerts');
      expect(find.text('Movie night'), findsOneWidget);
      expect(find.text('Waiting for you to review it'), findsOneWidget);
      expect(find.text('Hall bulb is offline'), findsOneWidget);
    });

    testWidgets('favourites are starred from Edit', (tester) async {
      await pump(tester, engine);
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Favourites'),
            matching: find.byType(Row),
          ),
          matching: find.text('Edit'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add Lounge TV to favourites'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('device.organize').single.$2, {
        'id': 'lounge_tv',
        'favourite': true,
      });
    });

    testWidgets('loading shows tile skeletons', (tester) async {
      // Longer than the skeleton's shimmer, which rests after a few sweeps.
      engine.delay = const Duration(seconds: 30);
      await pump(tester, engine);
      expect(find.byType(OmniTileSkeleton), findsWidgets);
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(find.byType(OmniTileSkeleton), findsNothing);
      expect(find.byKey(const ValueKey('tile-desk_lamp')), findsWidgets);
      // Let the slow reads Home started after the list finish.
      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
    });

    testWidgets('an engine that does not answer says so with Try again', (
      tester,
    ) async {
      engine.throwOn.add('device.list');
      await pump(tester, engine);
      expect(find.text('OmniFlow is not answering'), findsOneWidget);
      expect(find.textContaining('StateError'), findsNothing);
      engine.throwOn.clear();
      await tapKey(tester, 'engine-retry');
      expect(find.byKey(const ValueKey('tile-desk_lamp')), findsWidgets);
    });

    testWidgets('meets the tap target, label and contrast guidelines', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, engine);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      semantics.dispose();
    });
  });

  group('1.2 Quick control sheet', () {
    testWidgets('a long press opens the controls its capabilities need', (
      tester,
    ) async {
      await pump(tester, engine);
      await tester.longPress(
        find.byKey(const ValueKey('tile-desk_lamp')).first,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('quick-sheet-desk_lamp')),
        findsOneWidget,
      );
      expect(find.text('Philips WiZ Light · Study'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quick-power-desk_lamp')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('device.invoke').last.$2, {
        'id': 'desk_lamp',
        'capability': 'power',
        'params': {'value': false},
      });
    });

    testWidgets('a slider sends once, on release', (tester) async {
      await pump(tester, engine);
      await tester.longPress(
        find.byKey(const ValueKey('tile-desk_lamp')).first,
      );
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('slider-desk_lamp.brightness'));
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(engine.callsOf('device.invoke'), isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      final call = engine.callsOf('device.invoke').single.$2;
      expect(call['capability'], 'brightness');
      expect((call['params'] as Map)['value'], isA<int>());
    });

    testWidgets('Open device goes to the device page in the tab', (
      tester,
    ) async {
      await pump(tester, engine);
      await tester.longPress(
        find.byKey(const ValueKey('tile-desk_lamp')).first,
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'quick-open-desk_lamp');
      expect(find.byType(DevicePage), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-tabs')), findsOneWidget);
    });

    testWidgets('a TV gets power, volume, mute and a mini remote', (
      tester,
    ) async {
      await pump(tester, engine);
      await tester.longPress(find.byKey(const ValueKey('tile-lounge_tv')));
      await tester.pumpAndSettle();
      expect(find.text('Netflix · playing'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tv-card-power-lounge_tv')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('tv.key').last.$2, {
        'id': 'lounge_tv',
        'keycode': 223,
      });
      await tester.tap(find.byKey(const ValueKey('tv-mini-23')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('tv.key').last.$2['keycode'], 23);
      await tester.tap(find.byKey(const ValueKey('tv-mute-lounge_tv')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('tv.key').last.$2['keycode'], 164);
      await tester.tap(find.byKey(const ValueKey('tv-card-volume-lounge_tv')));
      await tester.pumpAndSettle();
      final volumes = engine.callsOf('tv.volume');
      expect(volumes, hasLength(1), reason: 'one tap sends one command');
      expect(volumes.single.$2['level'] as int, inInclusiveRange(40, 60));
    });
  });

  group('1.3 Search and commands', () {
    testWidgets('lists Do it, matching things, automations and settings', (
      tester,
    ) async {
      await pump(tester, engine);
      await openSearch(tester);
      await tester.enterText(find.byKey(const ValueKey('command-bar')), 'desk');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Do it'), findsOneWidget);
      expect(find.text('Desk lamp: 50%'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('search-thing-desk_lamp')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('search-automation-desk_button')),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const ValueKey('command-bar')), 'room');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Rooms'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('command-bar')),
        'desk lamp 50',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('search-thing-desk_lamp')),
        findsOneWidget,
        reason: 'each word is matched, numbers left out',
      );
      expect(find.text('Try'), findsOneWidget);
    });

    testWidgets('Enter runs the top result and says what happened', (
      tester,
    ) async {
      await pump(tester, engine);
      await openSearch(tester);
      await tester.enterText(
        find.byKey(const ValueKey('command-bar')),
        'desk lamp 50',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(engine.callsOf('command.interpret').single.$2, {
        'text': 'desk lamp 50',
      });
      expect(
        engine.callsOf('device.invoke').single.$2['capability'],
        'brightness',
      );
      expect(find.byKey(const ValueKey('command-summary')), findsOneWidget);
    });

    testWidgets('suggestions come from the user\'s own things', (tester) async {
      await pump(tester, engine);
      await openSearch(tester);
      expect(find.text('Try'), findsOneWidget);
      await tapKey(tester, 'try-desk lamp 50');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('command-bar')))
            .controller!
            .text,
        'desk lamp 50',
      );
    });

    testWidgets('a thing in the results opens its page', (tester) async {
      await pump(tester, engine);
      await openSearch(tester);
      await tester.enterText(
        find.byKey(const ValueKey('command-bar')),
        'lounge',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tapKey(tester, 'search-thing-lounge_tv');
      expect(find.byType(TvPage), findsOneWidget);
    });
  });

  group('3.1 Devices', () {
    testWidgets('lists by room with driver and state, and a status dot', (
      tester,
    ) async {
      await pump(tester, engine);
      await openTab(tester, 'Devices');
      expect(find.text('Philips WiZ Light · 80%'), findsOneWidget);
      expect(
        find.textContaining('Philips WiZ Light · offline since'),
        findsOneWidget,
      );
      expect(find.text('Problems 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('device-row-jade')), findsNothing);
      expect(
        find.byKey(const ValueKey('device-row-this_phone')),
        findsOneWidget,
      );
      expect(find.text('Not in a room'), findsOneWidget);
    });

    testWidgets('By type groups lights and sensors, Problems only offline', (
      tester,
    ) async {
      await pump(tester, engine);
      await openTab(tester, 'Devices');
      await tester.tap(find.text('By type'));
      await tester.pumpAndSettle();
      expect(find.text('Lights'), findsOneWidget);
      expect(find.text('Sensors'), findsOneWidget);
      expect(find.text('TVs'), findsOneWidget);
      await tester.tap(find.text('Problems 1'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('device-row-hall_bulb')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('device-row-desk_lamp')), findsNothing);
    });

    testWidgets('with nothing added it offers Add', (tester) async {
      engine.devices = [person()];
      await pump(tester, engine);
      await openTab(tester, 'Devices');
      expect(find.text('No devices yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('devices-add-empty')), findsOneWidget);
    });
  });

  group('3.2 Device page', () {
    testWidgets('a hero with the state and power, Used in and Recent', (
      tester,
    ) async {
      await pump(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      expect(find.text('On · 80%'), findsOneWidget);
      expect(find.text('Study'), findsWidgets);
      expect(find.text('Used in'), findsOneWidget);
      expect(find.byKey(const ValueKey('used-in-desk_button')), findsOneWidget);
      expect(find.text('toggle desk lamp'), findsOneWidget);
      expect(find.textContaining('turned on by Desk button'), findsOneWidget);
      expect(find.textContaining('turned off by you'), findsOneWidget);
      expect(engine.callsOf('automation.list').last.$2, {
        'device': 'desk_lamp',
      });
    });

    testWidgets('the power button switches it', (tester) async {
      await pump(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      await tapKey(tester, 'device-power-desk_lamp');
      expect(engine.callsOf('device.invoke').single.$2['params'], {
        'value': false,
      });
    });

    testWidgets('the star adds it to favourites', (tester) async {
      engine.devices = [
        {...lamp(), 'favourite': false},
      ];
      await pump(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      await tapKey(tester, 'device-star-desk_lamp');
      expect(engine.callsOf('device.organize').single.$2, {
        'id': 'desk_lamp',
        'favourite': true,
      });
    });

    testWidgets('Room moves it to another room by id', (tester) async {
      await pump(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      await tapKey(tester, 'device-room-desk_lamp');
      await tapKey(tester, 'room-pick-hall');
      expect(engine.callsOf('device.organize').single.$2, {
        'id': 'desk_lamp',
        'room': 'hall',
      });
    });

    testWidgets('Not in a room takes it out of its room', (tester) async {
      await pump(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      await tapKey(tester, 'device-room-desk_lamp');
      await tapKey(tester, 'room-none');
      expect(engine.callsOf('device.organize').single.$2, {
        'id': 'desk_lamp',
        'room': '',
      });
    });

    testWidgets('a new name is saved through device.organize', (tester) async {
      await pump(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      await tapKey(tester, 'device-details-desk_lamp');
      await tester.enterText(
        find.byKey(const ValueKey('device-name-field')),
        'Reading lamp',
      );
      await tapKey(tester, 'device-name-save');
      expect(engine.callsOf('device.organize').single.$2, {
        'id': 'desk_lamp',
        'name': 'Reading lamp',
      });
    });

    testWidgets('Remove asks first; Cancel keeps it, Remove removes it', (
      tester,
    ) async {
      await pump(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      await tapKey(tester, 'device-remove-desk_lamp');
      expect(find.text('Remove Desk lamp?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('device.remove'), isEmpty);
      expect(find.byType(DevicePage), findsOneWidget);
      await tapKey(tester, 'device-remove-desk_lamp');
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('device.remove').single.$2, {'id': 'desk_lamp'});
      expect(find.byType(DevicePage), findsNothing);
    });

    testWidgets('Find it on the network moves the device, keeping it', (
      tester,
    ) async {
      engine.answers['device.discover'] = {
        'ok': true,
        'found': [
          {'host': '192.168.1.77', 'stableId': 'a8bb50000001'},
        ],
      };
      engine.answers['thing.add'] = {'ok': true, 'id': 'hall_bulb'};
      await pump(tester, engine);
      await openDevicePage(tester, 'hall_bulb');
      await tapKey(tester, 'device-find');
      expect(engine.callsOf('device.discover').single.$2['serial'], false);
      await tapKey(tester, 'find-again-192.168.1.77');
      final add = engine.callsOf('thing.add').single.$2;
      expect(add['id'], 'hall_bulb');
      expect(add['host'], '192.168.1.77');
      expect(add['replace'], isTrue);
      expect(add['room'], 'hall');
      expect(add['name'], 'Hall bulb');
    });

    testWidgets('8.3: offline shows what to try and what it affects', (
      tester,
    ) async {
      engine.answers['automation.list'] = {
        'ok': true,
        'automations': [
          {
            'id': 'arrive_home',
            'name': 'Arrive home',
            'source': 'rule',
            'sentence': const <Object?>[],
            'devices': ['hall_bulb'],
          },
        ],
      };
      await pump(tester, engine);
      await openDevicePage(tester, 'hall_bulb');
      expect(find.textContaining('Not answering since'), findsOneWidget);
      expect(find.text('Automations that use it'), findsOneWidget);
      expect(
        find.text('this step will be skipped while it is offline'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('device-power-hall_bulb')),
        findsNothing,
      );
      await tapKey(tester, 'device-retry');
      expect(engine.callsOf('device.refresh').single.$2, {'id': 'hall_bulb'});
      await tapKey(tester, 'device-advanced');
      await tapKey(tester, 'device-packets');
      expect(find.byType(DeveloperScreen), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('packets-filter')))
            .controller!
            .text,
        '192.168.1.41',
      );
    });
  });

  group('3.3 Sensor page', () {
    testWidgets('the reading, its age and a day chart with low and high', (
      tester,
    ) async {
      engine.answers['device.history'] = {
        'ok': true,
        'entries': [
          for (final (i, v) in [29.5, 24.5, 21.0, 23.0].indexed)
            {
              'at': DateTime.now()
                  .subtract(Duration(hours: i))
                  .toUtc()
                  .toIso8601String(),
              'key': 'value',
              'value': v,
            },
        ],
      };
      await pump(tester, engine);
      await openDevicePage(tester, 'room_temp');
      expect(find.byType(SensorPage), findsOneWidget);
      expect(find.text('24.5 °C'), findsOneWidget);
      expect(find.text('Last 24 h · low 21.0 · high 29.5'), findsOneWidget);
      expect(find.byType(DayChart), findsOneWidget);
      final call = engine.callsOf('device.history').last.$2;
      expect(call['key'], 'value');
      expect(call['since'], isA<String>());
      expect(
        find.byKey(const ValueKey('sensor-automate-room_temp')),
        findsOneWidget,
      );
    });
  });

  group('7.1 Settings', () {
    testWidgets('lists the home, this phone, agents and your data', (
      tester,
    ) async {
      await pump(tester, engine);
      await openTab(tester, 'Settings');
      expect(find.text('Home · you are here'), findsOneWidget);
      expect(find.text('3 rooms'), findsOneWidget);
      // Scenes are under Automations now, beside what they belong with.
      expect(find.text('1 scene'), findsNothing);
      expect(find.text('Phone setup'), findsOneWidget);
      expect(find.text('Your data'), findsOneWidget);
      expect(find.text('On · battery saver off for OmniFlow'), findsOneWidget);
      expect(find.text('1 automation'), findsOneWidget);
    });

    testWidgets('background running warns and fixes battery saver', (
      tester,
    ) async {
      final access = FakeAccess(
        const PhoneAccessState(
          batteryUnrestricted: false,
          running: true,
          localNetwork: false,
          localNetworkNeeded: true,
          location: true,
          notifications: false,
          nfc: true,
        ),
      );
      await pump(tester, engine, access: access);
      await openTab(tester, 'Settings');
      expect(find.text('On · battery saver can stop it'), findsOneWidget);
      await tapKey(tester, 'settings-background');
      expect(find.byKey(const ValueKey('background-warning')), findsOneWidget);
      await tapKey(tester, 'grant-local-network');
      await tapKey(tester, 'grant-notifications');
      await tapKey(tester, 'fix-battery');
      expect(access.asked, ['localNetwork', 'notifications', 'battery']);
      expect(find.byKey(const ValueKey('background-warning')), findsNothing);
    });

    testWidgets('local network is not asked for where Android has none', (
      tester,
    ) async {
      final access = FakeAccess(
        const PhoneAccessState(localNetwork: true, location: false),
      );
      await pump(tester, engine, access: access);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-background');
      expect(find.byKey(const ValueKey('grant-local-network')), findsNothing);
      expect(find.textContaining('Not needed on this Android'), findsOneWidget);
      await tapKey(tester, 'grant-location');
      expect(access.asked, ['location']);
    });

    testWidgets('Waiting for approval opens the one review', (tester) async {
      await pump(tester, engine);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-waiting');
      expect(
        engine.callsOf('automation.get').map((c) => c.$2['id']),
        contains('movie_night'),
      );
    });

    testWidgets('Rooms: a removal asks first and says devices stay', (
      tester,
    ) async {
      await pump(tester, engine);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-rooms');
      expect(find.byType(RoomsPage), findsOneWidget);
      await tapKey(tester, 'room-remove-study');
      expect(find.text('Remove Study?'), findsOneWidget);
      expect(find.text('Its 2 devices stay, in no room.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('room.remove'), isEmpty);
      await tapKey(tester, 'room-remove-study');
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('room.remove').single.$2, {'id': 'study'});
    });

    testWidgets('Rooms: a new room is saved by name', (tester) async {
      await pump(tester, engine);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-rooms');
      await tapKey(tester, 'rooms-add');
      await tester.enterText(
        find.byKey(const ValueKey('room-name')),
        'Kitchen',
      );
      await tapKey(tester, 'room-name-save');
      expect(engine.callsOf('room.save').single.$2, {'name': 'Kitchen'});
    });

    testWidgets('Hubs: stopping the hub asks first', (tester) async {
      engine.answers['engine.status'] = {
        'ok': true,
        'hubRunning': true,
        'flows': ['desk_button'],
        'loadIssues': const <Object?>[],
      };
      await pump(tester, engine);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-hubs');
      expect(find.text('This phone runs the hub'), findsOneWidget);
      await tapKey(tester, 'hub-stop');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('hub.stop'), isEmpty);
      await tapKey(tester, 'hub-stop');
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('hub.stop'), hasLength(1));
    });
  });

  group('7.2 Places and people', () {
    setUp(() {
      engine.answers['zone.list'] = {
        'ok': true,
        'zones': [
          {
            'id': 'home',
            'name': 'Home',
            'place': 'home',
            'inside': true,
            'wifi': {
              'ssids': ['HomeWiFi'],
              'bssids': const <Object?>[],
              'required': false,
            },
          },
        ],
      };
    });

    testWidgets('where you are, since when and what saw you', (tester) async {
      await pump(tester, engine);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-places');
      expect(find.text('You are home'), findsOneWidget);
      expect(find.textContaining('seen by Wi-Fi'), findsOneWidget);
      expect(find.text('Wi-Fi HomeWiFi'), findsOneWidget);
      expect(find.byKey(const ValueKey('person-jade')), findsOneWidget);
    });

    testWidgets('Wi-Fi presence without location all the time warns and asks', (
      tester,
    ) async {
      final access = FakeAccess(
        const PhoneAccessState(
          location: true,
          locationAlways: false,
          batteryUnrestricted: true,
          running: true,
        ),
      );
      await pump(tester, engine, access: access);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-places');
      expect(find.byKey(const ValueKey('wifi-needs-always')), findsOneWidget);
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(access.asked, contains('locationAlways'));
    });

    testWidgets('the wait before away is set, and saved on the Wi-Fi', (
      tester,
    ) async {
      await pump(tester, engine);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-places');
      expect(find.text('2 min'), findsOneWidget);
      await tapKey(tester, 'away-wait');
      await tester.enterText(
        find.byKey(const ValueKey('duration-amount')),
        '5',
      );
      await tester.pump();
      await tapKey(tester, 'form-done');
      expect(
        ((engine.callsOf('zone.save').single.$2['zone'] as Map)['wifi']
            as Map)['awayAfterMs'],
        300000,
      );
    });

    testWidgets('a beacon is added by its name, keeping the Wi-Fi', (
      tester,
    ) async {
      await pump(tester, engine);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-places');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('presence-beacon')),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('beacon-name')),
        'OMNI_DESK',
      );
      await tapKey(tester, 'beacon-save');
      expect(engine.callsOf('zone.save').single.$2, {
        'zone': {
          'id': 'home',
          'name': 'Home',
          'wifi': {
            'ssids': ['HomeWiFi'],
            'bssids': const <Object?>[],
            'required': false,
          },
          'ble': {'matchName': 'OMNI_DESK'},
        },
      });
    });

    testWidgets('with no place yet, the Wi-Fi the phone is on makes the home '
        'place', (tester) async {
      engine.answers['zone.list'] = {'ok': true, 'zones': const <Object?>[]};
      await pump(tester, engine);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-places');
      expect(find.text('Use HomeWiFi'), findsOneWidget);
      await tapKey(tester, 'network-add-current');
      expect(engine.callsOf('zone.save').single.$2, {
        'zone': {
          'id': 'home',
          'name': 'Home',
          'wifi': {
            'ssids': ['HomeWiFi'],
            'bssids': const <Object?>[],
            'required': false,
          },
        },
      });
    });

    testWidgets('the menu says I am away through presence.set', (tester) async {
      await pump(tester, engine);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-places');
      await tapKey(tester, 'places-menu');
      await tester.tap(find.text('I am away now'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('presence.set').single.$2, {
        'home': false,
        'person': 'jade',
      });
    });
  });

  group('7.3 Developer', () {
    testWidgets('packets filter, then the run log, drivers and engine', (
      tester,
    ) async {
      engine.answers['automation.log'] = {
        'ok': true,
        'runs': [
          {
            'run': 'r1',
            'flow': 'desk_button',
            'outcome': 'failed',
            'reason': 'TV asleep',
            'startedAt': '2026-11-08T13:30:00Z',
            'nodes': const <Object?>[],
          },
        ],
      };
      engine.answers['engine.status'] = {
        'ok': true,
        'hubRunning': true,
        'flows': ['desk_button'],
        'loadIssues': [
          {'kind': 'flow', 'id': 'old', 'error': 'unknown node type'},
        ],
      };
      await pump(tester, engine);
      for (final (transport, text) in [
        ('udp', 'setPilot'),
        ('adb', 'keyevent'),
      ]) {
        engine.eventsOut.add({
          'event': 'packet.captured',
          'transport': transport,
          'direction': 'outgoing',
          'remote': '192.168.1.40',
          'text': text,
          'at': '2026-11-08T13:30:00Z',
        });
      }
      await openDeveloper(tester);
      expect(find.text('setPilot'), findsOneWidget);
      expect(find.text('keyevent'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('packets-filter')),
        'adb',
      );
      await tester.pumpAndSettle();
      expect(find.text('setPilot'), findsNothing);
      expect(find.text('keyevent'), findsOneWidget);
      await tester.tap(find.text('Run log'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('run-r1')), findsOneWidget);
      expect(find.textContaining('TV asleep'), findsOneWidget);
      await tester.tap(find.text('Drivers'));
      await tester.pumpAndSettle();
      expect(find.text('Philips WiZ Light'), findsOneWidget);
      await tester.tap(find.text('Engine'));
      await tester.pumpAndSettle();
      expect(find.text('running'), findsOneWidget);
      expect(find.text('unknown node type'), findsOneWidget);
    });
  });

  group('8.1 and 8.2 First run and empty home', () {
    testWidgets('first run asks for what is ticked, then shows Home', (
      tester,
    ) async {
      engine.devices = [phone()];
      final access = FakeAccess(const PhoneAccessState());
      final firstRun = FakeFirstRun(false);
      await pump(tester, engine, access: access, firstRun: firstRun);
      expect(find.byType(FirstRunScreen), findsOneWidget);
      expect(find.text('Connect anything to anything'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-device')), findsNothing);
      expect(find.byKey(const ValueKey('shell-tabs')), findsNothing);
      await tapKey(tester, 'first-run-home');
      await tapKey(tester, 'first-run-start');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(access.asked, ['localNetwork', 'notifications', 'battery']);
      expect(firstRun.isDone, isTrue);
      expect(find.byType(FirstRunScreen), findsNothing);
      expect(find.text('Nothing added yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-tabs')), findsOneWidget);
    });

    testWidgets('the empty home offers what discovery found', (tester) async {
      engine.devices = [phone()];
      engine.answers['thing.add'] = {
        'ok': true,
        'groups': [
          {
            'driver': 'philips_wiz_udp',
            'name': 'Philips WiZ Light (local UDP)',
            'category': 'lighting',
            'candidates': [
              {
                'driver': 'philips_wiz_udp',
                'host': '192.168.1.44',
                'name': 'WiZ bulb',
              },
              {
                'driver': 'philips_wiz_udp',
                'host': '192.168.1.40',
                'knownAs': 'desk_lamp',
              },
            ],
          },
        ],
        'manual': const <Object?>[],
      };
      await pump(tester, engine);
      expect(
        find.text('We looked on HomeWiFi and found 1 thing.'),
        findsOneWidget,
      );
      expect(find.text('WiZ bulb'), findsOneWidget);
      expect(find.byKey(const ValueKey('found-192.168.1.40')), findsNothing);
      expect(find.byKey(const ValueKey('add-device-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('add-device')), findsNothing);
      await openTab(tester, 'Devices');
      expect(find.byKey(const ValueKey('add-device')), findsOneWidget);
    });
  });

  testWidgets('Devices, Settings and the quick sheet meet the guidelines', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, engine);
    for (final tab in ['Devices', 'Settings']) {
      await openTab(tester, tab);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    }
    await openTab(tester, 'Home');
    await tester.longPress(find.byKey(const ValueKey('tile-desk_lamp')).first);
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });
}
