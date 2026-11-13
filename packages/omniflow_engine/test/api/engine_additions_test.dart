@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import '../storage/storage_test.dart' show v4Schema;
import 'things_test.dart' show until;

/// A light with no wire under it: the engine's optimistic state becomes its
/// state, so a step can be checked by reading it back.
const _testLight = {
  'schemaVersion': 1,
  'id': 'test_light',
  'name': 'Test light',
  'category': 'light',
  'transport': {'type': 'virtual'},
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'command': {'set': 'power', 'value': '{{value}}'},
      'stateJsonPath': r'$.power',
    },
    {
      'id': 'brightness',
      'type': 'level',
      'label': 'Brightness',
      'params': {
        'value': {'type': 'number', 'min': 0, 'max': 100, 'unit': '%'},
      },
      'command': {'set': 'brightness', 'value': '{{value}}'},
      'stateJsonPath': r'$.brightness',
    },
    {
      'id': 'temp',
      'type': 'sensor',
      'label': 'Temperature',
      'stateJsonPath': r'$.temp',
    },
  ],
};

/// A switch at a loopback port nothing listens on, so every command fails
/// at once with the connection refused.
const _brokenSwitch = {
  'schemaVersion': 1,
  'id': 'broken_switch',
  'name': 'Broken switch',
  'category': 'switch',
  'transport': {'type': 'http', 'port': 9},
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'command': {
        'method': 'POST',
        'path': '/power',
        'body': {'on': '{{value}}'},
      },
      'stateJsonPath': r'$.on',
    },
  ],
};

