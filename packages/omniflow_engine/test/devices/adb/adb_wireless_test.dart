import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/adb/adb_connection.dart';
import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:omniflow_engine/src/devices/adb/adb_pairing.dart';
import 'package:omniflow_engine/src/devices/adb/adb_tls.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

import '../fake_mdns.dart';
import 'fake_wireless_adbd.dart';

Uint8List unhex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

void main() {
  late AdbHostKey hostKey;
  late AdbHostKey phoneKey;
  late AdbHostKey strangerKey;

  setUpAll(() {
    hostKey = AdbHostKey.generateSync();
    phoneKey = AdbHostKey.generateSync();
    strangerKey = AdbHostKey.generateSync();
  });

  group('TLS exporter', () {
    // Each secret is the EXPORTER_SECRET a Dart client logged against an
    // OpenSSL 4.1 s_server, and each expected value is what that server
    // printed for -keymatexport adb-label -keymatexportlen 64.
    test('matches OpenSSL for a SHA-256 suite', () {
      final secret = unhex(
        'bd8e31a21ffca21fdc791ba4a4f4147f38e3a0d7d84fa25488bea6e284ff8828',
      );
      expect(
        tlsExporter(secret, ascii.encode('adb-label'), 64),
        unhex(
          '3ED9F8CD8F469D4B999F215B68F942384ABE22A1B5BDBC09636BB4B8D3F9BEB8'
          '16D1937688DAB70C1F0F749C10C013682396C67F70572D52355FA507DCF0931C',
        ),
      );
    });

    test('matches OpenSSL for a SHA-384 suite', () {
      final secret = unhex(
        '3faf051d15e9548d03aaa8418d1c4ab395eab5dd9a91afc103fc36fccb171c5a'
        '0c34af7a8af6b5cc6d9253c55a5d46e1',
      );
      expect(
        tlsExporter(secret, ascii.encode('adb-label'), 64),
        unhex(
          'BA2123E65DA950E5582AB04E19D56D42B83F134C47AD1ACE90D66D157F352CCB'
          'B3B8A45577A187FE89DA2E0512ADF7E68FEB025E01E3D47697A13847E54A4F04',
        ),
      );
    });

    test('the pairing label carries its NUL', () {
      expect(adbExporterLabel, [...ascii.encode('adb-label'), 0]);
    });

    test('reads the secret from a keyLog line only for its label', () {
      expect(keyLogSecret('EXPORTER_SECRET aa 0102\n', 'EXPORTER_SECRET'), [
        1,
        2,
      ]);
      expect(
        keyLogSecret('CLIENT_TRAFFIC_SECRET_0 aa 0102', 'EXPORTER_SECRET'),
        isNull,
      );
      expect(keyLogSecret('EXPORTER_SECRET aa 0x', 'EXPORTER_SECRET'), isNull);
    });

    test('HKDF matches RFC 5869 test case 3 (no salt)', () {
      final okm = hkdf(SHA256Digest.new, List.filled(22, 0x0b), const [], 42);
      expect(
        okm,
        unhex(
          '8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d'
          '9d201395faa4b61a96c8',
        ),
      );
    });
  });

  group('certificate', () {
    test('is a v3 self-signed CA for the key, as adb makes it', () async {
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        serverContext(phoneKey, trust: [hostKey]),
        requestClientCertificate: true,
      );
      final seen = server.first;
      final client = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
        context: adbTlsContext(hostKey),
        onBadCertificate: (_) => true,
      );
      final accepted = await seen;
      final cert = accepted.peerCertificate!;
      expect(cert.subject, contains('CN=Adb'));
      expect(cert.subject, contains('O=Android'));
      expect(cert.issuer, cert.subject);
      expect(
        cert.pem.trim(),
        adbCertificatePem(hostKey, now: cert.startValidity).trim(),
        reason: 'the bytes are exactly what adbCertificatePem builds',
      );
      expect(cert.endValidity.difference(cert.startValidity).inDays, 3650);
      client.destroy();
      accepted.destroy();
      await server.close();
    });
  });

  group('pairing', () {
    late FakePairingPhone phone;

    tearDown(() => phone.close());

    test('pairs with the code and returns the phone guid', () async {
      phone = await FakePairingPhone.start(
        phoneKey: phoneKey,
        hostKey: hostKey,
        code: '482913',
      );
      final result = await pairAdbDevice(
        host: '127.0.0.1',
        port: phone.port,
        code: '482913',
        key: hostKey,
        keyName: 'omniflow@test',
        onExported: phone.exported.complete,
      );
      expect(result.guid, 'adb-FAKEPHONE01-AbC123');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        phone.receivedKey,
        utf8
            .decode(hostKey.publicKeyPayload('omniflow@test'))
            .replaceAll('\x00', ''),
        reason: 'the phone gets the key line adbkey.pub holds',
      );
      expect(phone.clientCertificate?.subject, contains('CN=Adb'));
    });

    test('a wrong code fails without the code in the error', () async {
      phone = await FakePairingPhone.start(
        phoneKey: phoneKey,
        hostKey: hostKey,
        code: '111111',
      );
      final error = await pairAdbDevice(
        host: '127.0.0.1',
        port: phone.port,
        code: '222222',
        key: hostKey,
        keyName: 'omniflow@test',
        onExported: phone.exported.complete,
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<AdbPairingFailedException>());
      final failure = error! as AdbPairingFailedException;
      expect(failure.failure, AdbPairingFailure.wrongCode);
      expect('$failure', isNot(contains('222222')));
      expect('$failure', isNot(contains('111111')));
    });

    test('a closed port is unreachable', () async {
      phone = await FakePairingPhone.start(
        phoneKey: phoneKey,
        hostKey: hostKey,
        code: '111111',
      );
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      await expectLater(
        pairAdbDevice(
          host: '127.0.0.1',
          port: port,
          code: '123456',
          key: hostKey,
          keyName: 'omniflow@test',
        ),
        throwsA(
          isA<AdbPairingFailedException>().having(
            (e) => e.failure,
            'failure',
            AdbPairingFailure.unreachable,
          ),
        ),
      );
    });
  });

  group('TLS connect', () {
    late FakeTlsAdbd adbd;

    tearDown(() => adbd.close());

    test('answers STLS, presents the key and runs a shell over TLS', () async {
      adbd = await FakeTlsAdbd.start(phoneKey: phoneKey, allowed: [hostKey]);
      final c = await AdbConnection.connect(
        '127.0.0.1',
        adbd.port,
        key: hostKey,
        keyName: 'omniflow@test',
        offerKey: false,
      );
      expect(c.isTls, isTrue);
      expect(c.banner, contains('FakePhone'));
      expect(
        await c.shell(
          'getprop ro.product.model',
          timeout: const Duration(seconds: 5),
        ),
        'tls says hi\n',
      );
      expect(adbd.shells, ['shell:getprop ro.product.model']);
      c.close();
    });

    test('a key the phone does not know is refused over TLS', () async {
      adbd = await FakeTlsAdbd.start(phoneKey: phoneKey, allowed: [hostKey]);
      await expectLater(
        AdbConnection.connect(
          '127.0.0.1',
          adbd.port,
          key: strangerKey,
          keyName: 'omniflow@test',
          offerKey: false,
        ),
        throwsA(isA<AdbTlsRefusedException>()),
      );
      expect(adbd.refused, 1);
    });

    test('the channel follows a phone to its new port by guid', () async {
      adbd = await FakeTlsAdbd.start(phoneKey: phoneKey, allowed: [hostKey]);
      final secrets = InMemorySecretStore();
      await secrets.write(adbHostKeySecret, hostKey.toPem());
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final oldPort = closed.port;
      await closed.close();
      final located = <String>[];
      final moves = <String>[];
      final channel = AdbChannel(
        secrets,
        locateTls: (guid) async {
          located.add(guid);
          return (host: '127.0.0.1', port: adbd.port);
        },
        onMoved: (id, host, port) async => moves.add('$id $host:$port'),
      );
      final manifest = DriverRegistry.withBuiltIns()['android_tv_adb']!;
      final device = Device(
        id: 'phone',
        name: 'Phone',
        driverId: 'android_tv_adb',
        host: '127.0.0.1',
        port: oldPort,
        stableId: 'adb-FAKEPHONE01-AbC123',
      );
      final out = await channel.run(device, manifest, 'echo hi');
      expect(out, 'tls says hi\n');
      expect(located, ['adb-FAKEPHONE01-AbC123']);
      expect(moves, ['phone 127.0.0.1:${adbd.port}']);
      // The held connection now sits at the new port, so the moved device
      // reuses it instead of connecting again.
      final moved = device.copyWith(port: adbd.port);
      await channel.run(moved, manifest, 'echo again');
      expect(adbd.connections, 1);
      await channel.close();
    });

    test('a TV id without a guid suffix is never followed', () async {
      adbd = await FakeTlsAdbd.start(phoneKey: phoneKey, allowed: [hostKey]);
      final secrets = InMemorySecretStore();
      await secrets.write(adbHostKeySecret, hostKey.toPem());
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final oldPort = closed.port;
      await closed.close();
      var located = 0;
      final channel = AdbChannel(
        secrets,
        locateTls: (guid) async {
          located++;
          return (host: '127.0.0.1', port: adbd.port);
        },
      );
      final manifest = DriverRegistry.withBuiltIns()['android_tv_adb']!;
      final device = Device(
        id: 'tv',
        name: 'TV',
        driverId: 'android_tv_adb',
        host: '127.0.0.1',
        port: oldPort,
        stableId: 'adb-TVSERIAL01',
      );
      await expectLater(
        channel.run(device, manifest, 'echo hi'),
        throwsA(isA<TransportTimeoutException>()),
      );
      expect(located, 0);
      await channel.close();
    });
  });

  group('mDNS', () {
    const pairing = 'adb-SERIAL01-AbC123._adb-tls-pairing._tcp.local';
    const connect = 'adb-SERIAL01-AbC123._adb-tls-connect._tcp.local';
    final records = <ResourceRecord>[
      ptr('_adb-tls-pairing._tcp', pairing),
      srv(pairing, 'Android_X.local', 37011),
      txt(pairing, ['name=Pixel 9', 'serial=SERIAL01', 'v=2.0']),
      ptr('_adb-tls-connect._tcp', connect),
      srv(connect, 'Android_X.local', 41235),
      a('Android_X.local', '192.168.1.50'),
    ];

    test('finds both services with the guid and name', () async {
      final found = await browseAdbWireless(
        MdnsDiscovery(client: () => FakeMdns(records)),
      );
      expect(found.map((f) => f.toJson()), [
        {
          'service': '_adb-tls-pairing._tcp',
          'guid': 'adb-SERIAL01-AbC123',
          'name': 'Pixel 9',
          'host': '192.168.1.50',
          'port': 37011,
        },
        {
          'service': '_adb-tls-connect._tcp',
          'guid': 'adb-SERIAL01-AbC123',
          'name': 'adb-SERIAL01-AbC123',
          'host': '192.168.1.50',
          'port': 41235,
        },
      ]);
    });

    test('locates the connect port of one guid only', () async {
      final mdns = MdnsDiscovery(client: () => FakeMdns(records));
      expect(await locateAdbTlsConnect(mdns, 'adb-SERIAL01-AbC123'), (
        host: '192.168.1.50',
        port: 41235,
      ));
      expect(await locateAdbTlsConnect(mdns, 'adb-OTHER-Zzz999'), isNull);
    });

    test('both are known service types', () {
      expect(
        knownMdnsServices,
        containsAll([adbTlsPairingService, adbTlsConnectService]),
      );
      expect(mdnsServicePattern.hasMatch(adbTlsPairingService), isTrue);
      expect(mdnsServicePattern.hasMatch(adbTlsConnectService), isTrue);
    });
  });
}
