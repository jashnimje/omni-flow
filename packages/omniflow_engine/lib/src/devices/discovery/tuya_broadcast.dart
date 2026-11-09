import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../codecs/crc32.dart';
import '../../transports/packet_tap.dart';
import '../../transports/udp_transport.dart';

/// The discovery method a driver manifest names for Tuya LAN broadcasts.
const tuyaBroadcastMethod = 'tuya_broadcast';

/// 6666 carries v3.1 plaintext announcements, 6667 the encrypted v3.3+ ones.
const tuyaBroadcastPorts = [6666, 6667];

/// The fixed key every Tuya device encrypts its LAN announcement with:
/// md5("yGAdlopoPVldABfn"), as in tinytuya's `udp_helper.udpkey`. It is a
/// published protocol constant shared by all devices, not a device secret.
final Uint8List tuyaUdpKey = MD5Digest().process(
  Uint8List.fromList(ascii.encode('yGAdlopoPVldABfn')),
);

/// One device's LAN announcement.
class TuyaBroadcast {
  const TuyaBroadcast({
    required this.gwId,
    required this.json,
    this.ip,
    this.version,
    this.productKey,
  });

  /// The device id (`devId`), stable across address changes.
  final String gwId;

  /// The address the device says it has. Discovery uses the datagram's
  /// source address instead, which is where the device really is.
  final String? ip;

  /// The protocol version, for example `3.3`.
  final String? version;
  final String? productKey;

  /// The whole decoded announcement.
  final Map<String, Object?> json;
}

/// A heard announcement and the address it came from.
class TuyaSighting {
  const TuyaSighting(this.host, this.broadcast);

  final String host;
  final TuyaBroadcast broadcast;
}

const _prefix55aa = 0x000055AA;
const _suffix55aa = 0x0000AA55;
const _prefix6699 = 0x00006699;
const _suffix6699 = 0x00009966;
const _header55aa = 16;
const _header6699 = 18;
const _retcodeLength = 4;
const _gcmIvLength = 12;
const _gcmTagLength = 16;

final _gwIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _versionPattern = RegExp(r'^\d{1,2}\.\d{1,2}$');

/// Decodes one announcement datagram, or returns null when it is not one.
///
/// Follows tinytuya's `decrypt_udp`: a 0x55AA frame (16-byte header, 4-byte
/// return code, payload, CRC-32, suffix) carries plaintext JSON on 6666 and
/// AES-128-ECB JSON on 6667; a 0x6699 frame (v3.5) carries AES-GCM JSON with
/// the header as associated data; anything else is tried as bare ECB.
TuyaBroadcast? decodeTuyaBroadcast(Uint8List datagram) {
  final Uint8List? plain;
  try {
    plain = _payload(datagram);
  } on Object {
    return null;
  }
  if (plain == null) return null;
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(plain));
  } on FormatException {
    return null;
  }
  if (json is! Map) return null;
  final gwId = json['gwId'];
  if (gwId is! String || !_gwIdPattern.hasMatch(gwId)) return null;
  final version = json['version'];
  final ip = json['ip'];
  final productKey = json['productKey'];
  return TuyaBroadcast(
    gwId: gwId,
    ip: ip is String ? ip : null,
    version: version is String && _versionPattern.hasMatch(version)
        ? version
        : null,
    productKey: productKey is String ? productKey : null,
    json: Map<String, Object?>.from(json),
  );
}

Uint8List? _payload(Uint8List data) {
  final view = ByteData.sublistView(data);
  final prefix = data.length >= 4 ? view.getUint32(0) : null;
  if (prefix == _prefix55aa) {
    if (data.length < _header55aa + _retcodeLength + 8) return null;
    final end = _header55aa + view.getUint32(12);
    if (end > data.length || end < _header55aa + _retcodeLength + 8) {
      return null;
    }
    if (view.getUint32(end - 4) != _suffix55aa) return null;
    final crcAt = end - 8;
    if (view.getUint32(crcAt) != crc32(Uint8List.sublistView(data, 0, crcAt))) {
      return null;
    }
    final payload = Uint8List.sublistView(
      data,
      _header55aa + _retcodeLength,
      crcAt,
    );
    if (payload.isNotEmpty && payload.first == 0x7B && payload.last == 0x7D) {
      return payload;
    }
    return _ecb(false, payload);
  }
  if (prefix == _prefix6699) {
    if (data.length < _header6699) return null;
    final end = _header6699 + view.getUint32(14);
    if (end + 4 > data.length ||
        end - _header6699 < _gcmIvLength + _gcmTagLength) {
      return null;
    }
    if (view.getUint32(end) != _suffix6699) return null;
    final iv = Uint8List.sublistView(
      data,
      _header6699,
      _header6699 + _gcmIvLength,
    );
    final sealed = Uint8List.sublistView(data, _header6699 + _gcmIvLength, end);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(tuyaUdpKey),
          _gcmTagLength * 8,
          iv,
          Uint8List.sublistView(data, 4, _header6699),
        ),
      );
    var plain = gcm.process(sealed);
    if (plain.length > _retcodeLength &&
        plain.first != 0x7B &&
        plain[_retcodeLength] == 0x7B) {
      plain = Uint8List.sublistView(plain, _retcodeLength);
    }
    var length = plain.length;
    while (length > 0 && plain[length - 1] == 0) {
      length--;
    }
    return Uint8List.sublistView(plain, 0, length);
  }
  if (data.isEmpty || data.length % 16 != 0) return null;
  return _ecb(false, data);
}

