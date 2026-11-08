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

  /// What link.options answers for each source, shaped like the engine's.
  Map<String, Object?> linkOptions(Map<String, Object?> args) =>
      switch (args['from']) {
        'desk.light' || 'desk.rssi' => {
          'ok': true,
          'from': args['from'],
          'modes': ['follow', 'threshold'],
          'targets': [
            {
              'to': 'desk_lamp.power',
              'type': 'toggle',
              'modes': ['threshold'],
            },
            {
              'to': 'desk_lamp.brightness',
              'type': 'level',
              'modes': ['follow', 'threshold'],
            },
          ],
        },
        _ => {
          'ok': true,
          'from': args['from'],
          'modes': ['toggle', 'follow'],
          'targets': [
            {
              'to': 'desk_lamp.power',
              'type': 'toggle',
              'modes': ['toggle', 'follow'],
            },
          ],
        },
      };

  /// Keeps the pins board.pins was sent, as the engine does.
  void persistPins() => engine.onCall = (command, args) {
    if (command != 'board.pins') return;
    engine.devices = [
      {
        ...board,
        'settings': {'pins': args['pins']},
      },
      FakeEngine.lamp(),
    ];
  };

  setUp(() {
    engine = FakeEngine();
    engine.devices = [board, FakeEngine.lamp()];
    engine.answerers['link.options'] = linkOptions;
  });

  testWidgets('sensors show their state', (tester) async {
    await pumpApp(tester, engine);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('sensor-desk.button')))
          .data,
      'on',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('sensor-desk.light'))).data,
      '42',
    );
  });

  testWidgets('Pins shows only for a device the engine marks as a board', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await tester.tap(find.byKey(const ValueKey('device-menu-desk_lamp')));
    await tester.pumpAndSettle();
    expect(find.text('Pins'), findsNothing);
  });

  testWidgets('the pin sheet names a pin through board.pins', (tester) async {
    persistPins();
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk', 'Pins');
    expect(find.text('GPIO 3, in_pullup'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pin-name')), 'relay');
    await tester.enterText(find.byKey(const ValueKey('pin-number')), '4');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pin-save')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('board.pins').single.$2, {
      'id': 'desk',
      'pins': {
        'button': {'pin': 3, 'mode': 'in_pullup'},
        'relay': {'pin': 4, 'mode': 'out'},
      },
    });
    await tester.tap(find.byKey(const ValueKey('pin-remove-button')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('board.pins').last.$2['pins'], {
      'relay': {'pin': 4, 'mode': 'out'},
    });
  });

  testWidgets('after a refused board.pins the sheet shows what the engine '
      'holds', (tester) async {
    engine.answers['board.pins'] = {
      'ok': false,
      'error': {'type': 'invalid', 'message': 'relay: pin 40 is not here'},
    };
    persistPins();
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk', 'Pins');
    await tester.enterText(find.byKey(const ValueKey('pin-name')), 'relay');
    await tester.enterText(find.byKey(const ValueKey('pin-number')), '40');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pin-save')));
    await tester.pumpAndSettle();
    expect(find.text('relay: pin 40 is not here'), findsOneWidget);
    expect(find.text('GPIO 40, out'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('pin-name')))
          .controller!
          .text,
      'relay',
    );
  });

  testWidgets('a pin sheet closed during a slow save does not fail', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk', 'Pins');
    await tester.enterText(find.byKey(const ValueKey('pin-name')), 'relay');
    await tester.enterText(find.byKey(const ValueKey('pin-number')), '4');
    await tester.pump();
    engine.delay = const Duration(seconds: 2);
    await tester.tap(find.byKey(const ValueKey('pin-save')));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pin-save')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pin-name')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
    expect(engine.callsOf('board.pins'), hasLength(1));
  });

  testWidgets('the pin sheet explains a bad name and asks before replacing', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk', 'Pins');
    await tester.enterText(find.byKey(const ValueKey('pin-name')), 'Relay');
    await tester.enterText(find.byKey(const ValueKey('pin-number')), '5');
    await tester.pump();
    expect(
      find.text('Start with a lower case letter, then letters, digits or _'),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const ValueKey('pin-name')), 'button');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pin-save')));
    await tester.pumpAndSettle();
    expect(find.text('Replace button?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.callsOf('board.pins'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('pin-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('board.pins').single.$2['pins'], {
      'button': {'pin': 5, 'mode': 'out'},
    });
  });

  testWidgets('a name the hint flags still goes to the engine to judge', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk', 'Pins');
    await tester.enterText(find.byKey(const ValueKey('pin-name')), 'Relay');
    await tester.enterText(find.byKey(const ValueKey('pin-number')), '5');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pin-save')));
    await tester.pumpAndSettle();
    expect(
      (engine.callsOf('board.pins').single.$2['pins'] as Map).keys,
      contains('Relay'),
    );
  });

  testWidgets('the link sheet creates a trusted toggle link', (tester) async {
    engine.answers['link.create'] = {
      'ok': true,
      'id': 'link_desk_button_desk_lamp_power_toggle',
      'name': 'desk.button toggles desk_lamp.power',
    };
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk', 'Link to...');
    expect(engine.callsOf('link.options').first.$2, {'from': 'desk.button'});
    expect(find.text('Desk board - button'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('link-to')));
    await tester.pumpAndSettle();
    expect(find.text('Desk lamp - Brightness'), findsNothing);
    await tester.tap(find.text('Desk lamp - Power').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-create')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('link.create').single.$2, {
      'from': 'desk.button',
      'to': 'desk_lamp.power',
      'mode': 'toggle',
      'trusted': true,
    });
    expect(
      find.text('Linked: desk.button toggles desk_lamp.power'),
      findsOneWidget,
    );
  });

  testWidgets('a numeric source defaults to threshold and cannot toggle', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk', 'Link to...');
    await tester.tap(find.byKey(const ValueKey('link-from')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Desk board - light').last);
    await tester.pumpAndSettle();
    final modes = tester.widget<SegmentedButton<String>>(
      find.byKey(const ValueKey('link-mode')),
    );
    expect(modes.selected, {'threshold'});
    expect(
      modes.segments.firstWhere((s) => s.value == 'toggle').enabled,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('link-to')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Desk lamp - Power').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('link-limit')), '30');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('link-create')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('link.create').single.$2, {
      'from': 'desk.light',
      'to': 'desk_lamp.power',
      'mode': 'threshold',
      'above': 30,
      'set': true,
      'trusted': true,
    });
  });

  testWidgets('a follow offers only the targets the engine allows for it', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk', 'Link to...');
    await tester.tap(find.byKey(const ValueKey('link-from')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Desk board - light').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-to')));
    await tester.pumpAndSettle();
    expect(find.text('Desk lamp - Power'), findsNothing);
    expect(find.text('Desk lamp - Brightness'), findsWidgets);
  });

  testWidgets('raw state keys stay behind More', (tester) async {
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk', 'Link to...');
    await tester.tap(find.byKey(const ValueKey('link-from')));
    await tester.pumpAndSettle();
    expect(find.text('Desk board - rssi'), findsNothing);
    await tester.tap(find.text('Desk board - button').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-from')));
    await tester.pumpAndSettle();
    expect(find.text('Desk board - rssi'), findsWidgets);
  });

  testWidgets('a source the engine refuses shows why', (tester) async {
    engine.answerers['link.options'] = (_) => {
      'ok': false,
      'error': {'type': 'not_found', 'message': 'desk has no state button'},
    };
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk', 'Link to...');
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('link-error'))).data,
      'desk has no state button',
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('link-create')))
          .onPressed,
      isNull,
    );
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
