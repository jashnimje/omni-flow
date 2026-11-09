import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

final _things = {
  'jade': {'home', 'place'},
  'phone': {'wifi_ssid', 'battery'},
  'room_temp': {'value'},
};
final _events = {
  'jade': <String>{},
  'phone': {'nfc_scanned'},
  'room_temp': <String>{},
};

final refs = FlowReferences(
  devices: {..._things.keys, 'desk_board'},
  stateKeysOf: (t) => t == 'desk_board' ? null : _things[t] ?? {},
  eventsOf: (t) => t == 'desk_board' ? null : _events[t] ?? {},
);

List<String> issuesOf(Map<String, Object?> trigger, {Object? rule}) =>
    validateFlow(
      FlowSpec.parse({
        'schemaVersion': 1,
        'id': 'f',
        'name': 'f',
        'nodes': [
          {'id': 't', 'type': 'on', 'config': trigger},
          {
            'id': 'c',
            'type': rule == null ? 'days' : 'compare',
            'config':
                rule ??
                {
                  'days': ['mon'],
                },
          },
        ],
        'edges': [
          {
            'id': 'e',
            'from': {'node': 't', 'port': 'out'},
            'to': {'node': 'c', 'port': 'in'},
          },
        ],
      }),
      refs: refs,
    ).map((i) => '$i').toList();

