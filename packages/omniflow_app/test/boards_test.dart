import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/boards/add_pin_page.dart';
import 'package:omniflow_app/ui/boards/board_page.dart';
import 'package:omniflow_app/ui/boards/board_pins.dart';
import 'package:omniflow_app/ui/boards/pin_sheet.dart';
import 'package:omniflow_app/ui/design/design.dart';

import 'fake_engine.dart';
import 'screen_harness.dart';

final board = <String, Object?>{
  'id': 'desk',
  'name': 'Desk board',
  'driver': 'omniflow_board',
  'board': true,
  'host': '192.168.1.77',
  'stableId': 'desk_board',
  'settings': {
    'pins': {
      'button': {'pin': 3, 'mode': 'in_pullup'},
      'knob': {'pin': 34, 'mode': 'adc'},
      'relay': {'pin': 4, 'mode': 'out', 'invert': true},
    },
  },
  'state': {'button': false, 'knob': 42, 'relay': true},
  'capabilities': const <Object?>[],
};

/// An ESP32-like describe: 2 and 4 do everything digital, 4 also reads
/// analog, 34 is input only, and 18 drives the IR LED.
final describe = <String, Object?>{
  'board': 'esp32',
  'fw': '2',
  'node': 'desk_board',
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
      'pin': 5,
      'caps': ['in', 'out'],
    },
    {
      'pin': 34,
      'caps': ['in', 'adc'],
    },
  ],
  'periph': [
    {
      'type': 'ir',
      'pins': {'tx': 18},
    },
  ],
  'periphTypes': ['ir', 'rf', 'nfc_rc522', 'nfc_pn532'],
};

