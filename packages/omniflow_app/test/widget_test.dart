import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/home.dart';

/// Answers core API commands from canned data and records every call.
class FakeEngine implements EngineClient {
  final calls = <(String, Map<String, Object?>)>[];
  final eventsOut = StreamController<Map<String, Object?>>.broadcast();
  final answers = <String, Map<String, Object?>>{
    'device.list': {
      'ok': true,
      'devices': [
        {
          'id': 'desk_lamp',
          'name': 'Desk lamp',
          'room': 'Study',
          'state': {'state': false, 'dimming': 30},
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
            {
              'id': 'brightness',
              'type': 'level',
              'label': 'Brightness',
              'stateKey': 'dimming',
              'params': {
                'value': {'type': 'number', 'min': 10, 'max': 100, 'unit': '%'},
              },
            },
            {'id': 'wake', 'type': 'action', 'label': 'Wake', 'params': {}},
          ],
        },
      ],
    },
    'flow.list': {
      'ok': true,
      'flows': [
        {
          'id': 'evening',
          'name': 'Evening desk',
          'enabled': true,
          'approved': true,
          'loaded': true,
        },
        {
          'id': 'wake_mac',
          'name': 'Wake the Mac',
          'enabled': true,
          'approved': false,
          'loaded': false,
        },
      ],
    },
    'flow.cards': {
      'ok': true,
      'tree': true,
      'when': [
        {'node': 'trig', 'type': 'zone_change', 'label': 'Arrived at desk'},
      ],
      'then': [
        {
          'kind': 'if',
          'node': 'cond',
          'type': 'all_of',
          'label': 'Evening',
          'then': [
            {
              'kind': 'step',
              'node': 'lamp',
              'type': 'device_capability',
              'label': 'Lamp warm',
            },
          ],
          'else': [],
        },
      ],
    },
    'command.interpret': {
      'ok': true,
      'kind': 'call',
      'command': 'device.invoke',
      'args': {
        'id': 'desk_lamp',
        'capability': 'brightness',
        'params': {'value': 50},
      },
      'summary': 'Desk lamp: 50%',
    },
  };

  @override
  Future<Map<String, Object?>> call(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    calls.add((command, args));
    return answers[command] ?? const {'ok': true};
  }

  @override
  Stream<Map<String, Object?>> get events => eventsOut.stream;

  List<(String, Map<String, Object?>)> callsOf(String command) =>
      calls.where((c) => c.$1 == command).toList();
}

void main() {
  late FakeEngine engine;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [engineClientProvider.overrideWithValue(engine)],
        child: const OmniFlowApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => engine = FakeEngine());

  testWidgets('the dashboard builds controls from capability types', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('Study'), findsOneWidget);
    expect(find.text('Desk lamp'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Wake'), findsOneWidget);
  });

  testWidgets('flipping the switch invokes the capability', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(engine.callsOf('device.invoke').single.$2, {
      'id': 'desk_lamp',
      'capability': 'power',
      'params': {'value': true},
    });
  });

  testWidgets('a state event moves the switch without a reload', (
    tester,
  ) async {
    await pumpApp(tester);
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
      await pumpApp(tester);
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

  testWidgets('flows show approve and run, and open the card view', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('Flows'));
    await tester.pumpAndSettle();
    expect(find.text('waiting for approval'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('approve-wake_mac')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('flow.approve').single.$2, {'id': 'wake_mac'});
    await tester.tap(find.byKey(const ValueKey('run-evening')));
    await tester.pump();
    expect(engine.callsOf('flow.run').single.$2, {'id': 'evening'});
    await tester.tap(find.text('Evening desk'));
    await tester.pumpAndSettle();
    expect(find.text('WHEN'), findsOneWidget);
    expect(find.text('IF'), findsOneWidget);
    expect(find.text('THEN'), findsOneWidget);
    expect(find.text('Lamp warm'), findsOneWidget);
  });

  testWidgets('the inspector lists packets from events', (tester) async {
    await pumpApp(tester);
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
    await pumpApp(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Wake'));
    await tester.pumpAndSettle();
    expect(find.text('no reply from desk_lamp'), findsOneWidget);
  });
}
