import 'dart:convert';
import 'dart:math';
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
  static const controlNew = 0x0d;
  static const dpQueryNew = 0x10;
  static const updateDps = 0x12;
  static const lanExtStream = 0x40;

  /// Commands sent without the version header.
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

/// The Tuya local protocol versions the codec speaks.
const tuyaProtocolVersions = ['3.3', '3.4', '3.5'];

class TuyaDecodeException implements Exception {
  TuyaDecodeException(this.message, {this.command, this.deviceMessage});

  final String message;

  /// The frame's command code, when the frame itself was sound.
  final int? command;

  /// Plain text the device sent instead of JSON (`json obj data unvalid`,
  /// `data format error`): its way of refusing a command.
  final String? deviceMessage;

  @override
  String toString() => 'TuyaDecodeException: $message';
}

class TuyaFrame {
  const TuyaFrame({
    required this.seq,
    required this.command,
    required this.retcode,
    required this.body,
    this.plain,
  });

  final int seq;
  final int command;

  /// The device's return code. Null for frames sent by a client.
  final int? retcode;

  /// The decrypted JSON body, or null when the frame carried no payload.
  final Map<String, Object?>? body;

  /// The decrypted payload bytes, without the version header. Set by
  /// [TuyaCodec.decodeBytes], which does not read them as JSON.
  final Uint8List? plain;
}

const _prefix55aa = 0x000055AA;
const _suffix55aa = 0x0000AA55;
const _prefix6699 = 0x00006699;
const _suffix6699 = 0x00009966;
const _header55aa = 16;
const _header6699 = 18;
const _crcTrailer = 8;
const _hmacTrailer = 36;
const _gcmIv = 12;
const _gcmTag = 16;
const _retcodeLength = 4;

Uint8List _versionHeader(String version) =>
    Uint8List.fromList([...ascii.encode(version), ...List.filled(12, 0)]);

Uint8List _secureRandom(int length) {
  final random = Random.secure();
  return Uint8List.fromList([
    for (var i = 0; i < length; i++) random.nextInt(256),
  ]);
}

/// Encodes and decodes Tuya frames for one protocol version, keyed by the
/// device's 16-byte local key or, from v3.4, by the session key the
/// handshake agrees ([TuyaSession]).
///
/// - 3.3: `0x55AA` frames, the version header in clear before an AES-ECB
///   body, CRC-32.
/// - 3.4: `0x55AA` frames, the version header inside the AES-ECB body,
///   HMAC-SHA256 under the key in place of the CRC.
/// - 3.5: `0x6699` frames, AES-GCM with a fresh 12-byte IV per frame and
///   the header as associated data, the return code inside the ciphertext.
class TuyaCodec {
  TuyaCodec(
    String localKey, {
    String version = '3.3',
    Uint8List Function(int length)? random,
  }) : this.withKey(
         Uint8List.fromList(utf8.encode(localKey)),
         version: version,
         random: random,
       );

  TuyaCodec.withKey(
    Uint8List key, {
    this.version = '3.3',
    Uint8List Function(int length)? random,
  }) : _key = Uint8List.fromList(key),
       _random = random ?? _secureRandom {
    if (_key.length != 16) {
      throw ArgumentError('a Tuya local key is 16 bytes, got ${_key.length}');
    }
    if (!tuyaProtocolVersions.contains(version)) {
      throw UnsupportedError(
        'Tuya protocol $version is not supported (${tuyaProtocolVersions.join(', ')})',
      );
    }
  }

  final Uint8List _key;
  final String version;
  final Uint8List Function(int length) _random;

  /// Whether this version agrees a session key before any command.
  bool get negotiatesSession => version != '3.3';

  /// The same version under another key, the session key once agreed.
  TuyaCodec withSessionKey(Uint8List key) =>
      TuyaCodec.withKey(key, version: version, random: _random);

  /// A frame carrying [body] as compact JSON, or no payload when null.
  ///
  /// A device reply (for an emulator or a test) passes [retcode]. A null
  /// [body] sends no payload, as a device does when it acknowledges a
  /// control command.
  Uint8List encode({
    required int seq,
    required int command,
    required Map<String, Object?>? body,
    int? retcode,
  }) => encodeBytes(
    seq: seq,
    command: command,
    payload: body == null
        ? null
        : Uint8List.fromList(utf8.encode(jsonEncode(body))),
    retcode: retcode,
  );

