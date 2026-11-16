@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

/// A light with no wire under it, so a command's state is its state.
const _light = {
  'schemaVersion': 1,
  'id': 'walk_test_bulb',
  'name': 'Test bulb',
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

/// A gadget reached over HTTP, for a step that gets no answer.
const _gadget = {
  'schemaVersion': 1,
  'id': 'walk_test_gadget',
  'name': 'Gadget',
  'category': 'misc',
  'transport': {'type': 'http'},
  'capabilities': [
    {
      'id': 'ping',
      'type': 'action',
      'label': 'Ping',
      'command': {'path': '/ping'},
    },
  ],
};

void main() {
  late Directory home;
  late OmniEngine engine;
  final events = <Map<String, Object?>>[];
  StreamSubscription<Map<String, Object?>>? sub;

  Future<OmniEngine> open() => OmniEngine.open(
    home: home,
    secrets: InMemorySecretStore(),
    mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
  );

  Future<Map<String, Object?>> ok(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final r = await engine.handle(command, args);
    expect(r['ok'], isTrue, reason: '$command $args -> $r');
    return r;
  }

  Future<Map<String, Object?>> err(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final r = await engine.handle(command, args);
    expect(r['ok'], isFalse, reason: '$command $args -> $r');
    return Map<String, Object?>.from(r['error'] as Map);
  }

  Future<void> twoHouses() async {
    await ok('house.rename', {'id': 'home', 'name': 'Mumbai'});
    await ok('house.add', {'name': 'Bangalore'});
    await ok('driver.register', {'manifest': _light});
    await ok('device.add', {
      'id': 'bed_lamp',
      'name': 'Bed lamp',
      'driver': 'walk_test_bulb',
      'host': 'virtual',
      'house': 'bangalore',
    });
    await ok('device.add', {
      'id': 'hall_lamp',
      'name': 'Hall lamp',
      'driver': 'walk_test_bulb',
      'host': 'virtual',
    });
  }

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_walk');
    engine = await open();
    events.clear();
    sub = engine.events.listen(events.add);
  });

  tearDown(() async {
    await sub?.cancel();
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('device.changed', () {
    test('adding, organizing, moving and removing a thing each say so, '
        'and so do rooms', () async {
      await ok('driver.register', {'manifest': _light});
      await ok('device.add', {
        'id': 'desk',
        'name': 'Desk',
        'driver': 'walk_test_bulb',
        'host': 'virtual',
      });
      await ok('device.organize', {'id': 'desk', 'name': 'Desk lamp'});
      await ok('room.save', {'name': 'Study'});
      await ok('device.remove', {'id': 'desk'});
      await settle();
      final changed = [
        for (final e in events)
          if (e['event'] == OmniEngine.deviceChangedEvent)
            (e['command'], e['id']),
      ];
      expect(
        changed,
        containsAllInOrder([
          ('device.add', 'desk'),
          ('device.organize', 'desk'),
          ('room.save', 'study'),
          ('device.remove', 'desk'),
        ]),
      );
    });

    test('a failed command and a read say nothing', () async {
      await err('device.organize', {'id': 'nothing_here', 'name': 'X'});
      await ok('device.list');
      await settle();
      expect(
        events.where((e) => e['event'] == OmniEngine.deviceChangedEvent),
        isEmpty,
      );
    });
  });

  group('presence per house', () {
    test('each house says where you are for its own places', () async {
      await twoHouses();
      await ok('device.add', {
        'id': 'jade',
        'name': 'Jade',
        'driver': 'person',
      });
      await ok('zone.save', {
        'zone': {
          'id': 'home',
          'name': 'Mumbai',
          'wifi': {
            'ssids': ['MumbaiNet'],
          },
        },
      });
      await ok('phone.wifi', {'ssid': 'MumbaiNet'});
      Future<Map> person(String house) async {
        final list = await ok('device.list', {'house': house});
        return ((list['devices'] as List).cast<Map>().firstWhere(
              (d) => d['id'] == 'jade',
            ))['state']
            as Map;
      }

      expect((await person('home'))['home'], isTrue);
      final bangalore = await person('bangalore');
      expect(bangalore['home'], isNull);
      expect(bangalore['presence'], 'not_set_up');
      expect(bangalore['homeSource'], isNull);
      final houses = {
        for (final h in (await ok('house.list'))['houses'] as List)
          (h as Map)['id']: h['presence'],
      };
      expect(houses, {'home': 'home', 'bangalore': 'not_set_up'});

      // Bangalore's own Wi-Fi: away there until the phone joins it.
      await ok('zone.save', {
        'zone': {
          'id': 'flat',
          'name': 'Bangalore flat',
          'wifi': {
            'ssids': ['FlatNet'],
          },
        },
        'house': 'bangalore',
      });
      expect((await person('bangalore'))['presence'], 'away');
      expect((await person('bangalore'))['home'], isFalse);
      await ok('phone.wifi', {'ssid': 'FlatNet'});
      expect((await person('bangalore'))['presence'], 'home');
      expect((await person('bangalore'))['home'], isTrue);
    });
  });

  group('follow the sun keeps to its house', () {
    test('a house with no location refuses, and its rooms stay in it after '
        'a restart', () async {
      await twoHouses();
      await ok('room.save', {'name': 'Bedroom', 'house': 'bangalore'});
      await ok('home.location.set', {'latitude': 19.07, 'longitude': 72.87});
      final refused = await err('sunlight.set', {
        'targets': ['bedroom'],
        'enabled': true,
        'house': 'bangalore',
      });
      expect(refused['message'], contains('where Bangalore is'));

      await engine.close();
      engine = await open();
      // After a restart Bangalore still has no location of its own.
      final again = await err('sunlight.set', {
        'targets': ['bedroom'],
        'enabled': true,
        'house': 'bangalore',
      });
      expect(again['message'], contains('where Bangalore is'));

      await ok('home.location.set', {
        'latitude': 12.97,
        'longitude': 77.59,
        'house': 'bangalore',
      });
      await ok('sunlight.set', {
        'targets': ['bedroom'],
        'enabled': true,
        'house': 'bangalore',
      });
      List<Object?> targets(Map<String, Object?> r) => [
        for (final t in r['targets'] as List) (t as Map)['id'],
      ];
      expect(targets(await ok('sunlight.get', {'house': 'bangalore'})), [
        'bedroom',
      ]);
      expect(targets(await ok('sunlight.get', {'house': 'home'})), isEmpty);
    });

    test('a room of another house is refused', () async {
      await twoHouses();
      await ok('room.save', {'name': 'Bedroom', 'house': 'bangalore'});
      await ok('home.location.set', {'latitude': 19.07, 'longitude': 72.87});
      final refused = await err('sunlight.set', {
        'targets': ['bedroom'],
        'enabled': true,
        'house': 'home',
      });
      expect(refused['message'], contains('Bedroom is in Bangalore'));
    });

    test('a house that does not exist is not the first house', () async {
      final r = await engine.handle('sunlight.get', {'house': 'nowhere'});
      expect(r['ok'], isFalse);
    });
  });

  test('home Wi-Fi is on for a place of any house', () async {
    await twoHouses();
    await ok('zone.save', {
      'zone': {
        'id': 'flat',
        'name': 'Bangalore flat',
        'wifi': {
          'ssids': ['FlatNet'],
        },
      },
      'house': 'bangalore',
    });
    await ok('phone.wifi', {'ssid': 'FlatNet'});
    expect(engine.flows.globals['HomeWifiConnected'], isTrue);
    await ok('phone.wifi', {'ssid': 'Cafe'});
    expect(engine.flows.globals['HomeWifiConnected'], isFalse);
  });

  group('times follow the phone clock', () {
    Map<String, Object?> rule() => {
      'name': 'Evening',
      'when': [
        {'time': '19:30'},
      ],
      'onlyIf': [
        {
          'between': ['18:00', '23:00'],
        },
      ],
      'then': [
        {'notify': 'hi'},
      ],
    };

    test(
      'rule.words with hour12 reads 7:30 PM, and 24 hours without',
      () async {
        final twelve = await ok('rule.words', {'rule': rule(), 'hour12': true});
        final parts = [
          for (final p in twelve['parts'] as List) (p as Map)['text'],
        ];
        expect(
          parts,
          containsAll(['At 7:30 PM', 'Between 6:00 PM and 11:00 PM']),
        );
        final day = await ok('rule.words', {'rule': rule(), 'hour12': false});
        expect([
          for (final p in day['parts'] as List) (p as Map)['text'],
        ], containsAll(['At 19:30', 'Between 18:00 and 23:00']));
      },
    );

    test('clockWords and nextRunText', () {
      expect(clockWords('00:05', hour12: true), '12:05 AM');
      expect(clockWords('12:00', hour12: true), '12:00 PM');
      expect(clockWords('19:30', hour12: false), '19:30');
      expect(clockWords('{{msg.at}}', hour12: true), '{{msg.at}}');
      final now = DateTime(2026, 11, 17, 9);
      expect(
        nextRunText(DateTime(2026, 11, 17, 19, 30), hour12: true, now: now),
        'today 7:30 PM',
      );
      expect(
        nextRunText(DateTime(2026, 11, 18, 6, 30), hour12: false, now: now),
        'tomorrow 06:30',
      );
    });
  });

  test(
    'a step to a device that does not answer reads in plain words',
    () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      await ok('driver.register', {'manifest': _gadget});
      await ok('driver.approve', {'id': 'walk_test_gadget'});
      await ok('device.add', {
        'id': 'gadget',
        'name': 'Light F444',
        'driver': 'walk_test_gadget',
        'host': '127.0.0.1',
        'port': port,
      });
      await ok('automation.save', {
        'form': 'rule',
        'spec': {
          'id': 'ping',
          'name': 'Ping',
          'when': ['manual'],
          'then': [
            {'do': 'gadget.ping'},
          ],
        },
        'trusted': true,
      });
      final ran = await ok('automation.run', {'id': 'ping'});
      final run = (ran['runs'] as List).single as Map;
      final failed = (run['nodes'] as List).cast<Map>().firstWhere(
        (n) => n['error'] != null,
      );
      expect(failed['error'], 'Light F444 did not answer. Is it switched on?');
      expect(failed['errorDetails'], contains('127.0.0.1'));
      expect('${run['reason']}', isNot(contains('127.0.0.1')));
    },
  );
}
