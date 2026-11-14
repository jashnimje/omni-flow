import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'adb_key.dart';

// TLS for Android Wireless Debugging: the engine's ADB key as a self-signed
// certificate, the client context that presents it, and the RFC 8446
// exporter that `dart:io` lacks, rebuilt from the keyLog line.

/// The exporter label pairing uses, with the NUL its `sizeof` counts
/// (tls/tls_connection.cpp, kExportedKeyLabel).
final adbExporterLabel = Uint8List.fromList([...ascii.encode('adb-label'), 0]);

/// How many exporter bytes pairing appends to the code
/// (pairing_connection.cpp, kExportedKeySize).
const adbExportedKeyLength = 64;

final _contexts = Expando<SecurityContext>();

/// A client context presenting [key]'s certificate, trusting no roots: the
/// device's own certificate is self-signed, and Wireless Debugging trusts
/// keys, not certificates. Built once per key.
SecurityContext adbTlsContext(AdbHostKey key) =>
    _contexts[key] ??= SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(adbCertificatePem(key)))
      ..usePrivateKeyBytes(utf8.encode(key.toPem()));

/// A self-signed X.509 v3 certificate for [key], shaped as adb's own
/// (crypto/x509_generator.cpp): serial 1, subject and issuer C=US, O=Android,
/// CN=Adb, ten years, CA basic constraints and key usage, SHA-256 with RSA.
String adbCertificatePem(AdbHostKey key, {DateTime? now}) {
  final start = (now ?? DateTime.now()).toUtc();
  final end = start.add(const Duration(days: 3650));
  final name = _seq([
    for (final (oid, value) in [
      ('2.5.4.6', 'US'),
      ('2.5.4.10', 'Android'),
      ('2.5.4.3', 'Adb'),
    ])
      _set([
        _seq([_oid(oid), _tlv(0x0c, utf8.encode(value))]),
      ]),
  ]);
  final rsaPublic = _seq([_int(key.modulus), _int(key.publicExponent)]);
  final spki = _seq([
    _seq([_oid('1.2.840.113549.1.1.1'), _tlv(0x05, const [])]),
    _tlv(0x03, [0, ...rsaPublic]),
  ]);
  final keyId = SHA1Digest().process(Uint8List.fromList(rsaPublic));
  final extensions = _tlv(
    0xa3,
    _seq([
      _ext(
        '2.5.29.19',
        critical: true,
        _seq([
          _tlv(0x01, const [0xff]),
        ]),
      ),
      // keyCertSign, cRLSign, digitalSignature: bits 0, 5 and 6.
      _ext('2.5.29.15', critical: true, _tlv(0x03, const [0x01, 0x86])),
      _ext('2.5.29.14', _tlv(0x04, keyId)),
    ]),
  );
  final sha256WithRsa = _seq([
    _oid('1.2.840.113549.1.1.11'),
    _tlv(0x05, const []),
  ]);
  final tbs = _seq([
    _tlv(0xa0, _int(BigInt.two)),
    _int(BigInt.one),
    sha256WithRsa,
    name,
    _seq([_time(start), _time(end)]),
    name,
    spki,
    extensions,
  ]);
  final der = _seq([
    tbs,
    sha256WithRsa,
    _tlv(0x03, [0, ...key.signSha256(tbs)]),
  ]);
  final body = base64.encode(der);
  return [
    '-----BEGIN CERTIFICATE-----',
    for (var i = 0; i < body.length; i += 64)
      body.substring(i, i + 64 > body.length ? body.length : i + 64),
    '-----END CERTIFICATE-----',
    '',
  ].join('\n');
}

/// The secret a TLS 1.3 keyLog line names [label] for (`EXPORTER_SECRET`
/// and so on), or null when [line] is another label.
Uint8List? keyLogSecret(String line, String label) {
  final parts = line.trim().split(' ');
  if (parts.length != 3 || parts[0] != label) return null;
  final hex = parts[2];
  if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
    return null;
  }
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// The RFC 8446 section 7.5 exporter from the connection's exporter master
/// secret, with an empty context as `SSL_export_keying_material` uses when
/// it is given none. The hash follows the secret's length: SHA-256 for the
/// 32-byte secret of an AES-128-GCM or ChaCha20 suite, SHA-384 for 48.
Uint8List tlsExporter(List<int> exporterSecret, List<int> label, int length) {
  Digest digest() => switch (exporterSecret.length) {
    32 => SHA256Digest(),
    48 => SHA384Digest(),
    _ => throw ArgumentError('an exporter secret is 32 or 48 bytes'),
  };
  final emptyHash = digest().process(Uint8List(0));
  final derived = _expandLabel(
    digest,
    exporterSecret,
    label,
    emptyHash,
    exporterSecret.length,
  );
  return _expandLabel(
    digest,
    derived,
    ascii.encode('exporter'),
    emptyHash,
    length,
  );
}

