@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/rules_core_commands.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

/// A light with no wire under it.
const _lamp = {
  'schemaVersion': 1,
  'id': 'test_lamp',
  'name': 'Test lamp',
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

Map<String, Object?> _rule(String name, String lamp, bool on) => {
  'name': name,
  'when': [
    {'time': '18:00'},
  ],
  'then': [
    {
      'do': '$lamp.power',
      'params': {'value': on},
    },
  ],
};

void main() {
  late Directory home;
  late OmniEngine engine;
  late List<Map<String, Object?>> events;
  late StreamSubscription<Map<String, Object?>> sub;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_safety');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
    events = [];
    sub = engine.events.listen(events.add);
  });

  tearDown(() async {
    RulesCoreCommands.onPhone = () => Platform.isAndroid;
    await sub.cancel();
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command -> $result');
    return result;
  }

  Future<Map<String, Object?>> fails(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isFalse, reason: '$command -> $result');
    return Map<String, Object?>.from(result['error'] as Map);
  }

  Future<void> saveRule(Map<String, Object?> rule, {String? replacing}) =>
      ok('automation.save', {
        'form': 'rule',
        'spec': rule,
        'trusted': true,
        if (replacing != null) ...{'id': replacing, 'replace': true},
      });

  /// Lets the events already sent arrive.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  Future<int> versionsOf(String id) async =>
      ((await ok('automation.versions', {'id': id}))['versions'] as List)
          .length;

  Future<bool> enabled(String id) async =>
      (await ok('automation.get', {'id': id}))['enabled'] == true;

  List<String> changed() => [
    for (final e in events)
      if (e['event'] == 'automation.changed') '${e['command']} ${e['id']}',
  ];

  group('built-in thing ids', () {
    test('no device takes house_mode or timers, and a thing named after one '
        'gets another id', () async {
      for (final id in ['house_mode', 'timers']) {
        final error = await fails('device.add', {
          'id': id,
          'name': 'X',
          'driver': 'person',
        });
        expect(error['type'], 'invalid');
        expect(error['message'], contains('built-in thing'));
      }
      final added = await ok('thing.add', {
        'driver': 'person',
        'name': 'Timers',
      });
      expect(added['id'], 'timers_2');
      await ok('home.mode.set', {'mode': 'night'});
      expect((await ok('home.mode'))['mode'], 'night');
    });
  });

  group('versions', () {
    test('capturing over a scene keeps the one it replaces', () async {
      await ok('driver.register', {'manifest': _lamp});
      await ok('device.add', {
        'id': 'lamp',
        'name': 'Lamp',
        'driver': 'test_lamp',
      });
      await ok('device.invoke', {
        'id': 'lamp',
        'capability': 'power',
        'params': {'value': true},
      });
      await ok('scene.capture', {
        'name': 'Eve',
        'devices': ['lamp'],
      });
      await ok('device.invoke', {
        'id': 'lamp',
        'capability': 'power',
        'params': {'value': false},
      });
      await ok('scene.capture', {
        'name': 'Eve',
        'id': 'eve',
        'devices': ['lamp'],
      });
      expect(await versionsOf('eve'), 1);
    });

    test('two saves of one automation at once both keep a version', () async {
      await ok('driver.register', {'manifest': _lamp});
      await ok('device.add', {
        'id': 'lamp',
        'name': 'Lamp',
        'driver': 'test_lamp',
      });
      await saveRule(_rule('Night', 'lamp', true));
      await Future.wait([
        for (final on in [false, true, false])
          engine.handle('automation.save', {
            'form': 'rule',
            'id': 'night',
            'replace': true,
            'trusted': true,
            'spec': {
              ..._rule('Night', 'lamp', on),
              'then': [
                {
                  'do': 'lamp.power',
                  'params': {'value': on},
                },
                {'wait': on ? 1000 : 2000},
              ],
            },
          }),
      ]);
      expect(await versionsOf('night'), 3);
    });
  });

  group('recently removed', () {
    test('a removed automation is kept with its versions, a new one with '
        'its id starts with none, and it can be put back', () async {
      await ok('driver.register', {'manifest': _lamp});
      await ok('device.add', {
        'id': 'lamp',
        'name': 'Lamp',
        'driver': 'test_lamp',
      });
      await saveRule(_rule('R', 'lamp', true));
      await saveRule(_rule('R', 'lamp', false), replacing: 'r');
      expect(await versionsOf('r'), 1);

      final removed = await ok('automation.remove', {'id': 'r'});
      expect(removed['removed'], isTrue);
      expect(removed['restorable'], isTrue);
      expect(removed['message'], contains('30 days'));
      final list = (await ok('automation.removed'))['removed'] as List;
      expect(
        [for (final r in list.cast<Map>()) (r['id'], r['versions'])],
        [('r', 1)],
      );

      await saveRule(_rule('R', 'lamp', true));
      expect(await versionsOf('r'), 0, reason: 'a new r inherits nothing');
      expect(
        (await fails('automation.unremove', {'id': 'r'}))['type'],
        'exists',
      );
      await ok('automation.remove', {'id': 'r'});
      await settle();
      events.clear();

      final back = await ok('automation.unremove', {'id': 'r'});
      expect((back['id'], back['enabled']), ('r', true));
      await settle();
      expect(changed(), ['automation.unremove r']);
      expect(await versionsOf('r'), 0, reason: 'the last removal had none');
      expect((await ok('automation.removed'))['removed'], isEmpty);
      expect(
        (await fails('automation.unremove', {'id': 'r'}))['type'],
        'not_found',
      );
    });

    test('what was removed over 30 days ago is gone', () async {
      await ok('driver.register', {'manifest': _lamp});
      await ok('device.add', {
        'id': 'lamp',
        'name': 'Lamp',
        'driver': 'test_lamp',
      });
      await saveRule(_rule('Old', 'lamp', true));
      await ok('automation.remove', {'id': 'old'});
      await engine.close();
      final db = OmniDatabase.file(File('${home.path}/omniflow.sqlite'));
      await db.customStatement('UPDATE automation_removed SET removed_at = ?', [
        DateTime.now()
            .subtract(const Duration(days: 31))
            .toUtc()
            .toIso8601String(),
      ]);
      await db.close();
      engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
        mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
      );
      expect((await ok('automation.removed'))['removed'], isEmpty);
    });
  });

  group('removing a device', () {
    test('turns its automations off with an automation.changed each, and '
        'adding it back turns them on again', () async {
      await ok('driver.register', {'manifest': _lamp});
      for (final id in ['lamp', 'desk']) {
        await ok('device.add', {'id': id, 'name': id, 'driver': 'test_lamp'});
      }
      await saveRule(_rule('Eve', 'lamp', true));
      await saveRule({
        ..._rule('Both', 'lamp', false),
        'then': [
          {
            'do': 'lamp.power',
            'params': {'value': false},
          },
          {
            'do': 'desk.power',
            'params': {'value': false},
          },
        ],
      });
      await saveRule(_rule('Desk', 'desk', true));
      await settle();
      events.clear();
      final removed = await ok('device.remove', {'id': 'lamp'});
      expect(removed['flows'], unorderedEquals(['eve', 'both']));
      await settle();
      expect(
        changed(),
        unorderedEquals(['device.remove eve', 'device.remove both']),
      );
      await ok('device.remove', {'id': 'desk'});
      expect(await enabled('desk'), isFalse);

      await settle();
      events.clear();
      final lampBack = await ok('device.add', {
        'id': 'lamp',
        'name': 'Lamp',
        'driver': 'test_lamp',
      });
      expect(lampBack['turnedBackOn'], [
        {'id': 'eve', 'name': 'Eve'},
      ]);
      await settle();
      expect(changed(), ['device.add eve']);
      expect(await enabled('both'), isFalse, reason: 'the desk is still gone');

      final deskBack = await ok('device.add', {
        'id': 'desk',
        'name': 'Desk',
        'driver': 'test_lamp',
      });
      expect([
        for (final r in (deskBack['turnedBackOn'] as List).cast<Map>()) r['id'],
      ], unorderedEquals(['both', 'desk']));
      expect(await enabled('both'), isTrue);
    });

    test(
      'one the user turned on or off since is left as the user set it',
      () async {
        await ok('driver.register', {'manifest': _lamp});
        await ok('device.add', {
          'id': 'lamp',
          'name': 'Lamp',
          'driver': 'test_lamp',
        });
        await saveRule(_rule('Eve', 'lamp', true));
        await ok('device.remove', {'id': 'lamp'});
        await ok('automation.enable', {'id': 'eve', 'enabled': false});
        final back = await ok('device.add', {
          'id': 'lamp',
          'name': 'Lamp',
          'driver': 'test_lamp',
        });
        expect(back.containsKey('turnedBackOn'), isFalse);
        expect(await enabled('eve'), isFalse);
      },
    );
  });

  group('when I leave without a hub', () {
    Future<Map<String, Object?>> saveLeave() async {
      await ok('device.add', {
        'id': 'jade',
        'name': 'Jade',
        'driver': 'person',
      });
      return ok('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Leave',
          'when': [
            {
              'on': 'jade.home',
              'change': {'to': false},
            },
          ],
          'then': [
            {
              'notify': {'title': 'bye'},
            },
          ],
        },
      });
    }

    test('on a phone the save warns that only phone actions and web '
        'requests run', () async {
      RulesCoreCommands.onPhone = () => true;
      final saved = await saveLeave();
      expect(saved['warnings'], [RulesCoreCommands.leaveWithoutHub]);
      expect(
        RulesCoreCommands.leaveWithoutHub,
        allOf(contains('phone actions'), contains('web requests')),
      );
      final last = await ok('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Last out',
          'when': [
            {'people': 'last_leaves'},
          ],
          'then': [
            {
              'notify': {'title': 'bye'},
            },
          ],
        },
      });
      expect(last['warnings'], isNotEmpty);
    });

    test(
      'on a hub, or for a rule that is not about leaving, no warning',
      () async {
        RulesCoreCommands.onPhone = () => false;
        expect((await saveLeave()).containsKey('warnings'), isFalse);
        RulesCoreCommands.onPhone = () => true;
        final arrive = await ok('automation.save', {
          'form': 'rule',
          'trusted': true,
          'spec': {
            'name': 'Arrive',
            'when': [
              {
                'on': 'jade.home',
                'change': {'to': true},
              },
            ],
            'then': [
              {
                'notify': {'title': 'hi'},
              },
            ],
          },
        });
        expect(arrive.containsKey('warnings'), isFalse);
      },
    );
  });

  group('automatic backup', () {
    test('backup.auto.set now writes a 0600 file in a 0700 folder, and '
        'engine.status says when', () async {
      final start = await ok('backup.auto.get');
      expect((start['on'], start['keep']), (true, 14));
      expect(start['folder'], '${home.absolute.path}/backups');
      final written = await ok('backup.auto.set', {'now': true});
      final file = File('${(written['written'] as Map)['file']}');
      final backup = jsonDecode(await file.readAsString()) as Map;
      expect(backup['schema'], 'omniflow.backup');
      expect((await file.stat()).mode & 0x1ff, 0x180);
      expect(
        (await Directory('${home.path}/backups').stat()).mode & 0x1ff,
        0x1c0,
      );
      final status = await ok('engine.status');
      expect(status['lastBackup'], isA<String>());
      expect(status['autoBackup'], isTrue);
      await ok('backup.auto.set', {'on': false});
      expect((await ok('engine.status'))['autoBackup'], isFalse);
      expect(
        (await fails('backup.auto.set', {'on': 'yes'}))['type'],
        'invalid',
      );
    });

    test('keeps the newest 14', () async {
      final dir = Directory('${home.path}/backups')..createSync();
      for (var d = 1; d <= 20; d++) {
        File(
          '${dir.path}/omniflow-2026-01-${d.toString().padLeft(2, '0')}.json',
        ).writeAsStringSync('{}');
      }
      await ok('backup.auto.set', {'now': true});
      final kept = (await ok('backup.auto.get'))['backups'] as List;
      expect(kept, hasLength(14));
      expect(
        '${(kept.first as Map)['file']}',
        endsWith('${DateTime.now().toIso8601String().substring(0, 10)}.json'),
      );
    });
  });
}
