import 'dart:async';
import 'dart:convert';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import 'executor_test.dart' show FakeClock, FakeEffects, pump;
import 'rules_test.dart' show context, refs;

class _Web implements WebRequester {
  _Web(this.body);

  final String body;
  final int status = 200;

  @override
  Future<WebReply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async => (status: status, body: this.body, bytes: this.body.length);
}

List<String> _paths(Map<String, Object?> rule) {
  try {
    normalizeRule(rule, context: context);
  } on ValidationException catch (e) {
    return [for (final i in e.issues) i.path];
  }
  return const [];
}

FlowSpec _compile(Map<String, Object?> rule) {
  final compiled = compileRule(
    normalizeRule(rule, context: context),
    refs: refs(),
  );
  final flow = FlowSpec.parse(compiled.flow);
  expect(validateFlow(flow, refs: refs()), isEmpty);
  return flow;
}

Map<String, Object?> _rule(List<Object?> then, {Map<String, Object?>? extra}) =>
    {
      'name': 'Shortcut',
      'when': ['manual'],
      'then': then,
      ...?extra,
    };

void main() {
  late FakeClock clock;
  late FakeEffects effects;
  late List<Map<String, Object?>> events;
  late AskBroker asks;

  setUp(() {
    clock = FakeClock(DateTime(2026, 11, 12, 18, 5, 9));
    effects = FakeEffects();
    events = [];
    asks = AskBroker(events.add);
  });

  FlowRunner runner(FlowSpec f, {WebRequester? web}) =>
      FlowRunner(f, effects, clock: clock, asks: asks, web: web ?? _Web('{}'));

  Map<String, Object?> announced(int i) => effects.announced[i];

  group('normalizing', () {
    test('each new step tells its problems at its own path', () {
      expect(
        _paths(
          _rule([
            {
              'ask': {'title': 'Which?'},
            },
            {
              'ask': {
                'title': 'Which?',
                'choices': ['A', 'B'],
                'default': 'C',
                'timeoutMs': 5,
              },
            },
            {
              'get': {'from': '{{%reply.body}}', 'path': 'a..b'},
            },
            {
              'text': {'value': 'x', 'op': 'shout'},
            },
            {
              'math': {'expr': '2 * * 3'},
            },
            {
              'date': {'offsetMinutes': 9999999},
            },
            {
              'forEach': {
                'in': 7,
                'max': 2000,
                'do': ['notify:x'],
              },
            },
            {'do': 'lamp.power', 'as': 'reply'},
            {
              'http': {'url': 'https://example.com', 'as': r'$Global'},
            },
          ]),
        ),
        [
          'then[0].ask.choices',
          'then[1].ask.default',
          'then[1].ask.timeoutMs',
          'then[2].get.path',
          'then[3].text.op',
          'then[4].math.expr',
          'then[5].date.offsetMinutes',
          'then[6].forEach.in',
          'then[6].forEach.max',
          'then[7].as',
          'then[8].http.as',
        ],
      );
    });

    test('the look and the ask-first switches are checked', () {
      expect(
        _paths(
          _rule(
            ['notify:hi'],
            extra: {
              'color': '#123456',
              'icon': 'rocket',
              'askFirst': 'yes',
              'notifyOnRun': 1,
            },
          ),
        ),
        ['color', 'icon', 'askFirst', 'notifyOnRun'],
      );
      final rule = normalizeRule(
        _rule(
          ['notify:hi'],
          extra: {
            'color': '#4D9DFF',
            'icon': 'tv',
            'askFirst': true,
            'notifyOnRun': false,
          },
        ),
        context: context,
      );
      expect(rule['color'], '#4D9DFF');
      expect(rule['icon'], 'tv');
      expect(rule['askFirst'], isTrue);
      expect(rule.containsKey('notifyOnRun'), isFalse);
    });

    test('a step may drive the device a run variable holds', () {
      expect(
        _paths(
          _rule([
            {
              'forEach': {
                'in': 'room:Living room',
                'do': [
                  {
                    'do': '{{%item}}.power',
                    'params': {'value': false},
                  },
                ],
              },
            },
          ]),
        ),
        isEmpty,
      );
    });
  });

  group('compiling', () {
    test('the steps become their nodes, and the switches reach the flow', () {
      final flow = _compile(
        _rule(
          [
            {
              'ask': {
                'title': 'Which app?',
                'choices': ['Netflix', 'YouTube'],
                'input': false,
                'default': 'Netflix',
              },
            },
            {
              'get': {'from': '{{%answer}}'},
            },
            {
              'text': {'value': '{{%value}}', 'op': 'upper'},
            },
            {
              'math': {'expr': '1 + 2'},
            },
            {
              'date': {'format': 'HH:mm'},
            },
            {
              'forEach': {
                'in': ['a', 'b'],
                'do': ['notify:{{%item}}'],
              },
            },
          ],
          extra: {'askFirst': true, 'notifyOnRun': true},
        ),
      );
      expect(
        [for (final n in flow.nodes) n.type],
        [
          'manual',
          'ask',
          'get_value',
          'format_text',
          'calculate',
          'format_date',
          'for_each',
          'notify',
        ],
      );
      expect(flow.askFirst, isTrue);
      expect(flow.notifyOnRun, isTrue);
      expect(flow.nodes[6].config['maxIterations'], RuleKeys.forEachDefault);
      expect(flow.nodes[1].config.containsKey('input'), isFalse);
    });

    test('a rule without the switches keeps its old flow', () {
      final flow = _compile(_rule(['notify:hi']));
      expect(flow.toJson().containsKey('askFirst'), isFalse);
      expect(flow.toJson().containsKey('notifyOnRun'), isFalse);
    });
  });

  group('running', () {
    test(
      'values flow from a web reply through get, math, text and date',
      () async {
        final flow = _compile(
          _rule([
            {
              'http': {'url': 'https://example.com/temp'},
            },
            {
              'get': {'from': '{{%reply.body}}', 'path': 'rooms[1].temp'},
            },
            {
              'math': {'expr': '{{%value}} * 2 + 1'},
            },
            {
              'text': {
                'value': ' it is {{%result}} ',
                'op': 'trim',
                'as': '%t',
              },
            },
            {
              'date': {'format': 'HH:mm:ss', 'offsetMinutes': 60},
            },
            {
              'notify': {'title': '{{%t}} at {{%date}} ({{%reply.status}})'},
            },
          ]),
        );
        final web = _Web(
          jsonEncode({
            'rooms': [
              {'temp': 1},
              {'temp': 20.5},
            ],
          }),
        );
        final trace = await runner(flow, web: web).fire('when_0', {});
        expect(
          trace.outcome,
          RunOutcome.completed,
          reason: '${trace.toJson()}',
        );
        expect(announced(0)['title'], 'it is 42.0 at 19:05:09 (200)');
      },
    );

    test('a do step keeps the device\'s new state', () async {
      effects.deviceStates['lamp'] = {'state': true};
      final flow = _compile(
        _rule([
          {
            'do': 'lamp.power',
            'params': {'value': true},
          },
          'notify:lamp is {{%state.state}}',
        ]),
      );
      await runner(flow).fire('when_0', {});
      expect(announced(0)['title'], 'lamp is true');
    });

    test('a missing value fails get, and try runs otherwise', () async {
      final flow = _compile(
        _rule([
          {
            'try': [
              {
                'get': {'from': '{{msg.data}}', 'path': 'nope'},
              },
              'notify:found',
            ],
            'otherwise': ['notify:{{msg.error}}'],
          },
        ]),
      );
      final trace = await runner(flow).fire('when_0', {
        'data': {'here': 1},
      });
      expect(trace.outcome, RunOutcome.completed);
      expect(
        effects.announced.single['title'],
        'the value has nothing at nope',
      );
    });

    test('a sum that cannot be worked out fails the step', () async {
      final flow = _compile(
        _rule([
          {
            'math': {'expr': '{{msg.word}} * 2'},
          },
        ]),
      );
      final trace = await runner(flow).fire('when_0', {'word': 'abc'});
      expect(trace.outcome, RunOutcome.failed);
      expect(trace.reason, contains('cannot be worked out'));
    });

    test('forEach goes through a list, stopping at max', () async {
      final flow = _compile(
        _rule([
          {
            'forEach': {
              'in': '{{msg.items}}',
              'as': '%x',
              'max': 2,
              'do': ['notify:{{msg.index}} {{%x}}'],
            },
          },
        ]),
      );
      await runner(flow).fire('when_0', {
        'items': ['a', 'b', 'c'],
      });
      expect([for (final a in effects.announced) a['title']], ['0 a', '1 b']);
    });

    test('forEach over a room drives each of its devices', () async {
      effects.rooms['Living room'] = ['lamp', 'fan'];
      final flow = _compile(
        _rule([
          {
            'forEach': {
              'in': 'room:Living room',
              'do': [
                {
                  'do': '{{%item}}.power',
                  'params': {'value': false},
                },
              ],
            },
          },
        ]),
      );
      final trace = await runner(flow).fire('when_0', {});
      expect(trace.outcome, RunOutcome.completed, reason: '${trace.toJson()}');
      expect([for (final i in effects.invoked) i.$1], ['lamp', 'fan']);
    });

    test('forEach over something that is not a list fails', () async {
      final flow = _compile(
        _rule([
          {
            'forEach': {
              'in': '{{msg.items}}',
              'do': ['notify:x'],
            },
          },
        ]),
      );
      final trace = await runner(flow).fire('when_0', {'items': 'one'});
      expect(trace.outcome, RunOutcome.failed);
      expect(trace.reason, contains('no list'));
    });
  });

  group('asking', () {
    FlowSpec choose({Object? fallback, List<Object?>? otherwise}) => _compile(
      _rule([
        {
          'try': [
            {
              'ask': {
                'title': 'Which app?',
                'body': 'For the TV',
                'choices': ['Netflix', 'YouTube'],
                'default': ?fallback,
                'timeoutMs': 60000,
              },
            },
            'notify:open {{%answer}}',
          ],
          'otherwise': ?otherwise,
        },
      ]),
    );

    test(
      'the answer goes into %answer, with request and closed events',
      () async {
        final done = runner(choose()).fire('when_0', {});
        await pump();
        final request = events.single;
        expect(request['event'], 'ask.request');
        expect(request['kind'], 'choose');
        expect(request['choices'], ['Netflix', 'YouTube']);
        expect(request['body'], 'For the TV');
        expect(request['expiresAt'], isA<String>());
        expect(asks.pending.single['askId'], request['askId']);
        expect(
          asks.answer('${request['askId']}', 'Disney'),
          contains('one of Netflix, YouTube'),
        );
        expect(asks.answer('${request['askId']}', 'YouTube'), isNull);
        final trace = await done;
        expect(trace.outcome, RunOutcome.completed);
        expect(effects.announced.single['title'], 'open YouTube');
        expect(events.last, {
          'event': 'ask.closed',
          'askId': request['askId'],
          'answer': 'YouTube',
          'reason': 'answered',
        });
        expect(asks.pending, isEmpty);
        expect(
          asks.answer('${request['askId']}', 'YouTube'),
          contains('not waiting'),
        );
      },
    );

    test('a timeout takes the default', () async {
      final done = runner(choose(fallback: 'Netflix')).fire('when_0', {});
      await pump();
      await clock.advance(const Duration(minutes: 1));
      final trace = await done;
      expect(trace.outcome, RunOutcome.completed);
      expect(effects.announced.single['title'], 'open Netflix');
      expect(events.last['reason'], 'timeout');
      expect(events.last['answer'], 'Netflix');
    });

    test(
      'a timeout with no default fails the step, and otherwise runs',
      () async {
        final done = runner(choose(otherwise: ['notify:no answer']))
            .fire('when_0', {});
        await pump();
        await clock.advance(const Duration(minutes: 1));
        final trace = await done;
        expect(trace.outcome, RunOutcome.completed);
        expect(effects.announced.single['title'], 'no answer');
        expect(events.last['reason'], 'timeout');
      },
    );

    test('a cancelled run closes its ask as cancelled', () async {
      final r = runner(choose());
      final done = r.fire('when_0', {});
      await pump();
      r.cancelAll();
      final trace = await done;
      expect(trace.outcome, RunOutcome.cancelled);
      expect(events.last['reason'], 'cancelled');
      expect(asks.pending, isEmpty);
    });

    test('an input ask takes any text', () async {
      final flow = _compile(
        _rule([
          {
            'ask': {'title': 'Say something', 'input': true, 'as': '%said'},
          },
          'notify:{{%said}}',
        ]),
      );
      final done = runner(flow).fire('when_0', {});
      await pump();
      expect(events.single['kind'], 'input');
      expect(events.single.containsKey('choices'), isFalse);
      expect(asks.answer('${events.single['askId']}', 'hello there'), isNull);
      await done;
      expect(effects.announced.single['title'], 'hello there');
    });

    test('a dry run takes the default without asking', () async {
      final trace = await runner(choose(fallback: 'YouTube'))
          .fire('when_0', {}, dryRun: true);
      expect(trace.outcome, RunOutcome.completed);
      expect(events, isEmpty);
    });
  });

  group('notification words stay out of the trace', () {
    test('the trigger, the step inputs and what was announced', () async {
      final flow = FlowSpec.parse({
        'schemaVersion': 1,
        'id': 'n',
        'name': 'N',
        'nodes': [
          {
            'id': 'on',
            'type': 'on',
            'config': {'thing': 'phone', 'key': 'notification', 'event': true},
          },
          {
            'id': 'tell',
            'type': 'notify',
            'config': {'title': '{{msg.payload.text}}'},
          },
          {
            'id': 'keep',
            'type': 'set_variable',
            'config': {'name': r'$Last', 'value': '{{msg.payload.text}}'},
          },
        ],
        'edges': [
          {
            'id': 'e1',
            'from': {'node': 'on', 'port': 'out'},
            'to': {'node': 'tell', 'port': 'in'},
          },
          {
            'id': 'e2',
            'from': {'node': 'tell', 'port': 'out'},
            'to': {'node': 'keep', 'port': 'in'},
          },
        ],
      });
      final trace = await runner(flow).fire('on', {
        'thing': 'phone',
        'key': 'notification',
        'payload': {
          'package': 'com.chat',
          'label': 'Chat',
          'title': 'Secret title',
          'text': 'Secret words',
        },
      });
      expect(effects.announced.single['title'], 'Secret words');
      final stored = jsonEncode(trace.toJson());
      expect(stored, isNot(contains('Secret')));
      expect(stored, contains('com.chat'));
      expect(effects.globals.containsKey('Last'), isFalse);
      expect(trace.reason, contains('cannot set the variable Last'));
    });
  });

  group('the date step', () {
    test('formats with the usual letters and quoted text', () {
      final at = DateTime(2026, 3, 7, 9, 4, 5);
      expect(formatDate(at, 'yyyy-MM-dd HH:mm:ss'), '2026-03-07 09:04:05');
      expect(formatDate(at, "EEE d MMM 'at' h:mm a"), 'Sat 7 Mar at 9:04 AM');
      expect(formatDate(at, 'EEEE, MMMM'), 'Saturday, March');
    });

    test('get reads dotted paths, list items and JSON text', () {
      expect(
        valueAt({
          'a': [
            1,
            {'b': 2},
          ],
        }, 'a[1].b'),
        (true, 2),
      );
      expect(valueAt('{"x": {"y": true}}', 'x.y'), (true, true));
      expect(valueAt({'a': 1}, 'b'), (false, null));
      expect(valueAt([5, 6], '[1]'), (true, 6));
    });
  });

  test('a broker with nothing open answers no one', () {
    expect(AskBroker((_) {}).answer('ask-1', 'Run'), contains('not waiting'));
  });

  test('every ask kind the engine sends is in the contract', () {
    expect(
      [for (final k in AskKind.values) k.name],
      ['confirm', 'choose', 'input'],
    );
  });

  group('the flow engine', () {
    test('an ask-first trigger that is not answered is dropped', () async {
      final host = _Host();
      final engine = FlowEngine(host, clock: clock);
      addTearDown(engine.close);
      engine.load([
        _compile({
          'name': 'Lamp',
          'askFirst': true,
          'notifyOnRun': true,
          'when': [
            {'on': 'front_door.scanned', 'event': true},
          ],
          'then': ['notify:hi'],
        }),
      ]);
      host.raise('front_door', 'scanned');
      await pump();
      expect(engine.asks.pending.single['kind'], 'confirm');
      await clock.advance(const Duration(minutes: 5));
      await pump();
      expect(host.named('ask.closed').single['reason'], 'timeout');
      expect(
        host.named('run.finished').single,
        containsPair('outcome', 'dropped'),
      );
      expect(host.named('run.finished').single['reason'], 'not answered');
      expect(host.named('flow.announce'), isEmpty);
      expect(host.traces, isEmpty);
    });

    test('Run runs it with the trigger\'s message, then notifies', () async {
      final host = _Host();
      final engine = FlowEngine(host, clock: clock);
      addTearDown(engine.close);
      engine.load([
        _compile({
          'name': 'Lamp',
          'askFirst': true,
          'notifyOnRun': true,
          'when': [
            {'on': 'front_door.scanned', 'event': true},
          ],
          'then': ['notify:by {{msg.device}}'],
        }),
      ]);
      host.raise('front_door', 'scanned');
      await pump();
      final id = '${engine.asks.pending.single['askId']}';
      expect(engine.asks.answer(id, 'Run'), isNull);
      await pump();
      expect(
        [for (final a in host.named('flow.announce')) a['title']],
        ['by front_door', 'Lamp ran'],
      );
    });
  });
}

class _Host implements FlowHost {
  final emitted = <Map<String, Object?>>[];
  final traces = <Map<String, Object?>>[];
  final _events = StreamController<Map<String, Object?>>.broadcast();

  List<Map<String, Object?>> named(String event) => [
    for (final e in emitted)
      if (e['event'] == event) e,
  ];

  void raise(String thing, String key) => _events.add({
    'event': 'thing.event',
    'thing': thing,
    'key': key,
    'payload': <String, Object?>{},
  });

  @override
  void emit(Map<String, Object?> event) => emitted.add(event);

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<bool> ranAt(String flowId, String scheduled) async => false;

  @override
  Future<void> markScheduled(String flowId, String scheduled) async {}

  @override
  Future<void> saveTrace(Map<String, Object?> trace) async => traces.add(trace);

  @override
  Future<void> saveGlobal(String name, Object? value) async {}

  @override
  Future<String?> webSecret(String name) async => null;

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