Uint8List _expandLabel(
  Digest Function() digest,
  List<int> secret,
  List<int> label,
  List<int> context,
  int length,
) {
  final fullLabel = [...ascii.encode('tls13 '), ...label];
  final info = [
    length >> 8,
    length & 0xff,
    fullLabel.length,
    ...fullLabel,
    context.length,
    ...context,
  ];
  return hkdfExpand(digest, secret, info, length);
}

/// HKDF-Expand (RFC 5869 section 2.3).
Uint8List hkdfExpand(
  Digest Function() digest,
  List<int> prk,
  List<int> info,
  int length,
) {
  final out = BytesBuilder();
  var previous = Uint8List(0);
  for (var i = 1; out.length < length; i++) {
    final hmac = HMac.withDigest(digest())
      ..init(KeyParameter(Uint8List.fromList(prk)));
    previous = hmac.process(Uint8List.fromList([...previous, ...info, i]));
    out.add(previous);
  }
  return Uint8List.sublistView(out.toBytes(), 0, length);
}

/// HKDF (RFC 5869) with no salt, which is HMAC with an all-zero key.
Uint8List hkdf(
  Digest Function() digest,
  List<int> ikm,
  List<int> info,
  int length,
) {
  final hmac = HMac.withDigest(digest())
    ..init(KeyParameter(Uint8List(digest().digestSize)));
  final prk = hmac.process(Uint8List.fromList(ikm));
  return hkdfExpand(digest, prk, info, length);
}

// A minimal DER encoder, enough for one certificate.

Uint8List _tlv(int tag, List<int> content) {
  final length = content.length;
  final List<int> encodedLength;
  if (length < 0x80) {
    encodedLength = [length];
  } else {
    final bytes = <int>[];
    for (var rest = length; rest > 0; rest >>= 8) {
      bytes.insert(0, rest & 0xff);
    }
    encodedLength = [0x80 | bytes.length, ...bytes];
  }
  return Uint8List.fromList([tag, ...encodedLength, ...content]);
}

Uint8List _seq(List<List<int>> items) =>
    _tlv(0x30, [for (final i in items) ...i]);

Uint8List _set(List<List<int>> items) =>
    _tlv(0x31, [for (final i in items) ...i]);

Uint8List _int(BigInt value) {
  final bytes = <int>[];
  for (var rest = value; rest > BigInt.zero; rest >>= 8) {
    bytes.insert(0, (rest & BigInt.from(0xff)).toInt());
  }
  if (bytes.isEmpty || bytes.first >= 0x80) bytes.insert(0, 0);
  return _tlv(0x02, bytes);
}

Uint8List _oid(String dotted) {
  final parts = dotted.split('.').map(int.parse).toList();
  final out = <int>[parts[0] * 40 + parts[1]];
  for (final part in parts.skip(2)) {
    final chunk = <int>[part & 0x7f];
    for (var rest = part >> 7; rest > 0; rest >>= 7) {
      chunk.insert(0, 0x80 | (rest & 0x7f));
    }
    out.addAll(chunk);
  }
  return _tlv(0x06, out);
}

Uint8List _ext(String oid, List<int> value, {bool critical = false}) => _seq([
  _oid(oid),
  if (critical) _tlv(0x01, const [0xff]),
  _tlv(0x04, value),
]);

/// UTCTime up to 2049, GeneralizedTime after, as RFC 5280 asks.
Uint8List _time(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final rest =
      '${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}'
      '${two(t.second)}Z';
  return t.year < 2050
      ? _tlv(0x17, ascii.encode('${two(t.year % 100)}$rest'))
      : _tlv(0x18, ascii.encode('${t.year}$rest'));
}
