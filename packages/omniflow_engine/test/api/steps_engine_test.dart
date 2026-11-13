@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/dag/templates.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import 'things_test.dart' show until;

const _light = {
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
  ],
};

void main() {
  late Directory home;
  late OmniEngine engine;
  late List<Map<String, Object?>> events;
  late StreamSubscription<Map<String, Object?>> sub;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_steps');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
    events = [];
    sub = engine.events.listen(events.add);
    await engine.handle('driver.register', {'manifest': _light});
    await engine.handle('device.add', {
      'id': 'lamp',
      'name': 'Desk lamp',
      'driver': 'test_light',
    });
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
    String type,
  ) async {
    final r = await engine.handle(command, args);
    expect(r['ok'], isFalse, reason: '$command: $r');
    final error = Map<String, Object?>.from(r['error'] as Map);
    expect(error['type'], type, reason: '$error');
    return error;
  }

  Future<void> rule(Map<String, Object?> spec) =>
      ok('automation.save', {'form': 'rule', 'trusted': true, 'spec': spec});

  List<String> titles() => [
    for (final e in events)
      if (e['event'] == 'flow.announce') '${e['title']}',
  ];

  List<Map<String, Object?>> named(String event) => [
    for (final e in events)
      if (e['event'] == event) e,
  ];

  Map<String, Object?> onEvent(String key, [Map<String, Object?>? match]) => {
    'on': 'phone.$key',
    'event': true,
    'match': ?match,
  };

  Future<Map<String, Object?>> phoneState() async => Map<String, Object?>.from(
    ((await ok('device.get', {'id': 'phone'}))['device'] as Map)['state']
        as Map,
  );

  group('phone inputs', () {
    test(
      'an app opening fires an on trigger and sets the app on screen',
      () async {
        await ok('phone.app', {'package': 'x', 'event': 'opened'});
        await rule({
          'name': 'Netflix opened',
          'when': [
            onEvent('app_opened', {'package': 'com.netflix'}),
          ],
          'then': ['notify:opened {{msg.payload.label}} on {{msg.device}}'],
        });
        await ok('phone.app', {
          'package': 'com.netflix',
          'label': 'Netflix',
          'event': 'opened',
        });
        await until(() => titles().contains('opened Netflix on phone'));
        expect((await phoneState())['app_on_screen'], 'com.netflix');
        await ok('phone.app', {'package': 'com.netflix', 'event': 'closed'});
        expect((await phoneState())['app_on_screen'], isNull);
        await fails('phone.app', {'package': 'a', 'event': 'gone'}, 'invalid');
        await fails('phone.app', {'event': 'opened'}, 'invalid');
      },
    );

    test('Bluetooth fires its events and keeps the connected names', () async {
      await ok('phone.battery', {'level': 50});
      await rule({
        'name': 'Car',
        'when': [onEvent('bluetooth_connected')],
        'then': ['notify:Connected to {{msg.payload.name}}'],
      });
      await rule({
        'name': 'Devices',
        'when': [
          {'on': 'phone.bluetooth_devices', 'change': true},
        ],
        'then': ['notify:now {{msg.value}}'],
      });
      await ok('phone.bluetooth', {
        'name': 'My car',
        'address': '00:11',
        'connected': true,
      });
      await until(() => titles().contains('Connected to My car'));
      await until(() => titles().contains('now ["My car"]'));
      await ok('phone.bluetooth', {'name': 'Buds', 'connected': true});
      await ok('phone.bluetooth', {'name': 'My car', 'connected': false});
      expect((await phoneState())['bluetooth_devices'], ['Buds']);
      expect(
        named('thing.event').map((e) => e['key']),
        containsAll(['bluetooth_connected', 'bluetooth_disconnected']),
      );
      await fails('phone.bluetooth', {'name': 'x'}, 'invalid');
    });

    test('the screen and Do Not Disturb fire change triggers', () async {
      await ok('phone.screen', {'on': false});
      await ok('phone.dnd', {'on': false});
      await rule({
        'name': 'Screen',
        'when': [
          {
            'on': 'phone.screen_on',
            'change': {'to': true},
          },
          {
            'on': 'phone.dnd_on',
            'change': {'to': true},
          },
        ],
        'then': ['notify:{{msg.key}} on'],
        'mode': 'parallel',
      });
      await ok('phone.screen', {'on': true});
      await ok('phone.dnd', {'on': true});
      await until(() => titles().contains('screen_on on'));
      await until(() => titles().contains('dnd_on on'));
      final state = await phoneState();
      expect(state['screen_on'], isTrue);
      expect(state['dnd_on'], isTrue);
      await fails('phone.dnd', {'on': 'yes'}, 'invalid');
    });

    test(
      'a notification\'s words reach the run and are stored nowhere',
      () async {
        await rule({
          'name': 'Chat',
          'when': [
            onEvent('notification', {'package': 'com.chat'}),
          ],
          'then': [
            'notify:{{msg.payload.title}}: {{msg.payload.text}}',
            {
              'text': {'value': '{{msg.payload.text}}', 'as': '%words'},
            },
          ],
        });
        final reply = await ok('phone.notification', {
          'package': 'com.chat',
          'label': 'Chat',
          'title': 'Hidden title',
          'text': 'Hidden words',
        });
        expect(jsonEncode(reply), isNot(contains('Hidden')));
        await until(() => titles().contains('Hidden title: Hidden words'));
        await until(
          () async =>
              ((await ok('automation.log', {'id': 'chat'}))['runs'] as List)
                  .isNotEmpty,
        );
        final stored = [
          await ok('automation.log', {'id': 'chat'}),
          await ok('device.get', {'id': 'phone'}),
          await ok('device.history', {'id': 'phone'}),
          await ok('automation.list'),
          await ok('config.export'),
          await ok('var.list'),
        ];
        for (final r in stored) {
          expect(jsonEncode(r), isNot(contains('Hidden')), reason: '$r');
        }
        expect(
          jsonEncode(await ok('automation.log', {'id': 'chat'})),
          contains('com.chat'),
        );
      },
    );
  });

  group('ask first', () {
    Future<void> askingRule() => rule({
      'name': 'TV on',
      'askFirst': true,
      'when': [onEvent('app_opened')],
      'then': ['notify:running {{msg.payload.package}}'],
    });

    test(
      'Run starts the held run, and a second trigger does not stack',
      () async {
        await askingRule();
        await ok('phone.app', {'package': 'one', 'event': 'opened'});
        await until(() => named('ask.request').isNotEmpty);
        final request = named('ask.request').single;
        expect(request['kind'], 'confirm');
        expect(request['choices'], ['Run', 'Not now']);
        expect(request['flow'], 'tv_on');
        expect(request['title'], 'Run TV on?');
        await ok('phone.app', {'package': 'two', 'event': 'opened'});
        await until(
          () =>
              named('run.finished')
                  .any((e) => e['reason'] == 'it is already asking you'),
        );
        final pending = (await ok('ask.pending'))['asks'] as List;
        expect(pending, hasLength(1));
        expect(titles(), isEmpty);
        await fails('ask.answer', {
          'askId': request['askId'],
          'answer': 'Maybe',
        }, 'invalid');
        await ok('ask.answer', {'askId': request['askId'], 'answer': 'Run'});
        await until(() => titles().contains('running one'));
        expect(named('ask.closed').single['reason'], 'answered');
        expect((await ok('ask.pending'))['asks'], isEmpty);
        await fails('ask.answer', {
          'askId': request['askId'],
          'answer': 'Run',
        }, 'not_found');
      },
    );

    test('Not now drops the run with a plain reason', () async {
      await askingRule();
      await ok('phone.app', {'package': 'one', 'event': 'opened'});
      await until(() => named('ask.request').isNotEmpty);
      await ok('ask.answer', {
        'askId': named('ask.request').single['askId'],
        'answer': 'Not now',
      });
      await until(
        () => named('run.finished').any(
          (e) =>
              e['outcome'] == 'dropped' && e['reason'] == 'you chose not now',
        ),
      );
      expect(titles(), isEmpty);
    });

    test('running it by hand never asks', () async {
      await askingRule();
      await ok('automation.run', {
        'id': 'tv_on',
        'msg': {
          'payload': {'package': 'by hand'},
        },
      });
      expect(titles(), ['running by hand']);
      expect(named('ask.request'), isEmpty);
    });

    test('closing the engine cancels an open ask', () async {
      await askingRule();
      await ok('phone.app', {'package': 'one', 'event': 'opened'});
      await until(() => named('ask.request').isNotEmpty);
      await engine.close();
      expect(named('ask.closed').single['reason'], 'cancelled');
      engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
        mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
      );
      expect((await ok('ask.pending'))['asks'], isEmpty);
    });
  });

  group('automations', () {
    test('notify on run announces a completed run', () async {
      await rule({
        'name': 'Movie time',
        'notifyOnRun': true,
        'when': ['manual'],
        'then': ['lamp.power=true'],
      });
      await ok('automation.run', {'id': 'movie_time'});
      await until(() => titles().contains('Movie time ran'));
      final ran = named('flow.announce')
          .firstWhere((e) => e['title'] == 'Movie time ran');
      expect(ran['flow'], 'movie_time');
    });

    test('a share passes its text into the run', () async {
      await rule({
        'name': 'Shared',
        'when': ['manual'],
        'then': ['notify:got {{msg.shared.text}}'],
      });
      await ok('automation.run', {
        'id': 'shared',
        'msg': {
          'shared': {'text': 'a link', 'url': 'https://example.com'},
        },
      });
      expect(titles(), ['got a link']);
    });

    test('the list carries the look and the switches', () async {
      await rule({
        'name': 'By hand',
        'color': '#F472B6',
        'icon': 'heart',
        'notifyOnRun': true,
        'when': ['manual'],
        'then': ['lamp.power=true'],
      });
      await rule({
        'name': 'On its own',
        'askFirst': true,
        'when': ['time:07:00', 'manual'],
        'then': ['lamp.power=true'],
      });
      await ok('scene.save', {
        'name': 'Cosy',
        'icon': 'sofa',
        'color': '#FB923C',
        'actions': ['lamp.power=true'],
      });
      await fails('scene.save', {
        'name': 'Bad',
        'color': 'red',
        'actions': ['lamp.power=true'],
      }, 'invalid');
      final all = {
        for (final a
            in ((await ok('automation.list'))['automations'] as List)
                .cast<Map>())
          a['id']: a,
      };
      expect(all['by_hand'], containsPair('color', '#F472B6'));
      expect(all['by_hand'], containsPair('icon', 'heart'));
      expect(all['by_hand'], containsPair('notifyOnRun', true));
      expect(all['by_hand'], containsPair('askFirst', false));
      expect(all['by_hand'], containsPair('manualOnly', true));
      expect(all['on_its_own'], containsPair('askFirst', true));
      expect(all['on_its_own'], containsPair('manualOnly', false));
      expect(all['cosy'], containsPair('color', '#FB923C'));
      expect(all['cosy'], containsPair('icon', 'sofa'));
      expect(all['cosy'], containsPair('manualOnly', true));
      final scenes = (await ok('scene.list'))['scenes'] as List;
      expect((scenes.single as Map)['color'], '#FB923C');
    });

    test('a rule with the new steps saves and its sentence reads', () async {
      await rule({
        'name': 'Steps',
        'when': ['manual'],
        'then': [
          {
            'ask': {
              'title': 'Which?',
              'choices': ['A', 'B'],
            },
          },
          {
            'math': {'expr': '2 + 2'},
          },
          {
            'forEach': {
              'in': ['x'],
              'do': ['notify:{{%item}}'],
            },
          },
        ],
      });
      final listed = ((await ok('automation.list'))['automations'] as List)
          .cast<Map>()
          .firstWhere((a) => a['id'] == 'steps');
      final words = [
        for (final c in (listed['sentence'] as List).cast<Map>()) c['text'],
      ];
      expect(words, contains('ask "Which?" (A or B)'));
      expect(words, contains('work out 2 + 2'));
      expect(words, contains('for each item of x: notify "the item"'));
    });
  });

  group('rule.tokens', () {
    final unsaved = {
      'when': [
        {'on': 'lamp.power', 'change': true},
        'manual',
      ],
      'then': [
        {
          'http': {'url': 'https://example.com/a'},
        },
        {
          'ask': {
            'title': 'Pick',
            'choices': ['A', 'B'],
            'as': '%pick',
          },
        },
        {
          'forEach': {
            'in': '{{%reply.body.items}}',
            'do': ['notify:{{%item}}'],
          },
        },
        {
          'try': [
            {
              'math': {'expr': '1 + 1'},
            },
          ],
          'otherwise': ['notify:x'],
        },
      ],
    };

    Future<List<Map>> tokens(Object? rule, String path) async =>
        ((await ok('rule.tokens', {'rule': rule, 'path': path}))['tokens']
                as List)
            .cast<Map>();

    List<Object?> texts(List<Map> t) => [for (final x in t) x['token']];

    test('the first step sees the triggers only', () async {
      final t = await tokens(unsaved, 'then[0]');
      expect(texts(t), [
        '{{msg.value}}',
        '{{msg.previous}}',
        '{{msg.device}}',
        '{{msg.shared.text}}',
        '{{msg.shared.url}}',
        '{{msg.at}}',
      ]);
      expect(t.first['label'], 'Desk lamp · new value');
      expect(t.first['from'], 'when[0]');
    });

    test('later steps see earlier outputs in order, with labels', () async {
      final t = await tokens(unsaved, 'then[2]');
      expect(texts(t).skip(6), [
        '{{%reply}}',
        '{{%reply.status}}',
        '{{%reply.body}}',
        '{{%pick}}',
      ]);
      final byToken = {for (final x in t) x['token']: x};
      expect(byToken['{{%reply.body}}']!['label'], 'Web reply · body');
      expect(byToken['{{%reply.status}}']!['kind'], 'number');
      expect(byToken['{{%pick}}']!['label'], 'Answer (%pick)');
      expect(byToken['{{%pick}}']!['from'], 'then[1]');
    });

    test('inside a forEach and an otherwise', () async {
      final inside = await tokens(unsaved, 'then[2].forEach.do[0]');
      expect(texts(inside), containsAll(['{{%item}}', '{{msg.index}}']));
      final otherwise = await tokens(unsaved, 'then[3].otherwise[0]');
      expect(
        texts(otherwise),
        containsAll(['{{%result}}', '{{msg.error}}', '{{%pick}}']),
      );
      final end = await tokens(unsaved, 'then[4]');
      expect(texts(end), contains('{{%result}}'));
    });

    test('an event trigger gives its payload keys', () async {
      final t = await tokens({
        'when': [
          {'on': 'phone.notification', 'event': true},
        ],
        'then': <Object?>[],
      }, 'then[0]');
      expect(
        texts(t),
        containsAll([
          '{{msg.payload.package}}',
          '{{msg.payload.text}}',
          '{{msg.device}}',
          '{{msg.at}}',
        ]),
      );
    });

    test('a path that is not a step is a plain error', () async {
      final e = await fails('rule.tokens', {
        'rule': unsaved,
        'path': 'then[9]',
      }, 'invalid');
      expect(e['message'], 'then[9] is not a step of this rule');
      await fails('rule.tokens', {
        'rule': unsaved,
        'path': 'when[0]',
      }, 'invalid');
      await fails('rule.tokens', {'rule': 'x', 'path': 'then[0]'}, 'invalid');
    });
  });

  group('templates', () {
    test(
      'every template has a category, icon and colour from the lists',
      () async {
        final all = (await ok('automation.templates'))['templates'] as List;
        for (final t in all.cast<Map>()) {
          expect(templateCategories, contains(t['category']), reason: '$t');
          expect(RuleKeys.icons, contains(t['icon']), reason: '$t');
          expect(RuleKeys.colors, contains(t['color']), reason: '$t');
        }
      },
    );

    test('the new templates fill into rules that save', () async {
      await ok('device.add', {
        'id': 'jade',
        'name': 'Jade',
        'driver': 'person',
      });
      for (final (id, values) in [
        ('ask_before_tv', {'person': 'jade', 'tv': 'lamp.power'}),
        ('bluetooth_connected', <String, Object?>{}),
        ('web_value_notify', {'time': '07:30'}),
      ]) {
        final filled =
            ((await ok('automation.templates', {
                          'id': id,
                          'values': values,
                        }))['templates']
                        as List)
                    .single
                as Map;
        await rule(Map<String, Object?>.from(filled['spec'] as Map));
      }
      final all = {
        for (final a
            in ((await ok('automation.list'))['automations'] as List)
                .cast<Map>())
          a['id']: a,
      };
      expect(all['ask_before_the_tv_turns_on'], containsPair('askFirst', true));
      expect(
        all['notify_when_bluetooth_connects'],
        containsPair('icon', 'car'),
      );
    });
  });

  test('the agent policy keeps answers and phone inputs for the user', () {
    for (final command in [
      'ask.answer',
      'phone.app',
      'phone.notification',
      'phone.bluetooth',
      'phone.screen',
      'phone.dnd',
    ]) {
      expect(
        agentRefusal(command, const {}, AgentAccess.setup),
        contains('for the user only'),
        reason: command,
      );
    }
    for (final command in ['ask.pending', 'rule.tokens']) {
      expect(agentRefusal(command, const {}, AgentAccess.read), isNull);
    }
  });
}
