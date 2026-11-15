import 'dart:async';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/dag/hold_triggers.dart';
import 'package:omniflow_engine/src/dag/skips.dart';
import 'package:test/test.dart';

/// A host that also tells the device history, the people and the
/// automations that do not run.
class _Host implements FlowHost, RulesHost {
  final announced = <String>[];
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final history = <String, List<({DateTime at, Object? value})>>{};
  Set<String> persons = {};
  List<(FlowSpec, String)> idle = [];

  @override
  Future<List<({DateTime at, Object? value})>> stateHistory(
    String thing,
    String key,
  ) async => history['$thing.$key'] ?? const [];

  @override
  Future<Set<String>> people() async => persons;

  @override
  Future<List<(FlowSpec, String)>> idleFlows() async => idle;

  @override
  Future<bool> ranAt(String flowId, String scheduled) async => false;

  @override
  Future<void> markScheduled(String flowId, String scheduled) async {}

  @override
  Future<void> saveTrace(Map<String, Object?> trace) async {}

  @override
  Future<void> saveGlobal(String name, Object? value) async {}

  @override
  Future<String?> webSecret(String name) async => null;

  @override
  void emit(Map<String, Object?> event) {
    if (event['event'] == 'flow.announce') announced.add('${event['title']}');
  }

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

  void state(String id, Map<String, Object?> state, {String? driver}) =>
      _events.add({
        'event': 'device.stateChanged',
        'device': {'id': id, 'driver': ?driver, 'state': state},
      });
}

Map<String, Object?> _edge(String from, String port, String to) => {
  'id': '$from-$to',
  'from': {'node': from, 'port': port},
  'to': {'node': to, 'port': 'in'},
};

/// A flow that says [title] when [trigger] fires, past [condition] when
/// given.
FlowSpec _flow(
  String id,
  String type,
  Map<String, Object?> trigger, {
  String title = 'ran',
  Map<String, Object?>? condition,
  Map<String, Object?> extra = const {},
}) => FlowSpec.parse({
  'schemaVersion': 1,
  'id': id,
  'name': id,
  ...extra,
  'nodes': [
    {'id': 't', 'type': type, 'label': 'the door opens', 'config': trigger},
    if (condition != null)
      {
        'id': 'only_if',
        'type': condition['type'],
        'config': {...condition}..remove('type'),
      },
    {
      'id': 'say',
      'type': 'notify',
      'config': {'title': title},
    },
  ],
  'edges': [
    if (condition != null) ...[
      _edge('t', 'out', 'only_if'),
      _edge('only_if', 'true', 'say'),
    ] else
      _edge('t', 'out', 'say'),
  ],
});

