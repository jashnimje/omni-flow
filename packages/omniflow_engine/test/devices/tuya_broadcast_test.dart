import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// Self-generated vectors, not captures from a device. Each is a made-up
/// announcement framed and encrypted with the documented UDP key by
/// tinytuya 1.20.0's own `pack_message` and `AESCipher`, then checked to
/// decode with tinytuya's `decrypt_udp`. The ids are fixtures.
const tinytuyaVectors = {
  '3.1': '000055aa00000000000000000000009f000000007b226970223a223139322e3136382e312e3530222c2267774964223a226266303132333435363738396162636465666768222c22616374697665223a322c226162696c697479223a302c226d6f6465223a302c22656e6372797074223a66616c73652c2270726f647563744b6579223a226b657966697874757265313233343536222c2276657273696f6e223a22332e31227dc97062ca0000aa55',
  '3.3': '000055aa0000000000000013000000ac00000000d09766676f3369eb10b5e9f132fd802a70172896956a9e330910344d11ac363f482611d8caa5248ac6cea65bdad007dfa41f010dca2abb30c50459a9f88024ffcb5924bb8792fe5eae7c9040e5921a98017f2170860421e6fc66f0a1ade138915fde850cd157270c5f3d1ab5ae90b300e5e6b90c2ea770deee7aa446856983fb1c8343bc25f3403c0c4c3db59350d34ae0bd1f2cbad705886d4ed8eed5ab9eb934fbb6a10000aa55',
  '3.5': '0000669900000000000000000013000000ae3031323334353637383961627f0e8c5c409ea2eaa8b6c4436693f7333132c436aeaada5e4d17a3aa76a64bdf0808d1a32b6328381ed7615e42cba5e1b0861bae925d7fa1de7fa1ef7336569437009968f6360fedc781791ed8ca73fbfb288a876860c00938da6a5a54b83cff01e9a8414c4907fcc394980f325ebfd65631797cad7400c86df96ce713ab5c7f62ac50f8e37d415e1832b2d14987e797af0fa35d212e09f2aec2d63268c0ab15c92500009966',
};

/// The announcement the vectors carry, in the key order tinytuya encoded.
Map<String, Object?> announcement(
  String version, {
  String gwId = 'bf0123456789abcdefgh',
}) => {
  'ip': '192.168.1.50',
  'gwId': gwId,
  'active': 2,
  'ability': 0,
  'mode': 0,
  'encrypt': version != '3.1',
  'productKey': 'keyfixture123456',
  'version': version,
};

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Binds each broadcast port as a loopback socket on a free port instead.
class LoopbackBinder {
  final sockets = <int, SpySocket>{};
  final ports = <int, int>{};

  Future<RawDatagramSocket> call(int port) async {
    final socket = SpySocket(
      await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    sockets[port] = socket;
    ports[port] = socket.inner.port;
    return socket;
  }

  int portFor(int broadcastPort) => ports[broadcastPort]!;
}

/// A loopback socket that records whether it was closed, the only part of
/// the socket the listener uses besides listen and receive.
class SpySocket extends Stream<RawSocketEvent> implements RawDatagramSocket {
  SpySocket(this.inner);

  final RawDatagramSocket inner;
  var closed = false;

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => inner.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Datagram? receive() => inner.receive();

