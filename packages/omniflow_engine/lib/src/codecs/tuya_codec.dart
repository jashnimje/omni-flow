import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'crc32.dart';

/// Tuya local protocol command codes (TCP 6668).
abstract final class TuyaCommand {
  static const sessionKeyStart = 3;
  static const sessionKeyResponse = 4;
  static const sessionKeyFinish = 5;
  static const control = 7;
  static const status = 8;
  static const heartbeat = 9;
  static const dpQuery = 0x0a;
  static const dpQueryNew = 0x10;
  static const updateDps = 0x12;
  static const lanExtStream = 0x40;

  /// Commands sent without the "3.3" version header.
  static const withoutVersionHeader = {
    dpQuery,
    dpQueryNew,
    updateDps,
    heartbeat,
    sessionKeyStart,
    sessionKeyResponse,
    sessionKeyFinish,
    lanExtStream,
  };
}

class TuyaDecodeException implements Exception {
  TuyaDecodeException(this.message);

  final String message;

  @override
  String toString() => 'TuyaDecodeException: $message';
}

class TuyaFrame {
  const TuyaFrame({
    required this.seq,
    required this.command,
    required this.retcode,
    required this.body,
  });

  final int seq;
  final int command;

  /// The device's return code. Null for frames sent by a client.
  final int? retcode;

  /// The decrypted JSON body, or null when the frame carried no payload.
  final Map<String, Object?>? body;
}

const _prefix = 0x000055AA;
const _suffix = 0x0000AA55;
const _headerLength = 16;
const _trailerLength = 8;
final _version33Header = Uint8List.fromList([
  ...ascii.encode('3.3'),
  ...List.filled(12, 0),
]);

/// Encodes and decodes Tuya v3.3 frames, keyed by the device's 16-byte local key.
///
/// v3.4 (session key, HMAC) and v3.5 (0x6699 prefix, AES-GCM) are added once
/// a scan of the user's devices shows they are needed.
class TuyaCodec {
  TuyaCodec(String localKey, {this.version = '3.3'})
    : _key = Uint8List.fromList(utf8.encode(localKey)) {
    if (_key.length != 16) {
      throw ArgumentError('a Tuya local key is 16 bytes, got ${_key.length}');
    }
    if (version != '3.3') {
      throw UnsupportedError('Tuya protocol $version is not implemented yet');
    }
  }

  final Uint8List _key;
  final String version;

  /// A client frame: header, optional version header, AES-128-ECB body, CRC-32, suffix.
  ///
  /// A device reply (for an emulator or a test) passes [retcode], which goes
  /// right after the header. A null [body] sends no payload, as a device does
  /// when it acknowledges a control command.
  Uint8List encode({
    required int seq,
    required int command,
    required Map<String, Object?>? body,
    int? retcode,
  }) {
    final payload = BytesBuilder(copy: false);
    if (retcode != null) {
      payload.add((ByteData(4)..setUint32(0, retcode)).buffer.asUint8List());
    }
    if (body != null) {
      if (!TuyaCommand.withoutVersionHeader.contains(command)) {
        payload.add(_version33Header);
      }
      payload.add(
        _aes(true, Uint8List.fromList(utf8.encode(jsonEncode(body)))),
      );
    }
    final payloadBytes = payload.toBytes();

    final header = ByteData(_headerLength)
      ..setUint32(0, _prefix)
      ..setUint32(4, seq)
      ..setUint32(8, command)
      ..setUint32(12, payloadBytes.length + _trailerLength);
    final data = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(payloadBytes);
    final beforeTrailer = data.toBytes();
    final trailer = ByteData(_trailerLength)
      ..setUint32(0, crc32(beforeTrailer))
      ..setUint32(4, _suffix);
    return Uint8List.fromList([
      ...beforeTrailer,
      ...trailer.buffer.asUint8List(),
    ]);
  }

