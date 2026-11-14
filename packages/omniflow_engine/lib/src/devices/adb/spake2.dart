import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// SPAKE2 over edwards25519, byte for byte as BoringSSL's `SPAKE2_CTX`
/// builds it (crypto/curve25519/spake25519.cc), which is what Android's
/// Wireless Debugging pairing runs. Alice is the pairing client and Bob the
/// phone.
///
/// The arithmetic is plain [BigInt] and not constant time. A context lives
/// for one pairing attempt of a few seconds, keyed by a code the phone shows
/// once, so timing does not leak anything reusable.
enum Spake2Role { alice, bob }

/// The names Android's pairing uses, with the trailing NUL its `sizeof`
/// counts (pairing_auth/pairing_auth.cpp, kClientName and kServerName).
final adbPairClientName = Uint8List.fromList([
  ...'adb pair client'.codeUnits,
  0,
]);
final adbPairServerName = Uint8List.fromList([
  ...'adb pair server'.codeUnits,
  0,
]);

class Spake2Exception implements Exception {
  Spake2Exception(this.message);

  final String message;

  @override
  String toString() => 'Spake2Exception: $message';
}

/// One run of the protocol: [generateMessage] once, then [processMessage]
/// once with the peer's message, which returns the 64-byte shared key.
class Spake2 {
  /// [privateKey] fixes the 64 random bytes the private scalar is reduced
  /// from, for test vectors only.
  Spake2(
    this.role, {
    required List<int> myName,
    required List<int> theirName,
    List<int>? privateKey,
  }) : _myName = Uint8List.fromList(myName),
       _theirName = Uint8List.fromList(theirName),
       _privateSeed = privateKey == null
           ? null
           : Uint8List.fromList(privateKey);

  /// The pairing client's side, with Android's names.
  factory Spake2.adbClient({List<int>? privateKey}) => Spake2(
    Spake2Role.alice,
    myName: adbPairClientName,
    theirName: adbPairServerName,
    privateKey: privateKey,
  );

  final Spake2Role role;
  final Uint8List _myName;
  final Uint8List _theirName;
  final Uint8List? _privateSeed;

  BigInt? _private;
  BigInt? _passwordScalar;
  Uint8List? _passwordHash;
  Uint8List? _myMessage;
  var _done = false;

  /// The 32-byte message for the peer, P + h(password) * (M or N).
  Uint8List generateMessage(List<int> password) {
    if (_myMessage != null) {
      throw Spake2Exception('the message was already generated');
    }
    final seed = _privateSeed ?? _randomBytes(64);
    if (seed.length != 64) {
      throw ArgumentError('the private seed is 64 bytes');
    }
    // Times the cofactor, so the peer's small-order part cancels later.
    final private = (_reduce(seed) << 3);
    final hash = _sha512(password);
    final passwordScalar = _passwordScalarOf(hash);
    final mask = _scalarMult(
      passwordScalar,
      role == Spake2Role.alice ? _pointM : _pointN,
    );
    final message = _encode(_add(_scalarMult(private, _base), mask));
    _private = private;
    _passwordScalar = passwordScalar;
    _passwordHash = hash;
    return _myMessage = message;
  }

  /// The 64-byte key from the peer's message. Both sides get the same key
  /// only when they used the same password and names.
  Uint8List processMessage(List<int> theirMessage) {
    final myMessage = _myMessage;
    if (myMessage == null || _done) {
      throw Spake2Exception('generate the message first, and process once');
    }
    _done = true;
    if (theirMessage.length != 32) {
      throw Spake2Exception('the peer message is not 32 bytes');
    }
    final q = _decode(theirMessage);
    if (q == null) throw Spake2Exception('the peer point is not on the curve');
    final peersMask = _scalarMult(
      _passwordScalar!,
      role == Spake2Role.alice ? _pointN : _pointM,
    );
    final shared = _encode(_scalarMult(_private!, _add(q, _negate(peersMask))));
    final digest = SHA512Digest();
    void update(List<int> data) {
      final length = ByteData(8)..setUint64(0, data.length, Endian.little);
      digest
        ..update(length.buffer.asUint8List(), 0, 8)
        ..update(Uint8List.fromList(data), 0, data.length);
    }

    final alice = role == Spake2Role.alice;
    update(alice ? _myName : _theirName);
    update(alice ? _theirName : _myName);
    update(alice ? myMessage : theirMessage);
    update(alice ? theirMessage : myMessage);
    update(shared);
    update(_passwordHash!);
    final key = Uint8List(64);
    digest.doFinal(key, 0);
    return key;
  }
}