  @override
  void close() {
    closed = true;
    inner.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> announce(int port, Uint8List frame) async {
  final sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  sender.send(frame, InternetAddress.loopbackIPv4, port);
  sender.close();
}

Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('decoding', () {
    test('the UDP key is md5 of the documented seed', () {
      expect(toHex(tuyaUdpKey), '6c1ec8e2bb9bb59ab50b0daf649b410a');
    });

    for (final MapEntry(key: version, value: frame)
        in tinytuyaVectors.entries) {
      test('decodes the tinytuya-built v$version announcement', () {
        final decoded = decodeTuyaBroadcast(hex(frame))!;
        expect(decoded.gwId, 'bf0123456789abcdefgh');
        expect(decoded.version, version);
        expect(decoded.ip, '192.168.1.50');
        expect(decoded.productKey, 'keyfixture123456');
        expect(decoded.json, announcement(version));
      });
    }

    test('encodes byte for byte what tinytuya packs', () {
      expect(
        toHex(encodeTuyaBroadcast(announcement('3.1'), encrypt: false)),
        tinytuyaVectors['3.1'],
      );
      expect(
        toHex(encodeTuyaBroadcast(announcement('3.3'))),
        tinytuyaVectors['3.3'],
      );
    });

    test('a bare ECB datagram with no frame is decoded too', () {
      final framed = hex(tinytuyaVectors['3.3']!);
      final bare = Uint8List.sublistView(framed, 20, framed.length - 8);
      expect(decodeTuyaBroadcast(bare)?.gwId, 'bf0123456789abcdefgh');
    });

    test('corrupt, foreign and malformed datagrams are not devices', () {
      final good = hex(tinytuyaVectors['3.3']!);
      final badCrc = Uint8List.fromList(good)..[good.length - 5] ^= 1;
      final gcm = hex(tinytuyaVectors['3.5']!);
      final badTag = Uint8List.fromList(gcm)..[gcm.length - 6] ^= 1;
      final badAad = Uint8List.fromList(gcm)..[5] ^= 1;
      final cases = {
        'empty': Uint8List(0),
        'CRC flipped': badCrc,
        'cut short': Uint8List.sublistView(good, 0, 40),
        'length past the end': Uint8List.fromList(good)..[15] = 0xff,
        'GCM tag flipped': badTag,
        'GCM header flipped': badAad,
        'plain text': Uint8List.fromList(utf8.encode('hello')),
        'a WiZ reply': Uint8List.fromList(
          utf8.encode('{"method":"registration","result":{"mac":"a8bb"}}'),
        ),
        'no gwId': encodeTuyaBroadcast({'ip': '10.0.0.2', 'version': '3.3'}),
        'gwId that is not an id': encodeTuyaBroadcast({
          'gwId': 'x; rm -rf /',
          'version': '3.3',
        }),
        'gwId not a string': encodeTuyaBroadcast({'gwId': 7}),
        'sound frame under another key': TuyaCodec('0123456789abcdef').encode(
          seq: 0,
          command: TuyaCommand.dpQuery,
          body: announcement('3.3'),
          retcode: 0,
        ),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(decodeTuyaBroadcast(value), isNull, reason: key);
      }
    });

    test('an unknown version string is dropped, the device is kept', () {
      final decoded = decodeTuyaBroadcast(
        encodeTuyaBroadcast({'gwId': 'abc123', 'version': '3.3; drop'}),
      )!;
      expect(decoded.gwId, 'abc123');
      expect(decoded.version, isNull);
    });
  });

  group('listening', () {
    test(
      'hears v3.1 on 6666 and v3.3 on 6667, keyed by gwId, from the sender',
      () async {
        final binder = LoopbackBinder();
        final tuya = TuyaDiscovery(bind: binder.call);
        final found = tuya.discover(window: const Duration(milliseconds: 400));
        await until(() => binder.sockets.length == 2);
        await announce(
          binder.portFor(6666),
          encodeTuyaBroadcast(
            announcement('3.1', gwId: 'plainplug0001'),
            encrypt: false,
          ),
        );
        await announce(
          binder.portFor(6667),
          encodeTuyaBroadcast(announcement('3.3', gwId: 'cryptplug0002')),
        );
        await announce(
          binder.portFor(6667),
          encodeTuyaBroadcast(announcement('3.3', gwId: 'cryptplug0002')),
        );
        final sightings = await found;
        expect(
          {for (final s in sightings) s.broadcast.gwId: s.broadcast.version},
          {'plainplug0001': '3.1', 'cryptplug0002': '3.3'},
        );
        expect(sightings.map((s) => s.host).toSet(), {'127.0.0.1'});
      },
    );

    test('closes its sockets when the window ends', () async {
      final binder = LoopbackBinder();
      await TuyaDiscovery(bind: binder.call)
          .discover(window: const Duration(milliseconds: 100));
      expect(binder.sockets, hasLength(2));
      // Rebinding the freed port instead races other test files for it.
      expect(binder.sockets.values.map((s) => s.closed), [true, true]);
    });

    test('a sender outside the local network is ignored', () async {
      final binder = LoopbackBinder();
      final asked = <String>[];
      final tuya = TuyaDiscovery(
        bind: binder.call,
        acceptFrom: (from) {
          asked.add(from.address);
          return false;
        },
      );
      final found = tuya.discover(window: const Duration(milliseconds: 300));
      await until(() => binder.sockets.length == 2);
      await announce(
        binder.portFor(6667),
        encodeTuyaBroadcast(announcement('3.3')),
      );
      expect(await found, isEmpty);
      expect(asked, ['127.0.0.1']);
    });

    test('locate answers as soon as the device is heard', () async {
      final binder = LoopbackBinder();
      final tuya = TuyaDiscovery(bind: binder.call);
      final clock = Stopwatch()..start();
      final host = tuya.locate(
        'CRYPTPLUG0002',
        window: const Duration(seconds: 10),
      );
      await until(() => binder.sockets.length == 2);
      await announce(
        binder.portFor(6667),
        encodeTuyaBroadcast(announcement('3.3', gwId: 'otherplug')),
      );
      await announce(
        binder.portFor(6667),
        encodeTuyaBroadcast(announcement('3.3', gwId: 'cryptplug0002')),
      );
      expect(await host, '127.0.0.1');
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('locate gives null for a device that is not heard', () async {
      final binder = LoopbackBinder();
      expect(
        await TuyaDiscovery(bind: binder.call)
            .locate('nobody', window: const Duration(milliseconds: 150)),
        isNull,
      );
    });

    test('one port held elsewhere still listens on the other', () async {
      final binder = LoopbackBinder();
      final tuya = TuyaDiscovery(
        bind: (port) => port == 6666
            ? throw const SocketException('address in use')
            : binder(port),
      );
      final found = tuya.discover(window: const Duration(milliseconds: 300));
      await until(() => binder.sockets.length == 1);
      await announce(
        binder.portFor(6667),
        encodeTuyaBroadcast(announcement('3.3')),
      );
      expect((await found).single.broadcast.gwId, 'bf0123456789abcdefgh');
    });

    test('no port to listen on fails discover and gives locate null', () async {
      final tuya = TuyaDiscovery(
        bind: (_) => throw const SocketException('address in use'),
      );
      await expectLater(tuya.discover(), throwsA(isA<SocketException>()));
      expect(await tuya.locate('anything'), isNull);
    });
  });

  group('DeviceDiscovery', () {
    final plug = DriverRegistry.withBuiltIns()['tuya_plug']!;
    final discoverable = DriverManifest(
      id: plug.id,
      name: plug.name,
      category: plug.category,
      transport: plug.transport,
      capabilities: plug.capabilities,
      settings: plug.settings,
      reliability: plug.reliability,
      discovery: const [DiscoverySpec(tuyaBroadcastMethod, {})],
    );

    test('a tuya_broadcast driver is found and healed by gwId', () async {
      final udp = await UdpTransport.bind();
      addTearDown(udp.close);
      final binder = LoopbackBinder();
      final discovery = DeviceDiscovery(
        udp: UdpDiscovery(udp, targets: () async => const []),
        tuya: TuyaDiscovery(bind: binder.call),
        tuyaMinimumWindow: const Duration(milliseconds: 300),
      );
      final located = discovery.locator(discoverable, 'cryptplug0002');
      await until(() => binder.sockets.length == 2);
      await announce(
        binder.portFor(6667),
        encodeTuyaBroadcast(announcement('3.3', gwId: 'cryptplug0002')),
      );
      expect(await located, '127.0.0.1');

      binder.sockets.clear();
      final found = discovery.discover(
        discoverable,
        window: const Duration(milliseconds: 300),
      );
      await until(() => binder.sockets.length == 2);
      await announce(
        binder.portFor(6666),
        encodeTuyaBroadcast(
          announcement('3.1', gwId: 'plainplug0001'),
          encrypt: false,
        ),
      );
      final hit = (await found).single;
      expect(hit.toJson(), {
        'host': '127.0.0.1',
        'stableId': 'plainplug0001',
        'method': 'tuya_broadcast',
        'reply': announcement('3.1', gwId: 'plainplug0001'),
      });
    });

    test('unbindable Tuya ports are unavailable, and other methods still '
        'report', () async {
      final udp = await UdpTransport.bind();
      addTearDown(udp.close);
      final discovery = DeviceDiscovery(
        udp: UdpDiscovery(udp, targets: () async => const []),
        tuya: TuyaDiscovery(
          bind: (_) => throw const SocketException('address in use'),
        ),
        tuyaMinimumWindow: const Duration(milliseconds: 100),
      );
      await expectLater(
        discovery.discover(discoverable),
        throwsA(
          isA<ApiError>()
              .having((e) => e.type, 'type', 'unavailable')
              .having((e) => e.message, 'message', contains('6666 or 6667')),
        ),
      );

      final both = DriverManifest(
        id: plug.id,
        name: plug.name,
        category: plug.category,
        transport: plug.transport,
        capabilities: plug.capabilities,
        settings: plug.settings,
        reliability: plug.reliability,
        discovery: const [
          DiscoverySpec(tuyaBroadcastMethod, {}),
          DiscoverySpec('udp_broadcast', {
            'port': 6666,
            'probe': {'probe': 1},
          }),
        ],
      );
      expect(
        await discovery.discover(
          both,
          window: const Duration(milliseconds: 100),
        ),
        isEmpty,
      );
    });
  });
}
