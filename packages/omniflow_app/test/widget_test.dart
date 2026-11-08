import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;

  setUp(() => engine = FakeEngine());

  testWidgets('the dashboard builds controls from capability types', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    expect(find.text('Study'), findsOneWidget);
    expect(find.text('Desk lamp'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Wake'), findsOneWidget);
  });

  testWidgets('flipping the switch invokes the capability', (tester) async {
    await pumpApp(tester, engine);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(engine.callsOf('device.invoke').single.$2, {
      'id': 'desk_lamp',
      'capability': 'power',
      'params': {'value': true},
    });
  });

  testWidgets('releasing the slider invokes the level as a whole number', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await tester.drag(find.byType(Slider), const Offset(60, 0));
    await tester.pumpAndSettle();
    final call = engine.callsOf('device.invoke').single.$2;
    expect(call['capability'], 'brightness');
    final value = (call['params'] as Map)['value'];
    expect(value, isA<int>());
    expect(value as int, greaterThan(30));
  });

  testWidgets('a state event moves the switch without a reload', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    engine.eventsOut.add({
      'event': 'device.stateChanged',
      'device': {
        'id': 'desk_lamp',
        'state': {'state': true, 'dimming': 70},
      },
    });
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 70);
  });

  testWidgets(
    'the command bar asks the engine to interpret, then runs the call',
    (tester) async {
      await pumpApp(tester, engine);
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

  testWidgets('a line nobody understood says the architect is not set up', (
    tester,
  ) async {
    engine.answers['command.interpret'] = {
      'ok': true,
      'kind': 'ask',
      'text': 'make it cosy',
      'summary': 'Ask the architect',
    };
    await pumpApp(tester, engine);
    await tester.enterText(
      find.byKey(const ValueKey('command-bar')),
      'make it cosy',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Not a device or flow command. The architect is not set up yet.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the inspector lists packets from events', (tester) async {
    await pumpApp(tester, engine);
    engine.eventsOut.add({
      'event': 'packet.captured',
      'transport': 'udp',
      'direction': 'outgoing',
      'remote': '192.168.1.40:38899',
      'text': '{"method":"setPilot"}',
      'at': '2026-11-06T19:00:00Z',
    });
    await tester.tap(find.text('Packets'));
    await tester.pumpAndSettle();
    expect(find.text('{"method":"setPilot"}'), findsOneWidget);
  });

  testWidgets('an engine error shows as a snackbar', (tester) async {
    engine.answers['device.invoke'] = {
      'ok': false,
      'error': {'type': 'timeout', 'message': 'no reply from desk_lamp'},
    };
    await pumpApp(tester, engine);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Wake'));
    await tester.pumpAndSettle();
    expect(find.text('no reply from desk_lamp'), findsOneWidget);
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
