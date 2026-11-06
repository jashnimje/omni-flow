import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// A loopback stand-in for a WiZ bulb that ignores the first [dropFirst]
/// requests, to exercise retries.
Future<UdpTransport> fakeBulb({int dropFirst = 0}) async {
  final bulb = await UdpTransport.bind();
  var seen = 0;
  bulb.incoming.listen((d) {
    seen++;
    if (seen <= dropFirst) return;
    final request = jsonDecode(d.text) as Map;
    bulb.send(
      d.address,
      d.port,
      utf8.encode(
        jsonEncode({
          'method': request['method'],
          'result': {'success': true},
        }),
      ),
    );
  });
  return bulb;
}

void main() {
  final loopback = InternetAddress.loopbackIPv4;

  group('request and reply over loopback', () {
    late UdpTransport client;
    late UdpTransport bulb;

    tearDown(() {
      client.close();
      bulb.close();
    });

    test('gets the reply from the device it asked', () async {
      final tap = PacketTap();
      client = await UdpTransport.bind(tap: tap);
      bulb = await fakeBulb();
      final reply = await client.request(
        loopback,
        bulb.localPort,
        utf8.encode('{"method":"getPilot","params":{}}'),
      );
      expect(jsonDecode(reply.text), {
        'method': 'getPilot',
        'result': {'success': true},
      });
      expect(tap.recent.map((p) => p.direction), [
        PacketDirection.outgoing,
        PacketDirection.incoming,
      ]);
      expect(tap.recent.first.remote, '127.0.0.1:${bulb.localPort}');
    });

    test('retries when the first request is dropped', () async {
      client = await UdpTransport.bind();
      bulb = await fakeBulb(dropFirst: 1);
      final reply = await client.request(
        loopback,
        bulb.localPort,
        utf8.encode('{"method":"setPilot","params":{}}'),
        timeout: const Duration(milliseconds: 150),
        retries: 2,
      );
      expect(reply.text, contains('setPilot'));
    });

    test('gives up after the last retry', () async {
      client = await UdpTransport.bind();
      bulb = await fakeBulb(dropFirst: 99);
      await expectLater(
        client.request(
          loopback,
          bulb.localPort,
          utf8.encode('{"method":"getPilot"}'),
          timeout: const Duration(milliseconds: 50),
          retries: 1,
        ),
        throwsA(isA<TransportTimeoutException>()),
      );
    });

    test('ignores datagrams that the accept check rejects', () async {
      client = await UdpTransport.bind();
      bulb = await fakeBulb();
      await expectLater(
        client.request(
          loopback,
          bulb.localPort,
          utf8.encode('{"method":"getPilot"}'),
          timeout: const Duration(milliseconds: 80),
          accept: (d) => d.text.contains('nothing-matches'),
        ),
        throwsA(isA<TransportTimeoutException>()),
      );
    });
  });

  test('the packet tap keeps only the newest packets', () {
    final tap = PacketTap(capacity: 2);
    for (var i = 0; i < 3; i++) {
      tap.record(
        CapturedPacket(
          transport: 'udp',
          direction: PacketDirection.outgoing,
          remote: 'x:$i',
          bytes: utf8.encode('$i'),
        ),
      );
    }
    expect(tap.recent.map((p) => p.text), ['1', '2']);
  });

  group('Wake-on-LAN', () {
    test('builds the 102-byte magic packet', () {
      final packet = wakeOnLanPacket('AA:BB:CC:00:11:22');
      expect(packet.length, 102);
      expect(packet.sublist(0, 6), List.filled(6, 0xFF));
      for (var i = 0; i < 16; i++) {
        expect(packet.sublist(6 + i * 6, 12 + i * 6), [
          0xAA,
          0xBB,
          0xCC,
          0x00,
          0x11,
          0x22,
        ]);
      }
    });

    test('accepts dashes and rejects a short MAC', () {
      expect(wakeOnLanPacket('aa-bb-cc-00-11-22').length, 102);
      expect(() => wakeOnLanPacket('AA:BB:CC'), throwsArgumentError);
    });
  });

  test('directed broadcast for common prefixes', () {
    String b(String ip, int prefix) =>
        directedBroadcast(InternetAddress(ip), prefix).address;
    expect(b('192.168.1.20', 24), '192.168.1.255');
    expect(b('10.0.5.9', 16), '10.0.255.255');
    expect(b('172.16.3.4', 22), '172.16.3.255');
    expect(b('192.168.1.20', 32), '192.168.1.20');
    expect(
      () => directedBroadcast(InternetAddress('::1'), 64),
      throwsArgumentError,
    );
  });
}