Uint8List _ecb(bool encrypt, Uint8List input) {
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))..init(
        encrypt,
        PaddedBlockCipherParameters<KeyParameter, Null>(
          KeyParameter(tuyaUdpKey),
          null,
        ),
      );
  return cipher.process(input);
}

/// Frames [json] as a device announcement, for emulators and tests: 0x55AA
/// with a zero return code, plaintext when [encrypt] is false (v3.1, on
/// 6666) and AES-128-ECB with [tuyaUdpKey] otherwise (v3.3, on 6667).
Uint8List encodeTuyaBroadcast(
  Map<String, Object?> json, {
  bool encrypt = true,
  int seq = 0,
}) {
  final body = Uint8List.fromList(utf8.encode(jsonEncode(json)));
  final payload = encrypt ? _ecb(true, body) : body;
  final length = _retcodeLength + payload.length + 8;
  final header = ByteData(_header55aa + _retcodeLength)
    ..setUint32(0, _prefix55aa)
    ..setUint32(4, seq)
    ..setUint32(8, encrypt ? 0x13 : 0)
    ..setUint32(12, length);
  final framed = Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...payload,
  ]);
  final trailer = ByteData(8)
    ..setUint32(0, crc32(framed))
    ..setUint32(4, _suffix55aa);
  return Uint8List.fromList([...framed, ...trailer.buffer.asUint8List()]);
}

/// Binds the receive socket for one broadcast port.
typedef TuyaSocketBinder = Future<RawDatagramSocket> Function(int port);

Future<RawDatagramSocket> _bindAny(int port) =>
    RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);

/// Listens for Tuya LAN announcements on UDP 6666 and 6667.
///
/// Receive only: nothing is ever sent from these sockets, and they are open
/// only while a [sightings] stream has a listener. Senders outside the
/// local network are dropped, because a sighting becomes a device address.
class TuyaDiscovery {
  TuyaDiscovery({
    this.ports = tuyaBroadcastPorts,
    this._bind = _bindAny,
    this._acceptFrom = isLocalNetworkAddress,
    this._tap,
  });

  final List<int> ports;
  final TuyaSocketBinder _bind;
  final bool Function(InternetAddress from) _acceptFrom;
  final PacketTap? _tap;

  /// Every announcement heard while listened to. Fails with a
  /// [SocketException] only when no port could be bound (another program
  /// holding both without address reuse).
  Stream<TuyaSighting> sightings() {
    final sockets = <RawDatagramSocket>[];
    var cancelled = false;
    late final StreamController<TuyaSighting> controller;
    void closeAll() {
      for (final s in sockets) {
        s.close();
      }
      sockets.clear();
    }

    Future<void> start() async {
      Object? lastError;
      for (final port in ports) {
        try {
          sockets.add(await _bind(port));
        } on SocketException catch (e) {
          lastError = e;
        }
        if (cancelled) {
          closeAll();
          return;
        }
      }
      if (sockets.isEmpty) {
        controller.addError(
          lastError ??
              const SocketException('no Tuya broadcast port to listen on'),
        );
        unawaited(controller.close());
        return;
      }
      for (final socket in sockets) {
        socket.listen(
          (event) {
            if (event != RawSocketEvent.read) return;
            final datagram = socket.receive();
            if (datagram == null || !_acceptFrom(datagram.address)) return;
            _tap?.record(
              CapturedPacket(
                transport: 'udp',
                direction: PacketDirection.incoming,
                remote: '${datagram.address.address}:${datagram.port}',
                bytes: datagram.data,
              ),
            );
            final broadcast = decodeTuyaBroadcast(datagram.data);
            if (broadcast != null && !cancelled) {
              controller.add(TuyaSighting(datagram.address.address, broadcast));
            }
          },
          onError: (Object _) {
            // A send the OS could not route (no network, no broadcast route)
            // comes back here on some systems. It is not a reply: ignore it.
          },
        );
      }
    }

    controller = StreamController<TuyaSighting>(
      onListen: () => unawaited(start()),
      onCancel: () {
        cancelled = true;
        closeAll();
      },
    );
    return controller.stream;
  }

  /// The devices heard within [window], one per `gwId` (the latest wins).
  Future<List<TuyaSighting>> discover({
    Duration window = const Duration(seconds: 6),
  }) async {
    final found = <String, TuyaSighting>{};
    await _listen(window, (s) {
      found[s.broadcast.gwId.toLowerCase()] = s;
      return false;
    });
    return found.values.toList();
  }

  /// The address of the device whose `gwId` is [gwId], as soon as it is
  /// heard, or null when it is not heard within [window] or no port could
  /// be bound.
  Future<String?> locate(
    String gwId, {
    Duration window = const Duration(seconds: 6),
  }) async {
    final wanted = gwId.toLowerCase();
    String? host;
    try {
      await _listen(window, (s) {
        if (s.broadcast.gwId.toLowerCase() != wanted) return false;
        host = s.host;
        return true;
      });
    } on SocketException {
      return null;
    }
    return host;
  }

  /// Feeds sightings to [onSighting] until it returns true or [window]
  /// ends, then closes the sockets.
  Future<void> _listen(
    Duration window,
    bool Function(TuyaSighting sighting) onSighting,
  ) async {
    final done = Completer<void>();
    final subscription = sightings().listen(
      (s) {
        if (onSighting(s) && !done.isCompleted) done.complete();
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    try {
      await done.future.timeout(window, onTimeout: () {});
    } finally {
      await subscription.cancel();
    }
  }
}
