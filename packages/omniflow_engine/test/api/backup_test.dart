@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import '../support/fake_wiz_bulb.dart';

const _host = {
  'schemaVersion': 1,
  'id': 'test_host',
  'name': 'Host',
  'category': 'computer',
  'transport': {'type': 'exec', 'host': 'local'},
  'capabilities': [
    {
      'id': 'say',
      'type': 'action',
      'label': 'Say',
      'command': {
        'argv': ['/usr/bin/true'],
      },
    },
  ],
};

/// A made-up local key, so the test can look for it in the export.
const _plugKey = 'fixture-local-key-0123456789';

Future<OmniEngine> _open(Directory home, SecretStore secrets) =>
    OmniEngine.open(
      home: home,
      secrets: secrets,
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );

void main() {
  late Directory homeA;
  late Directory homeB;
  late OmniEngine a;
  late OmniEngine b;

  Future<Map<String, Object?>> ok(
    OmniEngine engine,
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final r = await engine.handle(command, args);
    expect(r['ok'], isTrue, reason: '$command: $r');
    return r;
  }

  setUp(() async {
    homeA = await Directory.systemTemp.createTemp('omni_backup_a');
    homeB = await Directory.systemTemp.createTemp('omni_backup_b');
    a = await _open(homeA, InMemorySecretStore());
    b = await _open(homeB, InMemorySecretStore());

    await ok(a, 'driver.register', {'manifest': _host});
    await ok(a, 'room.save', {'name': 'Living room'});
    await ok(a, 'device.add', {
      'id': 'plug',
      'name': 'Kettle plug',
      'driver': 'tuya_plug',
      'host': '192.168.1.50',
      'room': 'living_room',
      'settings': {'devId': 'bf0123456789abcdef'},
    });
    await ok(a, 'secret.set', {
      'deviceId': 'plug',
      'key': 'localKey',
      'value': _plugKey,
    });
    await ok(a, 'device.add', {
      'id': 'mac',
      'name': 'Mac',
      'driver': 'test_host',
      'host': 'local',
    });
    await ok(a, 'device.add', {
      'id': 'jade',
      'name': 'Jade',
      'driver': 'person',
    });
    await ok(a, 'zone.save', {
      'zone': {
        'id': 'home',
        'name': 'Home',
        'wifi': {
          'ssids': ['HomeNet'],
          'awayAfterMs': 300000,
        },
      },
    });
    await ok(a, 'tag.save', {
      'id': 'front_door',
      'name': 'Front door',
      'uid': '04:A2:2B:1C',
    });
    await ok(a, 'var.set', {'name': 'Mood', 'value': 'calm'});
    await ok(a, 'home.location.set', {
      'latitude': 19.076,
      'longitude': 72.8777,
    });
    await ok(a, 'automation.save', {
      'form': 'rule',
      'trusted': true,
      'spec': {
        'name': 'Kettle at sunrise',
        'when': [
          {'sun': 'sunrise', 'offset': -15},
        ],
        'then': ['plug.power=true'],
      },
    });
    await ok(a, 'automation.save', {
      'form': 'rule',
      'trusted': true,
      'spec': {
        'name': 'Host step',
        'when': ['manual'],
        'then': ['mac.say'],
      },
    });
  });

  tearDown(() async {
    await a.close();
    await b.close();
    await homeA.delete(recursive: true);
    await homeB.delete(recursive: true);
  });

  Future<Map<String, Object?>> exported() async =>
      (await ok(a, 'config.export'))['backup'] as Map<String, Object?>;

  List<Object?> ids(Map<String, Object?> r, String key) => [
    for (final item in r[key] as List) (item as Map)['id'],
  ];

  test('a backup restores the same home into a fresh engine', () async {
    final backup = await exported();
    final imported = await ok(b, 'config.import', {'backup': backup});
    expect(imported['applied'], isTrue);
    expect((imported['add'] as Map)['things'], hasLength(5));

    for (final command in ['device.list', 'room.list', 'zone.list']) {
      final key = switch (command) {
        'device.list' => 'devices',
        'room.list' => 'rooms',
        _ => 'zones',
      };
      final from = await ok(a, command);
      final to = await ok(b, command);
      expect(ids(to, key), ids(from, key), reason: command);
    }
    final place = ((await ok(b, 'zone.list'))['zones'] as List).single as Map;
    expect((place['wifi'] as Map)['awayAfterMs'], 300000);
    final plug = (await ok(b, 'device.get', {'id': 'plug'}))['device'] as Map;
    expect(plug['name'], 'Kettle plug');
    expect(plug['room'], 'Living room');
    expect(((await ok(b, 'tag.list'))['tags'] as List), hasLength(1));
    expect(((await ok(b, 'var.list'))['variables'] as Map)['Mood'], 'calm');
    expect((await ok(b, 'home.location'))['location'], {
      'latitude': 19.076,
      'longitude': 72.8777,
    });

    final rules = {
      for (final r in (await ok(b, 'automation.list'))['automations'] as List)
        (r as Map)['id']: r,
    };
    expect(rules.keys, containsAll(['kettle_at_sunrise', 'host_step']));
    final rule = await ok(b, 'automation.get', {'id': 'kettle_at_sunrise'});
    final original = await ok(a, 'automation.get', {'id': 'kettle_at_sunrise'});
    expect(rule['spec'], original['spec']);

    final asked = (imported['needsSecrets'] as List).single as Map;
    expect(asked['id'], 'plug');
    expect(asked['name'], 'Kettle plug');
    expect(asked['secrets'], ['localKey']);
    expect(asked['labels'], ['Local key']);
    expect(asked['pair'], isNull);
  });

  test('no secret value is in the export, and none is taken in', () async {
    final backup = await exported();
    final text = jsonEncode(backup);
    expect(text, isNot(contains(_plugKey)));
    expect(text, isNot(contains('localKey')));

    final things = [
      for (final t in backup['things'] as List)
        if ((t as Map)['id'] == 'plug')
          {
            ...t,
            'settings': {...t['settings'] as Map, 'localKey': _plugKey},
          }
        else
          t,
    ];
    final r = await b.handle('config.import', {
      'backup': {...backup, 'things': things},
    });
    expect((r['error'] as Map)['type'], 'invalid');
    final issues = (r['error'] as Map)['issues'] as List;
    expect(
      issues.map((i) => (i as Map)['path']),
      contains(matches(RegExp(r'^things\[\d+\]\.settings\.localKey$'))),
    );
    expect('$r', isNot(contains(_plugKey)));
  });

  test('an invalid backup changes nothing, in merge or replace', () async {
    final backup = await exported();
    await ok(b, 'room.save', {'name': 'Study'});
    final broken = {
      ...backup,
      'automations': [
        ...backup['automations'] as List,
        {
          'id': 'ghost',
          'source': 'graph',
          'flow': {
            'schemaVersion': 1,
            'id': 'ghost',
            'name': 'Ghost',
            'nodes': [
              {'id': 'go', 'type': 'manual', 'config': {}},
              {
                'id': 'do',
                'type': 'device_capability',
                'config': {'deviceId': 'nobody', 'capabilityId': 'power'},
              },
            ],
            'edges': [
              {
                'id': 'e',
                'from': {'node': 'go', 'port': 'out'},
                'to': {'node': 'do', 'port': 'in'},
              },
            ],
          },
        },
      ],
    };
    for (final mode in ['merge', 'replace']) {
      final r = await b.handle('config.import', {
        'backup': broken,
        'mode': mode,
      });
      expect((r['error'] as Map)['type'], 'invalid', reason: mode);
      final paths = [
        for (final i in (r['error'] as Map)['issues'] as List)
          (i as Map)['path'],
      ];
      expect(paths.first, startsWith('automations[2].flow'), reason: '$r');
      expect(((await ok(b, 'device.list'))['devices'] as List), isEmpty);
      expect(ids(await ok(b, 'room.list'), 'rooms'), ['study']);
      expect((await ok(b, 'automation.list'))['automations'], isEmpty);
      expect((await ok(b, 'home.location'))['location'], isNull);
      final drivers = (await ok(b, 'driver.list'))['drivers'] as List;
      expect(drivers.any((d) => (d as Map)['id'] == 'test_host'), isFalse);
    }

    final wrong = await b.handle('config.import', {
      'backup': {'schema': 'something.else', 'version': 1},
    });
    expect(
      ((wrong['error'] as Map)['issues'] as List).first,
      containsPair('path', 'schema'),
    );
  });

  test('a high-risk automation comes back waiting for approval', () async {
    final before = {
      for (final r in (await ok(a, 'automation.list'))['automations'] as List)
        (r as Map)['id']: r['approved'],
    };
    expect(before['host_step'], isTrue);

    final imported = await ok(b, 'config.import', {'backup': await exported()});
    expect(imported['waitForApproval'], ['host_step']);
    final after = {
      for (final r in (await ok(b, 'automation.list'))['automations'] as List)
        (r as Map)['id']: r['approved'],
    };
    expect(after['host_step'], isFalse);
    expect(after['kettle_at_sunrise'], isTrue);
    final run = await b.handle('automation.run', {'id': 'host_step'});
    expect(run['ok'], isFalse);
  });

  test('a dry run says what would change and changes nothing', () async {
    final backup = await exported();
    final r = await ok(b, 'config.import', {'backup': backup, 'dryRun': true});
    expect(r['applied'], isFalse);
    expect((r['add'] as Map)['things'], contains('plug'));
    expect(r['location'], 'add');
    expect(((await ok(b, 'device.list'))['devices'] as List), isEmpty);
    expect((await ok(b, 'home.location'))['location'], isNull);
  });

  test('merge keeps what the backup lacks, replace removes it', () async {
    final backup = await exported();
    await ok(b, 'room.save', {'name': 'Study'});
    await ok(b, 'var.set', {'name': 'Extra', 'value': 1});

    final merged = await ok(b, 'config.import', {'backup': backup});
    expect(merged['remove'], isNull);
    expect(ids(await ok(b, 'room.list'), 'rooms'), contains('study'));

    final again = await ok(b, 'config.import', {'backup': backup});
    expect((again['skip'] as Map)['things'], hasLength(5));
    expect(again['add'], isEmpty);

    final replaced = await ok(b, 'config.import', {
      'backup': backup,
      'mode': 'replace',
    });
    expect((replaced['remove'] as Map)['rooms'], ['study']);
    expect((replaced['remove'] as Map)['variables'], ['Extra']);
    expect(ids(await ok(b, 'room.list'), 'rooms'), ['living_room']);
  });
  group('a WiZ bulb', () {
    final bulbs = <FakeWizBulb>[];
    tearDown(() {
      for (final bulb in bulbs) {
        bulb.close();
      }
      bulbs.clear();
    });

    Future<void> addBulb({String? key}) async {
      final bulb = await FakeWizBulb.start(
        module: 'ESP25_SHRGB_01',
        range: const [2200, 6500],
        key: key,
      );
      bulbs.add(bulb);
      await ok(a, 'device.add', {
        'id': 'wiz',
        'name': 'Philips WiZ',
        'driver': 'philips_wiz_udp',
        'host': bulb.host,
        'port': bulb.port,
        'room': 'living_room',
      });
      await a.devices.refreshState('wiz');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    Map<String, Object?> thingIn(Map<String, Object?> backup, String id) =>
        (backup['things'] as List).cast<Map<String, Object?>>().singleWhere(
          (t) => t['id'] == id,
        );

    List<Object?> asked(Map<String, Object?> imported) => [
      for (final s in imported['needsSecrets'] as List) (s as Map)['id'],
    ];

    test('comes back with what it said it is, and its optional key is not '
        'asked for, while a required key still is', () async {
      await addBulb();
      final backup = await exported();
      expect(backup['skipped'], isNull);
      final settings = thingIn(backup, 'wiz')['settings'] as Map;
      expect(settings['bulb'], containsPair('module', 'ESP25_SHRGB_01'));

      final imported = await ok(b, 'config.import', {'backup': backup});
      expect((imported['add'] as Map)['things'], contains('wiz'));
      final wiz = (await ok(b, 'device.get', {'id': 'wiz'}))['device'] as Map;
      expect(wiz['room'], 'Living room');
      expect((wiz['settings'] as Map)['bulb'], settings['bulb']);
      expect(asked(imported), isNot(contains('wiz')));
      expect(asked(imported), contains('plug'));
    });

    test(
      'that refused unsigned commands asks for its key after a restore',
      () async {
        const key = '00112233445566778899aabbccddeeff';
        await addBulb(key: key);
        final refused = await a.handle('device.invoke', {
          'id': 'wiz',
          'capability': 'power',
          'params': {'value': true},
        });
        expect((refused['error'] as Map)['type'], 'needs_user');
        final backup = await exported();
        expect(jsonEncode(backup), isNot(contains(key)));
        expect((thingIn(backup, 'wiz')['settings'] as Map)['setupNeeds'], [
          'signingKey',
        ]);

        final imported = await ok(b, 'config.import', {'backup': backup});
        expect(
          (imported['needsSecrets'] as List).firstWhere(
            (s) => (s as Map)['id'] == 'wiz',
          ),
          {
            'id': 'wiz',
            'name': 'Philips WiZ',
            'secrets': ['signingKey'],
            'labels': ['WiZ home key'],
            'category': 'lighting',
          },
        );
      },
    );

    test('with a setting its driver no longer lists still comes back, '
        'without it', () async {
      await addBulb();
      final backup = await exported();
      final things = [
        for (final t in backup['things'] as List)
          (t as Map)['id'] == 'wiz'
              ? {
                  ...t,
                  'settings': {
                    ...t['settings'] as Map,
                    'retired': 1,
                    'setupNeeds': ['nothing'],
                  },
                }
              : t,
      ];
      final imported = await ok(b, 'config.import', {
        'backup': {...backup, 'things': things},
      });
      expect((imported['add'] as Map)['things'], contains('wiz'));
      final wiz = (await ok(b, 'device.get', {'id': 'wiz'}))['device'] as Map;
      expect(wiz['settings'], isNot(contains('retired')));
      expect(wiz['settings'], isNot(contains('setupNeeds')));
      expect(asked(imported), isNot(contains('wiz')));
    });
    test('comes back with an automation that uses it, and only a TV paired '
        'over ADB asks to pair again', () async {
      await addBulb();
      await ok(a, 'device.add', {
        'id': 'den_tv',
        'name': 'Den TV',
        'driver': 'android_tv_adb',
        'host': '192.168.1.60',
      });
      await ok(a, 'automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Lights out',
          'when': [
            {'time': '23:00'},
          ],
          'then': ['wiz.power=false'],
        },
      });
      final imported = await ok(b, 'config.import', {
        'backup': await exported(),
      });
      expect(asked(imported), isNot(contains('wiz')));
      final tv = (imported['needsSecrets'] as List).firstWhere(
        (s) => (s as Map)['id'] == 'den_tv',
      ) as Map;
      expect(tv['pair'], isTrue);
      expect(tv['pairing'], 'adb');
      expect(tv['secrets'], isNull);
      final rule = {
        for (final r in (await ok(b, 'automation.list'))['automations'] as List)
          (r as Map)['id']: r,
      }['lights_out'];
      expect(rule, isNotNull);
      expect((rule as Map)['enabled'], isTrue);
    });
  });
}
