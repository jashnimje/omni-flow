import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/discovery/ssdp_discovery.dart';
import 'package:test/test.dart';

/// Replies in the shape the Roku ECP and Sonos documentation show.
const rokuReply =
    'HTTP/1.1 200 OK\r\nCache-Control: max-age=3600\r\nST: roku:ecp\r\n'
    'Location: http://127.0.0.1:8060/\r\nUSN: uuid:roku:ecp:P0A070000007\r\n\r\n';
const sonosReply =
    'HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age = 1800\r\n'
    'LOCATION: http://127.0.0.1:1400/xml/device_description.xml\r\n'
    'SERVER: Linux UPnP/1.0 Sonos/70.3-35220 (ZPS1)\r\n'
    'ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n'
    'USN: uuid:RINCON_000E58A0123401400::urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n';

/// A loopback SSDP responder: answers each M-SEARCH whose ST it knows.
class FakeResponder {
  FakeResponder._(this._socket) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = _socket.receive();
      if (d == null) return;
      final text = ascii.decode(d.data);
      searches.add(text);
      final st = RegExp(
        r'^ST: (.+)$',
        multiLine: true,
      ).firstMatch(text)?.group(1)?.trim();
      for (final reply in replies[st] ?? const <String>[]) {
        _socket.send(ascii.encode(reply), d.address, d.port);
      }
    });
  }

  static Future<FakeResponder> start() async => FakeResponder._(
    await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
  );

  final RawDatagramSocket _socket;
  final searches = <String>[];
  final replies = <String, List<String>>{
    'roku:ecp': [rokuReply],
    'urn:schemas-upnp-org:device:ZonePlayer:1': [
      sonosReply,
      rokuReply.replaceFirst('ST: roku:ecp', 'ST: urn:other'),
    ],
  };

  int get port => _socket.port;

  void close() => _socket.close();
}

void main() {
  late FakeResponder responder;
  late SsdpDiscovery ssdp;

  setUp(() async {
    responder = await FakeResponder.start();
    ssdp = SsdpDiscovery(
      targets: () async => [InternetAddress.loopbackIPv4],
      port: responder.port,
    );
  });

  tearDown(() => responder.close());

  test(
    'an M-SEARCH names its target, and a Roku answer gives its serial',
    () async {
      final found = await ssdp.discover(
        'roku:ecp',
        window: const Duration(milliseconds: 200),
      );
      expect(responder.searches.first, startsWith('M-SEARCH * HTTP/1.1\r\n'));
      expect(responder.searches.first, contains('MAN: "ssdp:discover"\r\n'));
      expect(responder.searches.first, contains('ST: roku:ecp\r\n'));
      expect(found, hasLength(1));
      expect(found.single.host, '127.0.0.1');
      expect(found.single.port, 8060);
      expect(found.single.stableId('usn'), 'P0A070000007');
    },
  );

  test(
    'a Sonos answer gives its RINCON id, and another ST is dropped',
    () async {
      final found = await ssdp.discover(
        'urn:schemas-upnp-org:device:ZonePlayer:1',
        window: const Duration(milliseconds: 200),
      );
      expect(found, hasLength(1));
      expect(found.single.port, 1400);
      expect(found.single.stableId('usn'), 'RINCON_000E58A0123401400');
      expect(found.single.headers['server'], contains('Sonos'));
    },
  );

  test('a reply from outside the local network is dropped', () async {
    final strict = SsdpDiscovery(
      targets: () async => [InternetAddress.loopbackIPv4],
      port: responder.port,
      acceptFrom: (_) => false,
    );
    expect(
      await strict.discover(
        'roku:ecp',
        window: const Duration(milliseconds: 200),
      ),
      isEmpty,
    );
  });

  test('a search target with header text in it is refused', () {
    expect(() => ssdp.discover('roku:ecp\r\nX-Evil: 1'), throwsArgumentError);
  });

  test('parse takes only a 200 reply, never another M-SEARCH', () {
    expect(
      SsdpDiscovery.parse(rokuReply)?['usn'],
      'uuid:roku:ecp:P0A070000007',
    );
    expect(
      SsdpDiscovery.parse(ascii.decode(SsdpDiscovery.search('roku:ecp'))),
      isNull,
    );
  });

  test('device discovery finds the built-in Roku and Sonos drivers', () async {
    final udp = await UdpTransport.bind();
    addTearDown(udp.close);
    final discovery = DeviceDiscovery(
      udp: UdpDiscovery(udp, targets: () async => const []),
      ssdp: ssdp,
    );
    final registry = DriverRegistry.withBuiltIns();
    final sweep = await discovery.discoverAll([
      registry['roku_ecp']!,
      registry['sonos_upnp']!,
    ], window: const Duration(milliseconds: 200));
    final roku = sweep.found['roku_ecp']!.single;
    expect(roku.stableId, 'P0A070000007');
    expect(roku.port, 8060);
    expect(roku.method, ssdpMethod);
    expect(
      sweep.found['sonos_upnp']!.single.stableId,
      'RINCON_000E58A0123401400',
    );
    expect(sweep.failures, isEmpty);
  });

  test('a manifest ssdp entry needs a plain search target', () {
    Map<String, Object?> manifest(Object? st) => {
      'schemaVersion': 1,
      'id': 'x',
      'name': 'X',
      'category': 'media',
      'transport': {'type': 'http', 'port': 80},
      'discovery': [
        {'method': 'ssdp', 'st': ?st},
      ],
      'capabilities': [
        {
          'id': 'home',
          'type': 'action',
          'command': {'path': '/keypress/Home'},
        },
      ],
    };
    for (final bad in [null, 'a\r\nb', '']) {
      expect(
        () => DriverManifest.parse(manifest(bad)),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.issues.map((i) => i.path).join(),
            'issues',
            contains('discovery'),
          ),
        ),
        reason: '$bad',
      );
    }
    expect(DriverManifest.parse(manifest('roku:ecp')).discovery, hasLength(1));
  });
}
