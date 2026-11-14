import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:test/test.dart';

import '../devices/adb/fake_wireless_adbd.dart';
import '../devices/fake_mdns.dart';

void main() {
  late Directory home;
  late OmniEngine engine;
  late AdbHostKey hostKey;
  late AdbHostKey phoneKey;

  const connect = 'adb-SERIAL01-AbC123._adb-tls-connect._tcp.local';
  final records = <ResourceRecord>[
    ptr('_adb-tls-connect._tcp', connect),
    srv(connect, 'Android_X.local', 41235),
    txt(connect, ['name=Pixel 9']),
    a('Android_X.local', '192.168.1.50'),
  ];

  setUpAll(() {
    hostKey = AdbHostKey.generateSync();
    phoneKey = AdbHostKey.generateSync();
  });

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_android_pair');
    final secrets = InMemorySecretStore();
    await secrets.write(adbHostKeySecret, hostKey.toPem());
    engine = await OmniEngine.open(
      home: home,
      secrets: secrets,
      mdns: MdnsDiscovery(client: () => FakeMdns(records)),
    );
  });

  tearDown(() async {
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> err(String c, Map<String, Object?> a) async {
    final r = await engine.handle(c, a);
    expect(r['ok'], isFalse, reason: '$c: $r');
    return Map<String, Object?>.from(r['error'] as Map);
  }

  test('a malformed code is refused without echoing it', () async {
    final e = await err('android.pair', {
      'host': '127.0.0.1',
      'port': 4000,
      'code': '12ab56',
    });
    expect(e['type'], 'invalid');
    expect('$e', isNot(contains('12ab56')));
  });

  test('a port out of range is refused', () async {
    final e = await err('android.pair', {
      'host': '127.0.0.1',
      'port': 70000,
      'code': '123456',
    });
    expect(e['type'], 'invalid');
  });

  test('a code the phone does not share fails as pairing_failed', () async {
    // The fake never learns this client's exporter, so its SPAKE2 key
    // differs, exactly as with a wrong code.
    final phone = await FakePairingPhone.start(
      phoneKey: phoneKey,
      hostKey: hostKey,
      code: '654321',
    );
    addTearDown(phone.close);
    final e = await err('android.pair', {
      'host': '127.0.0.1',
      'port': phone.port,
      'code': '654321',
    });
    expect(e['type'], 'pairing_failed');
    expect('$e', isNot(contains('654321')));
  });

  test('an unknown device id is refused before anything is sent', () async {
    final e = await err('android.pair', {
      'host': '127.0.0.1',
      'port': 4000,
      'code': '123456',
      'id': 'nope',
    });
    expect(e['type'], 'not_found');
  });

  test('an agent may never pair', () async {
    final pair = await engine.handle('agent.call', {
      'command': 'android.pair',
      'args': {'host': '127.0.0.1', 'port': 4000, 'code': '123456'},
    });
    expect(pair['ok'], isFalse);
    final error = pair['error'] as Map;
    expect(error['type'], 'needs_user');
    expect('$error', isNot(contains('123456')));
  });
}
