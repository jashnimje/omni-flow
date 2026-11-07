import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

DateTime at(int h, int m) => DateTime(2026, 11, 6, h, m);

void main() {
  group('time windows', () {
    test('a window that crosses midnight', () {
      expect(inTimeWindow(at(23, 0), '18:00', '05:00'), isTrue);
      expect(inTimeWindow(at(2, 0), '18:00', '05:00'), isTrue);
      expect(inTimeWindow(at(12, 0), '18:00', '05:00'), isFalse);
    });

    test('start is inside, end is not', () {
      expect(inTimeWindow(at(18, 0), '18:00', '05:00'), isTrue);
      expect(inTimeWindow(at(5, 0), '18:00', '05:00'), isFalse);
      expect(inTimeWindow(at(9, 0), '09:00', '17:30'), isTrue);
      expect(inTimeWindow(at(17, 30), '09:00', '17:30'), isFalse);
    });

    test('equal start and end is the whole day', () {
      expect(inTimeWindow(at(3, 33), '07:00', '07:00'), isTrue);
    });
  });

  group('rules', () {
    final ctx = EvalContext(
      now: at(19, 0),
      globals: const {'HomeWifiConnected': true, 'Lux': 120, 'Mode': 'home'},
      flowVars: const {'count': 3},
      deviceStates: const {
        'desk_lamp': {'state': true, 'dimming': 80.0},
      },
    );

    test('the evening-desk condition', () {
      final rule = {
        'type': 'all_of',
        'rules': [
          {'type': 'time_window', 'start': '18:00', 'end': '05:00'},
          {'type': 'var_equals', 'name': r'$HomeWifiConnected', 'value': true},
        ],
      };
      expect(evaluateRule(rule, ctx), isTrue);
      expect(
        evaluateRule(rule, EvalContext(now: at(12, 0), globals: ctx.globals)),
        isFalse,
      );
    });

    test('any_of, xor, not and nesting', () {
      Map<String, Object?> v(String n, Object? value) => {
        'type': 'var_equals',
        'name': n,
        'value': value,
      };
      expect(
        evaluateRule({
          'type': 'any_of',
          'rules': [v(r'$Mode', 'away'), v(r'$Mode', 'home')],
        }, ctx),
        isTrue,
      );
      expect(
        evaluateRule({
          'type': 'xor',
          'rules': [v(r'$Mode', 'home'), v('%count', 3)],
        }, ctx),
        isFalse,
      );
      expect(
        evaluateRule({
          'type': 'xor',
          'rules': [v(r'$Mode', 'home'), v('%count', 4)],
        }, ctx),
        isTrue,
      );
      expect(
        evaluateRule({'type': 'not', 'rule': v(r'$Mode', 'away')}, ctx),
        isTrue,
      );
    });

    test(
      'var_compare is numeric and false for missing or non-numeric values',
      () {
        Map<String, Object?> c(String n, String op, num value) => {
          'type': 'var_compare',
          'name': n,
          'op': op,
          'value': value,
        };
        expect(evaluateRule(c(r'$Lux', '<', 200), ctx), isTrue);
        expect(evaluateRule(c(r'$Lux', '>=', 120), ctx), isTrue);
        expect(evaluateRule(c(r'$Missing', '<', 200), ctx), isFalse);
        expect(evaluateRule(c(r'$Mode', '<', 200), ctx), isFalse);
      },
    );

    test('device_state_is compares numbers by value', () {
      expect(
        evaluateRule({
          'type': 'device_state_is',
          'deviceId': 'desk_lamp',
          'key': 'dimming',
          'value': 80,
        }, ctx),
        isTrue,
      );
      expect(
        evaluateRule({
          'type': 'device_state_is',
          'deviceId': 'nobody',
          'key': 'state',
          'value': true,
        }, ctx),
        isFalse,
      );
    });
  });

  group('expressions', () {
    num eval(String e, [Map<String, num> vars = const {}]) =>
        evaluateExpression(e, (n) => vars[n]);

    test('precedence, parentheses, unary minus and functions', () {
      expect(eval('1 + 2 * 3'), 7);
      expect(eval('(1 + 2) * 3'), 9);
      expect(eval('-value + 10', {'value': 4}), 6);
      expect(eval('round(value / 3)', {'value': 10}), 3);
      expect(eval('clamp(value * 2, 10, 100)', {'value': 70}), 100);
      expect(eval(r'max($Lux, 5, %n)', {r'$Lux': 3, '%n': 9}), 9);
      expect(eval('10 % 4'), 2);
    });

    test('rejects unknown names, functions, division by zero and junk', () {
      expect(() => eval('value + 1'), throwsA(isA<ExpressionException>()));
      expect(() => eval('exec(1)'), throwsA(isA<ExpressionException>()));
      expect(() => eval('1 / 0'), throwsA(isA<ExpressionException>()));
      expect(() => eval('1 +'), throwsA(isA<ExpressionException>()));
      expect(() => eval('2 3'), throwsA(isA<ExpressionException>()));
      expect(() => eval('1; 2'), throwsA(isA<ExpressionException>()));
    });
  });

  group('transformers', () {
    final msg = {
      'payload': {
        'node': 'pico',
        'event': 'knob_change',
        'value': 64,
        'text': 'temp=21.5C',
      },
    };

    test('jsonpath reads into msg.value by default', () {
      expect(
        applyTransformer('jsonpath', {'path': r'$.value'}, msg)['value'],
        64,
      );
    });

    test('regex takes the first group', () {
      final out = applyTransformer('regex', {
        'pattern': r'temp=([\d.]+)',
        'source': 'payload.text',
        'into': 'temp',
      }, msg);
      expect(out['temp'], '21.5');
    });

    test('range_map maps and clamps', () {
      Map<String, Object?> cfg(String source) => {
        'inMin': 0,
        'inMax': 100,
        'outMin': 10,
        'outMax': 100,
        'source': source,
      };
      expect(
        applyTransformer('range_map', cfg('payload.value'), msg)['value'],
        closeTo(67.6, 0.001),
      );
      expect(rangeMap(150, cfg('x')), 100);
      expect(rangeMap(-5, cfg('x')), 10);
      expect(
        rangeMap(50, {'inMin': 0, 'inMax': 100, 'outMin': 0, 'outMax': 1000}),
        500,
      );
    });

    test('math sees value, msg paths and variables', () {
      final out = applyTransformer(
        'math',
        {
          'expression': r'round(value * 1000 / 100) + $Offset',
          'source': 'payload.value',
          'into': 'payload.scaled',
        },
        msg,
        context: EvalContext(now: DateTime(2026), globals: const {'Offset': 1}),
      );
      expect((out['payload'] as Map)['scaled'], 641);
      expect((out['payload'] as Map)['value'], 64);
    });

    test('a transformer never changes the message it was given', () {
      applyTransformer('jsonpath', {
        'path': r'$.value',
        'into': 'payload.copy',
      }, msg);
      expect((msg['payload'] as Map).containsKey('copy'), isFalse);
    });
  });
}
