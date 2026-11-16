import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import 'executor_test.dart' show FakeClock, FakeEffects, action, edge, node;
import 'rules_test.dart' show refs;

List<String> _paths(void Function() f) {
  try {
    f();
  } on ValidationException catch (e) {
    return [for (final i in e.issues) i.path];
  }
  fail('no issues');
}

Map<String, Object?> _keep({
  Object? value = true,
  Map<String, Object?> extra = const {},
}) => {
  'keep': {
    'target': 'lamp.power',
    'value': value,
    'while': [
      {'state': 'jade.home', 'op': '==', 'value': false},
    ],
    ...extra,
  },
};

void main() {
  group('keep', () {
    test('goes last in then, at the top level, with its own while', () {
      expect(
        _paths(
          () => normalizeRule({
            'name': 'Nested',
            'when': ['manual'],
            'then': [
              {
                'if': ['jade.home'],
                'then': [_keep()],
              },
            ],
          }),
        ),
        ['then[0].then[0]'],
      );
      // A keep written before a plain step moves to the end, as the app's
      // editor puts it.
      final moved = normalizeRule({
        'name': 'After',
        'when': ['manual'],
        'then': [_keep(), 'lamp.power=true'],
      });
      expect(
        [for (final s in moved['then'] as List) (s as Map).keys.first],
        ['do', 'keep'],
      );
      expect(
        _paths(
          () => normalizeRule({
            'name': 'Single',
            'then': [_keep()],
            'mode': 'single',
          }),
        ),
        ['mode'],
      );
      expect(
        _paths(
          () => normalizeRule({
            'name': 'Msg',
            'then': [
              {
                'keep': {
                  'target': 'lamp.power',
                  'value': true,
                  'while': [
                    {'msg': 'value', 'op': '==', 'value': 1},
                  ],
                },
              },
            ],
          }),
        ),
        ['then[0].keep.while'],
      );
      expect(
        _paths(
          () => normalizeRule({
            'name': 'No when',
            'onlyIf': ['jade.home'],
            'then': [_keep()],
          }),
        ),
        ['onlyIf'],
      );
      expect(
        _paths(
          () => normalizeRule({
            'name': 'No value',
            'then': [
              {
                'keep': {
                  'target': 'lamp',
                  'while': ['jade.home'],
                },
              },
            ],
          }),
        ),
        ['then[0].keep.target', 'then[0].keep.value'],
      );
      expect(
        _paths(
          () => normalizeRule({
            'name': 'Stop',
            'when': ['manual'],
            'then': ['lamp.power=true'],
            'stopOnError': 'yes',
          }),
        ),
        ['stopOnError'],
      );
      final rule = normalizeRule({
        'name': 'Off while away',
        'then': [_keep(value: false)],
      });
      expect(rule['when'], isEmpty);
    });

    test('compiles to a check fed by triggers on its conditions and its '
        'target, and runs parallel', () {
      final compiled = compileRule(
        normalizeRule({
          'name': 'Off while away',
          'then': [_keep(value: false)],
        }),
        refs: refs(),
      ).flow;
      expect(compiled['mode'], 'parallel');
      expect(compiled['onError'], 'continue');
      final nodes = (compiled['nodes'] as List).cast<Map<String, Object?>>();
      final triggers = [
        for (final n in nodes)
          if (n['type'] == 'on') n['config'],
      ];
      expect(triggers, [
        {'thing': 'jade', 'key': 'home', 'change': <String, Object?>{}},
        {'thing': 'lamp', 'key': 'state', 'change': <String, Object?>{}},
      ]);
      final byId = {for (final n in nodes) n['id']: n};
      expect((byId['then_0_apply']!['config'] as Map)['params'], {
        'value': false,
      });
      expect((byId['then_0_release']!['config'] as Map)['params'], {
        'value': true,
      });
      expect(validateFlow(FlowSpec.parse(compiled), refs: refs()), isEmpty);

      final noRelease = compileRule(
        normalizeRule({
          'name': 'Hold',
          'then': [
            _keep(extra: {'release': null}),
          ],
        }),
        refs: refs(),
      ).flow;
      expect([
        for (final n in noRelease['nodes'] as List) (n as Map)['id'],
      ], isNot(contains('then_0_release')));
    });

    test('a rule with stopOnError compiles to a flow that stops', () {
      final flow = compileRule(
        normalizeRule({
          'name': 'Strict',
          'when': ['manual'],
          'then': ['lamp.power=true'],
          'stopOnError': true,
        }),
      ).flow;
      expect(flow.containsKey('onError'), isFalse);
      expect(FlowSpec.parse(flow).continueOnError, isFalse);
    });
  });

  group('onError', () {
    late FakeEffects effects;
    final traces = <RunTrace>[];

    setUp(() {
      effects = FakeEffects()..failDevice = 'b';
      traces.clear();
    });

    FlowSpec chain({String? onError}) => FlowSpec.parse({
      'schemaVersion': 1,
      'id': 'chain',
      'name': 'Chain',
      'onError': ?onError,
      'nodes': [
        node('trig', 'manual'),
        action('a1', 'a'),
        action('b1', 'b'),
        action('c1', 'c'),
      ],
      'edges': [
        edge('trig', 'out', 'a1'),
        edge('a1', 'out', 'b1'),
        edge('b1', 'out', 'c1'),
      ],
    });

    Future<RunTrace> fire(FlowSpec f) => FlowRunner(
      f,
      effects,
      clock: FakeClock(DateTime(2026, 11, 8, 12)),
      onTrace: traces.add,
    ).fire('trig', {});

    test('stop, the default, ends the branch at a failed action', () async {
      final trace = await fire(chain());
      expect(trace.outcome, RunOutcome.failed);
      expect([for (final i in effects.invoked) i.$1], ['a']);
      expect(chain().toJson().containsKey('onError'), isFalse);
    });

    test('continue records the failure and goes on through out', () async {
      final trace = await fire(chain(onError: 'continue'));
      expect(trace.outcome, RunOutcome.failed);
      expect(trace.reason, contains('b timed out'));
      expect([for (final i in effects.invoked) i.$1], ['a', 'c']);
      final failed = trace.nodes.singleWhere((n) => n.error != null);
      expect((failed.nodeId, failed.port), ('b1', 'error'));
      expect(chain(onError: 'continue').toJson()['onError'], 'continue');
    });

    test('anything else is an issue', () {
      expect(
        () => chain(onError: 'retry'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.issues.single.path,
            'path',
            r'$.onError',
          ),
        ),
      );
    });
  });
}
