@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/automation_view.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

/// A light on the virtual transport: commands are taken as sent.
const _light = {
  'schemaVersion': 1,
  'id': 'one_source_lamp',
  'name': 'Lamp',
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
    {
      'id': 'brightness',
      'type': 'level',
      'label': 'Brightness',
      'params': {
        'value': {'type': 'number', 'integer': true, 'min': 1, 'max': 100},
      },
      'command': {'set': 'brightness', 'value': '{{value}}'},
      'stateJsonPath': r'$.brightness',
    },
  ],
};

void main() {
  group('days in words', () {
    test('every reader writes days the same way', () {
      expect(daysWords(const []), 'every day');
      expect(daysWords(ruleWeekDays), 'every day');
      expect(
        daysWords(const ['mon', 'tue', 'wed', 'thu', 'fri']),
        'on weekdays',
      );
      expect(daysWords(const ['sun', 'sat']), 'on weekends');
      expect(daysWords(const ['fri', 'mon', 'wed']), 'on Mon, Wed and Fri');
      expect(daysWords(const ['tue']), 'on Tue');
      expect(
        sunTriggerLabel({
          'sun': 'sunset',
          'offset': -30,
          'days': ['sat', 'sun'],
        }),
        '30 min before sunset on weekends',
      );
      expect(
        const SentenceContext().trigger({
          'time': '07:00',
          'days': ['mon', 'tue', 'wed', 'thu', 'fri'],
        }),
        'At 07:00 on weekdays',
      );
      expect(
        const SentenceContext().condition({
          'days': ['mon', 'wed', 'fri'],
        }),
        'on Mon, Wed and Fri',
      );
    });
  });

  group('values, order and completeness', () {
    test('on, yes, off and no read as true and false everywhere', () {
      expect(typedValue('on'), isTrue);
      expect(typedValue(' Yes '), isTrue);
      expect(typedValue('OFF'), isFalse);
      expect(typedValue('no'), isFalse);
      expect(typedValue('12.5'), 12.5);
      expect(typedValue('null'), isNull);
      expect(typedValue('Movie night'), 'Movie night');
      final then = [
        for (final s in ['lamp.power=on', r'set:$Away=no', r'set:$Word="on"'])
          expandStep(s),
      ];
      expect((then[0] as Map)['params'], {'value': true});
      expect(((then[1] as Map)['set'] as Map)['value'], isFalse);
      expect(((then[2] as Map)['set'] as Map)['value'], 'on');
    });

    test('keep steps go last, in their own order', () {
      final steps = ['a', 'keep1', 'b', 'keep2', 'c'];
      keepStepsLast(steps, (s) => s.startsWith('keep'));
      expect(steps, ['a', 'b', 'c', 'keep1', 'keep2']);
    });

    test('what keeps a rule from saving is worded once', () {
      expect(ruleMissing(const {}), 'Choose a WHEN and a THEN to save.');
      expect(
        ruleMissing({
          'then': [
            {'wait': 1000},
          ],
        }),
        'Choose a WHEN to save.',
      );
      expect(
        ruleMissing({
          'when': ['manual'],
        }),
        'Choose a THEN step to save.',
      );
      expect(
        ruleMissing({
          'when': ['manual'],
          'then': [
            {'if': [], 'then': []},
          ],
        }),
        startsWith('A group needs filling in'),
      );
      expect(
        ruleMissing({
          'then': [
            {
              'keep': {
                'target': 'lamp.power',
                'value': true,
                'while': [
                  {'state': 'lamp.power', 'op': '==', 'value': false},
                ],
              },
            },
          ],
        }),
        isNull,
        reason: 'a rule of keep steps alone needs no trigger',
      );
      expect(
        stepsFilled([
          {
            'repeat': {
              'do': [
                {'wait': 1000},
              ],
            },
          },
        ]),
        isFalse,
        reason: 'a repeat needs a count or an until',
      );
    });
  });

  group('the engine', () {
    late Directory home;
    late OmniEngine engine;

    Future<Map<String, Object?>> ok(
      String command, [
      Map<String, Object?> args = const {},
    ]) async {
      final r = await engine.handle(command, args);
      expect(r['ok'], isTrue, reason: '$command: $r');
      return r;
    }

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_one_source');
      engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
        mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
      );
      await ok('driver.register', {'manifest': _light});
      await ok('device.add', {
        'id': 'desk',
        'name': 'Desk lamp',
        'driver': 'one_source_lamp',
      });
    });

    tearDown(() async {
      await engine.close();
      await home.delete(recursive: true);
    });

    test('rule.words words each part with what a tap edits', () async {
      final rule = {
        'name': 'Morning',
        'when': [
          {
            'time': '07:00',
            'days': ['mon', 'tue', 'wed', 'thu', 'fri'],
          },
          {
            'on': 'desk.power',
            'change': {'to': true},
          },
        ],
        'onlyIf': [
          {
            'between': ['06:00', '09:00'],
          },
        ],
        'then': [
          {
            'do': 'desk.brightness',
            'params': {'value': 70},
          },
          {
            'if': [
              {'state': 'desk.power', 'op': '==', 'value': false},
            ],
            'then': [
              {'wait': 300000},
            ],
          },
          {
            'notify': {'title': 'Hi {{%answer}}'},
          },
        ],
      };
      final r = await ok('rule.words', {'rule': rule});
      final parts = {
        for (final p in (r['parts'] as List).cast<Map>()) p['path']: p,
      };
      expect(parts['when[0]']!['text'], 'At 07:00 on weekdays');
      expect(
        [
          for (final w in (parts['when[0]']!['words'] as List).cast<Map>())
            w['blank'],
        ],
        [null, 'time', null, 'days'],
      );
      expect(parts['when[0]']!['part'], (rule['when'] as List)[0]);
      expect(parts['when[1]']!['text'], 'Desk lamp turns on');
      expect(parts['onlyIf[0]']!['text'], 'Between 06:00 and 09:00');
      expect(parts['then[0]']!['text'], 'Desk lamp brightness 70');
      expect(
        [
          for (final w in (parts['then[0]']!['words'] as List).cast<Map>())
            w['blank'],
        ],
        ['device', null, 'value'],
      );
      expect(parts['then[1].if[0]']!['text'], 'Desk lamp is off');
      expect(parts['then[1].then[0]']!['text'], 'Wait 5 min');
      expect(parts['then[2]']!['text'], 'Notify "Hi the answer"');
      final token = (parts['then[2]']!['words'] as List).cast<Map>().firstWhere(
        (w) => w['token'] != null,
      );
      expect(token['token'], '%answer');
      expect(r['missing'], isNull);
      expect(r['sentence'], isNotEmpty);

      final unfinished = await ok('rule.words', {
        'rule': {'name': 'New'},
      });
      expect(unfinished['missing'], 'Choose a WHEN and a THEN to save.');
      expect(unfinished['parts'], isEmpty);
    });

    test('the card and the editor read the same days', () async {
      await ok('automation.save', {
        'form': 'rule',
        'spec': {
          'id': 'weekday_lamp',
          'name': 'Weekday lamp',
          'when': [
            {
              'time': '07:00',
              'days': ['mon', 'tue', 'wed', 'thu', 'fri'],
            },
          ],
          'then': ['desk.power=on'],
        },
        'trusted': true,
      });
      final list = await ok('automation.list');
      final card = (list['automations'] as List).cast<Map>().single;
      final chips = (card['sentence'] as List).cast<Map>();
      expect(chips.first['text'], 'At 07:00 on weekdays');
      final saved = await ok('automation.get', {'id': 'weekday_lamp'});
      final then = (saved['spec'] as Map)['then'] as List;
      expect((then.single as Map)['params'], {'value': true});
    });

    test('removing a device forgets its sun and away lighting', () async {
      await ok('home.location.set', {'latitude': 51.5, 'longitude': -0.12});
      await ok('sunlight.set', {
        'targets': ['desk'],
        'enabled': true,
      });
      await ok('awaylight.set', {
        'lights': ['desk'],
        'enabled': true,
      });
      await ok('device.remove', {'id': 'desk'});
      await ok('device.add', {
        'id': 'desk',
        'name': 'Desk lamp',
        'driver': 'one_source_lamp',
      });
      final sun = await ok('sunlight.get');
      expect(
        (sun['targets'] as List).cast<Map>().where((t) => t['id'] == 'desk'),
        isEmpty,
      );
      expect((await ok('awaylight.get'))['lights'], isEmpty);
    });

    test('a room an agent sets is the agent\'s change, not a habit', () async {
      await ok('room.save', {'name': 'Study'});
      final rooms = (await ok('room.list'))['rooms'] as List;
      final room = (rooms.single as Map)['id'] as String;
      await ok('device.organize', {'id': 'desk', 'room': room});
      await ok('agent.access.set', {'access': 'setup'});
      await ok('agent.call', {
        'command': 'room.invoke',
        'args': {
          'room': room,
          'capability': 'power',
          'params': {'value': true},
        },
      });
      final history = await ok('device.history', {'id': 'desk'});
      final entries = (history['entries'] as List).cast<Map>();
      expect(entries.map((e) => e['by']), contains('agent'));
      expect(entries.map((e) => e['by']), isNot(contains('user')));
    });

    test('a person nothing can detect reads as not set up', () async {
      await ok('device.add', {
        'id': 'jade',
        'name': 'Jade',
        'driver': 'person',
      });
      Future<Map> person() async =>
          ((await ok('device.get', {'id': 'jade'}))['device'] as Map)['state']
              as Map;
      expect((await person())['home'], isNull);
      expect((await person())['presence'], 'not_set_up');
      final listed = ((await ok('device.list'))['devices'] as List)
          .cast<Map>()
          .firstWhere((d) => d['id'] == 'jade');
      expect((listed['state'] as Map)['presence'], 'not_set_up');
      await ok('zone.save', {
        'zone': {
          'id': 'home',
          'name': 'Home',
          'wifi': {
            'ssids': ['HomeNet'],
          },
        },
      });
      expect((await person())['presence'], isNull);
      expect((await person())['home'], isFalse);
    });

    test('device.move keeps the name and room at a new address', () async {
      final moved = await ok('device.move', {'id': 'desk', 'host': '10.0.0.9'});
      expect(moved['message'], 'Desk lamp is at 10.0.0.9 now');
      final device = (await ok('device.get', {'id': 'desk'}))['device'] as Map;
      expect(device['host'], '10.0.0.9');
      expect(device['name'], 'Desk lamp');
      final bad = await engine.handle('device.move', {
        'id': 'desk',
        'host': '10.0.0.9',
        'port': 70000,
      });
      expect(bad['ok'], isFalse);
    });

    test(
      'the retired aliases are gone and the new commands are classified',
      () async {
        for (final old in ['phone.nfc', 'phone.nfc_write', 'flow.cards']) {
          expect(engine.commandNames, isNot(contains(old)));
        }
        expect(agentReadCommands, contains('rule.words'));
        expect(agentUserOnly.keys, contains('device.move'));
        final weather = (await ok('driver.list'))['drivers'] as List;
        final caps =
            (weather.cast<Map>().firstWhere(
                  (d) => d['id'] == 'weather',
                ))['capabilities']
                as List;
        expect(caps, contains('stale'));
      },
    );
  });
}
