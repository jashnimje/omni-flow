import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import 'package:omniflow_engine/src/api/engine_flow_host.dart';

import 'automation_harness.dart';

void main() {
  late Directory home;
  late AutomationHarness h;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_automation');
    h = await AutomationHarness.open(home);
  });

  tearDown(() async {
    await h.shutdown();
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await h.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command: $result');
    return result;
  }

  Future<Map<String, Object?>> fails(
    String command,
    Map<String, Object?> args,
    String type,
  ) async {
    final result = await h.handle(command, args);
    expect(result['ok'], isFalse, reason: '$command: $result');
    final error = result['error'] as Map<String, Object?>;
    expect(error['type'], type, reason: '$error');
    return error;
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(done(), isTrue);
  }

  final welcome = {
    'name': 'Welcome home',
    'when': ['home:entered', 'time:18:00'],
    'onlyIf': ['lamp.power=false'],
    'then': ['lamp.power=true', 'wait:2s', 'notify:Welcome'],
  };

  final welcomeExpanded = {
    'id': 'welcome_home',
    'name': 'Welcome home',
    'when': [
      {
        'on': 'jade.home',
        'change': {'to': true},
      },
      {'time': '18:00'},
    ],
    'onlyIf': [
      {'state': 'lamp.power', 'op': '==', 'value': false},
    ],
    'then': [
      {
        'do': 'lamp.power',
        'params': {'value': true},
      },
      {'wait': 2000},
      {
        'notify': {'title': 'Welcome'},
      },
    ],
  };

  test(
    'a rule reopens as the rule it was written as, after a restart',
    () async {
      final saved = await ok('automation.save', {
        'form': 'rule',
        'spec': welcome,
        'trusted': true,
      });
      expect(saved, containsPair('id', 'welcome_home'));
      expect(saved, containsPair('source', 'rule'));
      expect(saved, containsPair('approved', true));
      expect(saved, containsPair('name', 'Welcome home'));

      await h.shutdown();
      h = await AutomationHarness.open(home, addThings: false);

      final got = await ok('automation.get', {'id': 'welcome_home'});
      expect(got['source'], 'rule');
      expect(got['spec'], welcomeExpanded);
      expect(got['enabled'], isTrue);
      expect(got['revision'], saved['revision']);
      final nodes = ((got['flow'] as Map)['nodes'] as List).cast<Map>();
      final onlyIf = nodes.firstWhere((n) => n['id'] == 'only_if');
      expect((onlyIf['config'] as Map)['left'], {
        'state': 'lamp.state',
      }, reason: 'the lamp reports power as state');
      expect(h.core.flows.loadedFlows, contains('welcome_home'));

      final listed = await ok('automation.list', {'source': 'rule'});
      expect(
        [
          for (final a in (listed['automations'] as List).cast<Map>())
            (a['id'], a['source']),
        ],
        [('welcome_home', 'rule')],
      );
      final flow = await ok('flow.get', {'id': 'welcome_home'});
      expect(flow['source'], 'rule');
      expect(flow['spec'], welcomeExpanded);
    },
  );

  test('saving the rule it got back changes nothing', () async {
    final first = await ok('automation.save', {
      'form': 'rule',
      'spec': welcome,
      'trusted': true,
    });
    final got = await ok('automation.get', {'id': 'welcome_home'});
    final again = await ok('automation.save', {
      'form': 'rule',
      'spec': got['spec'],
      'trusted': true,
      'replace': true,
    });
    expect(again['revision'], first['revision']);
  });

  test('problems come back at rule paths', () async {
    final error = await fails('automation.save', {
      'form': 'rule',
      'spec': {
        'name': 'Broken',
        'when': ['garage.door'],
        'then': ['lamp.launch=true', 'notify:ok'],
      },
    }, 'invalid');
    expect(error['message'], 'rule broken');
    expect([
      for (final i in (error['issues'] as List).cast<Map>()) i['path'],
    ], unorderedEquals(['when[0].on', 'then[0].do']));
    final shape = await fails('automation.save', {
      'form': 'rule',
      'spec': {
        'name': 'Shape',
        'when': ['work:entered', 'sometime'],
        'then': ['wait:2'],
      },
    }, 'invalid');
    expect(
      [for (final i in (shape['issues'] as List).cast<Map>()) i['path']],
      ['when[1]', 'then[0]'],
      reason: 'work is the office zone, so work:entered reads',
    );
    expect(
      await h.handle('automation.list', {}),
      containsPair('automations', isEmpty),
    );
  });

  test('a save names its form, and its spec is an object', () async {
    final none = await fails('automation.save', {'spec': welcome}, 'invalid');
    expect(none['message'], 'form must be one of link, rule, graph, scene');
    await fails('automation.save', {
      'form': 'script',
      'spec': welcome,
    }, 'invalid');
    await fails('automation.save', {'form': 'rule'}, 'invalid');
  });

  test('a dry run labels each node with the rule step it came from', () async {
    final dry = await ok('automation.dry_run', {
      'form': 'rule',
      'spec': {
        'name': 'Labels',
        'when': ['manual'],
        'onlyIf': ['lamp.power=false'],
        'then': ['notify:Hi', 'lamp.power=true'],
      },
    });
    final nodes = ((dry['run'] as Map)['nodes'] as List).cast<Map>();
    expect(
      [for (final n in nodes) (n['node'], n['label'])],
      [
        ('when_0', 'run by hand'),
        ('only_if', 'only if Lamp is off'),
        ('then_0', 'notify Hi'),
        ('then_1', 'Lamp on'),
      ],
    );
  });

  test('an unsaved rule dry-runs from its spec, and id names it', () async {
    final dry = await ok('automation.dry_run', {
      'form': 'rule',
      'spec': welcome,
      'id': 'try_it',
    });
    final run = dry['run'] as Map;
    expect(
      (run['flow'], run['dryRun'], run['trigger']),
      ('try_it', true, 'when_0'),
    );
    expect(await DriftFlowStore(h.db).get('try_it'), isNull);
    final bad = await fails('automation.dry_run', {
      'form': 'rule',
      'spec': {
        'name': 'x',
        'when': ['garage.door'],
        'then': ['notify:x'],
      },
    }, 'invalid');
    expect((bad['issues'] as List).single, containsPair('path', 'when[0].on'));
    final saved = await ok('automation.save', {
      'form': 'rule',
      'spec': welcome,
      'id': 'my_welcome',
      'trusted': true,
    });
    expect(saved['id'], 'my_welcome');
    await fails('automation.dry_run', {
      'form': 'link',
      'spec': {'from': 'jade.home', 'to': 'lamp.power', 'mode': 'toggle'},
    }, 'invalid');
  });

  test(
    'a graph can replace a rule, a rule cannot replace a graph or link',
    () async {
      final graph = {
        'schemaVersion': 1,
        'id': 'evening',
        'name': 'Evening',
        'nodes': [
          {'id': 'go', 'type': 'manual', 'config': <String, Object?>{}},
          {
            'id': 'say',
            'type': 'notify',
            'config': {'title': 'Evening'},
          },
        ],
        'edges': [
          {
            'id': 'e1',
            'from': {'node': 'go', 'port': 'out'},
            'to': {'node': 'say', 'port': 'in'},
          },
        ],
      };
      await ok('automation.save', {
        'form': 'graph',
        'spec': graph,
        'trusted': true,
      });
      final refused = await fails('automation.save', {
        'form': 'rule',
        'spec': {
          'name': 'Evening',
          'when': ['manual'],
          'then': ['notify:hi'],
        },
      }, 'exists');
      expect(refused['message'], startsWith('evening is a graph'));

      await ok('automation.save', {
        'form': 'rule',
        'spec': welcome,
        'trusted': true,
      });
      await ok('flow.save', {
        'flow': {...graph, 'id': 'welcome_home'},
        'trusted': true,
      });
      final promoted = await ok('automation.get', {'id': 'welcome_home'});
      expect(promoted['source'], 'graph');
      expect(promoted['spec'], promoted['flow']);
    },
  );

  test('links are automations under their old commands too', () async {
    final created = await ok('link.create', {
      'from': 'jade.home',
      'to': 'lamp.power',
      'mode': 'toggle',
      'trusted': true,
    });
    final id = created['id'] as String;
    expect(created['source'], 'link');
    final spec = {
      'from': 'jade.home',
      'to': 'lamp.power',
      'mode': 'toggle',
      'onValue': true,
    };
    final got = await ok('automation.get', {'id': id});
    expect(got['source'], 'link');
    expect(got['spec'], spec);
    final links = await ok('link.list', {});
    expect((links['links'] as List).single, containsPair('spec', spec));

    await fails('automation.save', {'form': 'link', 'spec': spec}, 'exists');
    final replaced = await ok('automation.save', {
      'form': 'link',
      'spec': spec,
      'replace': true,
      'trusted': true,
    });
    expect((replaced['id'], replaced['source']), (id, 'link'));
    final follow = await ok('automation.save', {
      'form': 'link',
      'spec': {
        'from': 'lamp.dimming',
        'to': 'lamp.brightness',
        'mode': 'follow',
      },
    });
    expect(follow['source'], 'link');
    expect([
      for (final a
          in ((await ok('automation.list', {'source': 'link'}))['automations']
                  as List)
              .cast<Map>())
        a['id'],
    ], unorderedEquals([id, follow['id']]));

    await ok('automation.save', {
      'form': 'rule',
      'spec': welcome,
      'trusted': true,
    });
    await fails('link.remove', {'id': 'welcome_home'}, 'invalid');
    expect((await ok('link.remove', {'id': id}))['removed'], isTrue);
  });

  test('a link stored before specs were kept gets its spec back', () async {
    final created = await ok('link.create', {
      'from': 'lamp.dimming',
      'to': 'lamp.brightness',
      'mode': 'follow',
      'trusted': true,
    });
    final id = created['id'] as String;
    final record = (await DriftFlowStore(h.db).get(id))!;
    await DriftFlowStore(h.db).put(
      id,
      record.json,
      enabled: true,
      approved: true,
      trusted: true,
      at: DateTime.utc(2026),
      source: FlowRecord.link,
    );
    expect((await DriftFlowStore(h.db).get(id))!.spec, isNull);
    await h.shutdown();
    h = await AutomationHarness.open(home, addThings: false);
    final spec = (await ok('automation.get', {'id': id}))['spec'] as Map;
    expect(spec, {
      'from': 'lamp.dimming',
      'to': 'lamp.brightness',
      'mode': 'follow',
    });
    final again = await ok('automation.save', {
      'form': 'link',
      'spec': spec,
      'replace': true,
      'trusted': true,
    });
    expect(
      (again['id'], again['revision']),
      (id, created['revision']),
      reason: 'the rebuilt spec makes the same link',
    );
  });

  test('enable, approve, run, dry run, log and remove work on rules', () async {
    final risky = await ok('automation.save', {
      'form': 'rule',
      'spec': {
        'name': 'Wake the mac',
        'when': ['manual'],
        'then': ['mac_mini.display_wake'],
      },
    });
    expect((risky['approved'], risky['highRisk']), (false, true));
    expect(h.core.flows.loadedFlows, isNot(contains('wake_the_mac')));
    await fails('automation.approve', {
      'id': 'wake_the_mac',
      'revision': 'stale',
    }, 'conflict');
    await ok('automation.approve', {
      'id': 'wake_the_mac',
      'revision': risky['revision'],
    });
    expect(
      (await ok('automation.get', {'id': 'wake_the_mac'}))['approved'],
      isTrue,
    );

    await ok('automation.save', {
      'form': 'rule',
      'spec': {
        'name': 'Mode',
        'when': ['jade.home'],
        'then': [r'set:$Mode=home', 'notify:hello'],
      },
      'trusted': true,
    });
    final ran = await ok('automation.run', {'id': 'mode'});
    final run = (ran['runs'] as List).single as Map;
    expect((run['trigger'], run['outcome']), ('when_0', 'completed'));
    expect(h.core.flows.globals['Mode'], 'home');
    await h.core.settle();
    final dry = await ok('automation.dry_run', {'id': 'mode'});
    expect((dry['run'] as Map)['dryRun'], isTrue);
    final log = await ok('automation.log', {'id': 'mode'});
    expect(log['runs'], isNotEmpty);

    await ok('automation.enable', {'id': 'mode', 'enabled': false});
    final disabled = await ok('automation.get', {'id': 'mode'});
    expect((disabled['enabled'], disabled['source']), (false, 'rule'));
    expect(h.core.flows.loadedFlows, isNot(contains('mode')));
    await ok('automation.save', {
      'form': 'rule',
      'spec': disabled['spec'],
      'trusted': true,
      'replace': true,
    });
    expect(
      (await ok('automation.get', {'id': 'mode'}))['enabled'],
      isFalse,
      reason: 'saving the reopened rule keeps it off',
    );

    expect((await ok('automation.remove', {'id': 'mode'}))['removed'], isTrue);
    await fails('automation.get', {'id': 'mode'}, 'not_found');
  });

  test('a new rule with an id another rule has is refused, and replace: true '
      'saves over it', () async {
    final first = await ok('automation.save', {
      'form': 'rule',
      'spec': welcome,
      'trusted': true,
    });
    final other = {
      'name': 'Welcome home',
      'when': ['manual'],
      'then': ['notify:Other'],
    };
    for (final args in [
      {'form': 'rule', 'spec': other, 'trusted': true},
      {
        'form': 'rule',
        'spec': {...other, 'name': 'Other'},
        'id': 'welcome_home',
        'trusted': true,
      },
      {'form': 'rule', 'spec': other, 'trusted': true, 'replace': false},
    ]) {
      final error = await fails('automation.save', args, 'exists');
      expect('${error['message']}', contains('welcome_home'), reason: '$args');
    }
    expect(
      (await ok('automation.get', {'id': 'welcome_home'}))['revision'],
      first['revision'],
      reason: 'the stored rule is untouched',
    );

    final replaced = await ok('automation.save', {
      'form': 'rule',
      'spec': other,
      'trusted': true,
      'replace': true,
    });
    expect(replaced['id'], 'welcome_home');
    expect(replaced['revision'], isNot(first['revision']));
    final got = await ok('automation.get', {'id': 'welcome_home'});
    expect((got['spec'] as Map)['then'], [
      {
        'notify': {'title': 'Other'},
      },
    ]);
  });

  test('a rule may read any state key of a thing that reports undeclared '
      'state, and not of one that does not', () async {
    final rule = {
      'name': 'Weak signal',
      'when': ['lamp.rssi<-70'],
      'onlyIf': ['lamp.rssi>-90'],
      'then': ['notify:Lamp signal is weak'],
    };
    final saved = await ok('automation.save', {
      'form': 'rule',
      'spec': rule,
      'trusted': true,
    });
    expect(saved['id'], 'weak_signal');
    final flow = (await ok('automation.get', {'id': 'weak_signal'}))['flow'];
    await ok('flow.save', {
      'flow': {...flow as Map, 'id': 'weak_signal_graph'},
    });
    final refused = await fails('automation.save', {
      'form': 'rule',
      'spec': {
        ...rule,
        'name': 'Mood',
        'when': ['jade.mood'],
      },
    }, 'invalid');
    expect(
      [for (final i in (refused['issues'] as List).cast<Map>()) i['path']],
      ['when[0].on'],
    );
  });

  test('an untrusted save over a trusted rule waits for approval', () async {
    await ok('automation.save', {
      'form': 'rule',
      'spec': welcome,
      'trusted': true,
    });
    final again = await ok('automation.save', {
      'form': 'rule',
      'spec': welcome,
      'replace': true,
    });
    expect(again['approved'], isFalse);
  });

  test('a rule fires on a tag scan and on reaching home', () async {
    await ok('automation.save', {
      'form': 'rule',
      'spec': {
        'name': 'Arrivals',
        'when': ['nfc:front_door', 'home:entered'],
        'then': [
          {
            'if': ['jade.home'],
            'then': [r'set:$Last=home'],
            'else': [r'set:$Last=door'],
          },
        ],
        'mode': 'queued',
      },
      'trusted': true,
    });
    h.core.raiseEvent('front_door', 'scanned', {'uid': '04A22B1C'});
    await until(() => h.core.flows.globals['Last'] == 'door');
    await h.core.devices.mergeState('jade', {'home': true});
    await until(() => h.core.flows.globals['Last'] == 'home');
  });

  test(
    'removing an automation forgets the daily time it last started',
    () async {
      await ok('automation.save', {
        'form': 'rule',
        'spec': {
          'name': 'Night',
          'when': ['time:01:00'],
          'then': ['notify:Night'],
        },
        'trusted': true,
      });
      final host = EngineFlowHost(h.core);
      const at = '2026-11-10T01:00:00.000';
      expect(await host.ranAt('night', at), isFalse);
      await host.markScheduled('night', at);
      expect(await host.ranAt('night', at), isTrue);
      await ok('automation.remove', {'id': 'night'});
      expect(
        await DriftGlobalStore(h.db).get(scheduledGlobalKey('night')),
        isNull,
      );
      expect(await host.ranAt('night', at), isFalse);
    },
  );

  test('a web request reads its secret from the engine store', () async {
    final host = EngineFlowHost(h.core);
    expect(await host.webSecret('ha_token'), isNull);
    await h.core.secrets.write(webSecretKey('ha_token'), 'fixture-value');
    expect(await host.webSecret('ha_token'), 'fixture-value');
  });
}
