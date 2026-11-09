import 'dart:convert';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

const shellyInstance = 'shellyplus1-a8032ab10001._shelly._tcp.local';
const hueInstance = 'Philips Hue - 0A0B0C._hue._tcp.local';

List<ResourceRecord> records({required int shellyPort}) => [
  ptr('_shelly._tcp', shellyInstance),
  srv(shellyInstance, 'shellyplus1-a8032ab10001.local', shellyPort),
  a('shellyplus1-a8032ab10001.local', '127.0.0.1'),
  ptr('_hue._tcp', hueInstance),
  srv(hueInstance, 'ecb5fa0a0b0c.local', 443),
  txt(hueInstance, ['bridgeid=ecb5fafffe0a0b0c', 'modelid=BSB002']),
  a('ecb5fa0a0b0c.local', '192.168.1.20'),
];

void main() {
  late Directory home;
  late InMemorySecretStore secrets;
  late HttpServer shelly;
  late List<ResourceRecord> mdnsRecords;

  Future<OmniEngine> open() => OmniEngine.open(
    home: home,
    secrets: secrets,
    discoveryTargets: () async => const [],
    mdns: MdnsDiscovery(client: () => FakeMdns(mdnsRecords)),
  );

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_discovery_wiring');
    secrets = InMemorySecretStore();
    shelly = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    shelly.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'was_on': false}));
      await request.response.close();
    });
    mdnsRecords = records(shellyPort: shelly.port);
  });

  tearDown(() async {
    await shelly.close(force: true);
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(
    OmniEngine engine,
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command: $result');
    return result;
  }

  test(
    'device.discover finds Shelly by instance and Hue by bridgeid',
    () async {
      final engine = await open();
      addTearDown(engine.close);
      final shellyFound =
          (await ok(engine, 'device.discover', {
                'driver': 'shelly_plus_switch',
                'windowMs': 200,
              }))['found']
              as List;
      expect(shellyFound.single, {
        'host': '127.0.0.1',
        'stableId': 'shellyplus1-a8032ab10001',
        'port': shelly.port,
        'name': 'shellyplus1-a8032ab10001',
        'method': 'mdns',
        'reply': isA<Map<String, Object?>>(),
      });

      await ok(engine, 'device.add', {
        'id': 'hall_light',
        'driver': 'philips_hue_light',
        'host': '192.168.1.20',
        'stableId': 'ecb5fafffe0a0b0c',
        'settings': {'lightId': '1'},
      });
      final hueFound =
          (await ok(engine, 'device.discover', {
                'driver': 'philips_hue_light',
                'windowMs': 200,
              }))['found']
              as List;
      expect((hueFound.single as Map)['stableId'], 'ecb5fafffe0a0b0c');
      expect((hueFound.single as Map)['knownAs'], 'hall_light');
    },
  );

  test('a Shelly that moved is healed through mDNS', () async {
    final engine = await open();
    addTearDown(engine.close);
    // Nothing answers at the old address, so the send fails and the
    // locator asks mDNS where the Shelly with this instance name is now.
    await ok(engine, 'device.add', {
      'id': 'heater',
      'driver': 'shelly_plus_switch',
      'host': '127.0.0.2',
      'port': shelly.port,
      'stableId': 'shellyplus1-a8032ab10001',
    });
    final result = await ok(engine, 'device.invoke', {
      'id': 'heater',
      'capability': 'power',
      'params': {'value': true},
    });
    expect((result['device'] as Map)['host'], '127.0.0.1');
  }, skip: Platform.isMacOS ? null : '127.0.0.2 is not routed everywhere');

  test(
    'a Tuya plug heals by its devId: set on add and backfilled on open',
    () async {
      var engine = await open();
      await ok(engine, 'device.add', {
        'id': 'kettle',
        'driver': 'tuya_plug',
        'host': '192.168.1.30',
        'settings': {'devId': 'fixturegwid0001'},
      });
      final added = (await ok(engine, 'device.get', {
        'id': 'kettle',
      }))['device'];
      expect((added as Map)['stableId'], 'fixturegwid0001');
      await engine.close();

      // A plug stored before the driver read its id from devId.
      final db = OmniDatabase.file(File('${home.path}/omniflow.sqlite'));
      await DriftDeviceStore(db).put(
        const Device(
          id: 'old_plug',
          name: 'old_plug',
          driverId: 'tuya_plug',
          host: '192.168.1.31',
          settings: {'devId': 'fixturegwid0002'},
        ),
      );
      await db.close();

      engine = await open();
      addTearDown(engine.close);
      final old = (await ok(engine, 'device.get', {
        'id': 'old_plug',
      }))['device'];
      expect((old as Map)['stableId'], 'fixturegwid0002');
    },
  );
}
