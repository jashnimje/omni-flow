import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;

  final board = {
    'id': 'desk',
    'name': 'Desk board',
    'driver': 'omniflow_board',
    'board': true,
    'host': '192.168.1.77',
    'room': 'Study',
    'settings': {
      'pins': {
        'button': {'pin': 3, 'mode': 'in_pullup'},
      },
    },
    'state': {'button': true, 'light': 42, 'rssi': -60},
    'capabilities': [
      {
        'id': 'button',
        'type': 'sensor',
        'label': 'button',
        'stateKey': 'button',
        'params': {},
      },
      {
        'id': 'light',
        'type': 'sensor',
        'label': 'light',
        'stateKey': 'light',
        'params': {},
      },
    ],
  };

  setUp(() {
    engine = FakeEngine();
    engine.devices = [board, FakeEngine.lamp()];
  });

  testWidgets('a board page shows its pins with their live values', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await openDevicePage(tester, 'desk');
    expect(find.byKey(const ValueKey('board-page')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pin-button')),
        matching: find.text('pressed'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Pins shows only for a device the engine marks as a board', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await openDevicePage(tester, 'desk_lamp');
    await tester.tap(find.byKey(const ValueKey('device-menu-desk_lamp')));
    await tester.pumpAndSettle();
    expect(find.text('Pins'), findsNothing);
  });

  testWidgets('a new board on the network is offered once, and Add adds it', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    final add = {
      'id': 'hall_board',
      'driver': 'omniflow_board',
      'host': '192.168.1.78',
      'port': 4000,
      'stableId': 'hall_board',
    };
    final hello = {
      'event': 'board.found',
      'node': 'hall_board',
      'board': 'esp32',
      'host': '192.168.1.78',
      'port': 4000,
      'add': add,
    };
    engine.eventsOut
      ..add(hello)
      ..add(hello);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final offer = find.text(
      'New board found: hall_board (esp32) at 192.168.1.78',
    );
    expect(offer, findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SnackBarAction));
    await tester.pumpAndSettle();
    expect(engine.callsOf('device.add').single.$2, add);
    expect(offer, findsNothing);
  });
}
