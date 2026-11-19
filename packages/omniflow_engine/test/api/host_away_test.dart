@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/alerts.dart';
import 'package:omniflow_engine/src/api/host_presence.dart';
import 'package:omniflow_engine/src/api/mode_commands.dart' show HomeFile;
import 'package:omniflow_engine/src/api/rules_core_commands.dart';
import 'package:omniflow_engine/src/api/things_runtime.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import 'automation_harness.dart';
import 'things_test.dart' show until;

/// A switch at a loopback port nothing listens on, polled every second, so
/// each hub poll fails as one that stopped answering does.
const _deadPolledSwitch = {
  'schemaVersion': 1,
  'id': 'dead_polled_switch',
  'name': 'Dead polled switch',
  'category': 'switch',
  'transport': {'type': 'http', 'port': 9},
  'statePoll': {
    'command': {'method': 'GET', 'path': '/state'},
    'intervalSeconds': 1,
  },
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'command': {
        'method': 'POST',
        'path': '/power',
        'body': {'on': '{{value}}'},
      },
      'stateJsonPath': r'$.on',
    },
  ],
};

Device _bulb(DateTime lastSeen) => Device(
  id: 'bulb',
  name: 'Bedroom Light',
  driverId: 'philips_wiz_udp',
  host: '127.0.0.1',
  lastSeen: lastSeen,
);

const _homePlace = Device(
  id: 'home',
  name: 'Home',
  driverId: placeDriverId,
  host: virtualHost,
  settings: {
    'wifi': {
      'ssids': ['HomeNet'],
    },
  },
);

Device _person({required bool home}) => Device(
  id: 'jade',
  name: 'Jade',
  driverId: personDriverId,
  host: virtualHost,
  state: {'home': home, 'place': home ? 'home' : null},
);

Device _phone(String? ssid) => Device(
  id: defaultPhoneId,
  name: 'Phone',
  driverId: phoneDriverId,
  host: virtualHost,
  state: {'wifi_ssid': ssid, 'wifi_bssid': null},
);