void main() {
  group('the on trigger validates', () {
    test('a change, a change to a value, an event and a crossing', () {
      expect(issuesOf({'thing': 'jade', 'key': 'home'}), isEmpty);
      expect(issuesOf({'thing': 'jade'}), isEmpty);
      expect(
        issuesOf({
          'thing': 'jade',
          'key': 'home',
          'change': {'to': true},
        }),
        isEmpty,
      );
      expect(
        issuesOf({
          'thing': 'phone',
          'key': 'nfc_scanned',
          'event': true,
          'match': {'tag': 'front_door'},
        }),
        isEmpty,
      );
      expect(
        issuesOf({
          'thing': 'room_temp',
          'key': 'value',
          'crosses': {'above': 28},
        }),
        isEmpty,
      );
    });

    test('a thing or key that does not exist names what does', () {
      expect(
        issuesOf({'thing': 'nobody', 'key': 'home'}).join(),
        contains('no thing nobody'),
      );
      expect(
        issuesOf({'thing': 'jade', 'key': 'awake'}).join(),
        contains('jade has no state awake (it has home, place)'),
      );
      expect(
        issuesOf({'thing': 'phone', 'key': 'wifi_ssid', 'event': true}).join(),
        contains('phone has no event wifi_ssid (it has nfc_scanned)'),
      );
      expect(
        issuesOf({'thing': 'jade', 'key': 'home', 'event': true}).join(),
        contains('no events at all'),
      );
    });

    test('a board takes events its manifest does not declare', () {
      expect(
        issuesOf({'thing': 'desk_board', 'key': 'nfc.scanned', 'event': true}),
        isEmpty,
      );
    });

    test('shape errors', () {
      expect(
        issuesOf({
          'thing': 'room_temp',
          'key': 'value',
          'crosses': {'above': 'hot'},
        }).join(),
        contains('must be {"above": number} or {"below": number}'),
      );
      expect(
        issuesOf({
          'thing': 'room_temp',
          'crosses': {'above': 3},
        }).join(),
        contains('is required for crosses'),
      );
      expect(
        issuesOf({
          'thing': 'jade',
          'key': 'home',
          'match': {'a': 1},
        }).join(),
        contains('is only for an event'),
      );
      expect(
        issuesOf({
          'thing': 'jade',
          'change': {'to': true},
        }).join(),
        contains('is required to change to a value'),
      );
      expect(
        issuesOf({
          'thing': 'jade',
          'key': 'home',
          'change': {'from': true},
        }).join(),
        contains('must be {} or {"to": value}'),
      );
      expect(
        issuesOf({'thing': 'phone', 'key': 'nfc_scanned', 'event': 'yes'})
            .join(),
        contains('must be true'),
      );
    });
  });

  group('compare and days validate', () {
    Map<String, Object?> on() => {'thing': 'jade', 'key': 'home'};

    test('every value source', () {
      for (final left in [
        {'literal': 3},
        {'state': 'jade.home'},
        {'msg': 'payload.temp'},
        {'var': r'$Mode'},
        {'var': '%count'},
      ]) {
        expect(
          issuesOf(
            on(),
            rule: {
              'left': left,
              'op': '==',
              'right': {'literal': 1},
            },
          ),
          isEmpty,
          reason: '$left',
        );
      }
    });

    test('a bad source, an unknown state and a bad day', () {
      final got = [
        ...issuesOf(
          on(),
          rule: {
            'left': {'name': 'x'},
            'op': '==',
            'right': {'literal': 1},
          },
        ),
        ...issuesOf(
          on(),
          rule: {
            'left': {'state': 'jade.awake'},
            'op': '==',
            'right': {'literal': 1},
          },
        ),
        ...issuesOf(
          on(),
          rule: {
            'left': {'state': 'jade'},
            'op': '==',
            'right': {'literal': 1},
          },
        ),
        ...issuesOf(
          on(),
          rule: {
            'left': {'var': 'Mode'},
            'op': '==',
            'right': {'literal': 1},
          },
        ),
      ].join('\n');
      expect(got, contains('must be one of {literal}'));
      expect(got, contains('jade has no state awake'));
      expect(got, contains('must be thing.key'));
      expect(got, contains(r'must be $Name (global) or %name (run)'));
      expect(
        validateFlow(
          FlowSpec.parse({
            'schemaVersion': 1,
            'id': 'f',
            'name': 'f',
            'nodes': [
              {'id': 't', 'type': 'manual'},
              {
                'id': 'c',
                'type': 'days',
                'config': {
                  'days': ['someday'],
                },
              },
            ],
            'edges': [
              {
                'id': 'e',
                'from': {'node': 't', 'port': 'out'},
                'to': {'node': 'c', 'port': 'in'},
              },
            ],
          }),
        ).join(),
        contains('must be a non-empty list of mon'),
      );
    });
  });

  group('compare evaluates', () {
    final ctx = EvalContext(
      now: DateTime(2026, 11, 7, 9),
      globals: const {'Mode': 'home', 'Lux': 40},
      flowVars: const {'count': 2},
      msg: const {
        'value': 30,
        'payload': {
          'temp': 28.5,
          'tags': ['a'],
        },
      },
      deviceStates: const {
        'jade': {'home': true, 'place': 'desk'},
        'desk': {
          'people': ['jade'],
        },
      },
    );
    bool cmp(Object left, String op, Object right) => evaluateRule({
      'type': 'compare',
      'left': left,
      'op': op,
      'right': right,
    }, ctx);

    test('reads literals, state, the message and variables', () {
      expect(cmp({'state': 'jade.home'}, '==', {'literal': true}), isTrue);
      expect(cmp({'msg': 'payload.temp'}, '>', {'literal': 28}), isTrue);
      expect(cmp({'var': r'$Lux'}, '<=', {'msg': 'value'}), isFalse);
      expect(cmp({'var': '%count'}, '==', {'literal': 2.0}), isTrue);
      expect(cmp({'state': 'jade.place'}, '!=', {'literal': 'home'}), isTrue);
    });

    test('lists and objects compare by content', () {
      expect(
        cmp(
          {'state': 'desk.people'},
          '==',
          {
            'literal': ['jade'],
          },
        ),
        isTrue,
      );
      expect(
        cmp(
          {'msg': 'payload.tags'},
          '==',
          {
            'literal': ['b'],
          },
        ),
        isFalse,
      );
    });

    test('ordering is false unless both sides are numbers', () {
      expect(cmp({'state': 'nobody.value'}, '<', {'literal': 5}), isFalse);
      expect(cmp({'var': r'$Mode'}, '>', {'literal': 5}), isFalse);
      expect(cmp({'state': 'nobody.value'}, '!=', {'literal': 5}), isTrue);
    });

    test('days holds on the listed weekdays', () {
      expect(
        evaluateRule({
          'type': 'days',
          'days': ['sat', 'sun'],
        }, ctx),
        isTrue,
      );
      expect(
        evaluateRule({
          'type': 'days',
          'days': ['mon'],
        }, ctx),
        isFalse,
      );
    });
  });

  group('state triggers fire', () {
    test('on any change, and only on a real one', () {
      expect(stateTriggerFires(const {}, 1, 2), isTrue);
      expect(stateTriggerFires(const {}, 2, 2.0), isFalse);
      expect(stateTriggerFires(const {}, ['a'], ['a']), isFalse);
    });

    test('on a change to one value', () {
      const config = {
        'change': {'to': true},
      };
      expect(stateTriggerFires(config, false, true), isTrue);
      expect(stateTriggerFires(config, null, true), isTrue);
      expect(stateTriggerFires(config, true, false), isFalse);
    });

    test('once per crossing, in the given direction', () {
      const above = {
        'crosses': {'above': 28},
      };
      expect(stateTriggerFires(above, 27, 29), isTrue);
      expect(stateTriggerFires(above, 29, 30), isFalse);
      expect(stateTriggerFires(above, 30, 27), isFalse);
      expect(stateTriggerFires(above, null, 29), isTrue);
      const below = {
        'crosses': {'below': 30},
      };
      expect(stateTriggerFires(below, 40, 20), isTrue);
      expect(stateTriggerFires(below, 20, 10), isFalse);
      expect(stateTriggerFires(below, 'dark', 10), isTrue);
    });

    test('an event payload matches by value', () {
      expect(payloadMatches(null, const {'hold': true}), isTrue);
      expect(
        payloadMatches(const {'hold': true}, const {'hold': true, 'pin': 4}),
        isTrue,
      );
      expect(payloadMatches(const {'hold': true}, const {'pin': 4}), isFalse);
      expect(payloadMatches(const {'pin': 4}, const {'pin': 4.0}), isTrue);
    });
  });
}
