import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// A loopback WiZ bulb that answers getSystemConfig like a real one.
Future<UdpTransport> fakeWiz(String mac, {bool wrongShape = false}) async {
  final bulb = await UdpTransport.bind();
  bulb.incoming.listen((d) {
    final probe = jsonDecode(d.text) as Map;
    final params = probe['params'] as Map;
    if (probe['method'] != 'registration' || params['register'] != false) {
      return;
    }
    final reply = wrongShape
        ? {'hello': 'not a wiz'}
        : {
            'method': 'registration',
            'env': 'pro',
            'result': {
              'mac': mac,
              'moduleName': 'ESP03_SHRGB1W_01',
              'fwVersion': '1.25.0',
            },
          };
    bulb.send(d.address, d.port, utf8.encode(jsonEncode(reply)));
  });
  return bulb;
}

void main() {
  final wiz = DriverRegistry.withBuiltIns()['philips_wiz_udp']!;
  final loopback = [InternetAddress.loopbackIPv4];

  test(
    'finds a bulb, reads its MAC as the stable id, and ignores non-WiZ replies',
    () async {
      final udp = await UdpTransport.bind();
      final bulb = await fakeWiz('a8bb50aabbcc');
      final other = await fakeWiz('', wrongShape: true);
      addTearDown(() {
        udp.close();
        bulb.close();
        other.close();
      });
      final discovery = UdpDiscovery(udp, targets: () async => loopback);
      final found = await discovery.discover(
        wiz,
        window: const Duration(milliseconds: 200),
        portOverride: bulb.localPort,
      );
      expect(found.single.host, '127.0.0.1');
      expect(found.single.stableId, 'a8bb50aabbcc');
      final none = await discovery.discover(
        wiz,
        window: const Duration(milliseconds: 200),
        portOverride: other.localPort,
      );
      expect(none, isEmpty);
    },
  );

  test('a driver without udp_broadcast discovery finds nothing', () async {
    final udp = await UdpTransport.bind();
    addTearDown(udp.close);
    final tuya = DriverRegistry.withBuiltIns()['tuya_plug']!;
    expect(
      await UdpDiscovery(udp, targets: () async => loopback).discover(tuya),
      isEmpty,
    );
  });

  test(
    'broadcast targets include the limited broadcast and no loopback /24',
    () async {
      final targets = (await broadcastTargets()).map((a) => a.address);
      expect(targets, contains('255.255.255.255'));
      expect(targets, isNot(contains('127.0.0.255')));
    },
  );

  test('device.discover marks a bulb that is already a device', () async {
    final home = await Directory.systemTemp.createTemp('omni_disc');
    final bulb = await fakeWiz('A8BB50AABBCC');
    final engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      discoveryTargets: () async => loopback,
    );
    addTearDown(() async {
      await engine.close();
      bulb.close();
      await home.delete(recursive: true);
    });
    await engine.handle('device.add', {
      'id': 'desk_lamp',
      'driver': 'philips_wiz_udp',
      'host': '10.0.0.5',
      'stableId': 'a8bb50aabbcc',
    });
    final result = await engine.handle('device.discover', {
      'driver': 'philips_wiz_udp',
      'windowMs': 200,
      'port': bulb.localPort,
    });
    final hit = (result['found'] as List).single as Map;
    expect(hit['host'], '127.0.0.1');
    expect(hit['knownAs'], 'desk_lamp');
  });
}