void main() {
  late Directory home;
  late OmniEngine engine;
  late List<Map<String, Object?>> events;
  late StreamSubscription<Map<String, Object?>> sub;

  Future<Map<String, Object?>> ok(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command -> $result');
    return result;
  }

  Future<Map<String, Object?>> fails(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isFalse, reason: '$command -> $result');
    return Map<String, Object?>.from(result['error'] as Map);
  }

  Future<Map<String, Object?>> device(String id) async =>
      Map<String, Object?>.from(
        (await ok('device.get', {'id': id}))['device'] as Map,
      );

  Future<Map<String, Object?>> stateOf(String id) async =>
      Map<String, Object?>.from((await device(id))['state'] as Map);

  Future<Map<String, Object?>> saveRule(
    Map<String, Object?> rule, {
    bool trusted = true,
  }) =>
      ok('automation.save', {'form': 'rule', 'spec': rule, 'trusted': trusted});

  Future<Map<String, Object?>> automation(String id) async =>
      ((await ok('automation.list', {}))['automations'] as List)
          .cast<Map<String, Object?>>()
          .singleWhere((a) => a['id'] == id);

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_additions');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      discoveryTargets: () async => [InternetAddress.loopbackIPv4],
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
    events = [];
    sub = engine.events.listen(events.add);
    await ok('driver.register', {'manifest': _testLight});
    await ok('device.add', {
      'id': 'lamp',
      'name': 'Desk lamp',
      'driver': 'test_light',
      'room': 'Living room',
    });
    await ok('device.add', {
      'id': 'fan',
      'name': 'Fan',
      'driver': 'test_light',
      'room': 'study',
    });
    await ok('device.add', {
      'id': 'room',
      'name': 'Room sensor',
      'driver': 'test_light',
    });
    await ok('device.add', {'id': 'jade', 'name': 'Jade', 'driver': 'person'});
  });

  tearDown(() async {
    await sub.cancel();
    await engine.close();
    await home.delete(recursive: true);
  });

  group('rooms', () {
    test('a room name on device.add becomes a room record the device keeps '
        'by id', () async {
      final rooms = (await ok('room.list', {}))['rooms'] as List;
      expect(rooms, [
        {
          'id': 'living_room',
          'name': 'Living room',
          'order': 0,
          'deviceCount': 1,
        },
        {'id': 'study', 'name': 'study', 'order': 1, 'deviceCount': 1},
      ]);
      final lamp = await device('lamp');
      expect(
        (lamp['roomId'], lamp['room'], lamp['favourite']),
        ('living_room', 'Living room', false),
      );
      await ok('device.add', {
        'id': 'bulb',
        'driver': 'test_light',
        'room': 'LIVING ROOM',
      });
      expect((await device('bulb'))['roomId'], 'living_room');
      final listed =
          (await ok('device.list', {'room': 'living room'}))['devices'] as List;
      expect([for (final d in listed.cast<Map>()) d['id']], ['bulb', 'lamp']);
      final byId =
          (await ok('device.list', {'room': 'study'}))['devices'] as List;
      expect([for (final d in byId.cast<Map>()) d['id']], ['fan']);
    });

    test('save renames and adds, order moves, remove leaves the devices '
        'with no room', () async {
      final renamed = await ok('room.save', {'id': 'study', 'name': 'Study'});
      expect(renamed['room'], {
        'id': 'study',
        'name': 'Study',
        'order': 1,
        'deviceCount': 1,
      });
      expect((await device('fan'))['room'], 'Study');
      final added = await ok('room.save', {'name': 'Kitchen'});
      expect(added['room'], containsPair('id', 'kitchen'));
      expect(added['room'], containsPair('order', 2));
      expect((await fails('room.save', {'name': 'kitchen'}))['type'], 'exists');

      final ordered = await ok('room.order', {
        'ids': ['kitchen', 'study'],
      });
      expect(
        [for (final r in (ordered['rooms'] as List).cast<Map>()) r['id']],
        ['kitchen', 'study', 'living_room'],
      );
      expect(
        (await fails('room.order', {
          'ids': ['attic'],
        }))['type'],
        'not_found',
      );

      final removed = await ok('room.remove', {'id': 'study'});
      expect(removed, containsPair('devices', ['fan']));
      final fan = await device('fan');
      expect(fan.containsKey('roomId'), isFalse);
      expect(
        [
          for (final r
              in ((await ok('room.list', {}))['rooms'] as List).cast<Map>())
            r['id'],
        ],
        ['kitchen', 'living_room'],
      );
    });
  });

  test('device.organize changes only the keys it is given, and adding a '
      'device again keeps its star and place', () async {
    final starred = await ok('device.organize', {
      'id': 'lamp',
      'favourite': true,
      'order': 3,
    });
    expect(
      (
        (starred['device'] as Map)['favourite'],
        (starred['device'] as Map)['order'],
        (starred['device'] as Map)['name'],
        (starred['device'] as Map)['roomId'],
      ),
      (true, 3, 'Desk lamp', 'living_room'),
    );
    final moved = await ok('device.organize', {
      'id': 'lamp',
      'name': 'Reading lamp',
      'room': 'Bedroom',
    });
    expect((moved['device'] as Map)['roomId'], 'bedroom');
    expect((moved['device'] as Map)['favourite'], isTrue);
    expect(events.any((e) => e['event'] == 'device.stateChanged'), isTrue);

    await ok('device.organize', {'id': 'lamp', 'room': null, 'order': null});
    final out = await device('lamp');
    expect(out.containsKey('roomId') || out.containsKey('order'), isFalse);
    expect(out['name'], 'Reading lamp');

    await ok('device.organize', {'id': 'lamp', 'order': 1, 'room': 'study'});
    await ok('device.add', {
      'id': 'lamp',
      'driver': 'test_light',
      'replace': true,
    });
    final again = await device('lamp');
    expect(
      (again['favourite'], again['order'], again['roomId']),
      (true, 1, 'study'),
    );
    expect(
      (await fails('device.organize', {
        'id': 'lamp',
        'favourite': 'yes',
      }))['type'],
      'invalid',
    );
    expect(
      (await fails('device.organize', {
        'id': 'nope',
        'favourite': true,
      }))['type'],
      'not_found',
    );
  });

  test('device.history keeps each change with who made it, newest first, '
      'and goes with the device', () async {
    await ok('device.invoke', {
      'id': 'lamp',
      'capability': 'power',
      'params': {'value': true},
    });
    await engine.devices.mergeState('lamp', {'temp': 21});
    await saveRule({
      'id': 'dim_it',
      'name': 'Dim it',
      'when': ['manual'],
      'then': ['lamp.brightness=40'],
    });
    await ok('automation.run', {'id': 'dim_it'});
    // A save with nothing changed is not a change.
    await engine.devices.mergeState('lamp', {'temp': 21});

    final all = (await ok('device.history', {'id': 'lamp'}))['entries'] as List;
    expect(
      [for (final e in all.cast<Map>()) (e['key'], e['value'], e['by'])],
      [
        ('brightness', 40, 'dim_it'),
        ('temp', 21, null),
        ('power', true, 'user'),
      ],
    );
    expect(DateTime.parse((all.first as Map)['at'] as String).isUtc, isTrue);

    final power =
        (await ok('device.history', {'id': 'lamp', 'key': 'power'}))['entries']
            as List;
    expect(power, hasLength(1));
    final one =
        (await ok('device.history', {'id': 'lamp', 'limit': 1}))['entries']
            as List;
    expect((one.single as Map)['key'], 'brightness');
    final later =
        (await ok('device.history', {
              'id': 'lamp',
              'since': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 1))
                  .toIso8601String(),
            }))['entries']
            as List;
    expect(later, isEmpty);
    expect(
      (await fails('device.history', {'id': 'lamp', 'limit': 0}))['type'],
      'invalid',
    );

    await ok('device.remove', {'id': 'lamp'});
    await ok('device.add', {'id': 'lamp', 'driver': 'test_light'});
    expect((await ok('device.history', {'id': 'lamp'}))['entries'], isEmpty);
  });

  group('scenes', () {
    test('a scene saves as an automation, lists, runs its actions together '
        'and removes', () async {
      final saved = await ok('scene.save', {
        'name': 'Movie night',
        'icon': 'movie',
        'actions': [
          'lamp.brightness=20',
          {
            'do': 'fan.power',
            'params': {'value': true},
          },
        ],
        'trusted': true,
      });
      expect(
        (saved['id'], saved['source'], saved['approved']),
        ('movie_night', 'scene', true),
      );
      final scenes = (await ok('scene.list', {}))['scenes'] as List;
      final scene = scenes.single as Map;
      expect(scene['icon'], 'movie');
      expect(scene['actions'], [
        {
          'do': 'lamp.brightness',
          'params': {'value': 20},
        },
        {
          'do': 'fan.power',
          'params': {'value': true},
        },
      ]);
      expect(scene['sentence'], [
        {'kind': 'then', 'text': 'Desk lamp brightness 20%'},
        {'kind': 'text', 'text': 'and'},
        {'kind': 'then', 'text': 'Fan on'},
      ]);

      final run = await ok('scene.run', {'id': 'movie_night'});
      expect(((run['runs'] as List).single as Map)['outcome'], 'completed');
      expect((await stateOf('lamp'))['brightness'], 20);
      expect((await stateOf('fan'))['power'], isTrue);
      final listed = await automation('movie_night');
      expect(listed['source'], 'scene');
      expect((listed['lastRun'] as Map)['ok'], isTrue);
      expect(listed['devices'], ['fan', 'lamp']);

      final got = await ok('automation.get', {'id': 'movie_night'});
      expect((got['spec'] as Map)['name'], 'Movie night');

      final second = await ok('scene.save', {
        'name': 'Movie night',
        'actions': ['lamp.power=false'],
        'trusted': true,
      });
      expect(second['id'], 'movie_night_2');

      await saveRule({
        'id': 'a_rule',
        'name': 'A rule',
        'when': ['manual'],
        'then': ['lamp.power=true'],
      });
      expect((await fails('scene.run', {'id': 'a_rule'}))['type'], 'invalid');
      expect(
        (await fails('scene.save', {
          'id': 'a_rule',
          'name': 'Clash',
          'actions': ['lamp.power=true'],
        }))['type'],
        'exists',
      );
      expect(
        await ok('scene.remove', {'id': 'movie_night'}),
        containsPair('removed', true),
      );
      expect((await ok('scene.list', {}))['scenes'], hasLength(1));
    });

    test('scene issues name the action, and an untrusted save over the '
        "user's scene waits for approval", () async {
      final error = await fails('scene.save', {
        'name': 'Bad',
        'actions': ['lamp.power=true', 'lamp.nope=1'],
      });
      expect(error['type'], 'invalid');
      expect([
        for (final i in (error['issues'] as List).cast<Map>()) i['path'],
      ], everyElement(startsWith('actions[1]')));
      expect(
        (await fails('scene.save', {'name': 'Empty', 'actions': []}))['issues'],
        [
          {'path': 'actions', 'message': 'needs at least one action'},
        ],
      );

      await ok('scene.save', {
        'id': 'evening',
        'name': 'Evening',
        'actions': ['lamp.power=true'],
        'trusted': true,
      });
      final agent = await ok('scene.save', {
        'id': 'evening',
        'name': 'Evening',
        'actions': ['lamp.power=false'],
      });
      expect(agent['approved'], isFalse);
      final listed = await automation('evening');
      expect((listed['needsApproval'], listed['needsYou']), (true, true));
      expect(
        (await ok('automation.list', {'needsYou': true}))['automations'],
        hasLength(1),
      );
    });
  });

  group('automation.list', () {
    test('reads each automation as a sentence with its things and last run, '
        'and filters by device, tag and needs you', () async {
      await ok('tag.save', {
        'id': 'front_door',
        'name': 'Front door',
        'uid': '04A22B1C',
      });
      await saveRule({
        'id': 'arrive_home',
        'name': 'Arrive home',
        'when': [
          {
            'on': 'jade.home',
            'change': {'to': true},
          },
        ],
        'onlyIf': [
          {
            'between': ['18:00', '23:30'],
          },
        ],
        'then': ['lamp.power=true', 'wait:3s', 'fan.brightness=70'],
      });
      await saveRule({
        'id': 'door_tag',
        'name': 'Door tag',
        'when': ['nfc:front_door'],
        'then': ['toggle:lamp.power'],
      });
      await ok('link.create', {
        'from': 'room.temp',
        'to': 'fan.power',
        'mode': 'threshold',
        'above': 28,
        'set': true,
      });

      final arrive = await automation('arrive_home');
      expect(arrive['sentence'], [
        {'kind': 'when', 'text': 'When I get home'},
        {'kind': 'if', 'text': 'between 18:00 and 23:30'},
        {'kind': 'text', 'text': '→'},
        {'kind': 'then', 'text': 'Desk lamp on'},
        {'kind': 'text', 'text': 'then'},
        {'kind': 'then', 'text': 'wait 3 s'},
        {'kind': 'text', 'text': 'then'},
        {'kind': 'then', 'text': 'Fan brightness 70%'},
      ]);
      expect(arrive['devices'], ['fan', 'jade', 'lamp']);
      expect(arrive['controls'], ['fan', 'lamp']);
      expect(
        (arrive['enabled'], arrive['approved'], arrive['needsApproval']),
        (true, true, false),
      );
      expect(arrive.containsKey('lastRun'), isFalse);

      expect((await automation('door_tag'))['sentence'], [
        {'kind': 'when', 'text': 'When Front door is scanned'},
        {'kind': 'text', 'text': '→'},
        {'kind': 'then', 'text': 'toggle Desk lamp'},
      ]);
      final link =
          ((await ok('automation.list', {'source': 'link'}))['automations']
                      as List)
                  .single
              as Map;
      expect(link['sentence'], [
        {'kind': 'when', 'text': 'When Room sensor temperature goes above 28'},
        {'kind': 'text', 'text': '→'},
        {'kind': 'then', 'text': 'Fan on'},
      ]);

      List<Object?> ids(Map<String, Object?> result) => [
        for (final a in (result['automations'] as List).cast<Map>()) a['id'],
      ];
      expect(ids(await ok('automation.list', {'device': 'jade'})), [
        'arrive_home',
      ]);
      expect(ids(await ok('automation.list', {'tag': 'front_door'})), [
        'door_tag',
      ]);
      expect(ids(await ok('automation.list', {'needsYou': true})), isEmpty);

      await ok('automation.run', {'id': 'door_tag'});
      final ran = (await automation('door_tag'))['lastRun'] as Map;
      expect((ran['ok'], ran['steps']), (true, 1));
      expect(DateTime.tryParse(ran['at'] as String), isNotNull);
    });
  });

  test('a failed step is logged and the rest still run, unless the rule '
      'sets stopOnError', () async {
    await ok('driver.register', {'manifest': _brokenSwitch});
    await ok('device.add', {
      'id': 'plug',
      'driver': 'broken_switch',
      'host': '127.0.0.1',
    });
    await saveRule({
      'id': 'carry_on',
      'name': 'Carry on',
      'when': ['manual'],
      'then': ['lamp.power=true', 'plug.power=true', 'fan.power=true'],
    });
    final run =
        ((await ok('automation.run', {'id': 'carry_on'}))['runs'] as List)
                .single
            as Map;
    expect(run['outcome'], 'failed');
    expect((await stateOf('lamp'))['power'], isTrue);
    expect((await stateOf('fan'))['power'], isTrue);
    final failed = (run['nodes'] as List).cast<Map>().singleWhere(
      (n) => n['error'] != null,
    );
    expect(failed['node'], 'then_1');
    final last = (await automation('carry_on'))['lastRun'] as Map;
    expect((last['ok'], last['steps']), (false, 3));
    expect(last['error'], isA<String>());
    expect(
      (await ok('automation.list', {'needsYou': true}))['automations'],
      hasLength(1),
    );

    await ok('device.invoke', {
      'id': 'fan',
      'capability': 'power',
      'params': {'value': false},
    });
    await saveRule({
      'id': 'stop_at_once',
      'name': 'Stop at once',
      'when': ['manual'],
      'then': ['plug.power=true', 'fan.power=true'],
      'stopOnError': true,
    });
    final stopped =
        ((await ok('automation.run', {'id': 'stop_at_once'}))['runs'] as List)
                .single
            as Map;
    expect(stopped['outcome'], 'failed');
    expect((await stateOf('fan'))['power'], isFalse);
    expect(
      ((await ok('automation.get', {'id': 'stop_at_once'}))['spec']
          as Map)['stopOnError'],
      isTrue,
    );
  });

  test('keep holds a value while its conditions hold, puts it back when '
      'changed, and releases it once when they stop', () async {
    await saveRule({
      'id': 'cool_down',
      'name': 'Cool down',
      'then': [
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
    });
    final listed = await automation('cool_down');
    expect(listed['sentence'], [
      {'kind': 'then', 'text': 'Keep Fan on'},
      {'kind': 'if', 'text': 'while Room sensor temperature is above 28'},
    ]);
    final flow =
        (await ok('automation.get', {'id': 'cool_down'}))['flow'] as Map;
    expect(flow['mode'], 'parallel');

    Future<void> setTemp(num t) =>
        engine.devices.mergeState('room', {'temp': t});
    Future<Object?> fan() async => (await stateOf('fan'))['power'];

    await setTemp(30);
    await until(() async => await fan() == true);

    await ok('device.invoke', {
      'id': 'fan',
      'capability': 'power',
      'params': {'value': false},
    });
    await until(() async => await fan() == true);

    await setTemp(25);
    await until(() async => await fan() == false);

    await ok('device.invoke', {
      'id': 'fan',
      'capability': 'power',
      'params': {'value': true},
    });
    await setTemp(24);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      await fan(),
      isTrue,
      reason: 'nothing was held, so nothing releases',
    );

    final history =
        (await ok('device.history', {'id': 'fan', 'key': 'power'}))['entries']
            as List;
    expect(
      [for (final e in history.cast<Map>()) (e['value'], e['by'])],
      [
        (true, 'user'),
        (false, 'cool_down'),
        (true, 'cool_down'),
        (false, 'user'),
        (true, 'cool_down'),
      ],
    );
  });

  test('a TV picked as a switch in a template wakes and sleeps', () async {
    await ok('device.add', {
      'id': 'tv',
      'name': 'TV',
      'driver': 'android_tv_adb',
      'host': '192.168.1.60',
    });
    Future<List<Object?>> stepsOf(String id, List<String> things) async {
      final filled =
          ((await ok('automation.templates', {
                        'id': id,
                        'values': {
                          if (id != 'bedtime') 'person': 'jade',
                          'things': things,
                        },
                      }))['templates']
                      as List)
                  .single
              as Map;
      return (filled['spec'] as Map)['then'] as List;
    }

    final arrive = await stepsOf('arrive_home', ['tv.power', 'lamp.power']);
    expect(arrive, [
      {'do': 'tv.wake'},
      {
        'do': 'lamp.power',
        'params': {'value': true},
      },
    ]);
    expect(await stepsOf('leave_home_all_off', ['tv.power']), [
      {'do': 'tv.sleep'},
    ]);
    expect((await stepsOf('bedtime', ['tv.wake'])).first, {'do': 'tv.sleep'});
    await saveRule({
      'id': 'tv_home',
      'name': 'TV home',
      'when': [
        {
          'on': 'jade.home',
          'change': {'to': true},
        },
      ],
      'then': arrive,
    });
  });

  test('templates list the starting points and fill into a rule that '
      'saves', () async {
    final all = (await ok('automation.templates', {}))['templates'] as List;
    expect(
      [for (final t in all.cast<Map>()) t['id']],
      [
        'arrive_home',
        'leave_home_all_off',
        'motion_light',
        'tag_toggle',
        'bedtime',
        'ask_before_tv',
        'bluetooth_connected',
        'web_value_notify',
      ],
    );
    final filled =
        ((await ok('automation.templates', {
                      'id': 'arrive_home',
                      'values': {
                        'person': 'jade',
                        'things': ['lamp.power', 'fan.power'],
                      },
                    }))['templates']
                    as List)
                .single
            as Map;
    expect(filled['spec'], {
      'name': 'Arrive home',
      'when': [
        {
          'on': 'jade.home',
          'change': {'to': true},
        },
      ],
      'then': [
        {
          'do': 'lamp.power',
          'params': {'value': true},
        },
        {
          'do': 'fan.power',
          'params': {'value': true},
        },
      ],
    });
    await saveRule(Map<String, Object?>.from(filled['spec'] as Map));

    final motion =
        ((await ok('automation.templates', {
                      'id': 'motion_light',
                      'values': {'motion': 'room.temp', 'light': 'lamp.power'},
                    }))['templates']
                    as List)
                .single
            as Map;
    expect(((motion['spec'] as Map)['then'] as List)[1], {'wait': 120000});
    expect(
      (await fails('automation.templates', {
        'id': 'bedtime',
        'values': <String, Object?>{},
      }))['message'],
      'needs things',
    );
    expect(
      (await fails('automation.templates', {'id': 'nope'}))['type'],
      'not_found',
    );
  });

  test('the person says what last decided home, and since when', () async {
    final state = (await ok('presence.set', {'home': true}))['state'] as Map;
    expect((state['home'], state['homeSource']), (true, 'manual'));
    expect(DateTime.parse(state['homeSince'] as String).isUtc, isTrue);
    expect((await fails('presence.set', {'home': 'yes'}))['type'], 'invalid');
    expect(
      (await fails('presence.set', {'home': true, 'person': 'lamp'}))['type'],
      'not_found',
    );
  });

  test('an engine opened on a version 4 database lists its rooms, and its '
      'rules carry on after a failed step', () async {
    final old = await Directory.systemTemp.createTemp('omni_v4_engine');
    addTearDown(() => old.delete(recursive: true));
    final rule = normalizeRule({
      'id': 'evening',
      'name': 'Evening',
      'when': ['manual'],
      'then': ['lamp.power=true', 'wait:1s'],
    });
    final strict = {...rule, 'id': 'strict', 'stopOnError': true};
    final db = sqlite3.open('${old.path}/omniflow.sqlite');
    for (final statement in v4Schema) {
      db.execute(statement);
    }
    db.execute(
      'INSERT INTO devices (id, name, driver_id, host, room) '
      "VALUES ('lamp', 'Lamp', 'philips_wiz_udp', '127.0.0.1', 'Study')",
    );
    for (final r in [rule, strict]) {
      final flow = {...compileRule(r).flow}..remove('onError');
      db.execute(
        'INSERT INTO flows (id, flow_json, enabled, approved, trusted, '
        "source, spec_json, updated_at) VALUES (?, ?, 1, 0, 0, 'rule', ?, 0)",
        [r['id'], jsonEncode(flow), jsonEncode(r)],
      );
    }
    db.execute('PRAGMA user_version = 4');
    db.close();

    final reopened = await OmniEngine.open(
      home: old,
      secrets: InMemorySecretStore(),
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
    addTearDown(reopened.close);
    final rooms = await reopened.handle('room.list', {});
    expect(rooms['rooms'], [
      {'id': 'study', 'name': 'Study', 'order': 0, 'deviceCount': 1},
    ]);
    final lamp =
        (await reopened.handle('device.get', {'id': 'lamp'}))['device'] as Map;
    expect((lamp['roomId'], lamp['room']), ('study', 'Study'));
    final evening = await reopened.handle('automation.get', {'id': 'evening'});
    expect((evening['flow'] as Map)['onError'], 'continue');
    expect(evening['approved'], isFalse, reason: 'approval stays as it was');
    final kept = await reopened.handle('automation.get', {'id': 'strict'});
    expect((kept['flow'] as Map).containsKey('onError'), isFalse);
  });
}
