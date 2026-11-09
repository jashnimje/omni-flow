import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omniflow_app/ui/setup_page.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;

  final tv = {
    'id': 'lounge_tv',
    'name': 'Lounge TV',
    'driver': 'android_tv_adb',
    'host': '192.168.1.60',
    'room': 'Lounge',
    'settings': const <String, Object?>{},
    'state': const <String, Object?>{},
    'pairing': {
      'method': 'adb',
      'prompt': 'When the TV asks "Allow USB debugging?", choose Allow',
    },
    'capabilities': const <Object?>[],
  };

  setUp(() {
    engine = FakeEngine();
    engine.devices = [tv, FakeEngine.lamp()];
  });

  testWidgets('Pair shows the engine prompt, then the outcome', (tester) async {
    engine.answers['device.pair'] = {
      'ok': true,
      'id': 'lounge_tv',
      'method': 'adb',
      'paired': true,
      'message': 'lounge_tv accepted the key',
    };
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'lounge_tv', 'Pair');
    expect(
      find.text('When the TV asks "Allow USB debugging?", choose Allow'),
      findsOneWidget,
    );
    expect(engine.callsOf('device.pair'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('pair-start')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('device.pair').single.$2, {'id': 'lounge_tv'});
    expect(find.text('lounge_tv accepted the key'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    expect(find.byKey(const ValueKey('pair-start')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pair-done')));
    await tester.pumpAndSettle();
    expect(find.text('lounge_tv accepted the key'), findsNothing);
    expect(engine.callsOf('device.pair'), hasLength(1));
  });

  testWidgets('a Home Assistant device has no Pair item', (tester) async {
    engine.devices = [
      {
        ...FakeEngine.lamp(),
        'id': 'hall',
        'name': 'Hall',
        'driver': 'home_assistant_entity',
        'pairing': {
          'method': 'secret',
          'prompt':
              'Create a long-lived access token. Then store it with: '
              'omni secret set hall token',
        },
      },
    ];
    await pumpApp(tester, engine);
    await tester.tap(find.byKey(const ValueKey('device-menu-hall')));
    await tester.pumpAndSettle();
    expect(find.text('Pair'), findsNothing);
    expect(find.text('Rename or move'), findsOneWidget);
  });

  testWidgets('adding a Home Assistant device does not point at Pair', (
    tester,
  ) async {
    engine.answers['driver.list'] = {
      'ok': true,
      'drivers': [
        {
          'id': 'home_assistant_entity',
          'name': 'Home Assistant entity',
          'pairing': 'secret',
          'settings': const <Object?>[],
        },
      ],
    };
    engine.answers['device.add'] = {
      'ok': true,
      'device': {
        'id': 'hall',
        'pairing': {'method': 'secret', 'prompt': 'store a token'},
      },
      'missingSettings': ['entityId'],
      'missingSecrets': ['token'],
      'next': {
        'step': 'secret',
        'keys': [
          {'step': 'secret', 'key': 'token', 'label': 'Access token'},
        ],
        'instruction': 'Enter the Access token for hall',
      },
    };
    await pumpApp(tester, engine);
    await openDriverSheet(tester);
    await tester.tap(find.byKey(const ValueKey('add-driver')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home Assistant entity').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('add-host')),
      '192.168.1.30',
    );
    await tester.enterText(find.byKey(const ValueKey('add-name')), 'Hall');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add-save')));
    await tester.pumpAndSettle();
    expect(find.byType(SetupPage), findsOneWidget);
    expect(find.text('Enter the Access token for hall'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-pair')), findsNothing);
  });

  testWidgets('a refused pairing shows why and offers a retry', (tester) async {
    engine.answers['device.pair'] = {
      'ok': false,
      'error': {
        'type': 'pairing_failed',
        'message': 'lounge_tv did not accept this ADB key',
      },
    };
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'lounge_tv', 'Pair');
    await tester.tap(find.byKey(const ValueKey('pair-start')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('pair-outcome'))).data,
      'lounge_tv did not accept this ADB key',
    );
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a device with nothing to pair has no Pair item', (tester) async {
    await pumpApp(tester, engine);
    await tester.tap(find.byKey(const ValueKey('device-menu-desk_lamp')));
    await tester.pumpAndSettle();
    expect(find.text('Pair'), findsNothing);
    expect(find.text('Rename or move'), findsOneWidget);
  });

  testWidgets('Add device asks for a driver\'s plain settings, not secrets', (
    tester,
  ) async {
    engine.answers['driver.list'] = {
      'ok': true,
      'drivers': [
        {
          'id': 'philips_hue_light',
          'name': 'Philips Hue light',
          'pairing': 'hue_bridge',
          'settings': [
            {'key': 'lightId', 'label': 'Light number on the bridge'},
            {'key': 'username', 'label': 'Bridge username', 'secret': true},
          ],
        },
        {
          'id': 'omniflow_board',
          'name': 'OmniFlow board',
          'board': true,
          'settings': [
            {'key': 'pins', 'label': 'Pins'},
          ],
        },
      ],
    };
    engine.answers['device.add'] = {
      'ok': true,
      'device': {
        'id': 'hall',
        'pairing': {'method': 'hue_bridge'},
      },
      'missingSecrets': ['username'],
      'next': {
        'step': 'pair',
        'method': 'hue_bridge',
        'instruction': 'Press the link button on the bridge',
      },
    };
    await pumpApp(tester, engine);
    await openDriverSheet(tester);
    await tester.tap(find.byKey(const ValueKey('add-driver')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OmniFlow board').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-setting-pins')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('add-driver')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Philips Hue light').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-setting-username')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('add-setting-lightId')),
      '3',
    );
    await tester.enterText(
      find.byKey(const ValueKey('add-host')),
      '192.168.1.20',
    );
    await tester.enterText(find.byKey(const ValueKey('add-name')), 'Hall');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add-save')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('device.add').single.$2, {
      'id': 'hall',
      'name': 'Hall',
      'driver': 'philips_hue_light',
      'host': '192.168.1.20',
      'settings': {'lightId': '3'},
    });
    expect(find.byType(SetupPage), findsOneWidget);
    expect(find.text('Press the link button on the bridge'), findsOneWidget);
  });
}
