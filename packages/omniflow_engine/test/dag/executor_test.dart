import 'dart:async';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// Time that only moves when the test calls [advance].
class FakeClock implements FlowClock {
  FakeClock(this._now);

  DateTime _now;
  final _sleepers = <(DateTime, Completer<void>, CancelToken)>[];

  @override
  DateTime now() => _now;

  @override
  Future<void> sleep(Duration duration, CancelToken token) {
    final done = Completer<void>();
    _sleepers.add((_now.add(duration), done, token));
    token.whenCancelled.then((_) {
      if (!done.isCompleted) done.completeError(RunCancelled());
    });
    return done.future;
  }

  Future<void> advance(Duration by) async {
    _now = _now.add(by);
    for (final s in List.of(_sleepers)) {
      if (!s.$1.isAfter(_now)) {
        _sleepers.remove(s);
        if (!s.$2.isCompleted) s.$2.complete();
      }
    }
    await pump();
  }
}

Future<void> pump() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FakeEffects implements FlowEffects {
  final invoked = <(String, String, Map<String, Object?>)>[];
  final announced = <Map<String, Object?>>[];
  final ranFlows = <String>[];
  final eventsOut = StreamController<Map<String, Object?>>.broadcast();
  String? failDevice;

  @override
  final Map<String, Object?> globals = {'HomeWifiConnected': true};

  @override
  Map<String, Map<String, Object?>> deviceStates = {};

  @override
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    String? flowId,
  }) async {
    if (deviceId == failDevice) throw Exception('$deviceId timed out');
    invoked.add((deviceId, capabilityId, params));
    return {'ok': true};
  }

  @override
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId, {
    String? flowId,
  }) async {
    invoked.add((deviceId, capabilityId, const {'toggle': true}));
    return {'ok': true};
  }

  @override
  Future<void> runFlow(String flowId, Map<String, Object?> msg) async =>
      ranFlows.add(flowId);

  @override
  void announce(Map<String, Object?> payload) => announced.add(payload);

  @override
  Future<void> setGlobal(String name, Object? value) async =>
      globals[name] = value;

  @override
  Stream<Map<String, Object?>> get events => eventsOut.stream;
}

Map<String, Object?> node(
  String id,
  String type, [
  Map<String, Object?> config = const {},
]) => {'id': id, 'type': type, 'config': config};

Map<String, Object?> edge(String from, String port, String to) => {
  'id': '$from-$port-$to',
  'from': {'node': from, 'port': port},
  'to': {'node': to, 'port': 'in'},
};

Map<String, Object?> action(
  String id,
  String device, [
  Map<String, Object?> params = const {},
]) => node(id, 'device_capability', {
  'deviceId': device,
  'capabilityId': 'power',
  'params': params,
});

FlowSpec flow(
  List<Map<String, Object?>> nodes,
  List<Map<String, Object?>> edges, {
  String mode = 'single',
  int cooldown = 0,
}) => FlowSpec.parse({
  'schemaVersion': 1,
  'id': 'test_flow',
  'name': 'Test',
  'mode': mode,
  'cooldownSeconds': cooldown,
  'nodes': nodes,
  'edges': edges,
});

