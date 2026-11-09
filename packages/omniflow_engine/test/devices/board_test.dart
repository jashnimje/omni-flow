import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

void main() {
  group('pins setting', () {
    test('each pin becomes the capability its mode implies', () {
      final pins = parseBoardPins({
        'relay': {'pin': 4, 'mode': 'out'},
        'fan': {'pin': 5, 'mode': 'pwm'},
        'arm': {'pin': 13, 'mode': 'servo'},
        'door': {'pin': 0, 'mode': 'in_pullup'},
        'light': {'pin': 34, 'mode': 'adc'},
      });
      final caps = {for (final p in pins) p.name: p.capability};
      expect(caps['relay']!.type, CapabilityType.toggle);
      expect(caps['relay']!.command, {
        'cmd': 'pin.write',
        'pin': 4,
        'value': '{{value}}',
      });
      expect(caps['fan']!.type, CapabilityType.level);
      expect(caps['fan']!.params['value']!.max, 100);
      expect(caps['arm']!.params['value']!.max, 180);
      expect(caps['door']!.type, CapabilityType.sensor);
      expect(caps['light']!.stateJsonPath, r'$.light');
    });

    test('inputs are watched by default, and in_pullup is active low', () {
      final pins = parseBoardPins({
        'door': {'pin': 0, 'mode': 'in_pullup'},
        'light': {'pin': 34, 'mode': 'adc'},
        'quiet': {'pin': 2, 'mode': 'in', 'watch': false},
        'switch': {'pin': 3, 'mode': 'in_pullup', 'invert': false},
      });
      final byName = {for (final p in pins) p.name: p};
      expect(byName['door']!.watchMs, 50);
      expect(byName['light']!.watchMs, 1000);
      expect(byName['light']!.watchDelta, 2);
      expect(byName['quiet']!.watchMs, isNull);
      expect(byName['door']!.stateValue(0), isTrue);
      expect(byName['door']!.stateValue(1), isFalse);
      expect(byName['switch']!.stateValue(1), isTrue);
      expect(byName['light']!.stateValue(42), 42);
    });

    test('every mistake is reported at once', () {
      expect(
        () => parseBoardPins(
          {
            'Relay': {'pin': 4, 'mode': 'out'},
            'a': {'pin': 4, 'mode': 'out'},
            'b': {'pin': 4, 'mode': 'out'},
            'c': {'pin': 50, 'mode': 'out'},
            'd': {'pin': 6, 'mode': 'blink'},
            'e': {
              'pin': 7,
              'mode': 'out',
              'watch': {'ms': 50},
            },
            'ir_nec': {'pin': 8, 'mode': 'out'},
          },
          reserved: {'ir_nec'},
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.issues.map((i) => i.path).toList(),
            'paths',
            [
              r'$.Relay',
              r'$.b.pin',
              r'$.c.pin',
              r'$.d.mode',
              r'$.e.watch',
              r'$.ir_nec',
            ],
          ),
        ),
      );
    });
  });

  test('a board device gets its pin capabilities after the built-in ones', () {
    final registry = DriverRegistry.withBuiltIns();
    const device = Device(
      id: 'desk',
      name: 'Desk',
      driverId: 'omniflow_board',
      host: '192.168.1.40',
      settings: {
        'pins': {
          'relay': {'pin': 4, 'mode': 'out'},
        },
      },
    );
    final manifest = manifestFor(registry, device)!;
    expect(manifest.capabilities.map((c) => c.id), [
      'ir_nec',
      'ir_code',
      'rf_send',
      'relay',
    ]);
    expect(registry['omniflow_board']!.capabilities, hasLength(3));
  });

  test('pins the board does not offer are named with what it can do', () {
    final pins = parseBoardPins({
      'radio': {'pin': 25, 'mode': 'out'},
      'level': {'pin': 16, 'mode': 'adc'},
      'ok': {'pin': 26, 'mode': 'adc'},
    });
    final problems = pinsUnsupportedBy(pins, {
      'board': 'pico_w',
      'pins': [
        {
          'pin': 16,
          'caps': ['in', 'out', 'pwm', 'servo'],
        },
        {
          'pin': 26,
          'caps': ['in', 'out', 'pwm', 'servo', 'adc'],
        },
      ],
    });
    expect(problems, [
      'radio: pin 25 is not available on pico_w',
      'level: pin 16 on pico_w cannot do adc (it can do in, out, pwm, servo)',
    ]);
  });

  test('setup restores remembered outputs and watches inputs', () {
    final pins = parseBoardPins({
      'relay': {'pin': 4, 'mode': 'out'},
      'fan': {'pin': 5, 'mode': 'pwm'},
      'door': {'pin': 0, 'mode': 'in_pullup'},
    });
    expect(pinSetupCommands(pins, {'relay': true}), [
      {'cmd': 'pin.mode', 'pin': 4, 'mode': 'out', 'value': 1},
      {'cmd': 'pin.write', 'pin': 4, 'value': true},
      {'cmd': 'pin.mode', 'pin': 5, 'mode': 'pwm'},
      {'cmd': 'pin.mode', 'pin': 0, 'mode': 'in_pullup'},
      {'cmd': 'pin.watch', 'pin': 0, 'ms': 50, 'delta': 0},
    ]);
  });

  test('every mode and write goes out before the first watch', () {
    final pins = parseBoardPins({
      'button': {'pin': 0, 'mode': 'in_pullup'},
      'relay': {'pin': 4, 'mode': 'out'},
    });
    expect(pinSetupCommands(pins, {'relay': false}).map((c) => c['cmd']), [
      'pin.mode',
      'pin.mode',
      'pin.write',
      'pin.watch',
    ]);
  });

  test('pins no longer configured are released and unwatched inputs stop', () {
    final pins = parseBoardPins({
      'door': {'pin': 0, 'mode': 'in', 'watch': false},
    });
    final describe = {
      'pins': [
        {
          'pin': 0,
          'mode': 'in',
          'caps': ['in', 'out'],
        },
        {
          'pin': 4,
          'mode': 'out',
          'caps': ['in', 'out'],
        },
        {
          'pin': 5,
          'mode': 'none',
          'caps': ['in', 'out'],
        },
        {
          'pin': 6,
          'caps': ['in', 'out'],
        },
      ],
    };
    expect(pinsSetOnBoard(describe), [0, 4]);
    // The shape the firmware sends: a top-level list of pins with a mode.
    expect(
      pinsSetOnBoard({
        'pins': describe['pins'],
        'set': [
          {'pin': 7, 'mode': 'out'},
          {'pin': 8, 'mode': 'none'},
        ],
      }),
      [7],
    );
    expect(
      pinSetupCommands(pins, const {}, current: pinsSetOnBoard(describe)),
      [
        {'cmd': 'pin.mode', 'pin': 4, 'mode': 'none'},
        {'cmd': 'pin.mode', 'pin': 0, 'mode': 'in'},
        {'cmd': 'pin.watch', 'pin': 0, 'off': true},
      ],
    );
  });

  test('more watched pins than the board has watches is refused', () {
    final pins = parseBoardPins({
      'a': {'pin': 0, 'mode': 'in'},
      'b': {'pin': 1, 'mode': 'in'},
      'c': {'pin': 2, 'mode': 'in', 'watch': false},
    });
    final describe = {
      'board': 'uno',
      'watches': 1,
      'pins': [
        for (final p in [0, 1, 2])
          {
            'pin': p,
            'caps': ['in'],
          },
      ],
    };
    expect(pinsUnsupportedBy(pins, describe), [
      '2 pins are watched but uno can watch 1: '
          'set "watch": false on the inputs that do not need it',
    ]);
    expect(pinsUnsupportedBy(pins, {...describe, 'watches': 2}), isEmpty);
  });

  test(
    'in_pullup needs a pull-up when the board reports which pins have one',
    () {
      final pins = parseBoardPins({
        'button': {'pin': 34, 'mode': 'in_pullup'},
      });
      expect(
        pinsUnsupportedBy(pins, {
          'board': 'esp32',
          'pins': [
            {
              'pin': 4,
              'caps': ['in', 'pullup', 'out'],
            },
            {
              'pin': 34,
              'caps': ['in', 'adc'],
            },
          ],
        }),
        [
          'button: pin 34 on esp32 has no internal pull-up: add an external '
              'resistor and use mode in',
        ],
      );
      expect(
        pinsUnsupportedBy(pins, {
          'board': 'esp32',
          'pins': [
            {
              'pin': 34,
              'caps': ['in', 'adc'],
            },
          ],
        }),
        isEmpty,
        reason: 'firmware that reports no pullup at all is not second-guessed',
      );
    },
  );

  test('an output reads back as on or off', () {
    final relay = parseBoardPins({
      'relay': {'pin': 4, 'mode': 'out'},
    }).single;
    expect(relay.stateValue(1), true);
    expect(relay.stateValue(0), false);
    expect(
      pinSetupCommands([relay], {'relay': relay.stateValue(1)}),
      contains(equals({'cmd': 'pin.write', 'pin': 4, 'value': true})),
    );
  });

  group('an active-low output', () {
    final relay = parseBoardPins({
      'relay': {'pin': 4, 'mode': 'out', 'invert': true},
    }).single;

    test('keeps state logical and drives the opposite level', () {
      expect(relay.invert, isTrue);
      expect(relay.stateValue(0), isTrue);
      expect(relay.stateValue(1), isFalse);
      expect(relay.levelFor(true), 0);
      expect(relay.levelFor(false), 1);
      final capability = relay.capability;
      expect(capability.toDevice(true), 0);
      expect(capability.toDevice(false), 1);
      expect(capability.fromDevice(0), isTrue);
      expect(relay.toJson(), {'pin': 4, 'mode': 'out', 'invert': true});
    });

    test('starts off at its mode, with no remembered state', () {
      expect(pinSetupCommands([relay], const {}), [
        {'cmd': 'pin.mode', 'pin': 4, 'mode': 'out', 'value': 1},
        {'cmd': 'pin.write', 'pin': 4, 'value': 1},
      ]);
    });

    test('starts as remembered', () {
      expect(pinSetupCommands([relay], {'relay': true}), [
        {'cmd': 'pin.mode', 'pin': 4, 'mode': 'out', 'value': 0},
        {'cmd': 'pin.write', 'pin': 4, 'value': 0},
      ]);
    });

    test('a plain output with nothing remembered starts low', () {
      final plain = parseBoardPins({
        'lamp': {'pin': 5, 'mode': 'out'},
      });
      expect(pinSetupCommands(plain, const {}), [
        {'cmd': 'pin.mode', 'pin': 5, 'mode': 'out', 'value': 0},
      ]);
      expect(plain.single.toJson(), {'pin': 5, 'mode': 'out'});
    });

    test('invert is refused on pwm, servo and adc pins', () {
      expect(
        () => parseBoardPins({
          'fan': {'pin': 5, 'mode': 'pwm', 'invert': true},
          'arm': {'pin': 6, 'mode': 'servo', 'invert': false},
          'light': {'pin': 34, 'mode': 'adc', 'invert': true},
          'bad': {'pin': 7, 'mode': 'out', 'invert': 'yes'},
        }),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.issues.map((i) => i.path).toList(),
            'paths',
            [
              r'$.fan.invert',
              r'$.arm.invert',
              r'$.light.invert',
              r'$.bad.invert',
            ],
          ),
        ),
      );
    });
  });

  group('strapping pins', () {
    final pins = parseBoardPins({
      'boot': {'pin': 0, 'mode': 'in_pullup'},
      'led': {'pin': 2, 'mode': 'out'},
      'cs': {'pin': 5, 'mode': 'out'},
      'flash': {'pin': 12, 'mode': 'in'},
      'tx': {'pin': 15, 'mode': 'out'},
      'safe': {'pin': 4, 'mode': 'out'},
    });

    List<String> warnedOn(String board) => [
      for (final w in strappingPinWarnings(pins, {'board': board}))
        w.split(':').first,
    ];

    test('ESP32 warns on GPIO 0, 2, 5, 12 and 15', () {
      expect(warnedOn('esp32'), ['boot', 'led', 'cs', 'flash', 'tx']);
      expect(
        strappingPinWarnings(pins, {'board': 'esp32'}).first,
        startsWith('boot: GPIO 0 is a boot strapping pin on esp32'),
      );
    });

    test('ESP8266 warns on GPIO 0, 2 and 15', () {
      expect(warnedOn('esp8266'), ['boot', 'led', 'tx']);
    });

    test('other boards and an unknown board give no warnings', () {
      expect(warnedOn('pico_w'), isEmpty);
      expect(warnedOn('uno'), isEmpty);
      expect(strappingPinWarnings(pins, const {}), isEmpty);
    });

    test('a warning never refuses the pin', () {
      final describe = {
        'board': 'esp32',
        'pins': [
          for (final p in [0, 2, 4, 5, 12, 15])
            {
              'pin': p,
              'caps': ['in', 'pullup', 'out'],
            },
        ],
      };
      expect(pinsUnsupportedBy(pins, describe), isEmpty);
    });
  });

  test('a kept describe drops the reply id and message type', () {
    expect(
      boardDescribeOf({
        'node': 'desk',
        'event': 'describe',
        'id': 7,
        'board': 'esp32',
        'rf': true,
      }),
      {'node': 'desk', 'board': 'esp32', 'rf': true},
    );
  });

  group('rf_send', () {
    final rf = DriverRegistry.withBuiltIns()['omniflow_board']!.capability(
      'rf_send',
    )!;

    Object? rendered(Map<String, Object?> params) => const TemplateRenderer()
        .render(rf.command, TemplateContext(params: rf.validateParams(params)));

    test('sends rf.send with the firmware defaults: 24 bits, protocol 1, 10 repeats', () {
      expect(rendered({'code': 5393}), {
        'cmd': 'rf.send',
        'code': 5393,
        'bits': 24,
        'protocol': 1,
        'repeat': 10,
      });
      expect(
        rendered({'code': 4294967295, 'bits': 32, 'protocol': 3, 'repeat': 20}),
        {
          'cmd': 'rf.send',
          'code': 4294967295,
          'bits': 32,
          'protocol': 3,
          'repeat': 20,
        },
      );
    });

    test('refuses a code, bits, protocol or repeat out of range', () {
      for (final bad in [
        {'code': -1},
        {'code': 4294967296},
        {'code': 1.5},
        {'code': 1, 'bits': 0},
        {'code': 1, 'bits': 33},
        {'code': 1, 'protocol': 4},
        {'code': 1, 'protocol': 0},
        {'code': 1, 'repeat': 0},
        {'code': 1, 'repeat': 21},
        <String, Object?>{},
      ]) {
        expect(
          () => rf.validateParams(bad),
          throwsA(isA<ValidationException>()),
          reason: '$bad',
        );
      }
    });

    test('rf_send is a reserved pin name', () {
      expect(
        () => boardPinsOf(
          const Device(
            id: 'desk',
            name: 'Desk',
            driverId: 'omniflow_board',
            host: '192.168.1.40',
            settings: {
              'pins': {
                'rf_send': {'pin': 4, 'mode': 'out'},
              },
            },
          ),
          DriverRegistry.withBuiltIns()['omniflow_board']!,
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  test('a serial port path picks the serial link', () {
    expect(isSerialHost('/dev/cu.usbmodem1101'), isTrue);
    expect(isSerialHost('COM3'), isTrue);
    expect(isSerialHost('192.168.1.40'), isFalse);
  });
}
