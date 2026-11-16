import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/state/providers.dart' show packetsCommand;
import 'package:omniflow_app/ui/design/design.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;

  setUp(() => engine = FakeEngine());

  testWidgets('the device page builds controls from capability types', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    expect(find.text('Study'), findsOneWidget);
    expect(find.byKey(const ValueKey('tile-desk_lamp')), findsOneWidget);
    await openDevicePage(tester, 'desk_lamp');
    expect(
      find.byKey(const ValueKey('device-power-desk_lamp')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('slider-desk_lamp.brightness')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('desk_lamp.wake')), findsOneWidget);
  });

  testWidgets('tapping a tile icon switches it at once', (tester) async {
    await pumpApp(tester, engine);
    await tester.tap(find.byKey(const ValueKey('tile-power-desk_lamp')));
    await tester.pump();
    expect(engine.callsOf('device.invoke').single.$2, {
      'id': 'desk_lamp',
      'capability': 'power',
      'params': {'value': true},
    });
    // The tile shows on before the lamp reports it.
    expect(
      tester.widget<OmniTile>(find.byKey(const ValueKey('tile-desk_lamp'))).on,
      isTrue,
    );
  });

  testWidgets('a switch that fails flips back and says so', (tester) async {
    engine.answers['device.invoke'] = {
      'ok': false,
      'error': {'type': 'timeout', 'message': 'no reply'},
    };
    await pumpApp(tester, engine);
    await tester.tap(find.byKey(const ValueKey('tile-power-desk_lamp')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<OmniTile>(find.byKey(const ValueKey('tile-desk_lamp'))).on,
      isFalse,
    );
    expect(find.textContaining('Could not turn Desk lamp on'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('releasing the slider invokes the level as a whole number', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await openDevicePage(tester, 'desk_lamp');
    await tester.drag(
      find.byKey(const ValueKey('slider-desk_lamp.brightness')),
      const Offset(120, 0),
    );
    await tester.pumpAndSettle();
    final call = engine.callsOf('device.invoke').single.$2;
    expect(call['capability'], 'brightness');
    final value = (call['params'] as Map)['value'];
    expect(value, isA<int>());
    expect(value as int, greaterThan(30));
  });

  testWidgets('a state event moves the tile and the page without a reload', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    expect(find.text('Off'), findsOneWidget);
    engine.eventsOut.add({
      'event': 'device.stateChanged',
      'device': {
        'id': 'desk_lamp',
        'state': {'state': true, 'dimming': 70},
      },
    });
    await tester.pumpAndSettle();
    expect(find.text('70%'), findsOneWidget);
    await openDevicePage(tester, 'desk_lamp');
    expect(find.text('On · 70%'), findsOneWidget);
  });

  testWidgets(
    'the command bar asks the engine to interpret, then runs the call',
    (tester) async {
      await pumpApp(tester, engine);
      await openSearch(tester);
      await tester.enterText(
        find.byKey(const ValueKey('command-bar')),
        'desk lamp 50%',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(engine.callsOf('command.interpret').single.$2, {
        'text': 'desk lamp 50%',
      });
      expect(
        (engine.callsOf('device.invoke').single.$2['params'] as Map)['value'],
        50,
      );
      expect(find.text('Desk lamp: 50%'), findsOneWidget);
    },
  );

  testWidgets('a line the engine half understood shows its explanation', (
    tester,
  ) async {
    engine.answers['command.interpret'] = {
      'ok': true,
      'kind': 'ask',
      'text': 'desk lamp sparkle',
      'summary': 'Desk lamp cannot sparkle. It can: power, brightness, wake',
    };
    await pumpApp(tester, engine);
    await openSearch(tester);
    await tester.enterText(
      find.byKey(const ValueKey('command-bar')),
      'desk lamp sparkle',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(
      find.text('Desk lamp cannot sparkle. It can: power, brightness, wake'),
      findsOneWidget,
    );
    expect(engine.callsOf('device.invoke'), isEmpty);
  });

  testWidgets('a line nobody understood gets examples that work', (
    tester,
  ) async {
    engine.answers['command.interpret'] = {
      'ok': true,
      'kind': 'ask',
      'text': 'make it cosy',
      'summary': 'Ask the architect',
    };
    await pumpApp(tester, engine);
    await openSearch(tester);
    await tester.enterText(
      find.byKey(const ValueKey('command-bar')),
      'make it cosy',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(find.textContaining('"desk lamp 50%"'), findsOneWidget);
  });

  testWidgets('the inspector lists packets from events', (tester) async {
    await pumpApp(tester, engine);
    await openDeveloper(tester);
    engine.eventsOut.add({
      'event': 'packet.captured',
      'transport': 'udp',
      'direction': 'outgoing',
      'remote': '192.168.1.40:38899',
      'text': '{"method":"setPilot"}',
      'at': '2026-11-06T19:00:00Z',
    });
    await tester.pumpAndSettle();
    expect(find.text('{"method":"setPilot"}'), findsOneWidget);
  });

  testWidgets('packets are taken only while the inspector is open', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    expect(engine.callsOf(packetsCommand), isEmpty);
    engine.eventsOut.add({
      'event': 'packet.captured',
      'transport': 'udp',
      'direction': 'outgoing',
      'remote': '192.168.1.40:38899',
      'text': 'before it opened',
      'at': '2026-11-06T19:00:00Z',
    });
    await tester.pumpAndSettle();
    await openDeveloper(tester);
    await tester.pumpAndSettle();
    expect(engine.callsOf(packetsCommand).single.$2, {'on': true});
    expect(find.text('before it opened'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(engine.callsOf(packetsCommand).last.$2, {'on': false});
  });

  testWidgets('an engine error shows as a snackbar', (tester) async {
    engine.answers['device.invoke'] = {
      'ok': false,
      'error': {'type': 'timeout', 'message': 'no reply from desk_lamp'},
    };
    await pumpApp(tester, engine);
    await openDevicePage(tester, 'desk_lamp');
    await tester.ensureVisible(find.byKey(const ValueKey('desk_lamp.wake')));
    await tester.tap(find.byKey(const ValueKey('desk_lamp.wake')));
    await tester.pumpAndSettle();
    expect(find.text('No reply from desk_lamp.'), findsOneWidget);
  });

  testWidgets('a hub that did not start shows a banner', (tester) async {
    await pumpApp(tester, engine, hubError: 'port 38951 is in use');
    expect(find.byKey(const ValueKey('hub-error')), findsOneWidget);
    expect(find.textContaining('port 38951 is in use'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hub-error')), findsNothing);
  });
}
