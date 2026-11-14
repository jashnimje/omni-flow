import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/android_names.dart';
import 'package:omniflow_engine/src/api/tv_commands.dart';
import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:omniflow_engine/src/manifest/built_in_drivers.g.dart';
import 'package:test/test.dart';

import '../../tool/embed_drivers.dart';
import '../devices/adb/fake_adbd.dart';
import '../devices/adb/fake_tv.dart';
import '../devices/fake_mdns.dart';

const _pairing = 'adb-FAKE0123-AbCdEf._adb-tls-pairing._tcp.local';
const _connect = 'adb-FAKE0123-AbCdEf._adb-tls-connect._tcp.local';

final _phoneRecords = <ResourceRecord>[
  ptr('_adb-tls-pairing._tcp', _pairing),
  srv(_pairing, 'android-phone.local', 37123),
  ptr('_adb-tls-connect._tcp', _connect),
  srv(_connect, 'android-phone.local', 41234),
  a('android-phone.local', '192.168.1.77'),
];

void main() {
  final phone = DriverRegistry.withBuiltIns()['android_phone_adb']!;

  group('the android_phone_adb driver', () {
    test('is embedded from drivers/', () {
      final file = File('$driversDir/android_phone_adb.omni_driver.json');
      expect(file.existsSync(), isTrue);
      expect(
        builtInDriverSources['android_phone_adb.omni_driver.json'],
        file.readAsStringSync(),
      );
      expect(
        File(outputPath).readAsStringSync(),
        generateBuiltInDrivers(Directory(driversDir)),
      );
    });

    test('is a phone on the ADB channel, with phone keys and no TV parts', () {
      expect(phone.category, 'phone');
      expect(phone.icon, 'smartphone');
      expect(phone.transport.type, TransportType.adb);
      expect(isAndroidPhone(phone), isTrue);
      expect(
        isAndroidPhone(DriverRegistry.withBuiltIns()['android_tv_adb']!),
        isFalse,
      );
      expect(phone.settings.map((s) => s.key), ['statePollSeconds']);
      expect(phone.settings.any((s) => s.key == 'mac'), isFalse);
      final ids = phone.capabilities.map((c) => c.id).toSet();
      expect(
        ids,
        containsAll([
          'screen',
          'wake',
          'lock',
          'power',
          'back',
          'home',
          'recents',
          'notifications',
          'volume',
          'volume_up',
          'volume_down',
        ]),
      );
      expect(ids, isNot(contains('wake_on_lan')));
      expect(ids, isNot(contains('remote')));
      Object? keyOf(String id) =>
          (phone.capability(id)!.command! as Map)['key'];
      expect(keyOf('back'), 'back');
      expect(keyOf('home'), 'home');
      expect(keyOf('recents'), 'app_switch');
      expect(keyOf('lock'), 'sleep');
      expect(keyOf('wake'), 'wakeup');
      expect(keyOf('notifications'), 'notification');
      expect(phone.discovery.map((d) => d.config['service']), [
        '_adb-tls-connect._tcp',
      ]);
    });
  });

  group('android.* names', () {
    test('every tv.* command is also an android.* one in the engine', () async {
      final home = await Directory.systemTemp.createTemp('omni_android_names');
      final engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
        mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
      );
      addTearDown(() async {
        await engine.close();
        await home.delete(recursive: true);
      });
      final names = engine.commandNames.toSet();
      final tv = names.where((c) => c.startsWith('tv.')).toList();
      expect(tv, isNotEmpty);
      for (final c in tv) {
        expect(names, contains(androidNameOf(c)), reason: c);
      }
      expect(names, contains('android.notifications'));
    });

    test('the agent policy of every android.* command is its tv.* one', () {
      final all = {
        ...agentReadCommands,
        ...agentSetupCommands,
        ...agentUserOnly.keys,
      };
      final tvNames = all.where((c) => c.startsWith('tv.')).toList();
      expect(tvNames.length, greaterThan(30));
      for (final c in tvNames) {
        final android = androidNameOf(c)!;
        expect(
          agentReadCommands.contains(android),
          agentReadCommands.contains(c),
          reason: c,
        );
        expect(
          agentSetupCommands.contains(android),
          agentSetupCommands.contains(c),
          reason: c,
        );
        expect(agentUserOnly[android], agentUserOnly[c], reason: c);
        for (final level in AgentAccess.values) {
          expect(
            agentRefusal(android, const {}, level) == null,
            agentRefusal(c, const {}, level) == null,
            reason: '$c at $level',
          );
        }
        expect(
          agentArgs(android, const {'id': 'p'})['allowPairing'],
          isFalse,
          reason: android,
        );
      }
      for (final c in all.where((c) => c.startsWith('android.'))) {
        if (c == 'android.pair' || c == 'android.find') continue;
        expect(all, contains(tvNameOf(c)), reason: c);
      }
      expect(
        agentRefusal('android.app', const {
          'action': 'open',
        }, AgentAccess.setup),
        isNull,
      );
      expect(
        agentRefusal('android.app', const {
          'action': 'uninstall',
        }, AgentAccess.setup),
        contains('for the user only'),
      );
      expect(
        agentRefusal('android.shell', const {}, AgentAccess.setup),
        contains('for the user only'),
      );
    });
  });

  group('a phone over the fake adbd', () {
    late AdbHostKey key;
    late Directory home;
    late FakeAdbd adbd;
    late FakeTv device;
    late OmniEngine engine;

    setUpAll(() => key = AdbHostKey.generateSync());

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_android_phone');
      final secrets = InMemorySecretStore();
      await secrets.write(adbHostKeySecret, key.toPem());
      adbd = await FakeAdbd.start();
      device = FakeTv(adbd)..physicalSize = '1080x2400';
      engine = await OmniEngine.open(
        home: home,
        secrets: secrets,
        discoveryTargets: () async => const [],
        mdns: MdnsDiscovery(client: () => FakeMdns(_phoneRecords)),
      );
      final added = await engine.handle('device.add', {
        'id': 'pixel',
        'driver': 'android_phone_adb',
        'host': InternetAddress.loopbackIPv4.address,
        'port': adbd.port,
      });
      expect(added['ok'], isTrue, reason: '$added');
    });

    tearDown(() async {
      await engine.close();
      await adbd.close();
      await home.delete(recursive: true);
    });

    Future<Map<String, Object?>> ok(String c, [Map<String, Object?>? a]) async {
      final r = await engine.handle(c, {'id': 'pixel', ...?a});
      expect(r['ok'], isTrue, reason: '$c: $r');
      return r;
    }

    Future<Map<String, Object?>> err(String c, Map<String, Object?> a) async {
      final r = await engine.handle(c, {'id': 'pixel', ...a});
      expect(r['ok'], isFalse, reason: '$c: $r');
      return Map<String, Object?>.from(r['error'] as Map);
    }

    test('android.state says whether the screen is on', () async {
      final on = await ok('android.state');
      expect(on['kind'], 'phone');
      expect(on['screen'], 'on');
      expect(on['reachable'], isTrue);
      device.wakefulness = 'Asleep';
      expect((await ok('tv.state'))['screen'], 'off');
      final stored = await engine.handle('device.get', {'id': 'pixel'});
      expect(((stored['device'] as Map)['state'] as Map)['screen'], 'off');
    });

    test(
      'android.keys is the phone catalog with Back, Home and Recents',
      () async {
        final groups = (await ok('android.keys'))['groups'] as List;
        final keys = {
          for (final g in groups)
            for (final k in (g as Map)['keys'] as List)
              (k as Map)['key']: k['label'],
        };
        expect(keys['back'], 'Back');
        expect(keys['home'], 'Home');
        expect(keys['app_switch'], 'Recents');
        expect(keys['sleep'], 'Lock');
        expect(keys['notification'], 'Notifications');
        expect(keys, isNot(contains('hdmi1')));
        expect(keys, isNot(contains('up')));
      },
    );

    test('phone keys go through, and TV keys answer plainly', () async {
      await ok('android.key', {'key': 'app_switch'});
      await ok('android.key', {'key': 'sleep'});
      await ok('android.key', {'keycode': 4});
      expect(device.keys.map((k) => k.last), containsAll(['187', '223', '4']));
      final e = await err('android.key', {'key': 'hdmi1'});
      expect(e['type'], 'invalid');
      expect(e['message'], contains('is a TV remote key'));
      expect(e['message'], contains('phone'));
    });

    test('the power key on a phone never tries Wake-on-LAN', () async {
      await adbd.close();
      final e = await err('android.key', {'key': 'wakeup'});
      expect(e['message'], isNot(contains('Wake-on-LAN')));
    });

    test(
      'a phone that does not answer says Wireless debugging went off',
      () async {
        await adbd.close();
        final state = await ok('android.state');
        expect(state['reachable'], isFalse);
        expect(state['screen'], isNull);
        expect(state['message'], contains('Wireless debugging'));
      },
    );

    test('android.notifications opens and closes the shade', () async {
      final base = adbd.respond;
      final ran = <String>[];
      adbd.respond = (script) => base(
        script.replaceAllMapped(RegExp(r'cmd statusbar [a-z-]+'), (m) {
          ran.add(m[0]!);
          return 'true';
        }),
      );
      expect((await ok('android.notifications'))['action'], 'expand');
      await ok('android.notifications', {'action': 'collapse'});
      expect(ran, [
        'cmd statusbar expand-notifications',
        'cmd statusbar collapse',
      ]);
      final e = await err('android.notifications', {'action': 'rm -rf'});
      expect(e['type'], 'invalid');
    });

    test('the settings catalog has no HDMI-CEC on a phone', () async {
      final categories = [
        for (final c
            in (await ok('android.settings.catalog'))['categories'] as List)
          (c as Map)['category'],
      ];
      expect(categories, isNot(contains('HDMI-CEC')));
      expect(categories, contains('Display and sound'));
    });

    test('a portrait tap maps to the phone screen in pixels', () async {
      final tap = await ok('android.input.tap', {'x': 0.5, 'y': 0.25});
      expect((tap['x'], tap['y']), (540, 600));
    });

    test('android.find joins the pairing and connect services', () async {
      final r = await engine.handle('android.find', {'windowMs': 200});
      expect(r['ok'], isTrue, reason: '$r');
      expect(r['phones'], [
        {
          'name': 'adb-FAKE0123-AbCdEf',
          'guid': 'adb-FAKE0123-AbCdEf',
          'host': '192.168.1.77',
          'pairingPort': 37123,
          'connectPort': 41234,
        },
      ]);
      await engine.handle('device.add', {
        'id': 'other',
        'driver': 'android_phone_adb',
        'host': '192.168.1.77',
        'port': 41234,
        'stableId': 'adb-FAKE0123-AbCdEf',
      });
      final again = await engine.handle('android.find', {'windowMs': 200});
      expect(((again['phones'] as List).single as Map)['knownAs'], 'other');
      expect(
        (await engine.handle('android.find', {'windowMs': 5}))['ok'],
        isFalse,
      );
    });
  });

  test('omni android ID is omni tv ID', () async {
    final key = AdbHostKey.generateSync();
    final home = await Directory.systemTemp.createTemp('omni_android_cli');
    final secrets = InMemorySecretStore();
    await secrets.write(adbHostKeySecret, key.toPem());
    final adbd = await FakeAdbd.start();
    FakeTv(adbd);
    addTearDown(() async {
      await adbd.close();
      await home.delete(recursive: true);
    });
    Future<(int, String)> omni(List<String> args) async {
      final out = StringBuffer();
      final code = await runOmni(
        ['--home', home.path, ...args],
        runner: OmniCommandRunner(
          out: out,
          engineFactory: (h, {tap}) =>
              OmniEngine.open(home: h, secrets: secrets, tap: tap),
          socketPath: '${home.path}/none.sock',
        ),
        err: StringBuffer(),
      );
      return (code, out.toString());
    }

    final (added, _) = await omni([
      'device',
      'add',
      'pixel',
      '--driver',
      'android_phone_adb',
      '--host',
      InternetAddress.loopbackIPv4.address,
      '--port',
      '${adbd.port}',
    ]);
    expect(added, 0);
    final (code, out) = await omni(['android', 'pixel', 'state']);
    expect(code, 0, reason: out);
    expect(out, contains('phone'));
  });
}