void main() {
  late FakeClock clock;
  late FakeEffects effects;
  final traces = <RunTrace>[];

  setUp(() {
    clock = FakeClock(DateTime(2026, 11, 6, 19, 0));
    effects = FakeEffects();
    traces.clear();
  });

  FlowRunner runner(FlowSpec f) =>
      FlowRunner(f, effects, clock: clock, onTrace: traces.add);

  FlowSpec evening({int cooldown = 1800}) => flow(
    [
      node('trig', 'manual'),
      node('cond', 'all_of', {
        'rules': [
          {'type': 'time_window', 'start': '18:00', 'end': '05:00'},
          {
            'type': 'compare',
            'left': {'var': r'$HomeWifiConnected'},
            'op': '==',
            'right': {'literal': true},
          },
        ],
      }),
      action('lamp', 'desk_lamp', {'value': true}),
      action('mac', 'mac_mini'),
    ],
    [
      edge('trig', 'out', 'cond'),
      edge('cond', 'true', 'lamp'),
      edge('cond', 'true', 'mac'),
    ],
    cooldown: cooldown,
  );

  group('the evening-desk flow', () {
    test('in the evening both actions run, from one trigger', () async {
      final trace = await runner(evening()).fire('trig', {'payload': {}});
      expect(trace.outcome, RunOutcome.completed);
      expect(
        effects.invoked.map((i) => i.$1),
        unorderedEquals(['desk_lamp', 'mac_mini']),
      );
      expect(trace.nodes.map((n) => n.nodeId), ['trig', 'cond', 'lamp', 'mac']);
      expect(trace.nodes[1].port, 'true');
    });

    test('at noon nothing runs, and the cooldown is not armed', () async {
      clock = FakeClock(DateTime(2026, 11, 6, 12, 0));
      final r = runner(evening());
      final noon = await r.fire('trig', {});
      expect(noon.nodes[1].port, 'false');
      expect(effects.invoked, isEmpty);
      await clock.advance(const Duration(hours: 6, minutes: 1));
      final evening2 = await r.fire('trig', {});
      expect(evening2.outcome, RunOutcome.completed);
      expect(effects.invoked, hasLength(2));
    });

    test('the cooldown drops a second arrival until it expires', () async {
      final r = runner(evening());
      await r.fire('trig', {});
      await clock.advance(const Duration(minutes: 10));
      final again = await r.fire('trig', {});
      expect((again.outcome, again.reason), (RunOutcome.dropped, 'cooldown'));
      await clock.advance(const Duration(minutes: 21));
      expect((await r.fire('trig', {})).outcome, RunOutcome.completed);
      expect(effects.invoked, hasLength(4));
    });
  });

  group('run modes, with a run waiting on a delay', () {
    FlowSpec delayed(String mode) => flow(
      [
        node('trig', 'manual'),
        node('wait', 'delay', {'ms': 1000}),
        action('lamp', 'desk_lamp', {'value': '{{msg.n}}'}),
      ],
      [edge('trig', 'out', 'wait'), edge('wait', 'out', 'lamp')],
      mode: mode,
    );

    test('single drops the second trigger', () async {
      final r = runner(delayed('single'));
      final first = r.fire('trig', {'n': 1});
      await pump();
      final second = await r.fire('trig', {'n': 2});
      expect((second.outcome, second.reason), (RunOutcome.dropped, 'running'));
      await clock.advance(const Duration(seconds: 1));
      expect((await first).outcome, RunOutcome.completed);
      expect(effects.invoked.map((i) => i.$3['value']), [1]);
    });

    test('restart cancels the first run before its action', () async {
      final r = runner(delayed('restart'));
      final first = r.fire('trig', {'n': 1});
      await pump();
      final second = r.fire('trig', {'n': 2});
      await pump();
      await clock.advance(const Duration(seconds: 1));
      expect((await first).outcome, RunOutcome.cancelled);
      expect((await second).outcome, RunOutcome.completed);
      expect(effects.invoked.map((i) => i.$3['value']), [2]);
    });

    test('queued runs the second after the first', () async {
      final r = runner(delayed('queued'));
      final first = r.fire('trig', {'n': 1});
      final second = r.fire('trig', {'n': 2});
      await pump();
      await clock.advance(const Duration(seconds: 1));
      await first;
      expect(effects.invoked.map((i) => i.$3['value']), [1]);
      await clock.advance(const Duration(seconds: 1));
      await second;
      expect(effects.invoked.map((i) => i.$3['value']), [1, 2]);
    });

    test('parallel runs both at once', () async {
      final r = runner(delayed('parallel'));
      final runs = [
        r.fire('trig', {'n': 1}),
        r.fire('trig', {'n': 2}),
      ];
      await pump();
      expect(r.activeRuns, 2);
      await clock.advance(const Duration(seconds: 1));
      await Future.wait(runs);
      expect(
        effects.invoked.map((i) => i.$3['value']),
        unorderedEquals([1, 2]),
      );
    });
  });

  group('errors', () {
    test('a failing action with no error edge fails the run', () async {
      effects.failDevice = 'desk_lamp';
      final trace = await runner(evening(cooldown: 0)).fire('trig', {});
      expect(trace.outcome, RunOutcome.failed);
      expect(trace.reason, contains('desk_lamp timed out'));
      expect(effects.invoked.single.$1, 'mac_mini');
    });

    test('a failing action with an error edge routes the error on', () async {
      effects.failDevice = 'desk_lamp';
      final f = flow(
        [
          node('trig', 'manual'),
          action('lamp', 'desk_lamp'),
          node('tell', 'notify', {'title': 'Lamp failed: {{msg.error}}'}),
        ],
        [edge('trig', 'out', 'lamp'), edge('lamp', 'error', 'tell')],
      );
      final trace = await runner(f).fire('trig', {});
      expect(trace.outcome, RunOutcome.completed);
      expect(
        effects.announced.single['title'],
        'Lamp failed: desk_lamp timed out',
      );
    });
  });

  test('debounce passes only the last of a burst', () async {
    final f = flow(
      [
        node('trig', 'manual'),
        node('quiet', 'debounce', {'ms': 500}),
        action('lamp', 'desk_lamp', {'value': '{{msg.n}}'}),
      ],
      [edge('trig', 'out', 'quiet'), edge('quiet', 'out', 'lamp')],
      mode: 'parallel',
    );
    final r = runner(f);
    final runs = <Future<RunTrace>>[];
    for (var n = 1; n <= 3; n++) {
      runs.add(r.fire('trig', {'n': n}));
      await pump();
      await clock.advance(const Duration(milliseconds: 100));
    }
    await clock.advance(const Duration(milliseconds: 500));
    await Future.wait(runs);
    expect(effects.invoked.map((i) => i.$3['value']), [3]);
  });

  test('a cooldown gate lets one pass per window', () async {
    final f = flow(
      [
        node('trig', 'manual'),
        node('gate', 'cooldown', {'seconds': 60}),
        action('lamp', 'desk_lamp'),
      ],
      [edge('trig', 'out', 'gate'), edge('gate', 'out', 'lamp')],
      mode: 'parallel',
    );
    final r = runner(f);
    await r.fire('trig', {});
    await r.fire('trig', {});
    await clock.advance(const Duration(seconds: 61));
    await r.fire('trig', {});
    expect(effects.invoked, hasLength(2));
  });

  group('wait_for_event', () {
    FlowSpec waiting() => flow(
      [
        node('trig', 'manual'),
        node('wait', 'wait_for_event', {
          'event': 'board.event',
          'timeoutMs': 5000,
        }),
        action('got', 'desk_lamp', {'value': '{{msg.event.value}}'}),
        action('late', 'mac_mini'),
      ],
      [
        edge('trig', 'out', 'wait'),
        edge('wait', 'event', 'got'),
        edge('wait', 'timeout', 'late'),
      ],
    );

    test('takes the event port when the event comes', () async {
      final run = runner(waiting()).fire('trig', {});
      await pump();
      effects.eventsOut.add({'event': 'board.event', 'value': 7});
      await pump();
      await run;
      expect(effects.invoked.single.$1, 'desk_lamp');
      expect(effects.invoked.single.$3, {'value': 7});
    });

    test('takes the timeout port otherwise', () async {
      final run = runner(waiting()).fire('trig', {});
      await pump();
      await clock.advance(const Duration(seconds: 5));
      await run;
      expect(effects.invoked.single.$1, 'mac_mini');
    });
  });

  group('wait_until', () {
    FlowSpec until(Map<String, Object?> on) => flow(
      [
        node('trig', 'manual'),
        node('wait', 'wait_until', {...on, 'timeoutMs': 5000}),
        action('got', 'desk_lamp'),
        action('late', 'mac_mini'),
      ],
      [
        edge('trig', 'out', 'wait'),
        edge('wait', 'matched', 'got'),
        edge('wait', 'timeout', 'late'),
      ],
    );

    Map<String, Object?> changed(String id, Map<String, Object?> state) => {
      'event': 'device.stateChanged',
      'device': {'id': id, 'state': state},
    };

    test('matches a state change to a value, not other changes', () async {
      effects.deviceStates['jade'] = {'home': false};
      final run = runner(
        until({
          'thing': 'jade',
          'key': 'home',
          'change': {'to': true},
        }),
      ).fire('trig', {});
      await pump();
      effects.eventsOut
        ..add(changed('lamp', {'home': true}))
        ..add(changed('jade', {'home': false, 'place': 'office'}));
      await pump();
      expect(effects.invoked, isEmpty);
      effects.eventsOut.add(changed('jade', {'home': true}));
      final trace = await run;
      expect(effects.invoked.single.$1, 'desk_lamp');
      final waited = trace.nodes.firstWhere((n) => n.nodeId == 'wait');
      expect(waited.port, 'matched');
      expect((waited.output!['event'] as Map)['value'], isTrue);
    });

    test('matches a crossing once the value goes past it', () async {
      effects.deviceStates['room'] = {'temp': 30};
      final run = runner(
        until({
          'thing': 'room',
          'key': 'temp',
          'crosses': {'below': 25},
        }),
      ).fire('trig', {});
      await pump();
      effects.eventsOut.add(changed('room', {'temp': 26}));
      await pump();
      expect(effects.invoked, isEmpty);
      effects.eventsOut.add(changed('room', {'temp': 24}));
      await run;
      expect(effects.invoked.single.$1, 'desk_lamp');
    });

    test('matches an event with its payload', () async {
      final run = runner(
        until({
          'thing': 'desk',
          'key': 'button',
          'event': true,
          'match': {'hold': true},
        }),
      ).fire('trig', {});
      await pump();
      effects.eventsOut.add({
        'event': 'thing.event',
        'thing': 'desk',
        'key': 'button',
        'payload': {'hold': false},
      });
      await pump();
      expect(effects.invoked, isEmpty);
      effects.eventsOut.add({
        'event': 'thing.event',
        'thing': 'desk',
        'key': 'button',
        'payload': {'hold': true},
      });
      await run;
      expect(effects.invoked.single.$1, 'desk_lamp');
    });

    test('takes the timeout port and stops listening', () async {
      final run = runner(until({'thing': 'jade', 'key': 'home'}))
          .fire('trig', {});
      await pump();
      await clock.advance(const Duration(seconds: 5));
      await run;
      expect(effects.invoked.single.$1, 'mac_mini');
      expect(effects.eventsOut.hasListener, isFalse);
    });
  });

  test('parallel runs its branches side by side, then done once', () async {
    final f = flow(
      [
        node('trig', 'manual'),
        node('both', 'parallel'),
        node('slow', 'delay', {'ms': 1000}),
        action('lamp', 'desk_lamp'),
        action('mac', 'mac_mini'),
        action('after', 'hall_plug'),
      ],
      [
        edge('trig', 'out', 'both'),
        edge('both', 'branch', 'slow'),
        edge('slow', 'out', 'lamp'),
        edge('both', 'branch', 'mac'),
        edge('both', 'done', 'after'),
      ],
    );
    final run = runner(f).fire('trig', {});
    await pump();
    expect(effects.invoked.map((i) => i.$1), ['mac_mini']);
    await clock.advance(const Duration(seconds: 1));
    await run;
    expect(effects.invoked.map((i) => i.$1), [
      'mac_mini',
      'desk_lamp',
      'hall_plug',
    ]);
  });

  test('repeat runs its body the set number of times, then done', () async {
    final f = flow(
      [
        node('trig', 'manual'),
        node('loop', 'repeat', {'maxIterations': 3}),
        action('blink', 'desk_lamp', {'value': '{{msg.iteration}}'}),
        action('after', 'mac_mini'),
      ],
      [
        edge('trig', 'out', 'loop'),
        edge('loop', 'body', 'blink'),
        edge('loop', 'done', 'after'),
      ],
    );
    await runner(f).fire('trig', {});
    expect(effects.invoked.map((i) => (i.$1, i.$3['value'])), [
      ('desk_lamp', 0),
      ('desk_lamp', 1),
      ('desk_lamp', 2),
      ('mac_mini', null),
    ]);
  });

  test('variables: a run variable feeds a later template, a global goes to the store', () async {
    final f = flow(
      [
        node('trig', 'manual'),
        node('set', 'set_variable', {
          'name': '%level',
          'value': '{{msg.payload.level}}',
        }),
        node('mark', 'set_variable', {
          'name': r'$LastLevel',
          'value': '{{%level}}',
        }),
        action('lamp', 'desk_lamp', {'value': '{{%level}}'}),
      ],
      [
        edge('trig', 'out', 'set'),
        edge('set', 'out', 'mark'),
        edge('mark', 'out', 'lamp'),
      ],
    );
    await runner(f).fire('trig', {
      'payload': {'level': 55},
    });
    expect(effects.invoked.single.$3, {'value': 55});
    expect(effects.globals['LastLevel'], 55);
  });

  test('a dry run calls nothing, ignores the cooldown and shows what would be sent', () async {
    final r = runner(evening());
    await r.fire('trig', {});
    effects.invoked.clear();
    final dry = await r.fire(
      'trig',
      {},
      dryRun: true,
      clock: InstantFlowClock(DateTime(2026, 11, 6, 20)),
    );
    expect(dry.outcome, RunOutcome.completed);
    expect(effects.invoked, isEmpty);
    final lamp = dry.nodes.firstWhere((n) => n.nodeId == 'lamp');
    expect((lamp.output!['result'] as Map)['dryRun'], isTrue);
    expect(dry.toJson()['dryRun'], isTrue);
  });

  group('reloads and queues', () {
    FlowSpec slow({String mode = 'queued', int cooldown = 0, int ms = 1000}) =>
        flow(
          [
            node('trig', 'manual'),
            node('wait', 'delay', {'ms': ms}),
            action('lamp', 'desk_lamp'),
          ],
          [edge('trig', 'out', 'wait'), edge('wait', 'out', 'lamp')],
          mode: mode,
          cooldown: cooldown,
        );

    test(
      'a queued run waiting when the flow is cancelled never acts',
      () async {
        final r = runner(slow());
        final first = r.fire('trig', {});
        await pump();
        final second = r.fire('trig', {});
        await pump();
        r.cancelAll();
        await clock.advance(const Duration(seconds: 2));
        await clock.advance(const Duration(seconds: 2));
        expect((await first).outcome, RunOutcome.cancelled);
        expect((await second).reason, 'cancelled');
        expect(effects.invoked, isEmpty);
      },
    );

    test(
      'a queued run is dropped when the run before it armed the cooldown',
      () async {
        final r = runner(slow(cooldown: 60, ms: 100));
        final first = r.fire('trig', {});
        await pump();
        final second = r.fire('trig', {});
        await pump();
        await clock.advance(const Duration(milliseconds: 200));
        await clock.advance(const Duration(milliseconds: 200));
        expect((await first).outcome, RunOutcome.completed);
        expect((await second).reason, 'cooldown');
        expect(effects.invoked, hasLength(1));
      },
    );
  });

  group('run_flow', () {
    FlowSpec calls(String target) => flow(
      [
        node('trig', 'manual'),
        node('call', 'run_flow', {'flowId': target}),
      ],
      [edge('trig', 'out', 'call')],
    );

    test('a call back into a flow on the call stack fails the node', () async {
      final self = await runner(calls('test_flow')).fire('trig', {});
      expect(self.outcome, RunOutcome.failed);
      expect(self.reason, contains('run_flow cycle'));
      final back = await runner(calls('a')).fire('trig', {
        callStackKey: ['a'],
      });
      expect(back.reason, contains('a -> test_flow -> a'));
      expect(effects.ranFlows, isEmpty);
    });

    test('a call to another flow passes the stack on', () async {
      final trace = await runner(calls('other')).fire('trig', {});
      expect(trace.outcome, RunOutcome.completed);
      expect(effects.ranFlows, ['other']);
    });
  });

  group('nothing is left running', () {
    test('a cancelled delay leaves no timer behind', () async {
      final timers = <Timer>[];
      await runZoned(
        () async {
          final r = FlowRunner(
            flow(
              [
                node('trig', 'manual'),
                node('wait', 'delay', {'ms': 3600000}),
                action('lamp', 'desk_lamp'),
              ],
              [edge('trig', 'out', 'wait'), edge('wait', 'out', 'lamp')],
            ),
            effects,
          );
          final run = r.fire('trig', {});
          await pump();
          r.cancelAll();
          expect((await run).outcome, RunOutcome.cancelled);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final t = parent.createTimer(zone, duration, callback);
            timers.add(t);
            return t;
          },
        ),
      );
      expect(timers.where((t) => t.isActive), isEmpty);
    });

    test('wait_for_event stops listening once it times out', () async {
      final f = flow(
        [
          node('trig', 'manual'),
          node('wait', 'wait_for_event', {'event': 'door', 'timeoutMs': 500}),
          action('lamp', 'desk_lamp'),
        ],
        [edge('trig', 'out', 'wait'), edge('wait', 'timeout', 'lamp')],
      );
      final run = runner(f).fire('trig', {});
      await pump();
      expect(effects.eventsOut.hasListener, isTrue);
      await clock.advance(const Duration(milliseconds: 600));
      expect((await run).outcome, RunOutcome.completed);
      expect(effects.invoked, hasLength(1));
      expect(effects.eventsOut.hasListener, isFalse);
    });
  });
}
