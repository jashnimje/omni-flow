@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/phone_actions.dart';
import 'package:omniflow_engine/src/api/phone_words.dart';
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

  /// What the fake phone answers to each `phone.action`, by action. Null
  /// leaves the request unanswered.
  late Map<String, Map<String, Object?>?> answers;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_phone_actions');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
    events = [];
    answers = {};
    sub = engine.events.listen((e) {
      events.add(e);
      if (e['event'] != phoneActionEvent) return;
      final action = e['action'] as String;
      final answer = answers.containsKey(action)
          ? answers[action]
          : const {'ok': true};
      if (answer == null) return;
      unawaited(
        engine.handle('phone.actionDone', {
          'requestId': e['requestId'],
          ...answer,
        }),
      );
    });
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

  Future<Map<String, Object?>> rule(Map<String, Object?> spec) =>
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

  Future<Map<String, Object?>> invoke(
    String capability, [
    Map<String, Object?> params = const {},
  ]) => engine.handle('device.invoke', {
    'id': 'phone',
    'capability': capability,
    'params': params,
  });

  group('phone actions', () {
    test(
      'a phone that is not connected answers unavailable in plain words',
      () async {
        await ok('phone.battery', {'level': 50});
        final error = await fails('device.invoke', {
          'id': 'phone',
          'capability': 'speak',
          'params': {'text': 'Hello'},
        }, 'unavailable');
        expect(
          error['message'],
          'Phone is not connected right now, so it cannot say out loud. Open '
          'OmniFlow on that phone, and check it reaches the hub.',
        );
        expect(named(phoneActionEvent), isEmpty);
      },
    );

    test(
      'an action is an event to the phone, answered by phone.actionDone',
      () async {
        await ok('phone.ready');
        final result = await invoke('speak', {'text': 'Dinner is ready'});
        expect(result['ok'], isTrue, reason: '$result');
        final asked = named(phoneActionEvent).single;
        expect(asked['phone'], 'phone');
        expect(asked['action'], 'speak');
        expect(asked['params'], {'text': 'Dinner is ready'});
        expect(asked['requestId'], isA<String>());
        expect((asked['requestId'] as String).length, 24);
        expect((result['reply'] as Map)['done'], isTrue);

        await ok('device.invoke', {
          'id': 'phone',
          'capability': 'torch',
          'params': {'value': true},
        });
        expect(named(phoneActionEvent).last['params'], {'value': true});
        expect((await phoneState())['torch'], isTrue);
      },
    );

    test('the phone\'s error comes back as the step\'s error', () async {
      await ok('phone.ready');
      answers['torch'] = {
        'ok': false,
        'error': 'This phone has no torch',
        'errorType': 'device_error',
      };
      answers['dnd'] = {
        'ok': false,
        'error': 'OmniFlow needs Do Not Disturb access',
        'errorType': 'needs_user',
      };
      answers['play_sound'] = {'ok': false, 'errorType': 'made_up'};
      final torch = await invoke('torch', {'value': true});
      expect((torch['error'] as Map)['message'], 'This phone has no torch');
      final dnd = await invoke('set_dnd', {'value': true});
      expect((dnd['error'] as Map)['type'], 'needs_user');
      final sound = await invoke('play_sound');
      expect((sound['error'] as Map)['type'], 'device_error');
      expect((sound['error'] as Map)['message'], 'The phone could not do it');
    });

    test('params are checked before the phone is asked', () async {
      await ok('phone.ready');
      for (final (cap, params) in [
        ('media_volume', {'value': 140}),
        ('ringer', {'mode': 'loud'}),
        ('open_link', {'url': 'file:///etc/passwd'}),
        ('set_alarm', {'time': '25:00'}),
        ('set_timer', {'minutes': 0}),
        ('speak', <String, Object?>{}),
      ]) {
        final r = await invoke(cap, params);
        expect(r['ok'], isFalse, reason: '$cap $r');
        expect((r['error'] as Map)['type'], 'invalid', reason: cap);
      }
      expect(named(phoneActionEvent), isEmpty);
    });

    test('an answer for another phone, or no request, is refused', () async {
      await ok('phone.ready');
      answers['vibrate'] = null;
      final waiting = invoke('vibrate', {'pattern': 'long'});
      await until(() => named(phoneActionEvent).isNotEmpty);
      final id = named(phoneActionEvent).single['requestId'];
      await ok('device.add', {'id': 'sam_phone', 'driver': 'phone'});
      await fails('phone.actionDone', {
        'requestId': id,
        'ok': true,
        'phone': 'sam_phone',
      }, 'invalid');
      await fails('phone.actionDone', {
        'requestId': 'nope',
        'ok': true,
      }, 'not_found');
      await fails('phone.actionDone', {'requestId': id}, 'invalid');
      await ok('phone.actionDone', {
        'requestId': id,
        'ok': true,
        'phone': 'phone',
      });
      expect((await waiting)['ok'], isTrue);
    });

    test('a phone that never answers times out after 10 s', () async {
      await ok('phone.ready');
      answers['play_sound'] = null;
      final r = await invoke('play_sound');
      expect((r['error'] as Map)['type'], 'timeout');
      expect(
        (r['error'] as Map)['message'],
        contains('did not answer within 10 s'),
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a hub asks only the phone a step names', () async {
      await ok('phone.battery', {'level': 50});
      await ok('device.add', {
        'id': 'sam_phone',
        'name': 'Sam\'s phone',
        'driver': 'phone',
      });
      await ok('phone.ready', {'phone': 'sam_phone'});
      final r = await engine.handle('device.invoke', {
        'id': 'sam_phone',
        'capability': 'vibrate',
        'params': const <String, Object?>{},
      });
      expect(r['ok'], isTrue, reason: '$r');
      expect(named(phoneActionEvent).single['phone'], 'sam_phone');
      final notReady = await invoke('vibrate');
      expect((notReady['error'] as Map)['type'], 'unavailable');
    });

    test('a rule step runs on the phone and its words read plainly', () async {
      await ok('phone.ready');
      await rule({
        'name': 'Wake up',
        'when': ['manual'],
        'then': [
          {
            'do': 'phone.speak',
            'params': {'text': 'Good morning'},
          },
          {
            'do': 'phone.set_timer',
            'params': {'minutes': 10},
          },
          {
            'do': 'phone.media',
            'params': {'key': 'next'},
          },
        ],
      });
      final run = await ok('automation.run', {'id': 'wake_up'});
      expect(((run['runs'] as List).single as Map)['outcome'], 'completed');
      expect(
        [for (final e in named(phoneActionEvent)) e['action']],
        ['speak', 'set_timer', 'media'],
      );
      final list = (await ok('automation.list'))['automations'] as List;
      final sentence = jsonEncode((list.single as Map)['sentence']);
      expect(sentence, contains('Phone says \\"Good morning\\"'));
      expect(sentence, contains('set a 10 min timer on Phone'));
      expect(sentence, contains('skip to the next track on Phone'));
    });

    test('an agent cannot answer for the phone or feed its readings', () async {
      for (final command in [
        'phone.actionDone',
        'phone.ready',
        'phone.alarm',
        'phone.call',
        'phone.media',
        'phone.calendar',
        'phone.shake',
        'phone.faceDown',
        'phone.headphones',
        'phone.boot',
        'phone.package',
      ]) {
        final r = await engine.handle('agent.call', {
          'command': command,
          'args': {'requestId': 'x', 'ok': true},
        });
        expect((r['error'] as Map)['type'], 'needs_user', reason: command);
      }
    });
  });

  group('phone triggers', () {
    test('before the next alarm fires once, N minutes ahead', () async {
      await rule({
        'name': 'Wake light',
        'when': [
          onEvent('alarm_soon', {'minutes': 20}),
        ],
        'then': ['notify:alarm in {{msg.payload.minutes}} min'],
      });
      final alarm = DateTime.now().add(
        const Duration(minutes: 20, milliseconds: 300),
      );
      final reply = await ok('phone.alarm', {'at': alarm.toIso8601String()});
      expect(reply['next_alarm'], alarm.toUtc().toIso8601String());
      expect((await phoneState())['next_alarm'], reply['next_alarm']);
      await until(() => titles().contains('alarm in 20 min'));
      await ok('phone.ready');
      await ok('phone.alarm', {'at': alarm.toIso8601String()});
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(titles().where((t) => t == 'alarm in 20 min'), hasLength(1));
      await ok('phone.alarm', {});
      expect((await phoneState())['next_alarm'], isNull);
      await fails('phone.alarm', {'at': 'soon'}, 'invalid');
    });

    test('event params are checked: minutes for an alarm, words for a '
        'calendar', () async {
      final noMinutes = await fails('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Bad alarm',
          'when': [onEvent('alarm_soon')],
          'then': ['notify:x'],
        },
      }, 'invalid');
      expect(jsonEncode(noMinutes), contains('when[0].match.minutes'));
      final tooLong = await fails('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Bad alarm',
          'when': [
            onEvent('alarm_soon', {'minutes': 5000}),
          ],
          'then': ['notify:x'],
        },
      }, 'invalid');
      expect(jsonEncode(tooLong), contains('must be at most 720'));
      final noWords = await fails('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Bad calendar',
          'when': [onEvent('calendar_started')],
          'then': ['notify:x'],
        },
      }, 'invalid');
      expect(jsonEncode(noWords), contains('when[0].match.words'));
      // An event that declares no params still takes any match.
      await rule({
        'name': 'Any app',
        'when': [
          onEvent('app_opened', {'package': 'com.x', 'label': 'X'}),
        ],
        'then': ['notify:x'],
      });
    });

    test('calls fire their events and never keep a number', () async {
      await rule({
        'name': 'Pause for calls',
        'when': [
          onEvent('call_ringing'),
          onEvent('call_answered'),
          onEvent('call_ended'),
        ],
        'then': ['notify:{{msg.key}}'],
        'mode': 'queued',
      });
      await ok('phone.call', {'state': 'ringing', 'number': '5551234'});
      expect((await phoneState())['call'], 'ringing');
      await ok('phone.call', {'state': 'answered'});
      expect((await phoneState())['call'], 'in_call');
      await ok('phone.call', {'state': 'ended'});
      expect((await phoneState())['call'], 'none');
      await until(() => titles().length == 3);
      expect(titles(), ['call_ringing', 'call_answered', 'call_ended']);
      expect(jsonEncode(events), isNot(contains('5551234')));
      await fails('phone.call', {'state': 'busy'}, 'invalid');
    });

    test('media, calendar, headphones, face down, boot and installs', () async {
      await rule({
        'name': 'All of them',
        'when': [
          onEvent('media_started'),
          onEvent('media_stopped'),
          onEvent('calendar_started', {'words': 'gym'}),
          onEvent('calendar_ended', {'words': 'gym'}),
          onEvent('started_up'),
          onEvent('app_installed'),
          onEvent('app_updated'),
          {
            'on': 'phone.headphones',
            'change': {'to': true},
          },
          {
            'on': 'phone.face_down',
            'change': {'to': true},
          },
        ],
        'then': ['notify:{{msg.key}}'],
        'mode': 'queued',
      });
      await rule({
        'name': 'Titles',
        'when': [
          onEvent('media_started', {'label': 'Spotify'}),
          onEvent('calendar_started', {'words': 'gym'}),
        ],
        'then': ['notify:title {{msg.payload.title}}'],
        'mode': 'queued',
      });
      // Nothing playing at the first reading is not a stop.
      await ok('phone.media', {'playing': false});
      await ok('phone.media', {
        'playing': true,
        'package': 'com.spotify.music',
        'label': 'Spotify',
        'title': 'A song',
      });
      expect((await phoneState())['media_playing'], isTrue);
      expect(jsonEncode(await phoneState()), isNot(contains('A song')));
      await ok('phone.media', {'playing': false});
      await ok('phone.calendar', {
        'event': 'started',
        'words': 'gym',
        'title': 'Gym with Sam',
      });
      await ok('phone.calendar', {'event': 'ended', 'words': 'gym'});
      await ok('phone.calendar', {'event': 'started', 'words': 'work'});
      await ok('phone.boot');
      await ok('phone.package', {'package': 'com.x', 'updated': false});
      await ok('phone.package', {'package': 'com.x', 'updated': true});
      await ok('phone.headphones', {'plugged': true});
      await ok('phone.faceDown', {'on': true});
      await until(() => titles().length == 10);
      expect(titles().toSet(), {
        'media_started',
        'title A song',
        'media_stopped',
        'calendar_started',
        'calendar_ended',
        'started_up',
        'app_installed',
        'app_updated',
        'headphones',
        'face_down',
      });
      // The calendar title stays on the phone: not in an event, the run log
      // or what a run renders.
      expect(jsonEncode(events), isNot(contains('Gym with Sam')));
      final log = await ok('automation.log', {'id': 'titles'});
      expect(jsonEncode(log), isNot(contains('Gym with Sam')));
      final state = await phoneState();
      expect(state['headphones'], isTrue);
      expect(state['face_down'], isTrue);
      await fails('phone.media', {'playing': 'yes'}, 'invalid');
      await fails('phone.calendar', {'event': 'started'}, 'invalid');
      await fails('phone.package', {'updated': true}, 'invalid');
      await fails('phone.headphones', {}, 'invalid');
    });

    test('a shake fires its event and runs the phone\'s shake scene', () async {
      await ok('scene.save', {
        'name': 'Lights on',
        'actions': ['lamp.power=true'],
        'trusted': true,
      });
      final none = await ok('phone.shake');
      expect(none['scene'], isNull);
      await ok('thing.configure', {
        'id': 'phone',
        'settings': {'shake_scene': 'lights_on'},
      });
      final shaken = await ok('phone.shake');
      expect(shaken['ran'], isTrue, reason: '$shaken');
      final lamp = await ok('device.get', {'id': 'lamp'});
      expect(((lamp['device'] as Map)['state'] as Map)['power'], isTrue);
      expect(
        named('thing.event').where((e) => e['key'] == 'shaken'),
        hasLength(2),
      );
    });

    test('phone.ready says which readings the automations use', () async {
      final empty = (await ok('phone.ready'))['watch'] as Map;
      expect(empty['shake'], isFalse);
      expect(empty['calendarWords'], isEmpty);
      await rule({
        'name': 'Many',
        'when': [
          onEvent('shaken'),
          onEvent('calendar_started', {'words': 'gym'}),
          onEvent('calendar_ended', {'words': 'dentist'}),
          onEvent('alarm_soon', {'minutes': 20}),
          onEvent('call_ringing'),
        ],
        'onlyIf': [
          {'state': 'phone.face_down', 'op': '==', 'value': true},
        ],
        'then': ['notify:x'],
      });
      final watch = (await ok('phone.ready'))['watch'] as Map;
      expect(watch, {
        'shake': true,
        'faceDown': true,
        'calls': true,
        'media': false,
        'alarm': true,
        'headphones': false,
        'boot': false,
        'packages': false,
        'apps': false,
        'calendarWords': ['dentist', 'gym'],
        'alarmMinutes': [20],
      });
      await ok('automation.enable', {'id': 'many', 'enabled': false});
      final off = (await ok('phone.ready'))['watch'] as Map;
      expect(off['shake'], isFalse);
      await ok('thing.configure', {
        'id': 'phone',
        'settings': {'shake_scene': 'many'},
      });
      expect(((await ok('phone.ready'))['watch'] as Map)['shake'], isTrue);
    });

    test('trigger sentences read plainly', () async {
      expect(
        phoneTriggerWords('Phone', 'alarm_soon', {'minutes': 20}),
        '20 min before the next alarm on Phone',
      );
      expect(
        phoneTriggerWords('Phone', 'alarm_soon', {'minutes': 60}),
        '1 h before the next alarm on Phone',
      );
      expect(
        phoneTriggerWords('Phone', 'calendar_started', {'words': 'gym'}),
        'a calendar event with "gym" starts on Phone',
      );
      expect(phoneTriggerWords('Phone', 'app_opened', null), isNull);
      await rule({
        'name': 'Ring',
        'when': [onEvent('call_ringing')],
        'then': ['notify:x'],
      });
      final list = (await ok('automation.list'))['automations'] as List;
      expect(
        jsonEncode((list.single as Map)['sentence']),
        contains('When a call rings on Phone'),
      );
    });
  });

  test('every CLI verb builds its args or refuses its words', () {
    final verbs = {for (final v in phoneReadingVerbs) v.verb: v};
    expect(verbs['call']!.args(['ringing']), {'state': 'ringing'});
    expect(verbs['call']!.args([]), isNull);
    expect(verbs['facedown']!.args(['on']), {'on': true});
    expect(verbs['headphones']!.args(['off']), {'plugged': false});
    expect(verbs['headphones']!.args(['maybe']), isNull);
    expect(verbs['installed']!.args(['com.x', 'updated']), {
      'package': 'com.x',
      'updated': true,
    });
    expect(verbs['media']!.args(['playing', 'com.x']), {
      'playing': true,
      'package': 'com.x',
    });
    expect(verbs['shake']!.args(['x']), isNull);
    expect(verbs['alarm']!.args([]), <String, Object?>{});
  });
}
