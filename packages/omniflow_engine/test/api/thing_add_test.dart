import 'package:multicast_dns/multicast_dns.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/discovery/board_hellos.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import 'thing_add_harness.dart';

const haInstance = 'Home._home-assistant._tcp.local';
const hueInstance = 'Philips Hue - 0A0B0C._hue._tcp.local';

final records = <ResourceRecord>[
  ptr('_home-assistant._tcp', haInstance),
  srv(haInstance, 'homeassistant.local', 8123),
  txt(haInstance, ['uuid=ha0001']),
  a('homeassistant.local', '192.168.1.5'),
  ptr('_hue._tcp', hueInstance),
  srv(hueInstance, 'ecb5fa0a0b0c.local', 443),
  txt(hueInstance, ['bridgeid=ecb5fafffe0a0b0c']),
  a('ecb5fa0a0b0c.local', '192.168.1.20'),
];

Map<String, Object?> boardFound(String node, String host) => {
  'event': 'board.found',
  'node': node,
  'host': host,
  'add': {
    'id': node.replaceAll('-', '_'),
    'name': node,
    'driver': 'omniflow_board',
    'host': host,
    'stableId': node,
  },
};

void main() {
  late AddHarness engine;

  setUp(() async {
    engine = await AddHarness.open(
      mdns: MdnsDiscovery(client: () => FakeMdns(records)),
      hellos: RecentHellos(),
    );
  });

  tearDown(() => engine.shutdown());

  Future<Map<String, Object?>> ok(String command, Map<String, Object?> args) =>
      engine.ok(command, args);

  Future<Map<String, Object?>> find() => ok('thing.add', {
    'windowMs': 200,
    'methods': ['mdns', 'hello'],
  });

  Map<String, Object?> firstCandidate(
    Map<String, Object?> found,
    String driver,
  ) =>
      (((found['groups'] as List).firstWhere((g) => g['driver'] == driver)
                      as Map)['candidates']
                  as List)
              .first
          as Map<String, Object?>;

  Map<String, Object?> nextOf(Map<String, Object?> reply) =>
      reply['next'] as Map<String, Object?>;

  test('thing.add with nothing to add by finds, groups and lists manual '
      'drivers', () async {
    engine.add.observe(boardFound('hall-board', '192.168.1.60'));
    final found = await find();
    final drivers = [
      for (final g in found['groups'] as List) (g as Map)['driver'],
    ];
    expect(drivers, containsAll(['home_assistant_entity', 'omniflow_board']));
    expect(found['methods'], ['mdns', 'hello']);
    expect(firstCandidate(found, 'omniflow_board')['method'], 'hello');
    expect(firstCandidate(found, 'omniflow_board')['id'], 'hall_board');
    final manual = {
      for (final m in found['manual'] as List) (m as Map)['driver']: m,
    };
    expect(manual.keys, containsAll(['lg_webos_tv', 'mqtt_switch', 'phone']));
    expect(manual['phone'], containsPair('virtual', true));
    expect(manual.keys, isNot(contains('philips_hue_light')));
  });

  test('thing.add rejects an unknown method, driver or window', () async {
    for (final args in [
      {
        'methods': ['ble'],
      },
      {
        'drivers': ['nope'],
      },
      {'windowMs': 5},
      {'methods': 'mdns'},
    ]) {
      final result = await engine.handle('thing.add', args);
      expect(result['ok'], isFalse, reason: '$args');
    }
  });

  test(
    'a Home Assistant find walks secret, configure, done, and resumes',
    () async {
      final found = await find();
      final added = await ok('thing.add', {
        'candidate': firstCandidate(found, 'home_assistant_entity'),
        'id': 'kitchen',
      });
      expect(added['id'], 'kitchen');
      expect((added['device'] as Map)['host'], '192.168.1.5');
      expect((added['device'] as Map)['stableId'], 'ha0001');
      final secret = nextOf(added);
      expect(secret['step'], 'secret');
      expect((secret['keys'] as List).single, containsPair('key', 'token'));
      expect(secret['instruction'], contains('long-lived access token'));

      // Resume: the step is recomputed from what is stored, not remembered.
      expect(nextOf(await ok('thing.next', {'id': 'kitchen'})), secret);

      await ok('secret.set', {
        'deviceId': 'kitchen',
        'key': 'token',
        'value': 'fixture-token',
      });
      final configure = nextOf(await ok('thing.next', {'id': 'kitchen'}));
      expect(configure['step'], 'configure');
      expect(
        [for (final k in configure['keys'] as List) (k as Map)['key']],
        ['entityId', 'domain'],
      );

      final half = await ok('thing.configure', {
        'id': 'kitchen',
        'settings': {'entityId': 'light.kitchen'},
      });
      expect(nextOf(half)['keys'], [
        {
          'step': 'configure',
          'key': 'domain',
          'label': isA<String>(),
          'help': isA<String>(),
        },
      ]);
      final done = await ok('thing.configure', {
        'id': 'kitchen',
        'settings': {'domain': 'light'},
      });
      expect(nextOf(done)['step'], 'done');
      expect((done['device'] as Map)['settings'], {
        'entityId': 'light.kitchen',
        'domain': 'light',
      });
      expect('$done', isNot(contains('fixture-token')));
    },
  );

  test('a find that is already a device is refused unless replaced', () async {
    final found = await find();
    final hue = firstCandidate(found, 'philips_hue_light');
    final first = await ok('thing.add', {'candidate': hue});
    expect(first['id'], 'philips_hue_0a0b0c');
    expect(nextOf(first)['step'], 'pair');
    expect(nextOf(first)['method'], 'hue_bridge');
    expect((first['device'] as Map).containsKey('port'), isFalse);

    final again = await engine.handle('thing.add', {'candidate': hue});
    expect((again['error'] as Map)['type'], 'exists');
    expect(
      '${(again['error'] as Map)['message']}',
      contains('philips_hue_0a0b0c'),
    );

    final refound = await find();
    expect(
      firstCandidate(refound, 'philips_hue_light')['knownAs'],
      'philips_hue_0a0b0c',
    );
    final replaced = await ok('thing.add', {
      'candidate': hue,
      'id': 'philips_hue_0a0b0c',
      'replace': true,
    });
    expect(replaced['id'], 'philips_hue_0a0b0c');
  });

  test('a Hue light is paired by its username, then configured', () async {
    final added = await ok('thing.add', {
      'driver': 'philips_hue_light',
      'host': '192.168.1.20',
      'id': 'hall',
    });
    expect(nextOf(added)['step'], 'pair');
    expect(nextOf(added)['instruction'], contains('link button'));
    await engine.secrets.write(deviceSecretKey('hall', 'username'), 'u');
    final next = nextOf(await ok('thing.next', {'id': 'hall'}));
    expect(next['step'], 'configure');
    expect((next['keys'] as List).single, containsPair('key', 'lightId'));
  });

  test('a Tuya find has its devId and asks for the local key', () async {
    final added = await ok('thing.add', {
      'candidate': {
        'driver': 'tuya_plug',
        'host': '192.168.1.30',
        'stableId': 'fixturegwid0001',
        'name': 'Kettle plug',
      },
    });
    expect(added['id'], 'kettle_plug');
    expect((added['device'] as Map)['settings'], {'devId': 'fixturegwid0001'});
    final next = nextOf(added);
    expect(next['step'], 'secret');
    expect(next['remaining'], ['secret:localKey', 'configure:version?']);
  });

  test('a board from a hello is configured with its pins', () async {
    engine.add.observe(boardFound('desk-board', '192.0.2.10'));
    final found = await find();
    final added = await ok('thing.add', {
      'candidate': firstCandidate(found, 'omniflow_board'),
      'provision': false,
    });
    expect(added['id'], 'desk_board');
    final next = nextOf(added);
    expect(next['step'], 'configure');
    expect(next['instruction'], contains('board.describe'));

    final bad = await engine.handle('thing.configure', {
      'id': 'desk_board',
      'settings': {
        'pins': {
          'Relay': {'pin': 4, 'mode': 'out'},
        },
      },
      'provision': false,
    });
    expect(bad['ok'], isFalse);

    final done = await ok('thing.configure', {
      'id': 'desk_board',
      'settings': {
        'pins': {
          'relay': {'pin': 4, 'mode': 'out'},
        },
      },
      'provision': false,
    });
    expect(nextOf(done)['step'], 'done');
    final caps = (await ok('device.get', {'id': 'desk_board'}))['device'];
    expect(((caps as Map)['settings'] as Map)['pins'], isA<Map>());
  });

  test('thing.configure takes only plain settings of the driver', () async {
    await ok('thing.add', {
      'driver': 'home_assistant_sensor',
      'host': '192.168.1.5',
      'id': 'temp',
    });
    for (final settings in [
      {'token': 'leak'},
      {'nope': 1},
      <String, Object?>{},
    ]) {
      final result = await engine.handle('thing.configure', {
        'id': 'temp',
        'settings': settings,
      });
      expect(result['ok'], isFalse, reason: '$settings');
    }
    expect(await engine.secrets.read(deviceSecretKey('temp', 'token')), isNull);
    final missing = await engine.handle('thing.configure', {
      'id': 'nobody',
      'settings': {'entityId': 'x'},
    });
    expect((missing['error'] as Map)['type'], 'not_found');
  });

  test('thing.configure with null removes a setting', () async {
    await ok('thing.add', {
      'driver': 'mqtt_sensor',
      'host': '127.0.0.1',
      'id': 'probe',
      'settings': {'stateTopic': 'a/b', 'username': 'u'},
    });
    final removed = await ok('thing.configure', {
      'id': 'probe',
      'settings': {'username': null},
    });
    expect((removed['device'] as Map)['settings'], {'stateTopic': 'a/b'});
    expect(nextOf(removed)['step'], 'done');
    expect(
      [for (final o in nextOf(removed)['optional'] as List) (o as Map)['key']],
      ['username', 'password'],
    );
  });

  test('an ADB TV is paired once thing.next hears it was, until it is '
      'removed', () async {
    final added = await ok('thing.add', {
      'driver': 'android_tv_adb',
      'host': '192.0.2.5',
      'id': 'den_tv',
    });
    expect(nextOf(added)['method'], 'adb');
    expect(nextOf(await ok('thing.next', {'id': 'den_tv'}))['step'], 'pair');
    final paired = await ok('thing.next', {'id': 'den_tv', 'paired': true});
    expect(nextOf(paired)['step'], 'done');
    expect(nextOf(paired)['optional'], [
      {
        'step': 'configure',
        'key': 'mac',
        'label': isA<String>(),
        'help': contains('wake it'),
        'optional': true,
      },
    ]);
    await ok('device.remove', {'id': 'den_tv'});
    await ok('thing.add', {
      'driver': 'android_tv_adb',
      'host': '192.0.2.5',
      'id': 'den_tv',
    });
    expect(nextOf(await ok('thing.next', {'id': 'den_tv'}))['step'], 'pair');
  });

  test(
    'paired: true does not stand in for a key a TV pairing stores',
    () async {
      await ok('thing.add', {
        'driver': 'lg_webos_tv',
        'host': '192.0.2.6',
        'id': 'lounge',
      });
      final next = await ok('thing.next', {'id': 'lounge', 'paired': true});
      expect(nextOf(next)['step'], 'pair');
      final bad = await engine.handle('thing.next', {
        'id': 'lounge',
        'paired': 'yes',
      });
      expect(bad['ok'], isFalse);
    },
  );

  test('a virtual thing needs nothing', () async {
    final added = await ok('thing.add', {'driver': 'phone', 'id': 'my_phone'});
    expect(nextOf(added), {'step': 'done', 'instruction': 'my_phone is ready'});
  });

  test('device.add returns next too', () async {
    final added = await ok('device.add', {
      'id': 'heater',
      'driver': 'shelly_plus_switch',
      'host': '192.0.2.7',
    });
    expect(nextOf(added)['step'], 'done');
  });

  test('a candidate id that is taken gets a number', () async {
    await ok('device.add', {
      'id': 'kettle_plug',
      'driver': 'shelly_plus_switch',
      'host': '192.0.2.8',
    });
    final added = await ok('thing.add', {
      'candidate': {
        'driver': 'tuya_plug',
        'host': '192.168.1.31',
        'name': 'Kettle plug',
      },
    });
    expect(added['id'], 'kettle_plug_2');
    expect(nextOf(added)['step'], 'configure');
  });

  test(
    'a find with no stable id that is known by address is refused',
    () async {
      final refused = await engine.handle('thing.add', {
        'candidate': {
          'driver': 'shelly_plus_switch',
          'host': '192.0.2.9',
          'knownAs': 'porch',
          'add': {'driver': 'shelly_plus_switch', 'host': '192.0.2.9'},
        },
      });
      expect((refused['error'] as Map)['type'], 'exists');
      final odd = await engine.handle('thing.add', {
        'candidate': {
          'driver': 'shelly_plus_switch',
          'host': '192.0.2.9',
          'knownAs': 7,
        },
      });
      expect(
        odd['ok'],
        isTrue,
        reason: 'a knownAs that is not an id is ignored',
      );
    },
  );

  test('an add by address with no stable id is refused when it is a device '
      'already, but one host can serve many entities', () async {
    final bulb = {'driver': 'philips_wiz_udp', 'host': '192.0.2.20'};
    final first = await ok('thing.add', bulb);
    for (final again in [
      bulb,
      {'candidate': bulb},
      {
        'candidate': {'add': bulb},
      },
    ]) {
      final refused = await engine.handle('thing.add', again);
      expect((refused['error'] as Map?)?['type'], 'exists', reason: '$again');
      expect('${(refused['error'] as Map)['message']}', contains(first['id']));
    }
    await ok('thing.add', {...bulb, 'id': first['id'], 'replace': true});
    await ok('thing.add', {...bulb, 'host': '192.0.2.21'});

    Map<String, Object?> entity(String id) => {
      'driver': 'home_assistant_entity',
      'host': '192.0.2.5',
      'settings': {'entityId': id},
    };
    await ok('thing.add', entity('light.kitchen'));
    await ok('thing.add', entity('light.hall'));
    final twice = await engine.handle('thing.add', entity('light.hall'));
    expect((twice['error'] as Map?)?['type'], 'exists');
    await ok('thing.add', {'driver': 'person', 'name': 'Jade'});
    await ok('thing.add', {'driver': 'person', 'name': 'Sam'});
  });

  group('several devices behind one hub', () {
    Future<Map<String, Object?>> refused(Map<String, Object?> args) async {
      final reply = await engine.handle('thing.add', args);
      expect(reply['ok'], isFalse, reason: '$args -> $reply');
      return Map<String, Object?>.from(reply['error'] as Map);
    }

    test('two Hue lights on one bridge are two things, and the same light '
        'twice is refused', () async {
      final hue = firstCandidate(await find(), 'philips_hue_light');
      expect(hue['stableId'], 'ecb5fafffe0a0b0c');
      await ok('thing.add', {
        'candidate': hue,
        'id': 'hall_light',
        'settings': {'lightId': '1'},
      });
      await ok('thing.add', {
        'candidate': hue,
        'id': 'desk_light',
        'settings': {'lightId': '2'},
      });
      final twice = await refused({
        'candidate': hue,
        'id': 'hall_again',
        'settings': {'lightId': 1},
      });
      expect(twice['type'], 'exists');
      expect('${twice['message']}', contains('hall_light'));

      final bare = firstCandidate(await find(), 'philips_hue_light');
      expect(
        bare,
        isNot(contains('knownAs')),
        reason: 'every light on the bridge names its light',
      );
      await ok('thing.add', {'candidate': bare, 'id': 'porch_light'});
      final unnamed = await refused({'candidate': bare, 'id': 'porch_again'});
      expect(unnamed['type'], 'exists');
      expect('${unnamed['message']}', contains('porch_light'));
      await ok('thing.configure', {
        'id': 'porch_light',
        'settings': {'lightId': '3'},
      });
      await ok('thing.add', {'candidate': bare, 'id': 'garden_light'});
    });

    test('two Home Assistant entities on one host are two things, and the '
        'same entity twice is refused', () async {
      final ha = firstCandidate(await find(), 'home_assistant_entity');
      Map<String, Object?> entity(String id, String entityId) => {
        'candidate': ha,
        'id': id,
        'settings': {'entityId': entityId},
      };
      await ok('thing.add', entity('kitchen', 'light.kitchen'));
      await ok('thing.add', entity('hall', 'light.hall'));
      final twice = await refused(entity('hall_again', 'light.hall'));
      expect(twice['type'], 'exists');
      expect('${twice['message']}', contains('hall'));

      final byHost = {
        'driver': 'home_assistant_entity',
        'host': '192.0.2.50',
        'knownAs': 'porch',
        'add': {'driver': 'home_assistant_entity', 'host': '192.0.2.50'},
      };
      await ok('thing.add', {
        'driver': 'home_assistant_entity',
        'host': '192.0.2.50',
        'id': 'porch',
        'settings': {'entityId': 'switch.porch'},
      });
      await ok('thing.add', {
        'candidate': byHost,
        'id': 'heater',
        'settings': {'entityId': 'switch.heater'},
      });
      final sameByHost = await refused({
        'candidate': byHost,
        'id': 'porch_again',
        'settings': {'entityId': 'switch.porch'},
      });
      expect(sameByHost['type'], 'exists');
      expect('${sameByHost['message']}', contains('porch'));
    });
  });
}