Future<void> _settle([int ms = 0]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late _Host host;
  late FlowEngine engine;

  setUp(() {
    host = _Host();
    engine = FlowEngine(host);
  });

  tearDown(() => engine.close());

  group('held for a time', () {
    final heldOpen = {
      'thing': 'door',
      'key': 'open',
      'change': {'to': true},
      'forMs': 120,
    };

    test('fires once the state has held the whole time', () async {
      engine.deviceStates['door'] = {'open': false};
      engine.load([_flow('door', 'on', heldOpen)]);
      host.state('door', {'open': true});
      await _settle(60);
      expect(host.announced, isEmpty);
      // A heartbeat with the same value does not start it again.
      host.state('door', {'open': true});
      await _settle(120);
      expect(host.announced, ['ran']);
      await _settle(150);
      expect(host.announced, ['ran'], reason: 'never twice for one hold');
    });

    test('is cancelled when the state changes back', () async {
      engine.deviceStates['door'] = {'open': false};
      engine.load([_flow('door', 'on', heldOpen)]);
      host.state('door', {'open': true});
      await _settle(50);
      host.state('door', {'open': false});
      await _settle(150);
      expect(host.announced, isEmpty);
      host.state('door', {'open': true});
      await _settle(180);
      expect(host.announced, ['ran']);
    });

    test('a crossing holds while the number stays past it', () async {
      engine.deviceStates['room'] = {'temp': 20};
      engine.load([
        _flow('hot', 'on', {
          'thing': 'room',
          'key': 'temp',
          'crosses': {'above': 28},
          'forMs': 100,
        }),
      ]);
      host.state('room', {'temp': 30});
      await _settle(40);
      host.state('room', {'temp': 31});
      await _settle(40);
      host.state('room', {'temp': 27});
      await _settle(120);
      expect(host.announced, isEmpty);
      host.state('room', {'temp': 29});
      await _settle(160);
      expect(host.announced, ['ran']);
    });

    test('resumes the time left after a restart from the history', () async {
      engine.deviceStates['door'] = {'open': true};
      host.history['door.open'] = [
        (
          at: DateTime.now().subtract(const Duration(milliseconds: 60)),
          value: true,
        ),
        (at: DateTime.now().subtract(const Duration(hours: 1)), value: false),
      ];
      engine
        ..load([
          _flow('door', 'on', {...heldOpen, 'forMs': 200}),
        ])
        ..startTimers();
      await _settle(80);
      expect(host.announced, isEmpty);
      await _settle(150);
      expect(host.announced, ['ran']);
    });

    test(
      'a hold whose time passed while down, or unknown, never fires',
      () async {
        engine.deviceStates['door'] = {'open': true};
        engine.deviceStates['gate'] = {'open': true};
        host.history['door.open'] = [
          (
            at: DateTime.now().subtract(const Duration(seconds: 5)),
            value: true,
          ),
        ];
        engine
          ..load([
            _flow('door', 'on', heldOpen),
            _flow('gate', 'on', {...heldOpen, 'thing': 'gate'}),
          ])
          ..startTimers();
        await _settle(250);
        expect(host.announced, isEmpty);
      },
    );

    test('the node check wants a state to hold', () {
      final issues = IssueCollector();
      checkHeldOn({'thing': 'door', 'key': 'open', 'forMs': 5}, r'$', issues);
      expect(issues.issues.single.message, contains('needs a state'));
      final ok = IssueCollector();
      checkHeldOn(heldOpen, r'$', ok);
      expect(ok.hasIssues, isFalse);
    });
  });

  group('people', () {
    void household(Map<String, bool> home) {
      host.persons = home.keys.toSet();
      for (final e in home.entries) {
        engine.deviceStates[e.key] = {'home': e.value, 'place': null};
      }
    }

    test('the first to get home and the last to leave', () async {
      household({'jade': false, 'asha': false});
      engine.load([
        _flow('first', 'people_change', {
          'when': 'first_arrives',
        }, title: 'first'),
        _flow('last', 'people_change', {'when': 'last_leaves'}, title: 'last'),
      ]);
      await _settle();
      host.state('jade', {'home': true, 'place': 'home'}, driver: 'person');
      await _settle();
      host.state('asha', {'home': true, 'place': 'home'}, driver: 'person');
      await _settle();
      expect(host.announced, ['first']);
      host.state('jade', {'home': false, 'place': null}, driver: 'person');
      await _settle();
      expect(host.announced, ['first'], reason: 'asha is still home');
      host.state('asha', {'home': false, 'place': null}, driver: 'person');
      await _settle();
      expect(host.announced, ['first', 'last']);
    });

    test('everyone away and anyone home as conditions', () async {
      household({'jade': true, 'asha': false});
      engine.load([
        _flow(
          'away',
          'manual',
          {},
          title: 'away',
          condition: {'type': 'people', 'is': 'all_away'},
        ),
        _flow(
          'home',
          'manual',
          {},
          title: 'home',
          condition: {'type': 'people', 'is': 'anyone_home'},
        ),
      ]);
      await _settle();
      await engine.run('away');
      await engine.run('home');
      expect(host.announced, ['home']);
      engine.deviceStates['jade'] = {'home': false, 'place': null};
      await engine.run('away');
      expect(host.announced, ['home', 'away']);
    });
  });

  group('aligned times', () {
    test('every hour at :05 and every 15 min in a window', () {
      expect(
        nextAlignedTime(
          DateTime(2026, 11, 12, 10, 7),
          seconds: 3600,
          offsetSeconds: 300,
        ),
        DateTime(2026, 11, 12, 11, 5),
      );
      final window = ['09:00', '18:00'];
      expect(
        nextAlignedTime(
          DateTime(2026, 11, 12, 7, 0),
          seconds: 900,
          between: window,
        ),
        DateTime(2026, 11, 12, 9, 0),
      );
      expect(
        nextAlignedTime(
          DateTime(2026, 11, 12, 9, 1),
          seconds: 900,
          between: window,
        ),
        DateTime(2026, 11, 12, 9, 15),
      );
      expect(
        nextAlignedTime(
          DateTime(2026, 11, 12, 17, 45),
          seconds: 900,
          between: window,
        ),
        DateTime(2026, 11, 13, 9, 0),
        reason: 'the end is not inside',
      );
    });

    test('a window across midnight', () {
      expect(
        nextAlignedTime(
          DateTime(2026, 11, 12, 0, 40),
          seconds: 3600,
          between: ['22:00', '02:00'],
        ),
        DateTime(2026, 11, 12, 1, 0),
      );
      expect(
        nextAlignedTime(
          DateTime(2026, 11, 12, 2, 0),
          seconds: 3600,
          between: ['22:00', '02:00'],
        ),
        DateTime(2026, 11, 12, 22, 0),
      );
    });

    test('words', () {
      expect(alignedWords(3600, 300, null), 'at :05');
      expect(alignedWords(900, 300, null), 'at :05, :20, :35 and :50');
      expect(alignedWords(900, 0, ['09:00', '18:00']), 'from 09:00 to 18:00');
    });
  });

  group('engine start', () {
    test('fires once, when the engine starts running automations', () async {
      engine.load([_flow('boot', 'engine_started', {})]);
      await _settle();
      expect(host.announced, isEmpty, reason: 'loading alone is not a start');
      engine.startTimers();
      await _settle();
      engine
        ..stopTimers()
        ..startTimers();
      await _settle();
      expect(host.announced, ['ran']);
    });
  });

  group('skips', () {
    test('a condition that says no, with the part that said it', () async {
      engine.deviceStates['door'] = {'open': false};
      engine.deviceStates['lamp'] = {'state': true};
      engine.load([
        _flow(
          'door',
          'on',
          {
            'thing': 'door',
            'key': 'open',
            'change': {'to': true},
          },
          condition: {
            'type': 'all_of',
            'rules': [
              {'type': 'time_window', 'start': '00:00', 'end': '23:59'},
              {
                'type': 'compare',
                'left': {'state': 'lamp.state'},
                'op': '==',
                'right': {'literal': false},
              },
            ],
          },
        ),
      ]);
      host.state('door', {'open': true});
      await _settle(20);
      final skip = engine.skips.of('door').single;
      expect(skip.kind, SkipKind.condition);
      expect(skip.triggerLabel, 'the door opens');
      expect((skip.stop!['rule'] as Map)['type'], 'compare');
      expect(skip.stop!['actual'], true);
    });

    test('the cooldown and a single run already going', () async {
      engine.deviceStates['door'] = {'open': false};
      engine.load([
        _flow(
          'door',
          'on',
          {'thing': 'door', 'key': 'open'},
          extra: {'cooldownSeconds': 60},
        ),
      ]);
      host.state('door', {'open': true});
      await _settle(20);
      host.state('door', {'open': false});
      await _settle(20);
      expect(host.announced, ['ran']);
      expect(engine.skips.of('door').map((s) => s.kind), [SkipKind.cooldown]);
    });

    test('an automation that is off, from the host', () async {
      engine.deviceStates['door'] = {'open': false};
      host.idle = [
        (
          _flow('door', 'on', {
            'thing': 'door',
            'key': 'open',
            'change': {'to': true},
          }),
          SkipKind.off,
        ),
      ];
      engine.load(const []);
      await _settle();
      host.state('door', {'open': true});
      await _settle();
      expect(engine.skips.of('door').single.kind, SkipKind.off);
      expect(host.announced, isEmpty);
    });

    test('keeps the last 20', () {
      final log = SkipLog();
      for (var i = 0; i < 25; i++) {
        log.add(
          SkipEntry(
            at: DateTime(2026, 1, 1, 0, i),
            flowId: 'a',
            trigger: 't',
            triggerLabel: null,
            kind: SkipKind.running,
          ),
        );
      }
      expect(log.of('a'), hasLength(20));
      expect(log.of('a').first.at.minute, 24);
    });
  });

  group('try as if', () {
    test('a made-up event for each kind of trigger', () {
      expect(ruleTriggerNodeId(2), 'when_2');
      expect(
        asIfMessage({
          'on': 'door.open',
          'change': {'to': true},
          'for': 300000,
        }),
        allOf(
          containsPair('value', true),
          containsPair('previous', false),
          containsPair('heldMs', 300000),
          containsPair('thing', 'door'),
        ),
      );
      expect(
        asIfMessage({
          'on': 'room.temp',
          'crosses': {'below': 18},
        })['value'],
        17,
      );
      expect(
        asIfMessage({
          'on': 'phone.app_opened',
          'event': true,
          'match': {'package': 'com.x'},
        })['payload'],
        {'package': 'com.x'},
      );
      expect(asIfMessage({'time': '18:00'}), contains('scheduled'));
    });
  });
}
