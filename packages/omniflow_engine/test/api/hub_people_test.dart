@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import 'things_test.dart' show until;

/// Several phones feeding one hub: each reading names its phone, presence
/// follows that phone's person, and asks and notifications name a person.
void main() {
  late Directory home;
  late OmniEngine engine;
  late List<Map<String, Object?>> events;
  late StreamSubscription<Map<String, Object?>> sub;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_hub_people');
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
    String type,
  ) async {
    final r = await engine.handle(command, args);
    expect(r['ok'], isFalse, reason: '$command: $r');
    final error = Map<String, Object?>.from(r['error'] as Map);
    expect(error['type'], type, reason: '$error');
    return error;
  }

  Future<Map<String, Object?>> stateOf(String id) async => Map.from(
    ((await ok('device.get', {'id': id}))['device'] as Map)['state'] as Map,
  );

  List<Map<String, Object?>> named(String event) => [
    for (final e in events)
      if (e['event'] == event) e,
  ];

  /// Two people, each with a phone, and a home place on Wi-Fi.
  Future<void> twoPhones() async {
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
    await ok('device.add', {'id': 'jade', 'name': 'Jade', 'driver': 'person'});
    await ok('device.add', {'id': 'asha', 'name': 'Asha', 'driver': 'person'});
    await ok('device.add', {
      'id': 'phone',
      'driver': 'phone',
      'settings': {'person': 'jade'},
    });
    await ok('device.add', {
      'id': 'asha_phone',
      'driver': 'phone',
      'settings': {'person': 'asha'},
    });
  }

  group('phone inputs per phone', () {
    test('presence follows the person of the phone that reads it', () async {
      await twoPhones();
      await ok('phone.wifi', {'ssid': 'HomeNet', 'phone': 'asha_phone'});
      await until(() async => (await stateOf('asha'))['home'] == true);
      expect((await stateOf('jade'))['home'], isFalse);
      expect(await stateOf('home'), {
        'inside': true,
        'people': ['asha'],
      });
      expect(named('zone.changed').last['person'], 'asha');
      expect(
        (await stateOf('asha_phone'))['wifi_ssid'],
        'HomeNet',
        reason: 'the reading lands on the phone that sent it',
      );

      // No phone id is the household phone, as with one phone.
      await ok('phone.wifi', {'ssid': 'HomeNet'});
      await until(() async => (await stateOf('jade'))['home'] == true);
      expect((await stateOf('home'))['people'], ['jade', 'asha']);
      expect(named('zone.changed').last.containsKey('person'), isFalse);

      // One person leaving keeps the place inside while the other stays.
      await ok('phone.wifi', {'ssid': 'Cafe', 'phone': 'asha_phone'});
      await until(() async => (await stateOf('asha'))['home'] == false);
      expect(await stateOf('home'), {
        'inside': true,
        'people': ['jade'],
      });
      final vars = (await ok('var.list'))['variables'] as Map;
      expect(vars['Zone_home'], isTrue);
      expect(vars['WifiSsid'], 'HomeNet', reason: "the household phone's");

      await ok('phone.wifi', {'ssid': 'Cafe', 'phone': 'phone'});
      await until(() async => (await stateOf('home'))['inside'] == false);
      expect(
        (await ok('var.list'))['variables'],
        containsPair('Zone_home', false),
      );
    });

    test('a BLE reading takes a phone id too', () async {
      await twoPhones();
      await ok('zone.save', {
        'zone': {
          'id': 'desk',
          'name': 'Desk',
          'ble': {'matchName': 'OMNI_DESK'},
        },
      });
      final at = DateTime.utc(2026, 1, 1);
      for (var s = 0; s <= 3; s++) {
        await ok('phone.ble', {
          'name': 'OMNI_DESK',
          'rssi': -50,
          'phone': 'asha_phone',
          'at': at.add(Duration(seconds: s)).toIso8601String(),
        });
      }
      await until(() async => (await stateOf('desk'))['inside'] == true);
      expect((await stateOf('desk'))['people'], ['asha']);
      expect((await stateOf('asha'))['place'], 'desk');
      expect((await stateOf('jade'))['place'], isNull);
    });

    test('a reading for a phone that does not exist is refused', () async {
      await twoPhones();
      for (final (command, args) in [
        ('phone.wifi', {'ssid': 'HomeNet'}),
        ('phone.ble', {'name': 'OMNI_DESK', 'rssi': -50}),
        ('phone.battery', {'level': 50}),
        ('phone.app', {'package': 'com.x', 'event': 'opened'}),
        ('phone.notification', {'package': 'com.x'}),
        ('phone.bluetooth', {'name': 'Car', 'connected': true}),
        ('phone.screen', {'on': true}),
        ('phone.dnd', {'on': true}),
        ('nfc.scanned', {'uid': '04:A2:2B:1C', 'source': 'phone'}),
      ]) {
        final error = await fails(command, {
          ...args,
          'phone': 'stolen_phone',
        }, 'invalid');
        expect(error['message'], contains('no phone stolen_phone'));
      }
      await fails('phone.wifi', {'ssid': 'x', 'phone': 'jade'}, 'invalid');
    });

    test('with no phone id the inputs keep today\'s single phone', () async {
      await ok('phone.battery', {'level': 40});
      expect((await stateOf('phone'))['battery'], 40);
      await ok('phone.screen', {'on': true, 'phone': 'phone'});
      expect((await stateOf('phone'))['screen_on'], isTrue);
    });
  });

  group('asks and notifications name a person', () {
    Future<void> rule(Map<String, Object?> spec) =>
        ok('automation.save', {'form': 'rule', 'trusted': true, 'spec': spec});

    test('an ask started by a phone goes to its person', () async {
      await twoPhones();
      await rule({
        'name': 'Movie',
        'when': [
          {'on': 'asha_phone.app_opened', 'event': true},
        ],
        'then': [
          {
            'ask': {
              'title': 'Dim the lights?',
              'choices': ['Yes', 'No'],
              'default': 'No',
              'timeoutMs': 1000,
            },
          },
        ],
      });
      await ok('phone.app', {
        'package': 'com.netflix',
        'event': 'opened',
        'phone': 'asha_phone',
      });
      await until(() => named('ask.request').isNotEmpty);
      expect(named('ask.request').single['person'], 'asha');
      expect((await ok('ask.pending'))['asks'], [
        containsPair('person', 'asha'),
      ]);
    });

    test('an ask-first automation asks the trigger\'s person', () async {
      await twoPhones();
      await rule({
        'name': 'TV on',
        'askFirst': true,
        'when': [
          {'on': 'phone.app_opened', 'event': true},
        ],
        'then': ['notify:running'],
      });
      await ok('phone.app', {'package': 'one', 'event': 'opened'});
      await until(() => named('ask.request').isNotEmpty);
      expect(named('ask.request').single['person'], 'jade');
    });

    test('to names the person, and without one there is none', () async {
      await twoPhones();
      await rule({
        'id': 'ask_to',
        'name': 'Ask Jade',
        'when': [
          {'on': 'asha_phone.app_opened', 'event': true},
        ],
        'then': [
          {
            'ask': {
              'title': 'Lock up?',
              'to': 'jade',
              'choices': ['Yes', 'No'],
              'default': 'No',
              'timeoutMs': 1000,
            },
          },
          {
            'notify': {'title': 'Locked', 'to': 'jade'},
          },
          {
            'notify': {'title': 'Everyone'},
          },
        ],
      });
      await ok('phone.app', {
        'package': 'x',
        'event': 'opened',
        'phone': 'asha_phone',
      });
      await until(() => named('ask.request').isNotEmpty);
      expect(named('ask.request').single['person'], 'jade');
      final askId = named('ask.request').single['askId'];
      await ok('ask.answer', {'askId': askId, 'answer': 'Yes'});
      await until(() => named('flow.announce').length == 2);
      final announced = named('flow.announce');
      expect(announced.first, containsPair('to', 'jade'));
      expect(announced.last.containsKey('to'), isFalse);

      final list = (await ok('automation.list'))['automations'] as List;
      final sentence = '${(list.single as Map)['sentence']}';
      expect(sentence, contains('ask Jade "Lock up?"'));
      expect(sentence, contains('notify Jade "Locked"'));
      expect(sentence, contains('notify "Everyone"'));
    });

    test('to must be a person, checked when it is saved', () async {
      await twoPhones();
      for (final to in ['nobody', 'phone']) {
        final error = await fails('automation.save', {
          'form': 'rule',
          'trusted': true,
          'spec': {
            'name': 'Bad',
            'when': ['time:07:00'],
            'then': [
              {
                'notify': {'title': 'Hi', 'to': to},
              },
            ],
          },
        }, 'invalid');
        expect('$error', contains('no person $to'));
      }
      final flow = await engine.handle('flow.validate', {
        'flow': {
          'schemaVersion': 1,
          'id': 'f',
          'name': 'f',
          'nodes': [
            {'id': 't', 'type': 'manual', 'config': {}},
            {
              'id': 'n',
              'type': 'notify',
              'config': {'title': 'x', 'to': 7},
            },
          ],
          'edges': [
            {
              'id': 'e',
              'from': {'node': 't', 'port': 'out'},
              'to': {'node': 'n', 'port': 'in'},
            },
          ],
        },
      });
      expect('$flow', contains('must be the id of a person'));
    });
  });
}
