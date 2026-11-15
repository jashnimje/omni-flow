@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/automation_diagram.dart';
import 'package:omniflow_engine/src/api/automation_view.dart';
import 'package:omniflow_engine/src/dag/skips.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import 'things_test.dart' show until;

/// A rule with every construct the diagram draws.
final Map<String, Object?> _everything = {
  'id': 'every_thing',
  'name': 'Every thing',
  'when': [
    {'time': '18:00'},
    {'manual': true},
  ],
  'onlyIf': [
    {'var': r'$mode', 'op': '==', 'value': 'home'},
    {
      'between': ['18:00', '23:00'],
    },
  ],
  'then': [
    {
      'notify': {'title': 'Hi'},
    },
    {
      'if': [
        {'var': r'$n', 'op': '>', 'value': 2},
      ],
      'then': [
        {
          'set': {'var': r'$a', 'value': 1},
        },
      ],
      'else': [
        {
          'set': {'var': r'$a', 'value': 2},
        },
      ],
    },
    {
      'together': [
        [
          {
            'notify': {'title': 'A'},
          },
        ],
        [
          {'wait': 1000},
          {
            'notify': {'title': 'B'},
          },
        ],
      ],
    },
    {
      'try': [
        {'run': 'other'},
      ],
      'otherwise': [
        {
          'notify': {'title': 'Failed'},
        },
      ],
    },
    {
      'repeat': {
        'times': 3,
        'do': [
          {
            'notify': {'title': 'R'},
          },
        ],
      },
    },
    {
      'forEach': {
        'in': ['a', 'b'],
        'do': [
          {
            'notify': {'title': '{{%item}}'},
          },
        ],
      },
    },
    {
      'ask': {
        'title': 'Mood?',
        'choices': ['Good', 'Bad', 'Meh'],
      },
    },
    {
      'if': [
        {'var': '%answer', 'op': '==', 'value': 'Good'},
      ],
      'then': [
        {
          'notify': {'title': 'Yay'},
        },
      ],
    },
    {
      'if': [
        {'var': '%answer', 'op': '==', 'value': 'Bad'},
      ],
      'then': [
        {
          'notify': {'title': 'Oh'},
        },
      ],
    },
    {
      'waitFor': {
        'on': 'door.open',
        'change': {'to': true},
        'timeoutMs': 60000,
        'onTimeout': [
          {
            'notify': {'title': 'Late'},
          },
        ],
      },
    },
    {
      'keep': {
        'target': 'fan.power',
        'value': true,
        'while': [
          {'state': 'room.temp', 'op': '>', 'value': 28},
        ],
      },
    },
  ],
};

Map<String, Object?> _step(int i) =>
    Map<String, Object?>.from((_everything['then'] as List)[i] as Map);

