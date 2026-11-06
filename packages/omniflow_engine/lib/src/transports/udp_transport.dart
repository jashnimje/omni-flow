import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'packet_tap.dart';

class UdpDatagram {
  UdpDatagram(this.address, this.port, this.bytes);

  final InternetAddress address;
  final int port;
  final Uint8List bytes;

  String get text => utf8.decode(bytes, allowMalformed: true);
}

class TransportTimeoutException implements Exception {
  TransportTimeoutException(this.message);

  final String message;

  @override
  String toString() => 'TransportTimeoutException: $message';
}

/// One bound UDP socket, owned for the transport's whole life.
///
/// The same socket sends commands, receives replies and receives pushed
/// state, so no call binds a throwaway socket.
class UdpTransport {
  UdpTransport._(this._socket, this._tap) {
    _socket.broadcastEnabled = true;
    _socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final datagram = _socket.receive();
        if (datagram == null) return;
        final received = UdpDatagram(
          datagram.address,
          datagram.port,
          datagram.data,
        );
        _tap?.record(
          CapturedPacket(
            transport: 'udp',
            direction: PacketDirection.incoming,
            remote: '${datagram.address.address}:${datagram.port}',
            bytes: datagram.data,
          ),
        );
        _incoming.add(received);
      },
      onError: (Object _) {
        // A send the OS could not route (no network, no broadcast route)
        // comes back here on some systems. It is not a reply: ignore it.
      },
    );
  }

  /// Binds on all IPv4 interfaces. Port 0 picks a free port.
  static Future<UdpTransport> bind({int port = 0, PacketTap? tap}) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    return UdpTransport._(socket, tap);
  }

  final RawDatagramSocket _socket;
  final PacketTap? _tap;
  final _incoming = StreamController<UdpDatagram>.broadcast();

  int get localPort => _socket.port;

  Stream<UdpDatagram> get incoming => _incoming.stream;

  void send(InternetAddress address, int port, List<int> bytes) {
    final sent = _socket.send(bytes, address, port);
    if (sent != bytes.length) {
      throw SocketException(
        'sent $sent of ${bytes.length} bytes to ${address.address}:$port',
      );
    }
    _tap?.record(
      CapturedPacket(
        transport: 'udp',
        direction: PacketDirection.outgoing,
        remote: '${address.address}:$port',
        bytes: Uint8List.fromList(bytes),
      ),
    );
  }

  /// Sends [bytes] and waits for the first datagram back from the same
  /// address and port that [accept] (when given) agrees is the reply.
  /// Resends up to [retries] times, waiting [timeout] each time.
  Future<UdpDatagram> request(
    InternetAddress address,
    int port,
    List<int> bytes, {
    Duration timeout = const Duration(seconds: 1),
    int retries = 0,
    bool Function(UdpDatagram reply)? accept,
  }) async {
    final reply = Completer<UdpDatagram>();
    final subscription = incoming.listen((d) {
      if (!reply.isCompleted &&
          d.address == address &&
          d.port == port &&
          (accept == null || accept(d))) {
        reply.complete(d);
      }
    });
    try {
      for (var attempt = 0; attempt <= retries; attempt++) {
        send(address, port, bytes);
        try {
          return await reply.future.timeout(timeout);
        } on TimeoutException {
          continue;
        }
      }
      throw TransportTimeoutException(
        'no reply from ${address.address}:$port after ${retries + 1} attempts',
      );
    } finally {
      await subscription.cancel();
    }
  }

  void close() {
    _socket.close();
    _incoming.close();
  }
}

/// The Wake-on-LAN magic packet: six 0xFF bytes, then the MAC 16 times.
Uint8List wakeOnLanPacket(String mac) {
  final hex = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (hex.length != 12) {
    throw ArgumentError.value(
      mac,
      'mac',
      'must be 6 bytes, for example AA:BB:CC:DD:EE:FF',
    );
  }
  final macBytes = [
    for (var i = 0; i < 12; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  return Uint8List.fromList([
    ...List.filled(6, 0xFF),
    for (var i = 0; i < 16; i++) ...macBytes,
  ]);
}

/// The subnet-directed broadcast address for [address]/[prefixLength],
/// for example 192.168.1.20/24 -> 192.168.1.255.
InternetAddress directedBroadcast(InternetAddress address, int prefixLength) {
  if (address.type != InternetAddressType.IPv4) {
    throw ArgumentError.value(address, 'address', 'must be IPv4');
  }
  if (prefixLength < 0 || prefixLength > 32) {
    throw RangeError.range(prefixLength, 0, 32, 'prefixLength');
  }
  final raw = address.rawAddress;
  final value = (raw[0] << 24) | (raw[1] << 16) | (raw[2] << 8) | raw[3];
  final hostMask = prefixLength == 32 ? 0 : (0xFFFFFFFF >> prefixLength);
  final broadcast = (value | hostMask) & 0xFFFFFFFF;
  return InternetAddress.fromRawAddress(
    Uint8List.fromList([
      (broadcast >> 24) & 0xFF,
      (broadcast >> 16) & 0xFF,
      (broadcast >> 8) & 0xFF,
      broadcast & 0xFF,
    ]),
  );
}
