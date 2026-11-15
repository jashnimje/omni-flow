@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import 'things_test.dart' show until;

/// Held state triggers, people triggers, aligned times, engine start, why
/// an automation did not run, conflicts and version history, through the
/// engine's commands.
void main() {
  late Directory home;
  late OmniEngine engine;
  late List<Map<String, Object?>> events;
  late StreamSubscription<Map<String, Object?>> sub;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_rules_core');
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

  Future<Map<String, Object?>> fails(
    String command,
    Map<String, Object?> args,
  ) async {
    final r = await engine.handle(command, args);
    expect(r['ok'], isFalse, reason: '$command: $r');
    return Map<String, Object?>.from(r['error'] as Map);
  }

  Future<Map<String, Object?>> saveRule(Map<String, Object?> rule) => ok(
    'automation.save',
    {'form': 'rule', 'spec': rule, 'trusted': true, 'replace': true},
  );

  List<String> announced(String flow) => [
    for (final e in events)
      if (e['event'] == 'flow.announce' && e['flow'] == flow) '${e['title']}',
  ];

  Future<String> sentence(String id) async {
    final list = (await ok('automation.list'))['automations'] as List;
    final row = list.cast<Map>().firstWhere((a) => a['id'] == id);
    return [for (final c in (row['sentence'] as List).cast<Map>()) c['text']]
        .join(' ');
  }

  Map<String, Object?> notify(String title) => {
    'notify': {'title': title},
  };

  group('validation', () {
    Future<List<String>> issues(Map<String, Object?> rule) async {
      final error = await fails('automation.save', {
        'form': 'rule',
        'spec': rule,
      });
      return [
        for (final i in (error['issues'] as List).cast<Map>())
          '${i['path']}: ${i['message']}',
      ];
    }

    test('for needs a state to hold and a sensible time', () async {
      await ok('phone.battery', {'level': 50, 'charging': false});
      expect(
        await issues({
          'name': 'Bad hold',
          'when': [
            {'on': 'phone.charging', 'for': 60000},
          ],
          'then': [notify('x')],
        }),
        [contains('when[0].for: needs a state to hold')],
      );
      expect(
        await issues({
          'name': 'Short hold',
          'when': [
            {
              'on': 'phone.charging',
              'change': {'to': true},
              'for': 10,
            },
          ],
          'then': [notify('x')],
        }),
        [contains('when[0].for')],
      );
    });

    test('people, engine and aligned interval shapes', () async {
      expect(
        await issues({
          'name': 'Bad people',
          'when': [
            {'people': 'someone'},
            {'event': 'reboot'},
            {'interval': 3600, 'offset': 3600},
            {
              'interval': 900,
              'between': ['09:00'],
            },
          ],
          'onlyIf': [
            {'people': 'nobody'},
          ],
          'then': [notify('x')],
        }),
        unorderedEquals([
          contains('when[0].people'),
          contains('when[1].event'),
          contains('when[2].offset'),
          contains('when[3].between'),
          contains('onlyIf[0].people'),
        ]),
      );
    });
  });

  test('sentences for the new triggers and conditions', () async {
    await ok('phone.battery', {'level': 50, 'charging': false});
    await saveRule({
      'name': 'Held',
      'when': [
        {
          'on': 'phone.charging',
          'change': {'to': true},
          'for': 300000,
        },
        {'people': 'first_arrives'},
        {'event': 'engine_started'},
        {'interval': 3600, 'offset': 300},
        {
          'interval': 900,
          'between': ['09:00', '18:00'],
        },
      ],
      'onlyIf': [
        {'people': 'all_away'},
      ],
      'then': [notify('x')],
    });
    final words = await sentence('held');
    expect(words, contains('has been on for 5 min'));
    expect(words, contains('the first person gets home'));
    expect(words, contains('OmniFlow starts'));
    expect(words, contains('every hour at :05'));
    expect(words, contains('every 15 min from 09:00 to 18:00'));
    expect(words, contains('everyone is away'));
  });

  test('a held trigger fires once the state has held', () async {
    await ok('phone.battery', {'level': 50, 'charging': false});
    await saveRule({
      'name': 'Charging a while',
      'when': [
        {
          'on': 'phone.charging',
          'change': {'to': true},
          'for': 1000,
        },
      ],
      'then': [notify('charged a while')],
    });
    await ok('phone.battery', {'level': 50, 'charging': true});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(announced('charging_a_while'), isEmpty);
    await until(() => announced('charging_a_while').isNotEmpty);
  });

  test('the first person home and the last to leave', () async {
    await ok('zone.save', {
      'zone': {
        'id': 'home',
        'name': 'Home',
        'wifi': {
          'ssids': ['HomeNet'],
          'awayAfterMs': 0,
        },
      },
    });
    for (final p in ['jade', 'asha']) {
      await ok('device.add', {'id': p, 'name': p, 'driver': 'person'});
    }
    await saveRule({
      'name': 'Welcome',
      'when': [
        {'people': 'first_arrives'},
      ],
      'then': [notify('first home')],
    });
    await saveRule({
      'name': 'Goodbye',
      'when': [
        {'people': 'last_leaves'},
      ],
      'onlyIf': [
        {'people': 'all_away'},
      ],
      'then': [notify('all gone')],
    });
    await ok('presence.set', {'home': true, 'person': 'jade'});
    await ok('presence.set', {'home': true, 'person': 'asha'});
    await until(() => announced('welcome').length == 1);
    await ok('presence.set', {'home': false, 'person': 'jade'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(announced('goodbye'), isEmpty);
    await ok('presence.set', {'home': false, 'person': 'asha'});
    await until(() => announced('goodbye').length == 1);
    expect(announced('welcome'), ['first home']);
  });

  test('When OmniFlow starts runs once the engine runs automations', () async {
    await saveRule({
      'name': 'Boot',
      'when': [
        {'event': 'engine_started'},
      ],
      'then': [notify('started')],
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(announced('boot'), isEmpty);
    engine.flows.startTimers();
    await until(() => announced('boot').length == 1);
  });

  group('why it did not run', () {
    /// A window that does not hold now.
    List<String> notNow() {
      String hhmm(DateTime t) =>
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
      final now = DateTime.now();
      return [
        hhmm(now.add(const Duration(hours: 2))),
        hhmm(now.add(const Duration(hours: 3))),
      ];
    }

    test('a condition, in plain words', () async {
      await ok('phone.battery', {'level': 50, 'charging': false});
      final window = notNow();
      await saveRule({
        'name': 'Evening charge',
        'when': [
          {
            'on': 'phone.charging',
            'change': {'to': true},
          },
        ],
        'onlyIf': [
          {'between': window},
        ],
        'then': [notify('x')],
      });
      expect(
        (await ok('automation.skips', {'id': 'evening_charge'}))['skips'],
        isEmpty,
      );
      await ok('phone.battery', {'level': 50, 'charging': true});
      late List<Map> skips;
      await until(() async {
        skips =
            ((await ok('automation.skips', {'id': 'evening_charge'}))['skips']
                    as List)
                .cast<Map>();
        return skips.isNotEmpty;
      });
      expect(skips.single['kind'], 'condition');
      expect(
        skips.single['text'],
        allOf(
          contains('but it was not between ${window[0]} and ${window[1]}'),
          contains('charging'),
        ),
      );
    });

    test('an automation that is off', () async {
      await ok('phone.battery', {'level': 50, 'charging': false});
      await saveRule({
        'name': 'Off one',
        'enabled': false,
        'when': [
          {
            'on': 'phone.charging',
            'change': {'to': true},
          },
        ],
        'then': [notify('x')],
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ok('phone.battery', {'level': 50, 'charging': true});
      late List<Map> skips;
      await until(() async {
        skips =
            ((await ok('automation.skips', {'id': 'off_one'}))['skips'] as List)
                .cast<Map>();
        return skips.isNotEmpty;
      });
      expect(skips.single['reason'], 'it was turned off');
    });

    test('a value that did not match names what it was', () async {
      await ok('phone.battery', {'level': 50, 'charging': false});
      await saveRule({
        'name': 'Low and plugged',
        'when': [
          {
            'on': 'phone.charging',
            'change': {'to': true},
          },
        ],
        'onlyIf': [
          {'state': 'phone.battery', 'op': '<', 'value': 20},
        ],
        'then': [notify('x')],
      });
      await ok('phone.battery', {'level': 50, 'charging': true});
      late List<Map> skips;
      await until(() async {
        skips =
            ((await ok('automation.skips', {'id': 'low_and_plugged'}))['skips']
                    as List)
                .cast<Map>();
        return skips.isNotEmpty;
      });
      expect(skips.single['reason'], contains('was 50, not below 20'));
    });
  });

  test('try as if: a dry run from one trigger with a made-up event', () async {
    await ok('phone.battery', {'level': 50, 'charging': false});
    final rule = {
      'name': 'As if',
      'when': [
        {'manual': true},
        {
          'on': 'phone.charging',
          'change': {'to': true},
        },
      ],
      'then': [notify('plugged in')],
    };
    final run =
        (await ok('automation.dry_run', {
              'form': 'rule',
              'spec': rule,
              'trigger': ruleTriggerNodeId(1),
              'msg': asIfMessage(
                (rule['when'] as List)[1] as Map<String, Object?>,
              ),
            }))['run']
            as Map;
    final nodes = (run['nodes'] as List).cast<Map>();
    expect(nodes.first['node'], 'when_1');
    expect((nodes.first['input'] as Map)['value'], true);
    expect(nodes.map((n) => n['type']), contains('notify'));
  });

  group('conflicts', () {
    setUp(() async {
      await ok('phone.battery', {'level': 50, 'charging': false});
      await ok('device.add', {
        'id': 'lamp',
        'name': 'Lamp',
        'driver': 'philips_wiz_udp',
        'host': '127.0.0.1',
      });
    });

    Map<String, Object?> lamp(Object? to, bool value, String name) => {
      'name': name,
      'when': [
        {
          'on': 'phone.charging',
          'change': {'to': to},
        },
      ],
      'then': [
        {
          'do': 'lamp.power',
          'params': {'value': value},
        },
      ],
    };

    test('two automations set the lamp both ways on one trigger', () async {
      await saveRule(lamp(true, true, 'Lamp on'));
      await saveRule(lamp(true, false, 'Lamp off'));
      await saveRule(lamp(false, false, 'Unplugged off'));
      final all = ((await ok('automation.conflicts'))['conflicts'] as List)
          .cast<Map>();
      expect(all, hasLength(1));
      expect(all.single['automations'], ['lamp_off', 'lamp_on']);
      expect(
        all.single['reason'],
        allOf(contains('Lamp off sets Lamp off'), contains('Lamp on sets')),
      );
      final mine =
          (await ok('automation.conflicts', {
                'id': 'unplugged_off',
              }))['conflicts']
              as List;
      expect(mine, isEmpty);
      // The list carries each row's clashes, for the card's warning.
      final listed = (await ok('automation.list'))['automations'] as List;
      final rows = {for (final a in listed.cast<Map>()) a['id']: a};
      expect(rows['lamp_on']!['conflicts'], [all.single['reason']]);
      expect(rows['unplugged_off']!.containsKey('conflicts'), isFalse);
    });

    test('a turned off automation does not conflict', () async {
      await saveRule(lamp(true, true, 'Lamp on'));
      await saveRule({...lamp(true, false, 'Lamp off'), 'enabled': false});
      expect((await ok('automation.conflicts'))['conflicts'], isEmpty);
    });
  });

  group('version history', () {
    Map<String, Object?> rule(String title) => {
      'name': 'Versioned',
      'when': [
        {'manual': true},
      ],
      'then': [notify(title)],
    };

    test(
      'each save keeps the one before, and restore brings it back',
      () async {
        await saveRule(rule('one'));
        expect(
          (await ok('automation.versions', {'id': 'versioned'}))['versions'],
          isEmpty,
        );
        await saveRule(rule('two'));
        // Saving the same rule again keeps nothing new.
        await saveRule(rule('two'));
        final versions =
            ((await ok('automation.versions', {'id': 'versioned'}))['versions']
                    as List)
                .cast<Map>();
        expect(versions, hasLength(1));
        expect(versions.single['source'], 'you');
        expect(versions.single['form'], 'rule');
        expect(
          (versions.single['sentence'] as List).cast<Map>().map(
            (c) => c['text'],
          ),
          contains('notify "one"'),
        );
        final restored = await ok('automation.restore', {
          'id': 'versioned',
          'version': versions.single['version'],
          'trusted': true,
        });
        expect(restored['approved'], isTrue);
        final spec = (await ok('automation.get', {'id': 'versioned'}))['spec'];
        expect(((spec as Map)['then'] as List).single, notify('one'));
        expect(
          ((await ok('automation.versions', {'id': 'versioned'}))['versions']
                  as List)
              .length,
          2,
        );
        expect(
          (await fails('automation.restore', {
            'id': 'versioned',
            'version': 99,
          }))['type'],
          'not_found',
        );
      },
    );

    test('keeps the last 10', () async {
      for (var i = 0; i < 13; i++) {
        await saveRule(rule('take $i'));
      }
      final versions =
          ((await ok('automation.versions', {'id': 'versioned'}))['versions']
                  as List)
              .cast<Map>();
      expect(versions, hasLength(10));
      expect(versions.first['version'], 12);
    });

    test('agents read history but only you restore', () async {
      await saveRule(rule('one'));
      await saveRule(rule('two'));
      final read = await engine.handle('agent.call', {
        'command': 'automation.versions',
        'args': {'id': 'versioned'},
      });
      expect(read['ok'], isTrue, reason: '$read');
      final restore = await engine.handle('agent.call', {
        'command': 'automation.restore',
        'args': {'id': 'versioned', 'version': 1},
      });
      expect((restore['error'] as Map)['type'], 'needs_user');
      for (final command in [
        'automation.skips',
        'automation.conflicts',
        'automation.versions',
      ]) {
        expect(agentRefusal(command, const {}, AgentAccess.read), isNull);
      }
    });
  });
}