void main() {
  const words = SentenceContext();

  group('a rule as a diagram', () {
    late Map<String, Object?> json;
    late Map<String, Map<String, Object?>> byId;
    late List<Map<String, Object?>> edges;

    Map<String, Object?> edge(String from, String to, [String? label]) =>
        edges.singleWhere(
          (e) => e['from'] == from && e['to'] == to && e['label'] == label,
          orElse: () => throw StateError('no edge $from -> $to ($label)'),
        );

    setUp(() {
      json = Diagram.of('rule', _everything, words).toJson();
      byId = {
        for (final n in (json['nodes'] as List).cast<Map<String, Object?>>())
          n['id'] as String: n,
      };
      edges = (json['edges'] as List).cast<Map<String, Object?>>();
    });

    test('nodes, kinds and paths for every construct', () {
      expect(json['source'], 'rule');
      final kinds = {for (final n in byId.values) n['id']: n['kind']};
      expect(kinds, {
        '/when/0': 'trigger',
        '/when/1': 'trigger',
        '/onlyIf/0': 'check',
        '/onlyIf/0#end': 'end',
        '/onlyIf/1': 'check',
        '/onlyIf/1#end': 'end',
        '/then/0': 'step',
        '/then/1': 'decision',
        '/then/1/then/0': 'step',
        '/then/1/else/0': 'step',
        '/then/1#merge': 'merge',
        '/then/2': 'group',
        '/then/2/together/0/0': 'step',
        '/then/2/together/1/0': 'step',
        '/then/2/together/1/1': 'step',
        '/then/2#merge': 'merge',
        '/then/3': 'group',
        '/then/3/try/0': 'step',
        '/then/3/otherwise/0': 'step',
        '/then/3#merge': 'merge',
        '/then/4': 'group',
        '/then/4/repeat/do/0': 'step',
        '/then/4#merge': 'merge',
        '/then/5': 'group',
        '/then/5/forEach/do/0': 'step',
        '/then/5#merge': 'merge',
        '/then/6': 'ask',
        '/then/7/then/0': 'step',
        '/then/8/then/0': 'step',
        '/then/6#merge': 'merge',
        '/then/9': 'wait',
        '/then/9/waitFor/onTimeout/0': 'step',
        '/then/9#end': 'end',
        '/then/10/keep/while': 'check',
        '/then/10': 'step',
        '/then/10#end': 'end',
      });
      for (final n in byId.values) {
        final kind = n['kind'];
        if (kind == 'merge' || kind == 'end') {
          expect(n.containsKey('path'), isFalse, reason: '${n['id']}');
        } else {
          expect(n['path'], n['id'], reason: '${n['id']}');
        }
      }
      expect(byId['/then/2']!['group'], 'together');
      expect(byId['/then/2']!['children'], [
        '/then/2/together/0/0',
        '/then/2/together/1/0',
        '/then/2/together/1/1',
      ]);
      expect(byId['/then/3']!['children'], ['/then/3/try/0']);
      expect(byId['/then/4']!['group'], 'repeat');
      expect(byId['/then/5']!['group'], 'forEach');
      expect(byId['/then/10']!['lane'], 'keep');
      expect(byId['/then/10/keep/while']!['lane'], 'keep');
      expect(byId['/then/1']!['checks'], [
        {'path': '/then/1/if/0', 'words': r'$n is above 2'},
      ]);
    });

    test('words are the sentence words for each part', () {
      final when = (_everything['when'] as List).cast<Map<String, Object?>>();
      final only = (_everything['onlyIf'] as List).cast<Map<String, Object?>>();
      expect(byId['/when/0']!['words'], words.trigger(when[0]));
      expect(byId['/when/1']!['words'], 'When I run it');
      expect(byId['/onlyIf/0']!['words'], words.condition(only[0]));
      expect(byId['/onlyIf/1']!['words'], 'between 18:00 and 23:00');
      expect(byId['/then/0']!['words'], words.step(_step(0)));
      expect(byId['/then/1']!['words'], r'if $n is above 2');
      expect(byId['/then/2']!['words'], words.step(_step(2)));
      expect(byId['/then/3']!['words'], words.step(_step(3)));
      expect(byId['/then/4']!['words'], 'repeat 3 times');
      expect(byId['/then/5']!['words'], 'for each item of a, b');
      expect(byId['/then/6']!['words'], words.step(_step(6)));
      expect(byId['/then/9']!['words'], words.step(_step(9)));
      expect(byId['/onlyIf/0#end']!['words'], 'Stops here');
      // The keep lane reads as the sentence's keep and while chips.
      final chips = [for (final c in words.rule(_everything)) c['text']];
      expect(chips, contains(byId['/then/10']!['words']));
      expect(chips, contains(byId['/then/10/keep/while']!['words']));
    });

    test('edges, labels and insert points', () {
      for (final e in edges) {
        expect(e['insert'], isA<Map>(), reason: '$e');
      }
      Map<String, Object?> ins(String path, String as) => {
        'path': path,
        'as': as,
      };
      expect(edge('/when/0', '/onlyIf/0')['insert'], ins('/onlyIf/0', 'check'));
      expect(edge('/when/1', '/onlyIf/0')['insert'], ins('/onlyIf/0', 'check'));
      expect(
        edge('/onlyIf/0', '/onlyIf/1', 'yes')['insert'],
        ins('/onlyIf/1', 'check'),
      );
      expect(
        edge('/onlyIf/0', '/onlyIf/0#end', 'no')['insert'],
        ins('/onlyIf/1', 'check'),
      );
      expect(
        edge('/onlyIf/1', '/then/0', 'yes')['insert'],
        ins('/then/0', 'step'),
      );
      expect(edge('/then/0', '/then/1')['insert'], ins('/then/1', 'step'));
      expect(
        edge('/then/1', '/then/1/then/0', 'yes')['insert'],
        ins('/then/1/then/0', 'step'),
      );
      expect(
        edge('/then/1', '/then/1/else/0', 'no')['insert'],
        ins('/then/1/else/0', 'step'),
      );
      expect(
        edge('/then/1/then/0', '/then/1#merge')['insert'],
        ins('/then/1/then/1', 'step'),
      );
      expect(
        edge('/then/1#merge', '/then/2')['insert'],
        ins('/then/2', 'step'),
      );
      expect(
        edge('/then/2', '/then/2/together/1/0')['insert'],
        ins('/then/2/together/1/0', 'step'),
      );
      expect(
        edge('/then/2/together/1/1', '/then/2#merge')['insert'],
        ins('/then/2/together/1/2', 'step'),
      );
      expect(
        edge('/then/3', '/then/3/otherwise/0', 'fails')['insert'],
        ins('/then/3/otherwise/0', 'step'),
      );
      expect(
        edge('/then/4', '/then/4/repeat/do/0', 'each')['insert'],
        ins('/then/4/repeat/do/0', 'step'),
      );
      expect(
        edge('/then/5', '/then/5/forEach/do/0', 'each')['insert'],
        ins('/then/5/forEach/do/0', 'step'),
      );
      // One way out per answer, holding the if steps that branch on it.
      expect(
        edge('/then/6', '/then/7/then/0', 'Good')['insert'],
        ins('/then/7/then/0', 'step'),
      );
      expect(
        edge('/then/6', '/then/8/then/0', 'Bad')['insert'],
        ins('/then/8/then/0', 'step'),
      );
      expect(
        edge('/then/6', '/then/6#merge', 'Meh')['insert'],
        ins('/then/9', 'step'),
      );
      expect(
        edge('/then/6#merge', '/then/9')['insert'],
        ins('/then/9', 'step'),
      );
      expect(
        edge('/then/9', '/then/9/waitFor/onTimeout/0', 'otherwise')['insert'],
        ins('/then/9/waitFor/onTimeout/0', 'step'),
      );
      expect(
        edge('/then/9', '/then/10/keep/while')['insert'],
        ins('/then/10', 'step'),
      );
      expect(
        edge('/then/10/keep/while', '/then/10', 'yes')['insert'],
        ins('/then/10/keep/while/1', 'check'),
      );
    });

    test('every compiled id is a node the compiler makes', () {
      final compiled = {
        for (final n
            in (compileRule(_everything).flow['nodes'] as List)
                .cast<Map<String, Object?>>())
          n['id'],
      };
      for (final n in byId.values) {
        for (final id in (n['compiled'] as List? ?? const [])) {
          expect(compiled, contains(id), reason: '${n['id']}');
        }
      }
      expect(byId['/then/1/else/0']!['compiled'], ['then_1_else_0']);
      expect(byId['/then/9/waitFor/onTimeout/0']!['compiled'], [
        'then_9_wait_for_on_timeout_0',
      ]);
    });

    test('a rule with no checks offers one on the trigger line', () {
      final d = Diagram.of('rule', {
        'when': [
          {'manual': true},
        ],
        'then': [
          {'wait': 1000},
        ],
      }, words).toJson();
      final first = (d['edges'] as List).cast<Map>().first;
      expect(first['insert'], {'path': '/then/0', 'as': 'step'});
      expect(first['alsoInsert'], {'path': '/onlyIf/0', 'as': 'check'});
      final last = (d['edges'] as List).cast<Map>().last;
      expect(last['to'], '#end');
      expect(last['insert'], {'path': '/then/1', 'as': 'step'});
    });

    test('an ask whose steps do not branch on it has one way out', () {
      final d = Diagram.of('rule', {
        'when': [
          {'manual': true},
        ],
        'then': [
          {
            'ask': {
              'title': 'Go?',
              'choices': ['Yes', 'No'],
            },
          },
          {'wait': 1000},
        ],
      }, words).toJson();
      final out = (d['edges'] as List).cast<Map>().where(
        (e) => e['from'] == '/then/0',
      );
      expect(out.single['to'], '/then/1');
      expect(out.single.containsKey('label'), isFalse);
    });
  });

  group('marking a run', () {
    Map<String, Object?> t(
      String node,
      String? port, {
      Object? seen,
      bool hasSeen = false,
      String? error,
    }) => {
      'node': node,
      'port': ?port,
      'error': ?error,
      if (hasSeen || seen != null) 'seen': seen,
    };

    test('statuses, seen values and taken edges from the trace', () {
      final d = Diagram.of('rule', _everything, words);
      d.mark({
        'nodes': [
          t('when_0', 'out'),
          t(
            'only_if',
            'true',
            seen: [
              {'ok': true, 'seen': 'home'},
              {'ok': true},
            ],
          ),
          t('then_0', 'out'),
          t('then_1', 'false', seen: 1),
          t('then_1_else_0', 'out'),
          t('then_2', 'done'),
          t('then_2_together_0_0', 'out'),
          t('then_2_together_1_0', 'out'),
          t('then_2_together_1_1', 'out'),
          t('then_3_try_0', 'error'),
          t('then_3_otherwise_0', 'out'),
          t('then_4', 'done'),
          for (var i = 0; i < 3; i++) t('then_4_repeat_do_0', 'out'),
          t('then_5', 'done'),
          t('then_5_for_each_do_0', 'out'),
          t('then_6', 'out', seen: 'Bad'),
          t('then_7', 'false'),
          t('then_8', 'true'),
          t('then_8_then_0', 'out'),
          t('then_9', 'timeout'),
          t('then_9_wait_for_on_timeout_0', 'out'),
        ],
      }, continueOnError: true);
      final json = d.toJson();
      final nodes = {
        for (final n in (json['nodes'] as List).cast<Map>()) n['id']: n,
      };
      final edges = (json['edges'] as List).cast<Map>();
      bool? taken(String from, String to, [String? label]) => edges.singleWhere(
        (e) => e['from'] == from && e['to'] == to && e['label'] == label,
      )['taken'];
      String? status(String id) => nodes[id]!['status'] as String?;

      expect(status('/when/0'), 'ran');
      expect(status('/when/1'), 'skipped');
      expect(nodes['/onlyIf/0']!['seen'], 'home');
      expect(taken('/onlyIf/0', '/onlyIf/1', 'yes'), isTrue);
      expect(taken('/onlyIf/0', '/onlyIf/0#end', 'no'), isFalse);
      expect(status('/onlyIf/0#end'), 'skipped');
      expect(status('/then/1'), 'ran');
      expect(nodes['/then/1']!['seen'], 1);
      expect(taken('/then/1', '/then/1/then/0', 'yes'), isFalse);
      expect(taken('/then/1', '/then/1/else/0', 'no'), isTrue);
      expect(status('/then/1/then/0'), 'skipped');
      expect(status('/then/1#merge'), 'ran');
      expect(status('/then/3'), 'ran');
      expect(status('/then/3/try/0'), 'failed');
      expect(taken('/then/3', '/then/3/otherwise/0', 'fails'), isTrue);
      expect(taken('/then/3/try/0', '/then/3#merge'), isFalse);
      expect(taken('/then/4', '/then/4/repeat/do/0', 'each'), isTrue);
      expect(nodes['/then/6']!['seen'], 'Bad');
      expect(taken('/then/6', '/then/8/then/0', 'Bad'), isTrue);
      expect(taken('/then/6', '/then/7/then/0', 'Good'), isFalse);
      expect(taken('/then/6', '/then/6#merge', 'Meh'), isFalse);
      expect(status('/then/7/then/0'), 'skipped');
      expect(
        taken('/then/9', '/then/9/waitFor/onTimeout/0', 'otherwise'),
        isTrue,
      );
      expect(status('/then/9#end'), 'ran');
      expect(taken('/then/9', '/then/10/keep/while'), isFalse);
      expect(status('/then/10/keep/while'), 'skipped');
      expect(status('/then/10'), 'skipped');
    });

    test('a skip marks the check that said no', () {
      final d = Diagram.of('rule', _everything, words);
      final flow = compileRule(_everything).flow;
      final onlyIf = (flow['nodes'] as List).cast<Map>().singleWhere(
        (n) => n['id'] == 'only_if',
      );
      final second = ((onlyIf['config'] as Map)['rules'] as List)[1];
      final skip = SkipEntry(
        at: DateTime.utc(2026, 11, 13, 9),
        flowId: 'every_thing',
        trigger: 'when_1',
        triggerLabel: 'run by hand',
        kind: SkipKind.condition,
        stop: {'node': 'only_if', 'rule': second},
      );
      d.mark(d.skipTrace(skip, flow), continueOnError: true);
      final nodes = {
        for (final n in (d.toJson()['nodes'] as List).cast<Map>()) n['id']: n,
      };
      final edges = (d.toJson()['edges'] as List).cast<Map>();
      expect(nodes['/when/1']!['status'], 'ran');
      expect(nodes['/when/0']!['status'], 'skipped');
      expect(nodes['/onlyIf/0']!['status'], 'ran');
      expect(nodes['/onlyIf/1']!['status'], 'ran');
      expect(nodes['/onlyIf/1#end']!['status'], 'ran');
      expect(nodes['/then/0']!['status'], 'skipped');
      expect(
        edges.singleWhere((e) => e['to'] == '/onlyIf/1#end')['taken'],
        isTrue,
      );
    });
  });

  test('a raw graph projects its nodes and edges, read-only', () {
    final d = Diagram.of(
      'graph',
      null,
      words,
      flow: {
        'nodes': [
          {'id': 'go', 'type': 'manual', 'label': 'go'},
          {
            'id': 'check',
            'type': 'compare',
            'label': 'if it is on',
            'config': {
              'left': {'msg': 'value'},
              'op': '==',
              'right': {'literal': true},
            },
          },
          {
            'id': 'say',
            'type': 'notify',
            'config': {'title': 'on'},
          },
          {
            'id': 'pause',
            'type': 'delay',
            'config': {'ms': 10},
          },
        ],
        'edges': [
          {
            'from': {'node': 'go', 'port': 'out'},
            'to': {'node': 'check', 'port': 'in'},
          },
          {
            'from': {'node': 'check', 'port': 'true'},
            'to': {'node': 'say', 'port': 'in'},
          },
          {
            'from': {'node': 'check', 'port': 'false'},
            'to': {'node': 'pause', 'port': 'in'},
          },
        ],
      },
    );
    d.mark({
      'nodes': [
        {'node': 'go', 'port': 'out'},
        {'node': 'check', 'port': 'true', 'seen': true},
        {'node': 'say', 'port': 'out'},
      ],
    }, continueOnError: true);
    final json = d.toJson();
    expect(json['readOnly'], isTrue);
    final nodes = (json['nodes'] as List).cast<Map>();
    expect(
      [for (final n in nodes) n['kind']],
      ['trigger', 'decision', 'step', 'wait'],
    );
    expect(nodes.every((n) => !n.containsKey('path')), isTrue);
    expect(nodes[1]['seen'], true);
    expect(nodes[3]['status'], 'skipped');
    final edges = (json['edges'] as List).cast<Map>();
    expect(edges.every((e) => !e.containsKey('insert')), isTrue);
    expect([for (final e in edges) e['label']], [null, 'yes', 'no']);
    expect([for (final e in edges) e['taken']], [true, true, false]);
  });

  test('a scene is a group of its steps', () {
    final d = Diagram.of('scene', {
      'name': 'Movie',
      'actions': [
        {
          'do': 'lamp.power',
          'params': {'value': false},
        },
        {
          'do': 'tv.power',
          'params': {'value': true},
        },
      ],
    }, words).toJson();
    final nodes = (d['nodes'] as List).cast<Map>();
    expect(nodes.first['kind'], 'group');
    expect(nodes.first['group'], 'scene');
    expect(nodes.first['children'], ['/actions/0', '/actions/1']);
    expect(nodes[1]['words'], words.action('lamp.power', {'value': false}));
    expect(nodes[1]['compiled'], ['then_0_together_0_0']);
    expect(nodes[1]['thing'], 'lamp');
  });

  test('a link is its trigger, then its step', () {
    final spec = {'from': 'switch.power', 'to': 'lamp.power', 'mode': 'toggle'};
    final d = Diagram.of('link', spec, words).toJson();
    final chips = words.link(spec);
    final nodes = (d['nodes'] as List).cast<Map>();
    expect([for (final n in nodes) n['kind']], ['trigger', 'step']);
    expect(nodes[0]['words'], chips.first['text']);
    expect(nodes[1]['words'], chips.last['text']);
    expect(d['readOnly'], isTrue);
  });

  group('through the engine', () {
    late Directory home;
    late OmniEngine engine;
    late List<Map<String, Object?>> events;
    late StreamSubscription<Map<String, Object?>> sub;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_diagram');
      engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
        mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
      );
      events = [];
      sub = engine.events.listen(events.add);
    });

    tearDown(() async {
      await sub.cancel();
      await engine.close();
      await home.delete(recursive: true);
    });

    Future<Map<String, Object?>> ok(
      String command, [
      Map<String, Object?> args = const {},
    ]) async {
      final r = await engine.handle(command, args);
      expect(r['ok'], isTrue, reason: '$command: $r');
      return r;
    }

    Map<String, Map> byId(Map<String, Object?> d) => {
      for (final n in (d['nodes'] as List).cast<Map>()) '${n['id']}': n,
    };

    final rule = {
      'name': 'Check mode',
      'when': [
        {'manual': true},
      ],
      'onlyIf': [
        {'var': r'$mode', 'op': '==', 'value': 'home'},
      ],
      'then': [
        {
          'if': [
            {'var': r'$count', 'op': '>', 'value': 2},
          ],
          'then': [
            {
              'notify': {'title': 'Many'},
            },
          ],
          'else': [
            {
              'notify': {'title': 'Few'},
            },
          ],
        },
      ],
    };

    Future<void> save() => ok('automation.save', {
      'form': 'rule',
      'spec': rule,
      'trusted': true,
      'replace': true,
    });

    test('the last run and a run by id light the path', () async {
      await ok('var.set', {'name': 'mode', 'value': 'home'});
      await ok('var.set', {'name': 'count', 'value': 5});
      await save();
      final ran = await ok('automation.run', {'id': 'check_mode'});
      final runId = ((ran['runs'] as List).single as Map)['run'];
      late Map<String, Object?> d;
      await until(() async {
        final r = await engine.handle('automation.diagram', {
          'id': 'check_mode',
          'last': true,
        });
        if (r['ok'] != true) return false;
        d = r;
        return true;
      });
      expect((d['run'] as Map)['run'], runId);
      final nodes = byId(d);
      expect(nodes['/onlyIf/0']!['status'], 'ran');
      expect(nodes['/onlyIf/0']!['seen'], 'home');
      expect(nodes['/then/0']!['seen'], 5);
      expect(nodes['/then/0/then/0']!['status'], 'ran');
      expect(nodes['/then/0/else/0']!['status'], 'skipped');
      final byRun = await ok('automation.diagram', {
        'id': 'check_mode',
        'run': runId,
      });
      expect(byId(byRun)['/then/0/then/0']!['status'], 'ran');
      final missing = await engine.handle('automation.diagram', {
        'id': 'check_mode',
        'run': 'nope',
      });
      expect((missing['error'] as Map)['type'], 'not_found');
    });

    test('a dry run lights the path it would take', () async {
      await ok('var.set', {'name': 'mode', 'value': 'home'});
      await ok('var.set', {'name': 'count', 'value': 1});
      await save();
      final dry = await ok('automation.dry_run', {'id': 'check_mode'});
      final d = await ok('automation.diagram', {
        'id': 'check_mode',
        'dryRun': dry,
      });
      expect((d['run'] as Map)['dryRun'], isTrue);
      final nodes = byId(d);
      expect(nodes['/then/0/else/0']!['status'], 'ran');
      expect(nodes['/then/0/then/0']!['status'], 'skipped');
    });

    test('an unsaved rule, a try as if, and the sentence words', () async {
      final d = await ok('automation.diagram', {'spec': rule});
      expect(d['source'], 'rule');
      final list = (await ok('automation.diagram', {
        'spec': {'name': 'Half done', 'when': []},
      }));
      expect(list['issues'], isNotEmpty);
      await save();
      final row = ((await ok('automation.list'))['automations'] as List)
          .cast<Map>()
          .singleWhere((a) => a['id'] == 'check_mode');
      final chips = [for (final c in (row['sentence'] as List).cast<Map>()) c];
      final nodes = byId(d);
      expect(
        nodes['/onlyIf/0']!['words'],
        chips.firstWhere((c) => c['kind'] == 'if')['text'],
      );
      expect(
        nodes['/when/0']!['words'],
        chips.firstWhere((c) => c['kind'] == 'when')['text'],
      );
    });

    test('with skipsToo, the check that said no', () async {
      await save();
      await ok('automation.run', {'id': 'check_mode'});
      await until(
        () async =>
            ((await ok('automation.skips', {'id': 'check_mode'}))['skips']
                    as List)
                .isNotEmpty,
      );
      final d = await ok('automation.diagram', {
        'id': 'check_mode',
        'skipsToo': true,
      });
      expect((d['skip'] as Map)['kind'], 'condition');
      final nodes = byId(d);
      expect(nodes['/onlyIf/0']!['status'], 'ran');
      expect(nodes['/onlyIf/0#end']!['status'], 'ran');
      expect(nodes['/then/0']!['status'], 'skipped');
    });

    test('run.node events as each node finishes, with paths', () async {
      await ok('var.set', {'name': 'mode', 'value': 'home'});
      await ok('var.set', {'name': 'count', 'value': 5});
      await save();
      await ok('automation.diagram', {'id': 'check_mode'});
      await ok('automation.run', {'id': 'check_mode'});
      await until(
        () async => events.any(
          (e) => e['event'] == 'run.node' && e['node'] == 'then_0_then_0',
        ),
      );
      final nodes = [
        for (final e in events)
          if (e['event'] == 'run.node') e,
      ];
      expect(
        [for (final e in nodes) e['node']],
        ['when_0', 'only_if', 'then_0', 'then_0_then_0'],
      );
      expect(nodes[1]['path'], '/onlyIf');
      expect(nodes[1]['seen'], 'home');
      expect(nodes[2]['path'], '/then/0');
      expect(nodes[2]['port'], 'true');
      expect(nodes[3]['status'], 'ran');
    });

    test('an agent may draw the diagram at read level', () {
      expect(
        agentRefusal('automation.diagram', const {}, AgentAccess.read),
        isNull,
      );
    });
  });

  test('run.node never carries a web step header secret', () async {
    final host = _Host();
    final engine = FlowEngine(host, web: _FakeWeb())
      ..load([
        FlowSpec.parse({
          'schemaVersion': 1,
          'id': 'tell',
          'name': 'Tell',
          'nodes': [
            {'id': 'go', 'type': 'manual'},
            {
              'id': 'is_on',
              'type': 'compare',
              'config': {
                'left': {'msg': 'trigger'},
                'op': '==',
                'right': {'literal': 'manual'},
              },
            },
            {
              'id': 'send',
              'type': 'http_request',
              'config': {
                'url': 'https://hub.test/api',
                'headers': {
                  'Authorization': {'secret': 'ha_token'},
                },
                'body': 'hello',
              },
            },
            {
              'id': 'reply_ok',
              'type': 'compare',
              'config': {
                'left': {'var': '%reply'},
                'op': '!=',
                'right': {'literal': null},
              },
            },
          ],
          'edges': [
            for (final (i, from, port, to) in [
              (1, 'go', 'out', 'is_on'),
              (2, 'is_on', 'true', 'send'),
              (3, 'send', 'out', 'reply_ok'),
            ])
              {
                'id': 'e$i',
                'from': {'node': from, 'port': port},
                'to': {'node': to, 'port': 'in'},
              },
          ],
        }),
      ]);
    final traces = await engine.run('tell');
    await engine.close();
    expect(traces.single.outcome, RunOutcome.completed);
    final nodeEvents = [
      for (final e in host.emitted)
        if (e['event'] == 'run.node') e,
    ];
    expect(
      [for (final e in nodeEvents) e['node']],
      ['go', 'is_on', 'send', 'reply_ok'],
    );
    expect(nodeEvents[1]['seen'], 'manual');
    expect(nodeEvents.last.containsKey('seen'), isFalse);
    final wire = jsonEncode(host.emitted);
    expect(wire, isNot(contains('fixture-value')));
    expect(wire, isNot(contains('hello')));
    expect(wire, isNot(contains('Authorization')));
  });
}

class _Host implements FlowHost {
  final emitted = <Map<String, Object?>>[];
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<String?> webSecret(String name) async =>
      name == 'ha_token' ? 'fixture-value' : null;

  @override
  Future<bool> ranAt(String flowId, String scheduled) async => false;

  @override
  Future<void> markScheduled(String flowId, String scheduled) async {}

  @override
  Future<void> saveTrace(Map<String, Object?> trace) async {}

  @override
  Future<void> saveGlobal(String name, Object? value) async {}

  @override
  void emit(Map<String, Object?> event) => emitted.add(event);

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<Map<String, Object?>?> deviceState(String deviceId) async => null;

  @override
  Future<List<String>> roomDevices(String room) async => const [];

  @override
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    String? flowId,
  }) async => null;

  @override
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId, {
    String? flowId,
  }) async => null;
}

class _FakeWeb implements WebRequester {
  @override
  Future<WebReply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async => (status: 200, body: 'fixture-value body', bytes: 18);
}