/// The password scalar: SHA-512 reduced mod l, plus the multiples of l that
/// BoringSSL adds to clear its low three bits (its "password scalar hack",
/// which keeps the mask in the prime-order subgroup). The scalar is used as
/// that exact integer, so the multiples of l matter for M and N.
BigInt _passwordScalarOf(Uint8List hash) {
  var s = _reduce(hash);
  for (final bit in [1, 2, 4]) {
    if ((s & BigInt.from(bit)) != BigInt.zero) s += _order * BigInt.from(bit);
  }
  return s;
}

final _p = (BigInt.one << 255) - BigInt.from(19);

/// The order of the prime-order subgroup, 2^252 + 27742317777372353535851937790883648493.
final _order =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final _d = _mod(BigInt.from(-121665) * _inv(BigInt.from(121666)));
final _d2 = _mod(_d * BigInt.two);
final _sqrtM1 = BigInt.two.modPow((_p - BigInt.one) >> 2, _p);

/// The SPAKE2 points, as their encodings in spake25519.cc.
final _pointN = _decode(
  _hex('10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778'),
)!;
final _pointM = _decode(
  _hex('5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e'),
)!;
final _base = _decode(
  _hex('5866666666666666666666666666666666666666666666666666666666666666'),
)!;

/// A point in extended coordinates (X:Y:Z:T), x = X/Z, y = Y/Z, xy = T/Z.
class _Point {
  const _Point(this.x, this.y, this.z, this.t);

  final BigInt x;
  final BigInt y;
  final BigInt z;
  final BigInt t;
}

final _identity = _Point(BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);

BigInt _mod(BigInt v) => v % _p;
BigInt _inv(BigInt v) => v.modPow(_p - BigInt.two, _p);

/// The unified addition for a = -1 (add-2008-hwcd-3), complete on
/// edwards25519, so it doubles too.
_Point _add(_Point a, _Point b) {
  final aa = _mod((a.y - a.x) * (b.y - b.x));
  final bb = _mod((a.y + a.x) * (b.y + b.x));
  final cc = _mod(a.t * _d2 * b.t);
  final dd = _mod(a.z * BigInt.two * b.z);
  final e = bb - aa;
  final f = dd - cc;
  final g = dd + cc;
  final h = bb + aa;
  return _Point(_mod(e * f), _mod(g * h), _mod(f * g), _mod(e * h));
}

_Point _negate(_Point a) => _Point(_mod(-a.x), a.y, a.z, _mod(-a.t));

_Point _scalarMult(BigInt k, _Point point) {
  var result = _identity;
  for (var i = k.bitLength - 1; i >= 0; i--) {
    result = _add(result, result);
    if ((k >> i) & BigInt.one == BigInt.one) result = _add(result, point);
  }
  return result;
}

Uint8List _encode(_Point point) {
  final zInv = _inv(point.z);
  final x = _mod(point.x * zInv);
  final y = _mod(point.y * zInv);
  final out = _littleEndian(y, 32);
  if (x.isOdd) out[31] |= 0x80;
  return out;
}

/// The point [bytes] encodes, decoded as ref10's `ge_frombytes_vartime`
/// does: y from the low 255 bits, x from the square root, its sign from the
/// top bit. Null when there is no such point.
_Point? _decode(List<int> bytes) {
  final y = _mod(_fromLittleEndian(bytes) & ((BigInt.one << 255) - BigInt.one));
  final y2 = _mod(y * y);
  final u = _mod(y2 - BigInt.one);
  final v = _mod(_d * y2 + BigInt.one);
  final v3 = _mod(v * v * v);
  final v7 = _mod(v3 * v3 * v);
  var x = _mod(u * v3 * _mod(u * v7).modPow((_p - BigInt.from(5)) >> 3, _p));
  final vxx = _mod(v * x * x);
  if (vxx != u) {
    if (vxx != _mod(-u)) return null;
    x = _mod(x * _sqrtM1);
  }
  if (x.isOdd != ((bytes[31] & 0x80) != 0)) x = _mod(-x);
  return _Point(x, y, BigInt.one, _mod(x * y));
}

BigInt _reduce(List<int> bytes) => _fromLittleEndian(bytes) % _order;

BigInt _fromLittleEndian(List<int> bytes) {
  var v = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    v = (v << 8) | BigInt.from(bytes[i]);
  }
  return v;
}

Uint8List _littleEndian(BigInt v, int length) {
  final out = Uint8List(length);
  var rest = v;
  final mask = BigInt.from(0xff);
  for (var i = 0; i < length; i++) {
    out[i] = (rest & mask).toInt();
    rest >>= 8;
  }
  return out;
}

Uint8List _sha512(List<int> data) {
  final digest = SHA512Digest();
  return digest.process(Uint8List.fromList(data));
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

Uint8List _hex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);
