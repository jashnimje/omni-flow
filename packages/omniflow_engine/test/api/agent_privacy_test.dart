import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/dag/untrusted_templates.dart';
import 'package:test/test.dart';

/// A device that keeps what it is sent, standing in for a wall display, an
/// MQTT topic or a board an agent could send notification text to.
const _note = {
  'schemaVersion': 1,
  'id': 'note_display',
  'name': 'Note display',
  'category': 'other',
  'transport': {'type': 'virtual'},
  'capabilities': [
    {
      'id': 'show',
      'type': 'action',
      'label': 'Show',
      'params': {
        'text': {'type': 'string'},
      },
      'command': {'set': 'shown', 'value': '{{text}}'},
      'stateJsonPath': r'$.shown',
    },
  ],
};

void main() {
  group('the agent policy on another person\'s phone', () {
    test('screen input, screenshots, recording and the shade are the '
        'user\'s on a phone, and stay at setup on a TV', () {
      for (final c in [
        'tv.input.tap',
        'android.input.swipe',
        'tv.text',
        'android.screenshot',
        'tv.record.start',
        'android.notifications',
        'tv.pointer.click',
      ]) {
        expect(
          agentRefusal(c, const {}, AgentAccess.setup, onPhone: true),
          contains('for the user only'),
          reason: c,
        );
        expect(agentRefusal(c, const {}, AgentAccess.setup), isNull);
      }
    });

    test('on a phone tv.key takes power, volume and media keys only', () {
      String? key(Map<String, Object?> args) =>
          agentRefusal('android.key', args, AgentAccess.setup, onPhone: true);
      expect(key({'key': 'volume_up'}), isNull);
      expect(key({'key': 'play_pause'}), isNull);
      for (final args in [
        {'key': 'enter'},
        {'key': '4'},
        {'key': 'home'},
        {'key': 'notification'},
        {'keycode': 66},
        {'key': '66'},
      ]) {
        expect(key(args), contains('for the user only'), reason: '$args');
      }
      expect(
        agentRefusal('tv.key', const {'key': 'enter'}, AgentAccess.setup),
        isNull,
        reason: 'a TV keeps its remote at setup',
      );
    });

    test('a phone\'s files, apps, processes and settings need setup', () {
      for (final c in [
        'android.files.list',
        'tv.files.stat',
        'android.apps',
        'tv.app.permissions',
        'android.processes',
        'tv.settings.list',
        'android.settings.get',
      ]) {
        expect(
          agentRefusal(c, const {}, AgentAccess.read, onPhone: true),
          contains('sets the home up'),
          reason: c,
        );
        expect(
          agentRefusal(c, const {}, AgentAccess.setup, onPhone: true),
          isNull,
        );
        expect(agentRefusal(c, const {}, AgentAccess.read), isNull);
      }
    });
  });

  group('through agent.call', () {
    late Directory home;
    late OmniEngine engine;
    final events = <Map<String, Object?>>[];

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_agent_privacy');
      engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
      );
      events.clear();
      engine.events.listen(events.add);
    });

    tearDown(() async {
      await engine.close();
      await home.delete(recursive: true);
    });

    Future<Map<String, Object?>> agent(
      String command, [
      Map<String, Object?> args = const {},
    ]) => engine.handle('agent.call', {'command': command, 'args': args});

    Future<void> level(String access) async {
      final r = await engine.handle('agent.access.set', {'access': access});
      expect(r['ok'], isTrue);
    }

    Future<void> ok(String command, Map<String, Object?> args) async {
      final r = await engine.handle(command, args);
      expect(r['ok'], isTrue, reason: '$command $r');
    }

    test('the phone\'s Wi-Fi trail, apps, Bluetooth and media stay out of '
        'read-level replies, and come back at setup', () async {
      await ok('phone.wifi', {'ssid': 'HomeNet', 'bssid': 'aa:bb:cc:dd:ee:ff'});
      await ok('phone.app', {
        'package': 'com.example.health',
        'label': 'Clinic',
        'event': 'opened',
      });
      await ok('phone.bluetooth', {
        'name': 'Car stereo',
        'address': '11:22:33:44:55:66',
        'connected': true,
      });
      await ok('phone.wifi', {'ssid': 'ClinicGuest', 'bssid': '01:02:03:04'});
      await ok('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Seen',
          'when': [
            {'on': 'phone.app_opened', 'event': true},
          ],
          'then': ['notify:opened'],
        },
      });
      await ok('phone.app', {
        'package': 'com.example.dating',
        'label': 'Dating',
        'event': 'opened',
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      const private = [
        'HomeNet',
        'ClinicGuest',
        'aa:bb:cc',
        'com.example.health',
        'com.example.dating',
        'Car stereo',
      ];
      for (final (command, args) in [
        ('device.get', {'id': 'phone'}),
        ('device.history', {'id': 'phone'}),
        ('device.list', <String, Object?>{}),
        ('agent.describe', <String, Object?>{}),
        ('automation.log', {'id': 'seen'}),
      ]) {
        final r = await agent(command, args);
        expect(r['ok'], isTrue, reason: '$command $r');
        final text = jsonEncode(r);
        for (final p in private) {
          expect(text, isNot(contains(p)), reason: '$command shows $p');
        }
      }
      final read = await agent('device.get', {'id': 'phone'});
      expect(((read['device'] as Map)['state'] as Map)['battery'], isNull);
      await level('setup');
      final full = jsonEncode(await agent('device.history', {'id': 'phone'}));
      expect(full, contains('HomeNet'));
      expect(full, contains('com.example.health'));
    });

    test('a calendar title never reaches the run log, the events or '
        'what an agent reads', () async {
      await ok('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Cal',
          'when': [
            {
              'on': 'phone.calendar_started',
              'event': true,
              'match': {'words': 'meet'},
            },
          ],
          'then': ['notify:meeting'],
        },
      });
      await ok('phone.calendar', {
        'event': 'started',
        'words': 'meet',
        'title': 'Meet the lawyer about custody',
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final log = await agent('automation.log', {'id': 'cal'});
      expect(log['ok'], isTrue);
      expect((log['runs'] as List), isNotEmpty);
      expect(jsonEncode(log), isNot(contains('lawyer')));
      expect(jsonEncode(events), isNot(contains('lawyer')));
      final user = await engine.handle('automation.log', {'id': 'cal'});
      expect(jsonEncode(user), isNot(contains('lawyer')));
    });

    test('a song or calendar title a check compares stays out of seen, the '
        'run log and run.node events', () async {
      await ok('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Song',
          'when': [
            {'on': 'phone.media_started', 'event': true},
            {
              'on': 'phone.calendar_started',
              'event': true,
              'match': {'words': 'meet'},
            },
          ],
          'onlyIf': [
            {'msg': 'payload.title', 'op': '!=', 'value': 'nothing'},
          ],
          'then': ['notify:playing'],
        },
      });
      await ok('phone.media', {'playing': false});
      await ok('phone.media', {
        'playing': true,
        'package': 'com.example.music',
        'title': 'A very private song',
      });
      await ok('phone.calendar', {
        'event': 'started',
        'words': 'meet',
        'title': 'Meet the lawyer',
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final nodes = events.where((e) => e['event'] == 'run.node').toList();
      expect(nodes, isNotEmpty);
      for (final private in ['A very private song', 'lawyer']) {
        expect(jsonEncode(nodes), isNot(contains(private)));
        final log = await engine.handle('automation.log', {'id': 'song'});
        expect(jsonEncode(log), isNot(contains(private)));
        final diagram = await engine.handle('automation.diagram', {
          'id': 'song',
        });
        expect(jsonEncode(diagram), isNot(contains(private)));
      }
    });

    test(
      'phone actions that act on the person are high risk for agents',
      () async {
        final answering = engine.events
            .where((e) => e['event'] == 'phone.action')
            .listen(
              (e) => engine.handle('phone.actionDone', {
                'requestId': e['requestId'],
                'ok': true,
              }),
            );
        addTearDown(answering.cancel);
        await ok('phone.battery', {'level': 50});
        await ok('phone.ready', {'phone': null});
        await level('setup');
        for (final (capability, params) in [
          (
            'show_message',
            {'title': 'Security check', 'text': 'Enter your PIN'},
          ),
          ('open_link', {'url': 'https://example.com/login'}),
          ('open_app', {'package': 'com.example.bank'}),
          ('ringer', {'mode': 'silent'}),
          ('set_dnd', {'value': true}),
          ('set_alarm', {'time': '03:00'}),
          ('set_timer', {'minutes': 5}),
        ]) {
          final r = await agent('device.invoke', {
            'id': 'phone',
            'capability': capability,
            'params': params,
          });
          expect(r['ok'], isFalse, reason: capability);
          expect((r['error'] as Map)['type'], 'needs_user', reason: capability);
        }
        expect(
          events.where((e) => e['event'] == 'phone.action'),
          isEmpty,
          reason: 'nothing reached the phone',
        );
        final saved = await agent('automation.save', {
          'form': 'rule',
          'spec': {
            'name': 'Night message',
            'when': ['time:03:00'],
            'then': [
              {
                'do': 'phone.show_message',
                'params': {'title': 'Enter your PIN'},
              },
            ],
          },
        });
        expect(saved['highRisk'], isTrue);
        expect(saved['approved'], isFalse);
        final vibrate = await agent('device.invoke', {
          'id': 'phone',
          'capability': 'vibrate',
          'params': const <String, Object?>{},
        });
        expect(vibrate['ok'], isTrue, reason: 'other phone actions stay open');
        final mine = await engine.handle('automation.save', {
          'form': 'rule',
          'trusted': true,
          'spec': {
            'name': 'My message',
            'when': ['time:07:00'],
            'then': [
              {
                'do': 'phone.show_message',
                'params': {'title': 'Good morning'},
              },
            ],
          },
        });
        expect(mine['approved'], isTrue, reason: 'the user\'s own rule runs');
      },
    );

    test('an agent rule cannot send notification text to a device, and the '
        'user still can', () async {
      await ok('driver.register', {'manifest': _note});
      await ok('device.add', {
        'id': 'wall',
        'name': 'Wall display',
        'driver': 'note_display',
      });
      await level('setup');
      Map<String, Object?> grab(List<Object?> then) => {
        'form': 'rule',
        'spec': {
          'name': 'Grab',
          'when': [
            {'on': 'phone.notification', 'event': true},
          ],
          'then': then,
        },
      };
      for (final then in [
        [
          {
            'do': 'wall.show',
            'params': {'text': '{{msg.payload.text}}'},
          },
        ],
        // Through a run variable first.
        [
          {
            'text': {'value': '{{msg.payload.text}}', 'as': '%code'},
          },
          {
            'do': 'wall.show',
            'params': {'text': 'code {{%code}}'},
          },
        ],
        [
          {
            'http': {'url': 'https://example.com/?q={{msg.payload.title}}'},
          },
        ],
        [
          {
            'set': {'var': r'$Last', 'value': '{{msg.payload}}'},
          },
        ],
      ]) {
        final r = await agent('automation.save', grab(then));
        expect(r['ok'], isFalse, reason: '$then');
        expect(
          (r['error'] as Map)['message'],
          contains('cannot send what its trigger brought'),
        );
      }
      final shown = await agent(
        'automation.save',
        grab(['notify:{{msg.payload.label}}']),
      );
      expect(shown['ok'], isTrue, reason: 'a notify step may show it');
      final device = await agent('automation.save', {
        ...grab([
          {
            'do': 'wall.show',
            'params': {'text': 'something arrived from {{msg.device}}'},
          },
        ]),
        'replace': true,
      });
      expect(device['ok'], isTrue, reason: 'msg.device is not the words');
      final user = await engine.handle('automation.save', {
        ...grab([
          {
            'do': 'wall.show',
            'params': {'text': '{{msg.payload.text}}'},
          },
        ]),
        'trusted': true,
        'replace': true,
      });
      expect(user['ok'], isTrue, reason: 'the user\'s own rule may');
    });
  });

  group('ADB devices through agent.call', () {
    late Directory home;
    late OmniEngine engine;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_agent_adb');
      engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
      );
      for (final (id, driver) in [
        ('pixel', 'android_phone_adb'),
        ('tv', 'android_tv_adb'),
      ]) {
        final r = await engine.handle('device.add', {
          'id': id,
          'driver': driver,
          // TEST-NET: nothing answers, so nothing is ever sent.
          'host': '192.0.2.1',
        });
        expect(r['ok'], isTrue, reason: '$r');
      }
    });

    tearDown(() async {
      await engine.close();
      await home.delete(recursive: true);
    });

    Future<Map<String, Object?>> agent(
      String command, [
      Map<String, Object?> args = const {},
    ]) => engine.handle('agent.call', {'command': command, 'args': args});

    test('the screen of another phone is the user\'s at setup, and its '
        'files need setup', () async {
      final files = await agent('android.files.list', {
        'id': 'pixel',
        'path': '/sdcard',
      });
      expect((files['error'] as Map)['message'], contains('sets the home up'));
      await engine.handle('agent.access.set', {'access': 'setup'});
      for (final (command, args) in [
        ('android.screenshot', <String, Object?>{}),
        ('tv.text', {'text': 'hello'}),
        ('android.input.tap', {'x': 1, 'y': 1}),
        ('android.key', {'key': 'enter'}),
      ]) {
        final r = await agent(command, {'id': 'pixel', ...args});
        expect(r['ok'], isFalse, reason: command);
        expect(
          (r['error'] as Map)['message'],
          contains('for the user only'),
          reason: command,
        );
      }
    });

    test(
      'typing on a TV is high risk in an agent rule, its d-pad is not',
      () async {
        await engine.handle('agent.access.set', {'access': 'setup'});
        Future<Map<String, Object?>> save(String name, Object step) =>
            agent('automation.save', {
              'form': 'rule',
              'spec': {
                'name': name,
                'when': ['time:20:00'],
                'then': [step],
              },
            });
        final typed = await save('Type', {
          'do': 'tv.type_text',
          'params': {'text': 'hello'},
        });
        expect(typed['highRisk'], isTrue, reason: '$typed');
        expect(typed['approved'], isFalse);
        final pad = await save('Pad', {
          'do': 'tv.remote',
          'params': {'value': 'down'},
        });
        expect(pad['highRisk'], isFalse, reason: '$pad');
        final open = await save('Open on phone', {
          'do': 'pixel.open_url',
          'params': {'url': 'https://example.com'},
        });
        expect(open['highRisk'], isTrue, reason: '$open');
      },
    );
  });

  group('untrustedTriggerTextProblem', () {
    FlowSpec flow(List<Map<String, Object?>> nodes) => FlowSpec.parse({
      'schemaVersion': 1,
      'id': 'f',
      'name': 'F',
      'nodes': [
        for (final (i, n) in nodes.indexed)
          {'id': 'n$i', 'label': 'step $i', ...n},
      ],
      'edges': const <Object?>[],
    });

    test('follows run variables made from the trigger', () {
      expect(
        untrustedTriggerTextProblem(
          flow([
            {
              'type': 'format_text',
              'config': {'value': '{{msg.payload.text}}', 'as': '%a'},
            },
            {
              'type': 'set_variable',
              'config': {'name': '%b', 'value': '{{%a}}'},
            },
            {
              'type': 'device_capability',
              'config': {
                'deviceId': 'lamp',
                'capabilityId': 'power',
                'params': {'value': '{{%b}}'},
              },
            },
          ]),
        ),
        contains('step 2'),
      );
      expect(
        untrustedTriggerTextProblem(
          flow([
            {
              'type': 'format_text',
              'config': {'value': '{{msg.value}}', 'as': '%a'},
            },
            {
              'type': 'device_capability',
              'config': {
                'deviceId': 'lamp',
                'capabilityId': 'power',
                'params': {'value': '{{%a}}'},
              },
            },
          ]),
        ),
        isNull,
      );
    });
  });
}