void main() {
  group('alerts and the house the phone is at', () {
    late Directory dir;
    late AutomationHarness harness;
    late List<Map<String, Object?>> seen;
    late StreamSubscription<Map<String, Object?>> sub;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('omni_host_away');
      harness = await AutomationHarness.open(dir, addThings: false);
      seen = [];
      sub = harness.core.events.listen(seen.add);
    });

    tearDown(() async {
      await sub.cancel();
      await harness.shutdown();
      await dir.delete(recursive: true);
    });

    List<Object?> titles() => [
      for (final e in seen)
        if (e['event'] == 'flow.announce') e['title'],
    ];

    Future<void> put(Device d) => DriftDeviceStore(harness.db).put(d);

    test('the not answering alert is off by default', () async {
      final now = DateTime.now();
      await put(_bulb(now.subtract(const Duration(days: 2))));
      final alerts = HouseAlerts(harness.core, HomeFile(dir));
      await alerts.open();
      expect((await alerts.get(const {}))['offline'], isFalse);
      await alerts.check(at: now);
      await alerts.check(at: now.add(const Duration(hours: 1)));
      await Future<void>.delayed(Duration.zero);
      expect(titles(), isEmpty);
      await alerts.close();
    });

    test('an old saved "offline: true" does not turn it on, a choice '
        'does', () async {
      await HomeFile(dir).update({
        'alerts': {'offline': true, 'battery': true},
      });
      final alerts = HouseAlerts(harness.core, HomeFile(dir));
      await alerts.open();
      expect(alerts.offline, isFalse);
      await alerts.set({'offline': true});
      await alerts.close();
      final again = HouseAlerts(harness.core, HomeFile(dir));
      await again.open();
      expect(again.offline, isTrue);
      await again.close();
    });

    test('no alert while the phone is away, and "answering again" only '
        'after "not answering" was sent', () async {
      final now = DateTime.now();
      await put(_bulb(now.subtract(const Duration(days: 2))));
      var away = true;
      final alerts = HouseAlerts(
        harness.core,
        HomeFile(dir),
        hostAway: (_) => away,
      );
      await alerts.set({'offline': true});
      await alerts.check(at: now);
      await alerts.check(at: now.add(const Duration(minutes: 30)));
      await alerts.check(at: now.add(const Duration(hours: 2)));
      await Future<void>.delayed(Duration.zero);
      expect(titles(), isEmpty, reason: 'away, nothing is counted');

      // Back home: the bulb answers, and was never told as not answering.
      away = false;
      final back = now.add(const Duration(hours: 2, minutes: 1));
      await put(_bulb(back));
      await alerts.check(at: back);
      await Future<void>.delayed(Duration.zero);
      expect(titles(), isEmpty, reason: 'no "answering again" without one');

      // Home, the count starts from when the phone was back.
      await alerts.check(at: back.add(const Duration(minutes: 9)));
      expect(titles(), isEmpty);
      await alerts.check(at: back.add(const Duration(minutes: 14)));
      await put(_bulb(back.add(const Duration(minutes: 15))));
      await alerts.check(at: back.add(const Duration(minutes: 15)));
      await Future<void>.delayed(Duration.zero);
      expect(titles(), [
        'Bedroom Light is not answering',
        'Bedroom Light is answering again',
      ]);
    });

    group('HostPresence', () {
      Future<HostPresence> presence({
        String? person = 'jade',
        bool phone = true,
      }) async {
        final p = HostPresence(
          harness.core,
          householdPerson: () async => person,
          onPhone: () => phone,
        );
        await p.refresh();
        return p;
      }

      test('the household person away from the house is away', () async {
        await put(_homePlace);
        await put(_person(home: false));
        expect((await presence()).awayFrom('home'), isTrue);
        await put(_person(home: true));
        expect((await presence()).awayFrom('home'), isFalse);
      });

      test('an engine on a computer is never away', () async {
        await put(_homePlace);
        await put(_person(home: false));
        expect((await presence(phone: false)).awayFrom('home'), isFalse);
      });

      test('with presence not set up, the phone off the house Wi-Fi is '
          'away', () async {
        await put(_homePlace);
        await put(_person(home: false));
        await put(_phone('Cafe'));
        final p = await presence(person: null);
        expect(p.awayFrom('home'), isTrue);
        await put(_phone(null));
        expect((await presence(person: null)).awayFrom('home'), isTrue);
        await put(_phone('HomeNet'));
        expect((await presence(person: null)).awayFrom('home'), isFalse);
      });

      test('with nothing to compare with, the phone counts as there', () async {
        await put(_person(home: false));
        expect(
          (await presence()).awayFrom('home'),
          isFalse,
          reason: 'no place of the house can tell, and no Wi-Fi reading',
        );
        await put(_phone('Cafe'));
        expect(
          (await presence(person: null)).awayFrom('home'),
          isFalse,
          reason: 'the house has no Wi-Fi to compare with',
        );
        harness.core.flows.globals['HomeSsids'] = ['HomeNet'];
        expect((await presence(person: null)).awayFrom('home'), isTrue);
      });
    });
  });

  group('the device history while the phone is away', () {
    late Directory home;
    late OmniEngine engine;
    late List<Map<String, Object?>> events;
    late StreamSubscription<Map<String, Object?>> sub;
    final wasOnPhone = RulesCoreCommands.onPhone;

    Future<Map<String, Object?>> ok(
      String command, [
      Map<String, Object?> args = const {},
    ]) async {
      final result = await engine.handle(command, args);
      expect(result['ok'], isTrue, reason: '$command -> $result');
      return result;
    }

    setUp(() async {
      RulesCoreCommands.onPhone = () => true;
      home = await Directory.systemTemp.createTemp('omni_host_away_history');
      engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
        discoveryTargets: () async => [InternetAddress.loopbackIPv4],
        mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
      );
      events = [];
      sub = engine.events.listen(events.add);
      await ok('driver.register', {'manifest': _deadPolledSwitch});
      await ok('device.add', {
        'id': 'plug',
        'driver': 'dead_polled_switch',
        'host': InternetAddress.loopbackIPv4.address,
      });
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
    });

    tearDown(() async {
      RulesCoreCommands.onPhone = wasOnPhone;
      await sub.cancel();
      await engine.close();
      await home.delete(recursive: true);
    });

    Future<List<Object?>> answering() async => [
      for (final e
          in ((await ok('device.history', {
                    'id': 'plug',
                    'key': 'online',
                  }))['entries']
                  as List)
              .cast<Map>())
        e['value'],
    ];

    Future<void> pollFor() async {
      events.clear();
      await ok('hub.start', {'wizPort': 0, 'helloPort': 0});
      await until(
        () =>
            events.where((e) => e['event'] == 'device.pollFailed').length >= 2,
      );
      await ok('hub.stop');
      await engine.flows.settle();
    }

    Future<Object?> stateOf(String id) async =>
        ((await ok('device.get', {'id': id}))['device'] as Map)['state'];

    test('away by presence, nothing is written, and home again it '
        'is', () async {
      await ok('device.add', {'id': 'jade', 'driver': 'person'});
      await ok('phone.wifi', {'ssid': 'Cafe'});
      await until(() async => events.any((e) => e['event'] == 'wifi.changed'));
      await pollFor();
      expect(await answering(), isEmpty, reason: 'the phone is out');

      await ok('phone.wifi', {'ssid': 'HomeNet'});
      await until(() async => ((await stateOf('jade')) as Map)['home'] == true);
      await pollFor();
      expect(await answering(), [false]);
    });

    test('a run to a device that does not answer fails once, naming it, '
        'also while the phone is away', () async {
      await ok('device.organize', {'id': 'plug', 'name': 'Bedroom Light'});
      await ok('device.add', {'id': 'jade', 'driver': 'person'});
      await ok('phone.wifi', {'ssid': 'Cafe'});
      await ok('automation.save', {
        'form': 'rule',
        'spec': {
          'id': 'lights_on',
          'name': 'Lights on',
          'when': ['manual'],
          'then': [
            {
              'do': 'plug.power',
              'params': {'value': true},
            },
          ],
        },
        'trusted': true,
      });
      events.clear();
      await ok('automation.run', {'id': 'lights_on'});
      await engine.flows.settle();
      final finished = [
        for (final e in events)
          if (e['event'] == 'run.finished') e,
      ];
      expect(finished, hasLength(1));
      expect(finished.single['outcome'], 'failed');
      expect(
        finished.single['reason'],
        'Bedroom Light did not answer. Is it switched on?',
      );
    });

    test('with no person, the phone off the house Wi-Fi writes '
        'nothing', () async {
      await ok('phone.wifi', {'ssid': 'Cafe'});
      await until(
        () async => ((await stateOf('phone')) as Map)['wifi_ssid'] == 'Cafe',
      );
      await pollFor();
      expect(await answering(), isEmpty);

      await ok('phone.wifi', {'ssid': 'HomeNet'});
      await until(
        () async => ((await stateOf('phone')) as Map)['wifi_ssid'] == 'HomeNet',
      );
      await pollFor();
      expect(await answering(), [false]);
    });
  });
}
