@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/houses.dart';
import 'package:omniflow_engine/src/api/hub_phone_session.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

/// A light with no wire under it, so a command's state is its state.
const _light = {
  'schemaVersion': 1,
  'id': 'house_test_bulb',
  'name': 'Test bulb',
  'category': 'lighting',
  'transport': {'type': 'virtual'},
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'command': {'set': 'power', 'value': '{{value}}'},
      'stateJsonPath': r'$.power',
    },
  ],
};

void main() {
  late Directory home;
  late OmniEngine engine;
  final events = <Map<String, Object?>>[];
  StreamSubscription<Map<String, Object?>>? sub;

  Future<OmniEngine> open() => OmniEngine.open(
    home: home,
    secrets: InMemorySecretStore(),
    mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
  );

  Future<Map<String, Object?>> ok(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final r = await engine.handle(command, args);
    expect(r['ok'], isTrue, reason: '$command $args -> $r');
    return r;
  }

  Future<Map<String, Object?>> err(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final r = await engine.handle(command, args);
    expect(r['ok'], isFalse, reason: '$command $args -> $r');
    return Map<String, Object?>.from(r['error'] as Map);
  }

  List<Object?> ids(Map<String, Object?> r, String key) => [
    for (final e in r[key] as List) (e as Map)['id'],
  ];

  Future<void> twoHouses() async {
    await ok('house.rename', {'id': 'home', 'name': 'Mumbai'});
    await ok('house.add', {'name': 'Bangalore'});
    await ok('driver.register', {'manifest': _light});
    await ok('device.add', {
      'id': 'desk_lamp',
      'name': 'Desk lamp',
      'driver': 'house_test_bulb',
      'host': 'virtual',
      'house': 'bangalore',
    });
    await ok('device.add', {
      'id': 'hall_lamp',
      'name': 'Hall lamp',
      'driver': 'house_test_bulb',
      'host': 'virtual',
    });
  }

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_houses');
    engine = await open();
    events.clear();
    sub = engine.events.listen(events.add);
  });

  tearDown(() async {
    await sub?.cancel();
    await engine.close();
    await home.delete(recursive: true);
  });

  group('house commands', () {
    test('a new home starts with one house, Home', () async {
      final r = await ok('house.list');
      expect(r['houses'], [
        {
          'id': 'home',
          'name': 'Home',
          'order': 0,
          'things': 0,
          'automations': 0,
        },
      ]);
    });

    test('add, rename and remove, with plain refusals', () async {
      final added = await ok('house.add', {'name': 'Bangalore'});
      expect(added['house'], {
        'id': 'bangalore',
        'name': 'Bangalore',
        'order': 1,
      });
      expect(events.any((e) => e['event'] == housesChangedEvent), isTrue);
      expect((await err('house.add', {'name': 'bangalore'}))['type'], 'exists');
      await ok('house.rename', {'id': 'home', 'name': 'Mumbai'});
      expect(ids(await ok('house.list'), 'houses'), ['home', 'bangalore']);
      // A house is found by its name too.
      await ok('room.save', {'name': 'Study', 'house': 'Bangalore'});

      await ok('driver.register', {'manifest': _light});
      await ok('device.add', {
        'id': 'desk_lamp',
        'name': 'Desk lamp',
        'driver': 'house_test_bulb',
        'host': 'virtual',
        'house': 'bangalore',
      });
      final refused = await err('house.remove', {'id': 'bangalore'});
      expect(refused['message'], contains('Bangalore still has 1 thing'));
      await ok('device.organize', {'id': 'desk_lamp', 'moveTo': 'home'});
      expect(
        await ok('house.remove', {'id': 'bangalore'}),
        containsPair('removed', 'bangalore'),
      );
      // Its rooms went with it.
      expect(ids(await ok('room.list'), 'rooms'), isEmpty);
      final last = await err('house.remove', {'id': 'home'});
      expect(last['message'], contains('only house'));
      expect(
        (await err('device.list', {'house': 'nowhere'}))['type'],
        'not_found',
      );
    });
  });

  group('the house in view', () {
    test('lists keep to a house, and say each entry\'s house', () async {
      await twoHouses();
      await ok('device.add', {'id': 'me', 'driver': 'person', 'name': 'Me'});
      final bangalore = await ok('device.list', {'house': 'bangalore'});
      expect(ids(bangalore, 'devices'), ['desk_lamp', 'me']);
      final all = await ok('device.list');
      expect(ids(all, 'devices'), ['desk_lamp', 'hall_lamp', 'me']);
      final byId = {
        for (final d in all['devices'] as List) (d as Map)['id']: d['house'],
      };
      expect(byId, {'desk_lamp': 'bangalore', 'hall_lamp': 'home', 'me': null});

      await ok('room.save', {'name': 'Living', 'house': 'bangalore'});
      // Each house may have a room of the same name.
      await ok('room.save', {'name': 'Living'});
      final rooms = await ok('room.list', {'house': 'bangalore'});
      expect(
        [for (final r in rooms['rooms'] as List) (r as Map)['house']],
        ['bangalore'],
      );

      await ok('scene.save', {
        'name': 'Desk off',
        'actions': ['desk_lamp.power=false'],
        'trusted': true,
        'house': 'bangalore',
      });
      expect(ids(await ok('scene.list', {'house': 'bangalore'}), 'scenes'), [
        'desk_off',
      ]);
      expect(ids(await ok('scene.list', {'house': 'home'}), 'scenes'), isEmpty);
      expect(
        ids(await ok('automation.list', {'house': 'home'}), 'automations'),
        isEmpty,
      );
      await ok('var.set', {
        'name': 'guests',
        'value': true,
        'house': 'bangalore',
      });
      expect(
        ((await ok('var.list', {'house': 'home'}))['variables'] as Map)
            .containsKey('guests'),
        isFalse,
      );
      expect(
        ((await ok('var.list', {'house': 'bangalore'}))['variables']
            as Map)['guests'],
        isTrue,
      );
    });

    test('rule.parse and search read only names of the house', () async {
      await twoHouses();
      final parsed = await ok('rule.parse', {
        'text': 'at 7 pm turn on desk lamp',
        'house': 'home',
      });
      expect(parsed['spec'], isNull);
      final there = await ok('rule.parse', {
        'text': 'at 7 pm turn on desk lamp',
        'house': 'bangalore',
      });
      expect(there['spec'], isNotNull);
      final found = await ok('command.interpret', {
        'text': 'turn on desk lamp',
        'house': 'home',
      });
      expect('$found', isNot(contains('desk_lamp')));
    });
  });

  group('isolation', () {
    test(
      'a scene, rule or link naming another house\'s thing is refused',
      () async {
        await twoHouses();
        final scene = await err('scene.save', {
          'name': 'Mixed',
          'actions': ['desk_lamp.power=false'],
          'trusted': true,
          'house': 'home',
        });
        expect(
          scene['message'],
          startsWith('Desk lamp is in Bangalore, not Mumbai'),
        );
        final rule = await err('automation.save', {
          'form': 'rule',
          'spec': {
            'name': 'Hall follows desk',
            'when': [
              {
                'on': 'hall_lamp.power',
                'change': {'to': true},
              },
            ],
            'then': [
              {
                'do': 'desk_lamp.power',
                'params': {'value': true},
              },
            ],
          },
          'trusted': true,
        });
        expect(
          rule['message'],
          contains('Desk lamp is in Bangalore, not Mumbai'),
        );
        expect(ids(await ok('automation.list'), 'automations'), isEmpty);
      },
    );

    test(
      'moving a thing turns off the old house\'s automations that use it',
      () async {
        await twoHouses();
        await ok('automation.save', {
          'form': 'rule',
          'spec': {
            'name': 'Hall at night',
            'when': [
              {'time': '22:00'},
            ],
            'then': [
              {
                'do': 'hall_lamp.power',
                'params': {'value': true},
              },
            ],
          },
          'trusted': true,
        });
        events.clear();
        final moved = await ok('device.organize', {
          'id': 'hall_lamp',
          'moveTo': 'bangalore',
        });
        expect(moved['turnedOff'], ['hall_at_night']);
        expect((moved['device'] as Map)['house'], 'bangalore');
        final listed = (await ok('automation.list'))['automations'] as List;
        expect((listed.single as Map)['enabled'], isFalse);
        expect(
          events.where(
            (e) =>
                e['event'] == 'automation.changed' &&
                e['id'] == 'hall_at_night',
          ),
          isNotEmpty,
        );
        // An agent may not move a thing between houses.
        expect(
          agentRefusal('device.organize', {
            'id': 'x',
            'moveTo': 'home',
          }, AgentAccess.setup),
          contains('for the user only'),
        );
      },
    );
  });

  group('the view switched while something was open', () {
    Map<String, Object?> deskRule() => {
      'name': 'Desk at seven',
      'when': [
        {'time': '19:00'},
      ],
      'then': [
        {
          'do': 'desk_lamp.power',
          'params': {'value': true},
        },
      ],
    };

    test(
      'a re-save keeps the automation\'s house, and moveTo moves it',
      () async {
        await twoHouses();
        final saved = await ok('automation.save', {
          'form': 'rule',
          'spec': deskRule(),
          'trusted': true,
          'house': 'bangalore',
        });
        final id = saved['id'] as String;
        expect((await ok('automation.get', {'id': id}))['house'], 'bangalore');
        expect((await ok('flow.get', {'id': id}))['house'], 'bangalore');
        // The app arrived in Mumbai and re-saves the open rule with its view.
        await ok('automation.save', {
          'form': 'rule',
          'id': id,
          'spec': {...deskRule(), 'name': 'Desk at seven, renamed'},
          'trusted': true,
          'replace': true,
          'house': 'home',
        });
        expect((await ok('automation.get', {'id': id}))['house'], 'bangalore');
        expect(
          ids(
            await ok('automation.list', {'house': 'bangalore'}),
            'automations',
          ),
          [id],
        );
        // A move names the house, and the isolation check holds there.
        final refused = await err('automation.save', {
          'form': 'rule',
          'id': id,
          'spec': deskRule(),
          'trusted': true,
          'replace': true,
          'moveTo': 'home',
        });
        expect(refused['message'], contains('Desk lamp is in Bangalore'));
        await ok('automation.save', {
          'form': 'rule',
          'id': id,
          'spec': {
            ...deskRule(),
            'then': [
              {
                'do': 'hall_lamp.power',
                'params': {'value': true},
              },
            ],
          },
          'trusted': true,
          'replace': true,
          'moveTo': 'home',
        });
        expect((await ok('automation.get', {'id': id}))['house'], 'home');

        // A scene re-saved from the other view stays too.
        await ok('scene.save', {
          'id': 'desk_off',
          'name': 'Desk off',
          'actions': ['desk_lamp.power=false'],
          'trusted': true,
          'house': 'bangalore',
        });
        await ok('scene.save', {
          'id': 'desk_off',
          'name': 'Desk off',
          'actions': ['desk_lamp.power=false'],
          'trusted': true,
          'house': 'home',
        });
        expect(ids(await ok('scene.list', {'house': 'bangalore'}), 'scenes'), [
          'desk_off',
        ]);
      },
    );

    test('a thing changes house only through moveTo', () async {
      await twoHouses();
      await ok('device.organize', {
        'id': 'desk_lamp',
        'name': 'Desk light',
        'house': 'home',
      });
      expect(
        ((await ok('device.get', {'id': 'desk_lamp'}))['device']
            as Map)['house'],
        'bangalore',
      );
      await ok('device.organize', {'id': 'desk_lamp', 'moveTo': 'home'});
      expect(
        ((await ok('device.get', {'id': 'desk_lamp'}))['device']
            as Map)['house'],
        'home',
      );
    });
  });

  group('per-house settings', () {
    test('each house has its own mode, and rules see only theirs', () async {
      await twoHouses();
      await ok('automation.save', {
        'form': 'rule',
        'spec': {
          'name': 'Night desk',
          'when': [
            {
              'on': 'house_mode.changed',
              'event': true,
              'match': {'mode': 'night'},
            },
          ],
          'then': [
            {
              'do': 'desk_lamp.power',
              'params': {'value': true},
            },
          ],
        },
        'trusted': true,
        'house': 'bangalore',
      });
      await ok('home.mode.set', {'mode': 'night'});
      expect((await ok('home.mode', {'house': 'bangalore'}))['mode'], 'home');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      Future<Object?> desk() async =>
          ((await ok('device.get', {'id': 'desk_lamp'}))['device']
              as Map)['state'];
      expect((await desk() as Map)['power'], isNot(true));
      await ok('home.mode.set', {'mode': 'night', 'house': 'bangalore'});
      for (var i = 0; i < 50 && (await desk() as Map)['power'] != true; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect((await desk() as Map)['power'], isTrue);
      expect((await ok('home.mode'))['mode'], 'night');
    });

    test('a location keeps its place name per house, and a new one without a '
        'name clears it', () async {
      await twoHouses();
      final set = await ok('home.location.set', {
        'latitude': 12.97,
        'longitude': 77.59,
        'name': 'Bengaluru, India',
        'house': 'bangalore',
      });
      expect(set['name'], 'Bengaluru, India');
      expect(
        (await ok('home.location', {'house': 'bangalore'}))['name'],
        'Bengaluru, India',
      );
      expect((await ok('home.location')).containsKey('name'), isFalse);
      await ok('home.location.set', {
        'latitude': 12.9,
        'longitude': 77.6,
        'house': 'bangalore',
      });
      expect(
        (await ok('home.location', {'house': 'bangalore'})).containsKey('name'),
        isFalse,
      );
    });

    test('location, alerts, energy price and timers are per house', () async {
      await twoHouses();
      await ok('home.location.set', {'latitude': 19.07, 'longitude': 72.87});
      await ok('home.location.set', {
        'latitude': 12.97,
        'longitude': 77.59,
        'house': 'bangalore',
      });
      expect(
        ((await ok('home.location'))['location'] as Map)['latitude'],
        19.07,
      );
      expect(
        ((await ok('home.location', {'house': 'bangalore'}))['location']
            as Map)['latitude'],
        12.97,
      );
      await ok('alerts.set', {'offline': true, 'house': 'bangalore'});
      expect((await ok('alerts.get'))['offline'], isFalse);
      expect(
        (await ok('alerts.get', {'house': 'bangalore'}))['offline'],
        isTrue,
      );
      await ok('energy.price.set', {
        'perKwh': 8,
        'currency': 'Rs',
        'house': 'bangalore',
      });
      expect((await ok('energy.price'))['perKwh'], isNull);
      expect((await ok('energy.price', {'house': 'bangalore'}))['perKwh'], 8.0);

      await ok('timer.start', {'name': 'Tea', 'ms': 60000});
      await ok('timer.start', {
        'name': 'Tea',
        'ms': 120000,
        'house': 'bangalore',
      });
      expect((await ok('timer.list'))['timers'] as List, hasLength(2));
      final there =
          (await ok('timer.list', {'house': 'bangalore'}))['timers'] as List;
      expect((there.single as Map)['durationMs'], 120000);
      await ok('timer.cancel', {'name': 'Tea', 'house': 'bangalore'});
      expect(
        (await ok('timer.list', {'house': 'home'}))['timers'] as List,
        hasLength(1),
      );

      // They are still there after a restart.
      await engine.close();
      engine = await open();
      expect(
        ((await ok('home.location', {'house': 'bangalore'}))['location']
            as Map)['longitude'],
        77.59,
      );
      expect((await ok('energy.price', {'house': 'bangalore'}))['perKwh'], 8.0);
    });
  });

  group('each house\'s location, people and removed automations', () {
    test(
      'sun rules and the sun curve use their own house\'s location',
      () async {
        await twoHouses();
        await ok('home.location.set', {'latitude': 19.07, 'longitude': 72.87});
        Map<String, Object?> sunRule(String name, String lamp) => {
          'form': 'rule',
          'spec': {
            'name': name,
            'when': [
              {'sun': 'sunset'},
            ],
            'then': [
              {
                'do': '$lamp.power',
                'params': {'value': true},
              },
            ],
          },
          'trusted': true,
        };
        await ok('automation.save', {
          ...sunRule('Hall at sunset', 'hall_lamp'),
        });
        final refused = await err('automation.save', {
          ...sunRule('Desk at sunset', 'desk_lamp'),
          'house': 'bangalore',
        });
        expect('$refused', contains('home'));
        final curve = await err('sunlight.set', {
          'targets': ['desk_lamp'],
          'enabled': true,
          'house': 'bangalore',
        });
        expect(curve['message'], contains('needs to know where Bangalore is'));
        await ok('home.location.set', {
          'latitude': 12.97,
          'longitude': 77.59,
          'house': 'bangalore',
        });
        await ok('automation.save', {
          ...sunRule('Desk at sunset', 'desk_lamp'),
          'house': 'bangalore',
        });
      },
    );

    test('a removed automation comes back to its own house', () async {
      await twoHouses();
      await ok('scene.save', {
        'id': 'desk_off',
        'name': 'Desk off',
        'actions': ['desk_lamp.power=false'],
        'trusted': true,
        'house': 'bangalore',
      });
      await ok('scene.remove', {'id': 'desk_off', 'house': 'bangalore'});
      expect(
        ids(await ok('automation.removed', {'house': 'home'}), 'removed'),
        isEmpty,
      );
      expect(
        ids(await ok('automation.removed', {'house': 'bangalore'}), 'removed'),
        ['desk_off'],
      );
      // Put back from the Mumbai view, it goes to Bangalore.
      await ok('automation.unremove', {'id': 'desk_off', 'house': 'home'});
      expect(ids(await ok('scene.list', {'house': 'bangalore'}), 'scenes'), [
        'desk_off',
      ]);
    });

    test('away lighting counts only the people at that house', () async {
      await twoHouses();
      await ok('device.add', {
        'id': 'jade',
        'driver': 'person',
        'name': 'Jade',
      });
      await ok('presence.set', {'home': true});
      expect((await ok('awaylight.get'))['away'], isFalse);
      final bangalore = await ok('awaylight.get', {'house': 'bangalore'});
      expect((bangalore['away'], bangalore['reason']), (true, 'everyone_away'));
    });
  });

  test('arriving at a place of a house says so', () async {
    await twoHouses();
    await ok('device.add', {'id': 'jade', 'driver': 'person', 'name': 'Jade'});
    await ok('zone.save', {
      'zone': {
        'id': 'flat',
        'name': 'Flat',
        'wifi': {
          'ssids': ['FlatNet'],
          'awayAfterMs': 0,
        },
      },
      'house': 'bangalore',
    });
    await ok('phone.wifi', {'ssid': 'FlatNet'});
    for (
      var i = 0;
      i < 40 && !events.any((e) => e['event'] == houseArrivedEvent);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final arrived = events.firstWhere((e) => e['event'] == houseArrivedEvent);
    expect(arrived['house'], 'bangalore');
    expect(arrived['person'], 'jade');
  });

  test('a backup of one house restores into another house', () async {
    await twoHouses();
    await ok('room.save', {'name': 'Study', 'house': 'bangalore'});
    final one =
        (await ok('config.export', {'house': 'bangalore'}))['backup'] as Map;
    expect(one['house'], {'id': 'bangalore', 'name': 'Bangalore'});
    expect(
      [for (final t in one['things'] as List) (t as Map)['id']],
      ['desk_lamp'],
    );
    final all = (await ok('config.export'))['backup'] as Map;
    expect(
      [for (final h in all['houses'] as List) (h as Map)['id']],
      ['home', 'bangalore'],
    );
    final things = {
      for (final t in all['things'] as List) (t as Map)['id']: t['house'],
    };
    expect(things, {'desk_lamp': 'bangalore', 'hall_lamp': 'home'});

    await ok('house.add', {'name': 'Pune'});
    final restored = await ok('config.import', {
      'backup': {
        ...one,
        'things': [
          for (final t in one['things'] as List)
            {...t as Map, 'id': 'pune_lamp'},
        ],
        'rooms': const [],
      },
      'house': 'pune',
    });
    expect(restored['house'], 'pune');
    expect(ids(await ok('device.list', {'house': 'pune'}), 'devices'), [
      'pune_lamp',
    ]);
    // A replace into Pune leaves the other houses alone.
    await ok('config.import', {
      'backup': {...one, 'things': const [], 'rooms': const []},
      'house': 'pune',
      'mode': 'replace',
    });
    expect(ids(await ok('device.list', {'house': 'pune'}), 'devices'), isEmpty);
    expect(ids(await ok('device.list'), 'devices'), ['desk_lamp', 'hall_lamp']);
  });

  test('agent policy and the phone session name every house command', () {
    expect(agentReadCommands, contains('house.list'));
    expect(agentSetupCommands, containsAll(['house.add', 'house.rename']));
    expect(agentUserOnly.keys, contains('house.remove'));
    expect(phoneCommandRefusal('house.remove'), isNull);
    expect(phoneCommandRefusal('house.add'), isNull);
  });

  group('migration', () {
    test('a home made by 0.8.0 becomes house Home with nothing lost', () async {
      await sub?.cancel();
      await engine.close();
      final fixture = Directory('test/fixtures/pre_houses_home');
      await File('${fixture.path}/omniflow_0_8_0.sqlite3fixture')
          .copy('${home.path}/omniflow.sqlite');
      await File('${fixture.path}/home.json').copy('${home.path}/home.json');
      engine = await open();

      final houses = (await ok('house.list'))['houses'] as List;
      expect(houses, [
        {
          'id': 'home',
          'name': 'Home',
          'order': 0,
          'things': 3,
          'automations': 3,
          'presence': 'not_set_up',
        },
      ]);
      final devices = {
        for (final d in (await ok('device.list'))['devices'] as List)
          (d as Map)['id']: d['house'],
      };
      expect(devices, {
        'desk_lamp': 'home',
        'tv_plug': 'home',
        'office': 'home',
        'me': null,
        'phone': null,
      });
      expect(
        [
          for (final r in (await ok('room.list'))['rooms'] as List)
            (r as Map)['house'],
        ],
        ['home', 'home'],
      );
      expect(
        {
          for (final a
              in (await ok('automation.list', {'house': 'home'}))['automations']
                  as List)
            (a as Map)['id'],
        },
        {'movie_night', 'lamp_follows_tv', 'link_083f8a1bf4ce'},
      );
      expect(
        (await ok('var.list', {'house': 'home'}))['variables'],
        containsPair('guests', false),
      );
      // The settings stay the first house's.
      expect((await ok('home.mode', {'house': 'home'}))['mode'], 'night');
      expect(
        ((await ok('home.location'))['location'] as Map)['latitude'],
        19.07,
      );
      expect((await ok('alerts.get'))['offline'], isFalse);

      // Opening again changes nothing.
      await engine.close();
      engine = await open();
      expect((await ok('house.list'))['houses'], houses);
      final db = OmniDatabase.file(File('${home.path}/again.sqlite'));
      addTearDown(db.close);
      expect(await houseMigration(db), isTrue);
      expect(await houseMigration(db), isFalse);
    });
  });
}
