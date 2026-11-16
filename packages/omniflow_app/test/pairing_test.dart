import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
    engine.answers['tv.state'] = {
      'ok': false,
      'error': {'type': 'unavailable', 'message': 'not paired'},
    };
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
    await openPairOnTv(tester);
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

  testWidgets('a TV that answers offers no Pair again', (tester) async {
    engine.answers['tv.state'] = {'ok': true, 'power': 'on'};
    await pumpApp(tester, engine);
    await openDevicePage(tester, 'lounge_tv');
    expect(find.byKey(const ValueKey('tv-offline')), findsNothing);
    expect(find.byKey(const ValueKey('tv-pair')), findsNothing);
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
    await openDevicePage(tester, 'hall');
    await tester.tap(find.byKey(const ValueKey('device-menu-hall')));
    await tester.pumpAndSettle();
    expect(find.text('Pair'), findsNothing);
    expect(find.text('Setup steps'), findsOneWidget);
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
    await openPairOnTv(tester);
    await tester.tap(find.byKey(const ValueKey('pair-start')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pair-outcome')),
        matching: find.text('Lounge_tv did not accept this ADB key.'),
      ),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a device with nothing to pair has no Pair item', (tester) async {
    await pumpApp(tester, engine);
    await openDevicePage(tester, 'desk_lamp');
    await tester.tap(find.byKey(const ValueKey('device-menu-desk_lamp')));
    await tester.pumpAndSettle();
    expect(find.text('Pair'), findsNothing);
    expect(find.text('Setup steps'), findsOneWidget);
  });
}

/// A TV that stops answering offers Pair again on its page.
Future<void> openPairOnTv(WidgetTester tester) async {
  await openDevicePage(tester, 'lounge_tv');
  expect(find.byKey(const ValueKey('tv-offline')), findsOneWidget);
  await tester.tap(find.text('Pair again'));
  await tester.pumpAndSettle();
}