  /// A frame carrying [payload] bytes (a handshake nonce or HMAC).
  Uint8List encodeBytes({
    required int seq,
    required int command,
    required Uint8List? payload,
    int? retcode,
  }) {
    final withHeader =
        payload != null && !TuyaCommand.withoutVersionHeader.contains(command);
    return switch (version) {
      '3.3' => _encode55aa(
        seq,
        command,
        retcode,
        payload == null
            ? Uint8List(0)
            : Uint8List.fromList([
                if (withHeader) ..._versionHeader(version),
                ..._ecb(true, payload),
              ]),
      ),
      '3.4' => _encode55aa(
        seq,
        command,
        retcode,
        payload == null
            ? Uint8List(0)
            : _ecb(
                true,
                Uint8List.fromList([
                  if (withHeader) ..._versionHeader(version),
                  ...payload,
                ]),
              ),
      ),
      _ => _encode6699(seq, command, retcode, [
        if (withHeader) ..._versionHeader(version),
        ...?payload,
      ]),
    };
  }

  Uint8List _encode55aa(int seq, int command, int? retcode, Uint8List body) {
    final trailer = version == '3.3' ? _crcTrailer : _hmacTrailer;
    final payload = [if (retcode != null) ..._uint32(retcode), ...body];
    final header = ByteData(_header55aa)
      ..setUint32(0, _prefix55aa)
      ..setUint32(4, seq)
      ..setUint32(8, command)
      ..setUint32(12, payload.length + trailer);
    final before = Uint8List.fromList([
      ...header.buffer.asUint8List(),
      ...payload,
    ]);
    final check = version == '3.3'
        ? _uint32(crc32(before))
        : TuyaSession.hmac(_key, before);
    return Uint8List.fromList([...before, ...check, ..._uint32(_suffix55aa)]);
  }

  Uint8List _encode6699(int seq, int command, int? retcode, List<int> body) {
    final plain = Uint8List.fromList([
      if (retcode != null) ..._uint32(retcode),
      ...body,
    ]);
    final header = ByteData(_header6699)
      ..setUint32(0, _prefix6699)
      ..setUint16(4, 0)
      ..setUint32(6, seq)
      ..setUint32(10, command)
      ..setUint32(14, _gcmIv + plain.length + _gcmTag);
    final headerBytes = header.buffer.asUint8List();
    final iv = _random(_gcmIv);
    final sealed = _gcm(true, iv, Uint8List.sublistView(headerBytes, 4), plain);
    return Uint8List.fromList([
      ...headerBytes,
      ...iv,
      ...sealed,
      ..._uint32(_suffix6699),
    ]);
  }

  /// Decodes one complete frame and reads its body as JSON. Device replies
  /// carry a return code after the header, so [fromDevice] is true by
  /// default.
  TuyaFrame decode(Uint8List frame, {bool fromDevice = true}) {
    final raw = decodeBytes(frame, fromDevice: fromDevice);
    return TuyaFrame(
      seq: raw.seq,
      command: raw.command,
      retcode: raw.retcode,
      body: parseBody(raw.plain!, raw.command),
      plain: raw.plain,
    );
  }

  /// Decodes one complete frame: checks it, decrypts it and strips the
  /// version header, leaving the payload as bytes in [TuyaFrame.plain].
  TuyaFrame decodeBytes(Uint8List frame, {bool fromDevice = true}) =>
      version == '3.5'
      ? _decode6699(frame, fromDevice)
      : _decode55aa(frame, fromDevice);

