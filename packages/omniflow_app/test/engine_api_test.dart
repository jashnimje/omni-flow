import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;
  late List<ApiFailure> failures;
  late EngineApi api;

  setUp(() {
    engine = FakeEngine();
    failures = [];
    api = EngineApi(engine, onFailure: failures.add);
  });

  test('rooms come back in their order', () async {
    engine.answers['room.list'] = {
      'ok': true,
      'rooms': [
        {'id': 'hall', 'name': 'Hall', 'order': 2, 'deviceCount': 1},
        {'id': 'living', 'name': 'Living room', 'order': 1, 'deviceCount': 4},
      ],
    };
    final rooms = (await api.rooms()).value!;
    expect([for (final r in rooms) r.id], ['living', 'hall']);
    expect(rooms.first.deviceCount, 4);
  });

  test('room and device organising send only the fields given', () async {
    await api.saveRoom(name: 'Study');
    await api.orderRooms(['living', 'hall']);
    await api.organizeDevice('desk_lamp', favourite: true, room: 'living');
    expect(engine.callsOf('room.save').single.$2, {'name': 'Study'});
    expect(engine.callsOf('room.order').single.$2, {
      'ids': ['living', 'hall'],
    });
    expect(engine.callsOf('device.organize').single.$2, {
      'id': 'desk_lamp',
      'room': 'living',
      'favourite': true,
    });
  });

  test('device rows read through DeviceView', () async {
    engine.devices = [
      {
        ...FakeEngine.lamp(state: const {'state': true, 'dimming': 80}),
        'roomId': 'living',
        'room': 'Living room',
        'favourite': true,
        'order': 3,
      },
    ];
    final lamp = (await api.devices()).value!.single;
    expect(engine.callsOf('device.list').single.$2, {'withCapabilities': true});
    expect(lamp.roomId, 'living');
    expect(lamp.favourite, isTrue);
    expect(lamp.order, 3);
    expect(lamp.hasPower, isTrue);
    expect(lamp.isOn, isTrue);
    expect(lamp.online, isTrue);
  });

  test(
    'history asks for a key and a start, and reads who changed it',
    () async {
      engine.answers['device.history'] = {
        'ok': true,
        'entries': [
          {
            'at': '2026-11-08T13:32:00Z',
            'key': 'state',
            'value': true,
            'by': 'arrive_home',
          },
          {
            'at': '2026-11-08T12:40:00Z',
            'key': 'state',
            'value': false,
            'by': 'user',
          },
        ],
      };
      final since = DateTime.utc(2026, 11, 7, 12);
      final entries = (await api.history(
        'desk_lamp',
        key: 'state',
        since: since,
      )).value!;
      expect(engine.callsOf('device.history').single.$2, {
        'id': 'desk_lamp',
        'key': 'state',
        'since': '2026-11-07T12:00:00.000Z',
      });
      expect(entries.first.by, 'arrive_home');
      expect(entries.last.byUser, isTrue);
    },
  );

  test('automations read their sentence, last run and devices', () async {
    engine.answers['automation.list'] = {
      'ok': true,
      'automations': [
        {
          'id': 'arrive',
          'name': 'Arrive home',
          'source': 'rule',
          'enabled': true,
          'approved': true,
          'needsApproval': false,
          'highRisk': false,
          'sentence': [
            {'kind': 'when', 'text': 'When I get home'},
            {'kind': 'if', 'text': 'after 6 pm'},
            {'kind': 'text', 'text': '→'},
            {'kind': 'then', 'text': 'TV on'},
          ],
          'lastRun': {
            'at': '2026-11-08T13:32:00Z',
            'ok': false,
            'steps': 3,
            'error': 'TV asleep',
          },
          'devices': ['tv', 'desk_lamp'],
        },
      ],
    };
    final a = (await api.automations(
      device: 'tv',
      needsYou: true,
    )).value!.single;
    expect(engine.callsOf('automation.list').single.$2, {
      'device': 'tv',
      'needsYou': true,
    });
    expect(
      [for (final p in a.sentence) p.kind],
      [
        SentenceKind.when,
        SentenceKind.onlyIf,
        SentenceKind.text,
        SentenceKind.then,
      ],
    );
    expect(a.lastRun!.ok, isFalse);
    expect(a.lastRun!.error, 'TV asleep');
    expect(a.devices, ['tv', 'desk_lamp']);
  });

  test('scenes save as their contract shape', () async {
    engine.answers['scene.save'] = {'ok': true, 'id': 'movie'};
    final id = await api.saveScene(
      const Scene(
        name: 'Movie',
        icon: 'movie',
        actions: [
          SceneAction('desk_lamp.brightness', {'value': 20}),
          SceneAction('hall_bulb.power'),
        ],
      ),
    );
    expect(id.value, 'movie');
    expect(engine.callsOf('scene.save').single.$2, {
      'name': 'Movie',
      'icon': 'movie',
      'actions': [
        {
          'do': 'desk_lamp.brightness',
          'params': {'value': 20},
        },
        {'do': 'hall_bulb.power'},
      ],
      'trusted': true,
    });
  });

  test('the run log reads each run and its failed step', () async {
    engine.answers['automation.log'] = {
      'ok': true,
      'runs': [
        {
          'run': 'r1',
          'flow': 'arrive',
          'trigger': 'home',
          'outcome': 'completed',
          'startedAt': '2026-11-08T13:32:00.000Z',
          'finishedAt': '2026-11-08T13:32:01.400Z',
          'nodes': [
            {'node': 'tv', 'type': 'device_capability', 'ms': 300},
            {'node': 'hall', 'type': 'device_capability', 'error': 'timed out'},
          ],
        },
      ],
    };
    final run = (await api.runLog(id: 'arrive', limit: 5)).value!.single;
    expect(engine.callsOf('automation.log').single.$2, {
      'id': 'arrive',
      'limit': 5,
    });
    expect(run.duration, const Duration(milliseconds: 1400));
    expect(run.ok, isFalse);
    expect(run.steps.last.error, 'timed out');
  });

  test('a failed call reports once and carries its rule paths', () async {
    engine.answers['automation.enable'] = {
      'ok': false,
      'error': {
        'type': 'invalid',
        'message': 'the rule is not valid',
        'issues': [
          {'path': 'then[2].do', 'message': 'no capability dim'},
          {'path': 'when[0]', 'message': 'no such tag'},
        ],
      },
    };
    final reply = await api.enableAutomation('arrive', true);
    expect(reply.ok, isFalse);
    expect(failures.single.message, 'The rule is not valid.');
    expect(reply.failure!.issuesAt('then[2]'), ['no capability dim']);
    expect(reply.failure!.issuesAt('then[1]'), isEmpty);
  });

  test('an engine that throws is a plain failure, not an exception', () async {
    engine.throwOn.add('scene.list');
    final reply = await api.scenes();
    expect(reply.failure!.type, 'unreachable');
    expect(failures, hasLength(1));
  });

  test('presence says where and what decided it', () {
    final p = Presence.of({
      'state': {
        'home': true,
        'homeSource': 'wifi',
        'homeSince': '2026-11-08T13:31:00Z',
      },
    });
    expect(p.home, isTrue);
    expect(p.source, PresenceSource.wifi);
    expect(p.since, DateTime.utc(2026, 11, 8, 13, 31).toLocal());
    expect(Presence.of(const {'state': {}}).source, PresenceSource.unknown);
  });

  test('the keep step and stop on error follow the contract', () {
    expect(
      RuleParts.keep('hall_bulb.power', false, [
        {'thing': 'jade.home', 'is': false},
      ]),
      {
        'keep': {
          'target': 'hall_bulb.power',
          'value': false,
          'while': [
            {'thing': 'jade.home', 'is': false},
          ],
        },
      },
    );
    final rule = {'name': 'Arrive', 'stopOnError': true};
    expect(RuleParts.stopOnError({'name': 'Arrive'}), rule);
    expect(RuleParts.stopOnError(rule, false), {'name': 'Arrive'});
  });

  test('templates read their spec', () async {
    engine.answers['automation.templates'] = {
      'ok': true,
      'templates': [
        {
          'id': 'arrive_home',
          'name': 'Arrive home',
          'description': 'Turn things on when you get home',
          'spec': {'when': []},
        },
      ],
    };
    final t = (await api.templates()).value!.single;
    expect(t.id, 'arrive_home');
    expect(t.spec, {'when': []});
  });
}
