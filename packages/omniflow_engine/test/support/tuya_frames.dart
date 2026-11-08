import 'dart:convert';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:pointycastle/export.dart';

/// A Tuya frame around any [payload] bytes, with a valid length and CRC, for
/// the malformed replies [TuyaCodec.encode] cannot produce.
Uint8List rawTuyaFrame(int command, List<int> payload, {int seq = 1}) {
  final header = ByteData(16)
    ..setUint32(0, 0x000055AA)
    ..setUint32(4, seq)
    ..setUint32(8, command)
    ..setUint32(12, payload.length + 8);
  final before = Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...payload,
  ]);
  final trailer = ByteData(8)
    ..setUint32(0, crc32(before))
    ..setUint32(4, 0x0000AA55);
  return Uint8List.fromList([...before, ...trailer.buffer.asUint8List()]);
}

/// [bytes] encrypted the way a device encrypts a body: AES-128-ECB, PKCS7.
Uint8List tuyaEncrypt(String localKey, List<int> bytes) {
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))..init(
        true,
        PaddedBlockCipherParameters<KeyParameter, Null>(
          KeyParameter(Uint8List.fromList(utf8.encode(localKey))),
          null,
        ),
      );
  return cipher.process(Uint8List.fromList(bytes));
}

/// A device reply's return code, as the 4 bytes after the header.
List<int> tuyaRetcode(int code) =>
    (ByteData(4)..setUint32(0, code)).buffer.asUint8List();
