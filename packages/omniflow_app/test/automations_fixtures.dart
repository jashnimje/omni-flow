import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/theme.dart';

import 'fake_engine.dart';
import 'things_fixtures.dart';

/// Pumps [page] on its own, with the app's theme and snackbars, so the
/// automation screens are tested without the rest of the app.
Future<void> pumpPage(
  WidgetTester tester,
  FakeEngine engine,
  Widget page,
) async {
  tester.view.physicalSize = const Size(1236, 5400);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [engineConnectionProvider.overrideWithValue(engine)],
      child: MaterialApp(
        theme: omniTheme(),
        scaffoldMessengerKey: messengerKey,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pumps a home page with an Open button that pushes [page], so the page
/// can pop like it does in the app.
Future<void> pumpPushed(
  WidgetTester tester,
  FakeEngine engine,
  Widget page,
) async {
  await pumpPage(
    tester,
    engine,
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            key: const ValueKey('open-page'),
            onPressed: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => page)),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-page')));
  await tester.pumpAndSettle();
}

/// Taps [text] inside the block [block] (`block-then`, `block-then[0].if`).
Future<void> tapIn(WidgetTester tester, String block, String text) async {
  final finder = find.descendant(
    of: find.byKey(ValueKey(block)),
    matching: find.text(text),
  );
  await tester.ensureVisible(finder.first);
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder.first);
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

/// Whether the button under [key] (an OmniButton) can be pressed.
bool buttonEnabled(WidgetTester tester, String key) => tester
    .widget<ButtonStyleButton>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    )
    .enabled;

/// The engine's answer to automation.save, the last call's spec.
Map<String, Object?> savedSpec(FakeEngine engine) => Map<String, Object?>.from(
  engine.callsOf('automation.save').last.$2['spec'] as Map,
);

final hallBulb = <String, Object?>{
  'id': 'hall_bulb',
  'name': 'Hall bulb',
  'driver': 'philips_wiz_udp',
  'host': '192.168.1.41',
  'state': const {'state': false},
  'online': false,
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'stateKey': 'state',
      'params': {
        'value': {'type': 'boolean'},
      },
    },
  ],
};

final livingTv = <String, Object?>{
  'id': 'living_tv',
  'name': 'Living room TV',
  'driver': 'android_tv_adb',
  'host': '192.168.1.111',
  'state': const {'power': true, 'app': 'Netflix'},
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'stateKey': 'power',
      'params': {
        'value': {'type': 'boolean'},
      },
    },
    {'id': 'app', 'type': 'sensor', 'label': 'App', 'stateKey': 'app'},
    {
      'id': 'shell',
      'type': 'exec',
      'label': 'Run a command',
      'highRisk': true,
      'params': {
        'command': {'type': 'string'},
      },
    },
  ],
};

final roomTemp = <String, Object?>{
  'id': 'room_temp',
  'name': 'Room temperature',
  'driver': 'mqtt_sensor',
  'host': 'mqtt',
  'state': const {'temp': 24.5},
  'capabilities': [
    {
      'id': 'temp',
      'type': 'sensor',
      'label': 'Temperature',
      'stateKey': 'temp',
      'unit': '°C',
    },
  ],
};

/// The household: a person, a tag, lights, a TV with a shell, a sensor.
List<Map<String, Object?>> household() => [
  FakeEngine.lamp(),
  hallBulb,
  livingTv,
  roomTemp,
  jade,
  frontDoorTag,
];

Map<String, Object?> part(String kind, String text) => {
  'kind': kind,
  'text': text,
};

/// automation.list rows shaped like the engine's.
List<Map<String, Object?>> automationRows() => [
  {
    'id': 'arrive_home',
    'name': 'Arrive home',
    'source': 'rule',
    'enabled': true,
    'approved': true,
    'needsApproval': false,
    'needsYou': false,
    'highRisk': false,
    'revision': 'r-arrive',
    'sentence': [
      part('when', 'When I get home'),
      part('if', 'after 6 pm'),
      part('text', '→'),
      part('then', 'TV on'),
      part('text', 'then'),
      part('then', 'lights on'),
    ],
    'lastRun': {
      'at': DateTime.now().toUtc().toIso8601String(),
      'ok': true,
      'steps': 3,
      'run': 'run-1',
      'outcome': 'completed',
    },
    'devices': ['desk_lamp', 'jade', 'living_tv'],
    'controls': ['desk_lamp', 'living_tv'],
  },
  {
    'id': 'bulb_away',
    'name': 'Bulb off while away',
    'source': 'rule',
    'enabled': true,
    'approved': true,
    'needsApproval': false,
    'needsYou': false,
    'sentence': [
      part('then', 'Keep hall bulb off'),
      part('if', 'while I am away'),
    ],
    'devices': ['hall_bulb', 'jade'],
    'controls': ['hall_bulb'],
  },
  {
    'id': 'door_mute',
    'name': 'Door tag mutes TV',
    'source': 'rule',
    'enabled': false,
    'approved': true,
    'needsApproval': false,
    'needsYou': false,
    'sentence': [
      part('when', 'When front door tag is scanned'),
      part('text', '→'),
      part('then', 'toggle TV mute'),
    ],
    'lastRun': {
      'at': DateTime.now().toUtc().toIso8601String(),
      'ok': false,
      'steps': 0,
      'error': 'TV asleep',
    },
    'devices': ['front_door', 'living_tv'],
    'controls': ['living_tv'],
  },
  {
    'id': 'desk_button',
    'name': 'Desk button',
    'source': 'link',
    'enabled': true,
    'approved': true,
    'needsApproval': false,
    'needsYou': false,
    'sentence': [
      part('when', 'When desk button is pressed'),
      part('text', '→'),
      part('then', 'toggle desk lamp'),
    ],
    'devices': ['desk_lamp'],
    'controls': ['desk_lamp'],
  },
  {
    'id': 'movie_night',
    'name': 'Movie night',
    'source': 'rule',
    'enabled': true,
    'approved': false,
    'needsApproval': true,
    'needsYou': true,
    'highRisk': false,
    'revision': 'r-movie',
    'sentence': [
      part('when', 'When the TV opens Netflix'),
      part('if', 'after 8 pm'),
      part('text', '→'),
      part('then', 'desk lamp 20%'),
      part('text', 'then'),
      part('then', 'hall bulb off'),
    ],
    'devices': ['desk_lamp', 'hall_bulb', 'living_tv'],
    'controls': ['desk_lamp', 'hall_bulb'],
  },
  {
    'id': 'movie',
    'name': 'Movie',
    'source': 'scene',
    'icon': 'movie',
    'enabled': true,
    'approved': true,
    'needsApproval': false,
    'sentence': [part('then', 'desk lamp 20%')],
    'devices': ['desk_lamp'],
    'controls': ['desk_lamp'],
  },
];

/// A FakeEngine with the household and its automations.
FakeEngine automationsEngine({List<Map<String, Object?>>? automations}) {
  final engine = FakeEngine()..devices = household();
  engine.answers['automation.list'] = {
    'ok': true,
    'automations': automations ?? automationRows(),
  };
  return engine;
}
