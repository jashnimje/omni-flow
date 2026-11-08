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
      'relay',
    ]);
    expect(registry['omniflow_board']!.capabilities, hasLength(2));
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
      {'cmd': 'pin.mode', 'pin': 4, 'mode': 'out'},
      {'cmd': 'pin.write', 'pin': 4, 'value': true},
      {'cmd': 'pin.mode', 'pin': 5, 'mode': 'pwm'},
      {'cmd': 'pin.mode', 'pin': 0, 'mode': 'in_pullup'},
      {'cmd': 'pin.watch', 'pin': 0, 'ms': 50, 'delta': 0},
    ]);
  });

  test('a serial port path picks the serial link', () {
    expect(isSerialHost('/dev/cu.usbmodem1101'), isTrue);
    expect(isSerialHost('COM3'), isTrue);
    expect(isSerialHost('192.168.1.40'), isFalse);
  });
}
