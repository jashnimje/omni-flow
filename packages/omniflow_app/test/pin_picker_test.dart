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
    'settings': {
      'pins': {
        'button': {'pin': 3, 'mode': 'in_pullup'},
      },
    },
    'state': const <String, Object?>{},
    'capabilities': const <Object?>[],
  };

  /// An ESP32-like describe: GPIO 2 and 4 do everything digital, 4 also
  /// reads analog, and 34 is input only.
  final describe = {
    'board': 'esp32',
    'pins': [
      {
        'pin': 2,
        'caps': ['in', 'pullup', 'out', 'pwm', 'servo'],
      },
      {
        'pin': 3,
        'caps': ['in', 'pullup', 'out'],
      },
      {
        'pin': 4,
        'caps': ['in', 'pullup', 'out', 'pwm', 'servo', 'adc'],
      },
      {
        'pin': 34,
        'caps': ['in', 'adc'],
      },
    ],
    'set': const <Object?>[],
    'watches': 4,
    'ir': false,
    'rf': false,
  };

  setUp(() {
    engine = FakeEngine();
    engine.devices = [board, FakeEngine.lamp()];
    engine.answers['board.describe'] = {
      'ok': true,
      'id': 'desk',
      'live': true,
      'describe': describe,
      'warnings': const <Object?>[],
    };
  });

  Future<void> openPins(WidgetTester tester) async {
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk', 'Pins');
  }

  Future<void> pick(WidgetTester tester, String field, String item) async {
    await tester.tap(find.byKey(ValueKey(field)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  /// The texts of the items a dropdown offers.
  Future<List<String>> itemsOf(WidgetTester tester, String field) async {
    final button = tester.widget(
      find.descendant(
        of: find.byKey(ValueKey(field)),
        matching: find.byWidgetPredicate((w) => w is DropdownButton),
      ),
    );
    return [
      for (final item in (button as DropdownButton).items!)
        (item.child as Text).data!,
    ];
  }

  testWidgets('the GPIO picker offers only the pins that can do the mode', (
    tester,
  ) async {
    await openPins(tester);
    expect(engine.callsOf('board.describe').single.$2, {'id': 'desk'});
    expect(find.byKey(const ValueKey('pin-number')), findsNothing);
    expect(await itemsOf(tester, 'pin-gpio'), [
      'Pick a pin',
      'GPIO 2',
      'GPIO 3 (button)',
      'GPIO 4',
    ]);

    await pick(tester, 'pin-mode', 'adc - analog sensor 0 to 100%');
    expect(await itemsOf(tester, 'pin-gpio'), [
      'Pick a pin',
      'GPIO 4',
      'GPIO 34',
    ]);
  });

  testWidgets('a picked pin limits the modes to what it can do', (
    tester,
  ) async {
    await openPins(tester);
    await pick(tester, 'pin-mode', 'in - digital input');
    await pick(tester, 'pin-gpio', 'GPIO 34');
    final modes = await itemsOf(tester, 'pin-mode');
    expect(modes, ['in - digital input', 'adc - analog sensor 0 to 100%']);

    await pick(tester, 'pin-mode', 'adc - analog sensor 0 to 100%');
    await tester.enterText(find.byKey(const ValueKey('pin-name')), 'light');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pin-save')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('board.pins').single.$2['pins'], {
      'button': {'pin': 3, 'mode': 'in_pullup'},
      'light': {'pin': 34, 'mode': 'adc'},
    });
  });

  testWidgets('Pick a pin widens the modes again', (tester) async {
    await openPins(tester);
    await pick(tester, 'pin-mode', 'in - digital input');
    await pick(tester, 'pin-gpio', 'GPIO 34');
    await pick(tester, 'pin-gpio', 'Pick a pin');
    expect(await itemsOf(tester, 'pin-mode'), hasLength(6));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('pin-save')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('a board that cannot describe itself keeps the number field', (
    tester,
  ) async {
    engine.answers['board.describe'] = {
      'ok': false,
      'error': {'type': 'unavailable', 'message': 'desk did not answer'},
    };
    await openPins(tester);
    expect(find.byKey(const ValueKey('pin-gpio')), findsNothing);
    expect(find.byKey(const ValueKey('pin-number')), findsOneWidget);
    expect(find.text('desk did not answer'), findsNothing);
    expect(await itemsOf(tester, 'pin-mode'), hasLength(6));
  });

  testWidgets('strapping pin warnings from board.pins are shown', (
    tester,
  ) async {
    engine.answers['board.pins'] = {
      'ok': true,
      'board': {'id': 'desk'},
      'warnings': [
        'GPIO 2 is a strapping pin: the board may not boot if it is held low',
        {'pin': 12, 'message': 'sets the flash voltage at boot'},
      ],
    };
    await openPins(tester);
    await tester.enterText(find.byKey(const ValueKey('pin-name')), 'led');
    await pick(tester, 'pin-gpio', 'GPIO 2');
    await tester.tap(find.byKey(const ValueKey('pin-save')));
    await tester.pumpAndSettle();
    final warnings = find.byKey(const ValueKey('pin-warnings'));
    expect(warnings, findsOneWidget);
    expect(
      find.descendant(
        of: warnings,
        matching: find.text(
          'GPIO 2 is a strapping pin: the board may not boot if it is held low',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: warnings,
        matching: find.text('GPIO 12: sets the flash voltage at boot'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('warnings board.describe gives show when the sheet opens', (
    tester,
  ) async {
    engine.answers['board.describe'] = {
      ...engine.answers['board.describe']!,
      'warnings': [
        'button: GPIO 3 is a boot strapping pin on esp32. Holding it low '
            'at power-on can stop the board from booting',
      ],
    };
    await openPins(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pin-warnings')),
        matching: find.textContaining('GPIO 3 is a boot strapping pin'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a refused pin shows the engine\'s reason, not only "pins"', (
    tester,
  ) async {
    engine.answers['board.pins'] = {
      'ok': false,
      'error': {
        'type': 'invalid',
        'message': 'pins',
        'issues': [
          {'path': 'pins.relay.pin', 'message': 'pin 3 is already "button"'},
        ],
      },
    };
    await openPins(tester);
    await tester.enterText(find.byKey(const ValueKey('pin-name')), 'relay');
    await pick(tester, 'pin-gpio', 'GPIO 3 (button)');
    await tester.tap(find.byKey(const ValueKey('pin-save')));
    await tester.pumpAndSettle();
    expect(
      find.text('pins\npins.relay.pin: pin 3 is already "button"'),
      findsOneWidget,
    );
  });

  testWidgets('an active low relay sends invert, and only for out pins', (
    tester,
  ) async {
    engine.onCall = (command, args) {
      if (command != 'board.pins') return;
      engine.devices = [
        {
          ...board,
          'settings': {'pins': args['pins']},
        },
      ];
    };
    await openPins(tester);
    final activeLow = find.byKey(const ValueKey('pin-active-low'));
    expect(activeLow, findsOneWidget);
    expect(find.text('Relay is active low'), findsOneWidget);

    await pick(tester, 'pin-mode', 'pwm - level 0 to 100%');
    expect(activeLow, findsNothing);
    await pick(tester, 'pin-mode', 'out - switch (relay, LED)');

    await tester.enterText(find.byKey(const ValueKey('pin-name')), 'relay');
    await pick(tester, 'pin-gpio', 'GPIO 4');
    await tester.tap(activeLow);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pin-save')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('board.pins').single.$2['pins'], {
      'button': {'pin': 3, 'mode': 'in_pullup'},
      'relay': {'pin': 4, 'mode': 'out', 'invert': true},
    });
    expect(find.text('GPIO 4, out, active low'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(activeLow).value, isFalse);
  });

  testWidgets('an out pin left active high sends no invert', (tester) async {
    await openPins(tester);
    await tester.enterText(find.byKey(const ValueKey('pin-name')), 'led');
    await pick(tester, 'pin-gpio', 'GPIO 2');
    await tester.tap(find.byKey(const ValueKey('pin-save')));
    await tester.pumpAndSettle();
    expect((engine.callsOf('board.pins').single.$2['pins'] as Map)['led'], {
      'pin': 2,
      'mode': 'out',
    });
  });
}
