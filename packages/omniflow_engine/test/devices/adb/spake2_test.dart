import 'dart:typed_data';

import 'package:omniflow_engine/src/devices/adb/spake2.dart';
import 'package:test/test.dart';

Uint8List unhex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

/// Interop vectors from BoringSSL's own SPAKE2_CTX (commit 583980e24f, built
/// from source with clang): the Dart side, with the fixed private seed,
/// sent `ours`, BoringSSL in the other role answered `theirs` and derived
/// `key` from `ours`. BoringSSL publishes no spake25519 vectors, so these
/// were generated with the adb pairing names and a code plus 64 exporter
/// bytes as the password.
final vectors = [
  (
    role: Spake2Role.alice,
    password:
        '31313934323065be15925eea177bd477b6d81ae5500548ddf33ca4832d927c34'
        '55693ea8d28aed40ab86b482266fae5a86f85a677b75253b40cf67ab995520e6'
        '24aafde33dcb',
    seed:
        '9cf789e1332b8b100d98d0e77f7d65d96a0f726dbc94157e19c6484fc5fb412e'
        '15814befb9e06f7d81dccee61d89a082905ec62b1bd90ee3b00dd2f1fcc25382',
    ours: '16826bd64a83574f4e863769740f5ab1a52eae47a0ce9b6f988826a8844e0364',
    theirs: 'f56cc118041933628b767bd574239183f86107629a308a874bd7e7e2f1c8268b',
    key:
        'f78a3ac10e4b0b8b14b5338e60edef35f9ab860e185586423d2c38704a38cb0d'
        '56fdd6297084c2c9ab49e4f4df3a040eecbc404a5d7ed7817c344b9c691df538',
  ),
  (
    role: Spake2Role.bob,
    password:
        '39333438353780bd6bac443803b393540de5abbc7310f2859e0497dd87f1ed8a'
        'aae0566daa0294417a71e7fd93459a2ea7f37ced5eaabb0fa2e929c86d6cdf8b'
        'da46dab39b86',
    seed:
        '40a731b7bd7a2a47c1477793335098a5e48cd144d1be24f3cd9f87783439c018'
        '59c6f316439a050eeadeb58ad8335a028a7dd6dc046e58bf32a16eadeef1205e',
    ours: '0b01abe326d9124ebadd6b6513783b8135bc7ce5ad7bf9439274379379ebc018',
    theirs: '26e98226791ca873da15fe4fc3a803fb81f798d60b4b51f0359082afb9366324',
    key:
        '8132337f97be08020262f6968d6982878a39a0708cd048ab9eeac040458358c1'
        '6dfb1554002fa1259ab0bb149c2ec5cdae988f1bbb47f03a563aecd5a9857f92',
  ),
];

Spake2 party(Spake2Role role, {List<int>? seed}) => role == Spake2Role.alice
    ? Spake2.adbClient(privateKey: seed)
    : Spake2(
        Spake2Role.bob,
        myName: adbPairServerName,
        theirName: adbPairClientName,
        privateKey: seed,
      );

void main() {
  test('the names are AOSP\'s, NUL included', () {
    expect(adbPairClientName, [...'adb pair client'.codeUnits, 0]);
    expect(adbPairServerName, [...'adb pair server'.codeUnits, 0]);
  });

  for (final v in vectors) {
    test('derives BoringSSL\'s key as ${v.role.name}', () {
      final dart = party(v.role, seed: unhex(v.seed));
      expect(hex(dart.generateMessage(unhex(v.password))), v.ours);
      expect(hex(dart.processMessage(unhex(v.theirs))), v.key);
    });
  }

  test('both Dart roles agree on the key', () {
    final password = [...'123456'.codeUnits, ...List.filled(64, 9)];
    final alice = party(Spake2Role.alice);
    final bob = party(Spake2Role.bob);
    final a = alice.generateMessage(password);
    final b = bob.generateMessage(password);
    expect(alice.processMessage(b), bob.processMessage(a));
  });

  test('a wrong password gives a different key', () {
    final alice = party(Spake2Role.alice);
    final bob = party(Spake2Role.bob);
    final a = alice.generateMessage('123456'.codeUnits);
    final b = bob.generateMessage('123457'.codeUnits);
    expect(alice.processMessage(b), isNot(bob.processMessage(a)));
  });

  test('a corrupted message never gives the same key', () {
    for (var bit = 0; bit < 256; bit += 17) {
      final alice = party(Spake2Role.alice);
      final bob = party(Spake2Role.bob);
      final a = alice.generateMessage('123456'.codeUnits);
      final b = bob.generateMessage('123456'.codeUnits);
      final corrupt = Uint8List.fromList(a)..[bit ~/ 8] ^= 1 << (bit % 8);
      final bobKey = (() {
        try {
          return bob.processMessage(corrupt);
        } on Spake2Exception {
          return null;
        }
      })();
      expect(bobKey, isNot(alice.processMessage(b)), reason: 'bit $bit');
    }
  });

  test('refuses a short message and a second use', () {
    final alice = party(Spake2Role.alice);
    expect(
      () => alice.processMessage(Uint8List(32)),
      throwsA(isA<Spake2Exception>()),
    );
    alice.generateMessage('1'.codeUnits);
    expect(
      () => alice.generateMessage('1'.codeUnits),
      throwsA(isA<Spake2Exception>()),
    );
    expect(
      () => alice.processMessage(Uint8List(31)),
      throwsA(isA<Spake2Exception>()),
    );
    expect(
      () => alice.processMessage(Uint8List(32)),
      throwsA(isA<Spake2Exception>()),
    );
  });
}