  TuyaFrame _decode55aa(Uint8List frame, bool fromDevice) {
    final trailer = version == '3.3' ? _crcTrailer : _hmacTrailer;
    if (frame.length < _header55aa + trailer) {
      throw TuyaDecodeException('frame is ${frame.length} bytes, too short');
    }
    final view = ByteData.sublistView(frame);
    if (view.getUint32(0) != _prefix55aa) {
      throw TuyaDecodeException(
        'bad prefix 0x${view.getUint32(0).toRadixString(16)}',
      );
    }
    final seq = view.getUint32(4);
    final command = view.getUint32(8);
    final length = view.getUint32(12);
    if (frame.length != _header55aa + length) {
      throw TuyaDecodeException(
        'declared length $length does not match ${frame.length - _header55aa} bytes',
      );
    }
    if (view.getUint32(frame.length - 4) != _suffix55aa) {
      throw TuyaDecodeException('bad suffix');
    }
    final end = frame.length - trailer;
    final signed = Uint8List.sublistView(frame, 0, end);
    if (version == '3.3') {
      if (view.getUint32(end) != crc32(signed)) {
        throw TuyaDecodeException('CRC mismatch');
      }
    } else if (!_equal(
      TuyaSession.hmac(_key, signed),
      Uint8List.sublistView(frame, end, end + 32),
    )) {
      throw TuyaDecodeException('HMAC mismatch');
    }

    var offset = _header55aa;
    int? retcode;
    if (fromDevice) {
      if (end - offset < _retcodeLength) {
        throw TuyaDecodeException('missing return code');
      }
      retcode = view.getUint32(offset);
      offset += _retcodeLength;
    }
    var payload = Uint8List.sublistView(frame, offset, end);
    final header = _versionHeader(version);
    if (version == '3.3') {
      payload = _stripHeader(payload, header, command);
      payload = _decrypt(payload, command);
    } else {
      payload = _stripHeader(_decrypt(payload, command), header, command);
    }
    return TuyaFrame(
      seq: seq,
      command: command,
      retcode: retcode,
      body: null,
      plain: payload,
    );
  }

  TuyaFrame _decode6699(Uint8List frame, bool fromDevice) {
    if (frame.length < _header6699 + _gcmIv + _gcmTag + 4) {
      throw TuyaDecodeException('frame is ${frame.length} bytes, too short');
    }
    final view = ByteData.sublistView(frame);
    if (view.getUint32(0) != _prefix6699) {
      throw TuyaDecodeException(
        'bad prefix 0x${view.getUint32(0).toRadixString(16)}',
      );
    }
    final seq = view.getUint32(6);
    final command = view.getUint32(10);
    final length = view.getUint32(14);
    if (frame.length != _header6699 + length + 4) {
      throw TuyaDecodeException(
        'declared length $length does not match ${frame.length - _header6699 - 4} bytes',
      );
    }
    if (view.getUint32(frame.length - 4) != _suffix6699) {
      throw TuyaDecodeException('bad suffix');
    }
    final iv = Uint8List.sublistView(frame, _header6699, _header6699 + _gcmIv);
    final sealed = Uint8List.sublistView(
      frame,
      _header6699 + _gcmIv,
      frame.length - 4,
    );
    Uint8List plain;
    try {
      plain = _gcm(
        false,
        iv,
        Uint8List.sublistView(frame, 4, _header6699),
        sealed,
      );
    } catch (_) {
      throw TuyaDecodeException('GCM tag mismatch');
    }
    int? retcode;
    if (fromDevice) {
      if (plain.length < _retcodeLength) {
        throw TuyaDecodeException('missing return code');
      }
      retcode = ByteData.sublistView(plain).getUint32(0);
      plain = Uint8List.sublistView(plain, _retcodeLength);
    }
    return TuyaFrame(
      seq: seq,
      command: command,
      retcode: retcode,
      body: null,
      plain: _stripHeader(plain, _versionHeader(version), command),
    );
  }

  Uint8List _stripHeader(Uint8List payload, Uint8List header, int command) {
    if (!_startsWith(payload, header.sublist(0, 3))) return payload;
    if (payload.length < header.length) {
      throw TuyaDecodeException(
        '$version header is cut short',
        command: command,
      );
    }
    return Uint8List.sublistView(payload, header.length);
  }

  Uint8List _decrypt(Uint8List payload, int command) {
    if (payload.isEmpty) return payload;
    try {
      return _ecb(false, payload);
    } catch (_) {
      throw TuyaDecodeException(
        'payload does not decrypt with this key',
        command: command,
      );
    }
  }

  /// [plain] read as the JSON object a body is, null when it is empty.
  static Map<String, Object?>? parseBody(Uint8List plain, int command) {
    if (plain.isEmpty) return null;
    final text = utf8.decode(plain, allowMalformed: true);
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      final printable = _isPrintable(text);
      throw TuyaDecodeException(
        printable ? 'device said "$text"' : 'decrypted body is not JSON',
        command: command,
        deviceMessage: printable ? text : null,
      );
    }
    if (decoded is! Map) {
      throw TuyaDecodeException(
        'decrypted body is not a JSON object',
        command: command,
      );
    }
    return Map<String, Object?>.from(decoded);
  }

  static bool _isPrintable(String text) =>
      text.trim().isNotEmpty &&
      text.codeUnits.every((c) => c >= 0x20 && c < 0x7F);

  Uint8List _ecb(bool encrypt, Uint8List input) {
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

  Uint8List _gcm(bool encrypt, Uint8List iv, Uint8List aad, Uint8List input) {
    final gcm = GCMBlockCipher(AESEngine())
      ..init(encrypt, AEADParameters(KeyParameter(_key), _gcmTag * 8, iv, aad));
    return gcm.process(input);
  }

  static bool _startsWith(Uint8List data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }
}

