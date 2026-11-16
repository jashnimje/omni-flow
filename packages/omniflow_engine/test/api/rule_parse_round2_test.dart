import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import 'rule_parse_test.dart' show read, spec;

void main() {
  test('"above 28 for 10 minutes" holds the crossing for 10 minutes', () async {
    final s = await spec(
      'when the thermometer is above 28 for 10 minutes turn on the fan',
    );
    expect(s['when'], [
      {
        'on': 'thermometer.temperature',
        'crosses': {'above': 28},
        'for': 600000,
      },
    ]);
  });

  test('"sunset minus 30 minutes" and "sunrise plus an hour" move the sun '
      'time', () async {
    final minus = await spec(
      'at sunset minus 30 minutes turn on the hall light',
    );
    expect(minus['when'], [
      {'sun': 'sunset', 'offset': -30},
    ]);
    final plus = await spec('at sunrise plus an hour turn on the hall light');
    expect(plus['when'], [
      {'sun': 'sunrise', 'offset': 60},
    ]);
  });

  test('a number too big to hold is refused, and the rule normalizer '
      'refuses one too', () async {
    final r = await read('if it gets above 1e400 turn on the fan');
    expect(r.spec, isNull);
    expect(r.problem, contains('not a number'));
    expect(
      () => normalizeRule({
        'name': 'x',
        'when': [
          {
            'on': 'fan.power',
            'crosses': {'above': double.infinity},
          },
        ],
        'then': [
          {
            'notify': {'title': 'x'},
          },
        ],
      }),
      throwsA(isA<ValidationException>()),
    );
  });
}
