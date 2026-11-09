import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

import '../../storage/secret_store.dart';

/// The one secret-store key holding this engine's ADB private key. Every
/// TV pairs with the same key, so accepting it once per TV is enough.
const adbHostKeySecret = 'adb/hostKey';

const _keyBits = 2048;
const _keyBytes = _keyBits ~/ 8;
const _keyWords = _keyBits ~/ 32;

/// DER DigestInfo prefix for SHA-1 (RFC 8017, section 9.2 note 1). adbd
/// verifies the token as if it were a SHA-1 digest.
const _sha1DigestInfoPrefix = [
  0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, //
  0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
];

const _pemHeader = '-----BEGIN RSA PRIVATE KEY-----';
const _pemFooter = '-----END RSA PRIVATE KEY-----';

final _mask32 = BigInt.from(0xffffffff);

/// This engine's RSA-2048 ADB key.
class AdbHostKey {
  AdbHostKey(this._key) {
    if (_key.modulus!.bitLength != _keyBits) {
      throw ArgumentError('an ADB key must be RSA-$_keyBits');
    }
  }

  final RSAPrivateKey _key;

  BigInt get modulus => _key.modulus!;
  BigInt get publicExponent => _key.publicExponent!;

  /// Generates a fresh key on a background isolate: 2048-bit prime search
  /// in pure Dart takes seconds and would stall the UI isolate.
  static Future<AdbHostKey> generate() async =>
      AdbHostKey.fromPem(await Isolate.run(() => generateSync().toPem()));

  static AdbHostKey generateSync() {
    final seed = Random.secure();
    final random = FortunaRandom()
      ..seed(
        KeyParameter(
          Uint8List.fromList(List.generate(32, (_) => seed.nextInt(256))),
        ),
      );
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), _keyBits, 64),
          random,
        ),
      );
    return AdbHostKey(generator.generateKeyPair().privateKey);
  }

  /// The AUTH SIGNATURE payload for a 20-byte AUTH TOKEN: an RSA PKCS#1
  /// v1.5 signature with the token standing in for the SHA-1 digest.
  Uint8List sign(List<int> token) {
    if (token.length != 20) {
      throw ArgumentError('an ADB auth token is 20 bytes, got ${token.length}');
    }
    final digestInfo = [..._sha1DigestInfoPrefix, ...token];
    final block = Uint8List(_keyBytes)
      ..[1] = 0x01
      ..fillRange(2, _keyBytes - digestInfo.length - 1, 0xff)
      ..setRange(_keyBytes - digestInfo.length, _keyBytes, digestInfo);
    final engine = RSAEngine()
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(_key));
    return engine.process(block);
  }

  /// The public key in Android's mincrypt `RSAPublicKey` layout, all
  /// little-endian: word count, n0inv, n, rr = 2^4096 mod n, exponent.
  Uint8List mincryptPublicKey() {
    final n = modulus;
    final r32 = BigInt.one << 32;
    final n0inv = (r32 - (n & _mask32).modInverse(r32)) % r32;
    final rr = (BigInt.one << (2 * _keyBits)) % n;
    final out = ByteData(4 + 4 + 2 * _keyBytes + 4)
      ..setUint32(0, _keyWords, Endian.little)
      ..setUint32(4, n0inv.toInt(), Endian.little);
    for (var i = 0; i < _keyWords; i++) {
      out
        ..setUint32(8 + 4 * i, _word(n, i), Endian.little)
        ..setUint32(8 + _keyBytes + 4 * i, _word(rr, i), Endian.little);
    }
    out.setUint32(8 + 2 * _keyBytes, publicExponent.toInt(), Endian.little);
    return out.buffer.asUint8List();
  }

  /// The AUTH RSAPUBLICKEY payload: base64 key, a space, the name the TV
  /// shows in its prompt, and a NUL.
  Uint8List publicKeyPayload(String name) => Uint8List.fromList([
    ...ascii.encode('${base64.encode(mincryptPublicKey())} $name'),
    0,
  ]);

  /// PKCS#1 RSAPrivateKey PEM, the same encoding `openssl rsa` reads.
  String toPem() {
    final p = _key.p!;
    final q = _key.q!;
    final d = _key.privateExponent!;
    final der = ASN1Sequence(
      elements: [
        for (final v in [
          BigInt.zero,
          modulus,
          publicExponent,
          d,
          p,
          q,
          d % (p - BigInt.one),
          d % (q - BigInt.one),
          q.modInverse(p),
        ])
          ASN1Integer(v),
      ],
    ).encode();
    final body = base64.encode(der);
    final lines = [
      for (var i = 0; i < body.length; i += 64)
        body.substring(i, min(i + 64, body.length)),
    ];
    return [_pemHeader, ...lines, _pemFooter, ''].join('\n');
  }

  static AdbHostKey fromPem(String pem) {
    final start = pem.indexOf(_pemHeader);
    final end = pem.indexOf(_pemFooter);
    if (start < 0 || end < start) {
      throw const FormatException('not an RSA PRIVATE KEY PEM');
    }
    final body = pem
        .substring(start + _pemHeader.length, end)
        .replaceAll(RegExp(r'\s'), '');
    final parsed = ASN1Parser(base64.decode(body)).nextObject();
    final values = parsed is ASN1Sequence
        ? [
            for (final e in parsed.elements ?? const <ASN1Object>[])
              if (e is ASN1Integer) e.integer,
          ]
        : const <BigInt?>[];
    if (values.length < 6 || values.any((v) => v == null)) {
      throw const FormatException('not a PKCS#1 RSA private key');
    }
    return AdbHostKey(
      RSAPrivateKey(values[1]!, values[3]!, values[4]!, values[5]!),
    );
  }
}

int _word(BigInt value, int index) =>
    ((value >> (32 * index)) & _mask32).toInt();

/// Reads the engine's ADB key, generating and storing it on first use.
Future<AdbHostKey> loadOrCreateAdbHostKey(
  SecretStore secrets, {
  Future<AdbHostKey> Function() generate = AdbHostKey.generate,
}) async {
  final stored = await secrets.read(adbHostKeySecret);
  if (stored != null) return AdbHostKey.fromPem(stored);
  final key = await generate();
  await secrets.write(adbHostKeySecret, key.toPem());
  return key;
}