  /// Decodes one complete frame. Device replies carry a return code after the
  /// header, so [fromDevice] is true by default.
  TuyaFrame decode(Uint8List frame, {bool fromDevice = true}) {
    if (frame.length < _headerLength + _trailerLength) {
      throw TuyaDecodeException('frame is ${frame.length} bytes, too short');
    }
    final view = ByteData.sublistView(frame);
    if (view.getUint32(0) != _prefix) {
      throw TuyaDecodeException(
        'bad prefix 0x${view.getUint32(0).toRadixString(16)}',
      );
    }
    final seq = view.getUint32(4);
    final command = view.getUint32(8);
    final length = view.getUint32(12);
    if (frame.length != _headerLength + length) {
      throw TuyaDecodeException(
        'declared length $length does not match ${frame.length - _headerLength} bytes',
      );
    }
    final end = frame.length - _trailerLength;
    if (view.getUint32(end + 4) != _suffix) {
      throw TuyaDecodeException('bad suffix');
    }
    final expectedCrc = view.getUint32(end);
    final actualCrc = crc32(Uint8List.sublistView(frame, 0, end));
    if (expectedCrc != actualCrc) throw TuyaDecodeException('CRC mismatch');

    var offset = _headerLength;
    int? retcode;
    if (fromDevice) {
      if (end - offset < 4) throw TuyaDecodeException('missing return code');
      retcode = view.getUint32(offset);
      offset += 4;
    }
    var payload = Uint8List.sublistView(frame, offset, end);
    if (_startsWith(payload, _version33Header.sublist(0, 3))) {
      payload = Uint8List.sublistView(payload, _version33Header.length);
    }
    Map<String, Object?>? body;
    if (payload.isNotEmpty) {
      final Uint8List plain;
      try {
        plain = _aes(false, payload);
      } catch (_) {
        throw TuyaDecodeException('payload does not decrypt with this key');
      }
      final decoded = jsonDecode(utf8.decode(plain, allowMalformed: true));
      if (decoded is! Map) {
        throw TuyaDecodeException('decrypted body is not a JSON object');
      }
      body = Map<String, Object?>.from(decoded);
    }
    return TuyaFrame(seq: seq, command: command, retcode: retcode, body: body);
  }

  Uint8List _aes(bool encrypt, Uint8List input) {
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
          ..init(
            encrypt,
            PaddedBlockCipherParameters<KeyParameter, Null>(
              KeyParameter(_key),
              null,
            ),
          );
    return cipher.process(input);
  }

  static bool _startsWith(Uint8List data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }
}

/// Splits a TCP byte stream into whole Tuya frames, whatever the chunking.
class TuyaFrameSplitter {
  final _buffer = BytesBuilder();

  /// Adds [chunk] and returns every frame now complete.
  List<Uint8List> add(List<int> chunk) {
    _buffer.add(chunk);
    var data = _buffer.takeBytes();
    final frames = <Uint8List>[];
    while (true) {
      final start = _indexOfPrefix(data);
      if (start < 0) {
        data = data.length > 3
            ? Uint8List.sublistView(data, data.length - 3)
            : data;
        break;
      }
      if (data.length - start < _headerLength) {
        data = Uint8List.sublistView(data, start);
        break;
      }
      final length = ByteData.sublistView(data, start).getUint32(12);
      final total = _headerLength + length;
      if (data.length - start < total) {
        data = Uint8List.sublistView(data, start);
        break;
      }
      frames.add(
        Uint8List.fromList(Uint8List.sublistView(data, start, start + total)),
      );
      data = Uint8List.sublistView(data, start + total);
    }
    _buffer.add(data);
    return frames;
  }

  static int _indexOfPrefix(Uint8List data) {
    for (var i = 0; i + 3 < data.length; i++) {
      if (data[i] == 0x00 &&
          data[i + 1] == 0x00 &&
          data[i + 2] == 0x55 &&
          data[i + 3] == 0xAA) {
        return i;
      }
    }
    return -1;
  }
}