/// The v3.4 and v3.5 session handshake, as tinytuya performs it.
///
/// 1. The client sends command 3 with a 16-byte random nonce.
/// 2. The device answers command 4 with its own nonce followed by
///    HMAC-SHA256(local key, client nonce), which proves it holds the key.
/// 3. The client sends command 5 with HMAC-SHA256(local key, device nonce).
///
/// Both sides then use [sessionKey] for every later frame. The handshake
/// frames themselves are under the local key.
abstract final class TuyaSession {
  static const nonceLength = 16;

  static Uint8List hmac(Uint8List key, List<int> data) => (HMac(
    SHA256Digest(),
    64,
  )..init(KeyParameter(key))).process(Uint8List.fromList(data));

  /// The device's nonce from its step 2 answer, or null when the answer is
  /// short or its HMAC is not over [localNonce] under [localKey], which is
  /// what a device holding another key sends.
  static Uint8List? remoteNonce(
    Uint8List answer,
    Uint8List localKey,
    Uint8List localNonce,
  ) {
    if (answer.length < nonceLength + 32) return null;
    final proof = Uint8List.sublistView(answer, nonceLength, nonceLength + 32);
    if (!_equal(proof, hmac(localKey, localNonce))) return null;
    return Uint8List.fromList(answer.sublist(0, nonceLength));
  }

  /// The session key: the two nonces XORed, then encrypted under the local
  /// key, with AES-ECB for v3.4 and AES-GCM (IV from the client nonce,
  /// ciphertext only) for v3.5.
  static Uint8List sessionKey(
    String version,
    Uint8List localKey,
    Uint8List localNonce,
    Uint8List remoteNonce,
  ) {
    final mixed = Uint8List.fromList([
      for (var i = 0; i < nonceLength; i++) localNonce[i] ^ remoteNonce[i],
    ]);
    if (version == '3.5') {
      final gcm = GCMBlockCipher(AESEngine())
        ..init(
          true,
          AEADParameters(
            KeyParameter(localKey),
            _gcmTag * 8,
            Uint8List.sublistView(localNonce, 0, _gcmIv),
            Uint8List(0),
          ),
        );
      return Uint8List.sublistView(gcm.process(mixed), 0, nonceLength);
    }
    final ecb = ECBBlockCipher(AESEngine())..init(true, KeyParameter(localKey));
    final out = Uint8List(nonceLength);
    ecb.processBlock(mixed, 0, out, 0);
    return out;
  }
}

List<int> _uint32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Splits a TCP byte stream into whole Tuya frames, whatever the chunking.
/// It reads `0x55AA` frames (3.3, 3.4) and `0x6699` frames (3.5).
///
/// A declared length over [maxFrameLength] is not a real frame (a stray
/// prefix inside other bytes), so the splitter skips that prefix and looks
/// for the next one rather than buffering up to 4 GB.
class TuyaFrameSplitter {
  static const maxFrameLength = 65536;

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
      final is6699 = data[start + 2] == 0x66;
      final headerLength = is6699 ? _header6699 : _header55aa;
      if (data.length - start < headerLength) {
        data = Uint8List.sublistView(data, start);
        break;
      }
      final length = ByteData.sublistView(
        data,
        start,
      ).getUint32(is6699 ? 14 : 12);
      if (length > maxFrameLength) {
        data = Uint8List.sublistView(data, start + 4);
        continue;
      }
      final total = headerLength + length + (is6699 ? 4 : 0);
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
      if (data[i] != 0x00 || data[i + 1] != 0x00) continue;
      if ((data[i + 2] == 0x55 && data[i + 3] == 0xAA) ||
          (data[i + 2] == 0x66 && data[i + 3] == 0x99)) {
        return i;
      }
    }
    return -1;
  }
}