void main() {
  late FakeEngine engine;

  /// Keeps the pins board.pins was sent, as the engine does.
  void persistPins() => engine.onCall = (command, args) {
    if (command != 'board.pins') return;
    engine.devices = [
      {
        ...board,
        'settings': {'pins': args['pins']},
      },
    ];
  };

  setUp(() {
    engine = FakeEngine();
    engine.devices = [board];
    engine.answers['board.describe'] = {
      'ok': true,
      'id': 'desk',
      'live': true,
      'describe': describe,
      'bootPins': [2, 5],
      'warnings': const <Object?>[],
    };
  });

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  group('5.1 board page', () {
    testWidgets('shows what the board is, its pins with live values, and '
        'its extras', (tester) async {
      await pumpScreen(tester, engine, const BoardPage(id: 'desk'));
      expect(engine.callsOf('board.describe').single.$2, {'id': 'desk'});
      expect(find.text('ESP32 · online'), findsOneWidget);
      expect(
        find.text('desk_board · 192.168.1.77 · firmware 2'),
        findsOneWidget,
      );
      expect(find.text('Button'), findsOneWidget);
      expect(find.text('GPIO 3 · button to ground'), findsOneWidget);
      expect(find.text('released'), findsOneWidget);
      expect(find.text('GPIO 34 · analog'), findsOneWidget);
      expect(find.text('42%'), findsOneWidget);
      expect(find.text('GPIO 4 · switch · active low'), findsOneWidget);
      expect(
        tester
            .widget<Switch>(find.byKey(const ValueKey('pin-switch-relay')))
            .value,
        isTrue,
      );
      expect(find.text('IR LED'), findsOneWidget);
      expect(find.text('GPIO 18 · send remote codes'), findsOneWidget);
      expect(find.text('NFC reader'), findsOneWidget);
      expect(find.text('RC522 · not set'), findsOneWidget);
    });

    testWidgets('a relay switch drives the pin through device.invoke', (
      tester,
    ) async {
      await pumpScreen(tester, engine, const BoardPage(id: 'desk'));
      await tapKey(tester, 'pin-switch-relay');
      expect(engine.callsOf('device.invoke').single.$2, {
        'id': 'desk',
        'capability': 'relay',
        'params': {'value': false},
      });
    });

    testWidgets('an offline board says so and shows what it last reported', (
      tester,
    ) async {
      engine.answers['board.describe'] = {
        'ok': true,
        'id': 'desk',
        'live': false,
        'seenAt': '2026-11-08T12:50:00Z',
        'describe': describe,
      };
      await pumpScreen(tester, engine, const BoardPage(id: 'desk'));
      expect(find.byKey(const ValueKey('board-stale')), findsOneWidget);
      expect(find.text('ESP32 · not answering'), findsOneWidget);
    });

    testWidgets('a board that never answered offers to try again', (
      tester,
    ) async {
      engine.answers['board.describe'] = {
        'ok': false,
        'error': {'type': 'timeout', 'message': 'no answer'},
      };
      await pumpScreen(tester, engine, const BoardPage(id: 'desk'));
      expect(find.byKey(const ValueKey('board-offline')), findsOneWidget);
      expect(find.text('Board · not answering'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('board.describe'), hasLength(2));
    });

    testWidgets('a board with no pins says what to add', (tester) async {
      engine.devices = [
        {...board, 'settings': const <String, Object?>{}},
      ];
      await pumpScreen(tester, engine, const BoardPage(id: 'desk'));
      expect(find.byKey(const ValueKey('pins-empty')), findsOneWidget);
    });

    testWidgets('removing a pin asks first, and Cancel keeps it', (
      tester,
    ) async {
      persistPins();
      await pumpScreen(tester, engine, const BoardPage(id: 'desk'));
      await tapKey(tester, 'pin-button');
      await tapKey(tester, 'pin-remove');
      expect(find.text('Remove Button?'), findsOneWidget);
      expect(find.textContaining('GPIO 3'), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('board.pins'), isEmpty);

      await tapKey(tester, 'pin-button');
      await tapKey(tester, 'pin-remove');
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('board.pins').single.$2, {
        'id': 'desk',
        'pins': {
          'knob': {'pin': 34, 'mode': 'adc'},
          'relay': {'pin': 4, 'mode': 'out', 'invert': true},
        },
      });
      expect(find.text('Button'), findsNothing);
    });

    testWidgets('removing the board asks first, then removes it', (
      tester,
    ) async {
      await pumpScreen(tester, engine, const BoardPage(id: 'desk'));
      await tapKey(tester, 'board-more');
      await tapKey(tester, 'board-remove');
      expect(find.text('Remove Desk board?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('device.remove'), isEmpty);

      await tapKey(tester, 'board-more');
      await tapKey(tester, 'board-remove');
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('device.remove').single.$2, {'id': 'desk'});
      expect(find.byType(BoardPage), findsNothing);
    });

    testWidgets('an extra is set and cleared with board.periph, clearing '
        'after a confirm', (tester) async {
      await pumpScreen(tester, engine, const BoardPage(id: 'desk'));
      await tapKey(tester, 'extra-nfc_rc522');
      await tester.enterText(find.byKey(const ValueKey('extra-pin-ss')), '5');
      await tester.enterText(find.byKey(const ValueKey('extra-pin-rst')), '22');
      await tester.pump();
      await tapKey(tester, 'extra-save');
      expect(engine.callsOf('board.periph').single.$2, {
        'id': 'desk',
        'type': 'nfc_rc522',
        'pins': {'ss': 5, 'rst': 22},
      });

      await tapKey(tester, 'extra-ir');
      await tapKey(tester, 'extra-clear');
      expect(find.text('Remove the IR LED?'), findsOneWidget);
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('board.periph').last.$2, {
        'id': 'desk',
        'type': 'ir',
        'clear': true,
      });
    });

    testWidgets('a board on Wi-Fi says why the extra was not set', (
      tester,
    ) async {
      engine.answers['board.periph'] = {
        'ok': false,
        'error': {
          'type': 'invalid',
          'message': 'a board takes peripherals over USB only',
        },
      };
      await pumpScreen(tester, engine, const BoardPage(id: 'desk'));
      await tapKey(tester, 'extra-rf');
      await tester.enterText(find.byKey(const ValueKey('extra-pin-tx')), '19');
      await tester.pump();
      await tapKey(tester, 'extra-save');
      expect(find.byKey(const ValueKey('extra-failed')), findsOneWidget);
      expect(find.textContaining('over USB only'), findsWidgets);
    });

    testWidgets('meets the tap target, label and contrast guidelines', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester, engine, const BoardPage(id: 'desk'));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });

  group('5.2 add a pin', () {
    bool enabled(WidgetTester tester, int pin) =>
        tester
            .getSemantics(find.byKey(ValueKey('gpio-$pin')))
            .flagsCollection
            .isEnabled ==
        Tristate.isTrue;

    Future<void> openAdd(WidgetTester tester) async {
      persistPins();
      await pumpScreen(tester, engine, const AddPinPage(id: 'desk'));
    }

    testWidgets('only the pins that can do the job are offered, and used '
        'ones are marked', (tester) async {
      final handle = tester.ensureSemantics();
      await openAdd(tester);
      expect(find.text('Button or switch'), findsOneWidget);
      expect(enabled(tester, 2), isTrue);
      expect(enabled(tester, 3), isFalse);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('gpio-3'))).label,
        contains('used by Button'),
      );
      expect(enabled(tester, 34), isFalse);
      await tapKey(tester, 'pin-role-analog');
      expect(enabled(tester, 2), isFalse);
      expect(enabled(tester, 34), isFalse);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('gpio-34'))).label,
        contains('used by Knob'),
      );
      await tapKey(tester, 'pin-role-dimmer');
      expect(enabled(tester, 2), isTrue);
      expect(enabled(tester, 5), isFalse);
      handle.dispose();
    });

    testWidgets('a boot pin warns, and Save sends the plain-word role as a '
        'mode', (tester) async {
      await openAdd(tester);
      await tester.enterText(
        find.byKey(const ValueKey('pin-name')),
        'Door sensor',
      );
      await tester.pump();
      expect(find.text('Saved as door_sensor'), findsOneWidget);
      await tapKey(tester, 'gpio-2');
      expect(find.byKey(const ValueKey('pin-boot-warning')), findsOneWidget);
      expect(
        find.textContaining('GPIO 2 is a boot pin on ESP32'),
        findsOneWidget,
      );
      await tapKey(tester, 'pin-save');
      expect(engine.callsOf('board.pins').single.$2['pins'], {
        'button': {'pin': 3, 'mode': 'in_pullup'},
        'knob': {'pin': 34, 'mode': 'adc'},
        'relay': {'pin': 4, 'mode': 'out', 'invert': true},
        'door_sensor': {'pin': 2, 'mode': 'in_pullup'},
      });
      expect(find.byType(AddPinPage), findsNothing);
    });

    testWidgets('a button not wired to ground is a plain input', (
      tester,
    ) async {
      await openAdd(tester);
      await tester.enterText(find.byKey(const ValueKey('pin-name')), 'door');
      await tapKey(tester, 'pin-to-ground');
      await tapKey(tester, 'gpio-5');
      await tapKey(tester, 'pin-save');
      expect((engine.callsOf('board.pins').single.$2['pins'] as Map)['door'], {
        'pin': 5,
        'mode': 'in',
      });
    });

    testWidgets('an active low relay sends invert, and only for a relay', (
      tester,
    ) async {
      await openAdd(tester);
      await tester.enterText(find.byKey(const ValueKey('pin-name')), 'lamp');
      await tapKey(tester, 'pin-role-relay');
      await tapKey(tester, 'pin-active-low');
      await tapKey(tester, 'gpio-2');
      await tapKey(tester, 'pin-save');
      expect((engine.callsOf('board.pins').single.$2['pins'] as Map)['lamp'], {
        'pin': 2,
        'mode': 'out',
        'invert': true,
      });
    });

    testWidgets('a name in use asks before replacing it', (tester) async {
      await openAdd(tester);
      await tester.enterText(find.byKey(const ValueKey('pin-name')), 'Button');
      await tapKey(tester, 'gpio-2');
      await tapKey(tester, 'pin-save');
      expect(find.text('Replace Button?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('board.pins'), isEmpty);
      await tapKey(tester, 'pin-save');
      await tapKey(tester, 'confirm');
      expect(
        (engine.callsOf('board.pins').single.$2['pins'] as Map)['button'],
        {'pin': 2, 'mode': 'in_pullup'},
      );
    });

    testWidgets('a refused pin shows the engine reason and stays', (
      tester,
    ) async {
      engine.answers['board.pins'] = {
        'ok': false,
        'error': {
          'type': 'invalid',
          'message': 'pins',
          'issues': [
            {'path': 'pins.door', 'message': 'GPIO 2 is in use by the IR LED'},
          ],
        },
      };
      await openAdd(tester);
      await tester.enterText(find.byKey(const ValueKey('pin-name')), 'door');
      await tapKey(tester, 'gpio-2');
      await tapKey(tester, 'pin-save');
      expect(find.byKey(const ValueKey('pin-refused')), findsOneWidget);
      expect(find.text('GPIO 2 is in use by the IR LED.'), findsOneWidget);
      expect(find.byType(AddPinPage), findsOneWidget);
    });

    testWidgets('a board that cannot describe itself takes a typed GPIO', (
      tester,
    ) async {
      engine.answers['board.describe'] = {
        'ok': false,
        'error': {'type': 'timeout', 'message': 'no answer'},
      };
      await openAdd(tester);
      expect(find.byKey(const ValueKey('pin-no-describe')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('pin-name')), 'door');
      await tester.enterText(find.byKey(const ValueKey('pin-number')), '14');
      await tester.pump();
      await tapKey(tester, 'pin-save');
      expect((engine.callsOf('board.pins').single.$2['pins'] as Map)['door'], {
        'pin': 14,
        'mode': 'in_pullup',
      });
    });

    testWidgets('meets the tap target, label and contrast guidelines', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await openAdd(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  });

  group('the pin sheet', () {
    Widget host() => Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            key: const ValueKey('open-pins'),
            onPressed: () => showOmniSheet<void>(
              context,
              builder: (_) => PinSheet(device: board),
            ),
            child: const Text('Pins'),
          ),
        ),
      ),
    );

    testWidgets('lists the pins, removes one after a confirm, and adds one '
        'with the picker', (tester) async {
      persistPins();
      await pumpScreen(tester, engine, host());
      await tapKey(tester, 'open-pins');
      expect(find.text('GPIO 34 · analog'), findsOneWidget);
      await tapKey(tester, 'pin-remove-knob');
      expect(find.text('Remove Knob?'), findsOneWidget);
      await tapKey(tester, 'confirm');
      expect((engine.callsOf('board.pins').single.$2['pins'] as Map).keys, [
        'button',
        'relay',
      ]);
      expect(find.text('GPIO 34 · analog'), findsNothing);
      await tapKey(tester, 'pin-add');
      expect(find.byType(AddPinPage), findsOneWidget);
    });
  });

  test('pin words, names and board types', () {
    const pin = NamedPin(name: 'door_sensor', pin: 2, mode: 'in');
    expect(pin.label, 'Door sensor');
    expect(pin.description, 'GPIO 2 · button');
    expect(pin.valueIn({'door_sensor': true}), 'pressed');
    expect(pinNameFor('Door sensor'), 'door_sensor');
    expect(pinNameFor('2nd relay'), 'pin_2nd_relay');
    expect(boardTypeLabel('esp8266'), 'ESP8266');
    expect(PinRole.button.mode(), 'in_pullup');
    expect(PinRole.button.mode(toGround: false), 'in');
    expect(capabilityFor('in_pullup'), 'pullup');
  });
}
