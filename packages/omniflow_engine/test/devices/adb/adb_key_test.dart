import 'dart:convert';

import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:omniflow_engine/src/storage/secret_store.dart';
import 'package:test/test.dart';

import 'fake_adbd.dart';

void main() {
  late AdbHostKey key;

  setUpAll(() async {
    key = await AdbHostKey.generate();
  });

  test('the key is RSA-2048 with exponent 65537', () {
    expect(key.modulus.bitLength, 2048);
    expect(key.publicExponent, BigInt.from(65537));
  });

  test('the mincrypt public key has adbd layout', () {
    final bytes = key.mincryptPublicKey();
    expect(bytes.length, 524);
    final parsed = MincryptKey.parse(bytes);
    expect(parsed.words, 64);
    expect(parsed.n, key.modulus);
    expect(parsed.e, 65537);
    final r32 = BigInt.one << 32;
    final n0 = key.modulus % r32;
    expect((BigInt.from(parsed.n0inv) * n0) % r32, r32 - BigInt.one);
    expect(parsed.rr, (BigInt.one << 4096) % key.modulus);
  });

  test('a signature over a token verifies the way adbd checks it', () {
    final token = List.generate(20, (i) => i * 7 % 256);
    final signature = key.sign(token);
    expect(signature.length, 256);
    final public = MincryptKey.parse(key.mincryptPublicKey());
    expect(public.verifies(token, signature), isTrue);
    expect(public.verifies([...token.skip(1), 0], signature), isFalse);
  });

  test('a token that is not 20 bytes is refused', () {
    expect(() => key.sign(List.filled(19, 0)), throwsArgumentError);
  });

  test('the public key payload is base64, the name, then NUL', () {
    final text = ascii.decode(key.publicKeyPayload('omniflow@phone'));
    expect(text, endsWith(' omniflow@phone\x00'));
    final b64 = text.substring(0, text.indexOf(' '));
    expect(base64.decode(b64), key.mincryptPublicKey());
  });

  test('the PEM form round trips', () {
    final pem = key.toPem();
    expect(pem, startsWith('-----BEGIN RSA PRIVATE KEY-----\n'));
    final back = AdbHostKey.fromPem(pem);
    expect(back.modulus, key.modulus);
    final token = List.filled(20, 3);
    expect(back.sign(token), key.sign(token));
  });

  test('a broken PEM is refused', () {
    expect(() => AdbHostKey.fromPem('nope'), throwsFormatException);
  });

  test(
    'the key is generated once and kept under one engine-wide name',
    () async {
      final secrets = InMemorySecretStore();
      var generated = 0;
      Future<AdbHostKey> generate() async {
        generated++;
        return key;
      }

      final first = await loadOrCreateAdbHostKey(secrets, generate: generate);
      final second = await loadOrCreateAdbHostKey(secrets, generate: generate);
      expect(generated, 1);
      expect(adbHostKeySecret, 'adb/hostKey');
      expect(await secrets.read(adbHostKeySecret), key.toPem());
      expect(second.modulus, first.modulus);
    },
  );
}
