import 'dart:convert';

import '../../api/api_error.dart';

/// NDEF records as the phone hands them over and writes them: `{tnf, type,
/// payload}`, where `tnf` is the type name format number (NFC Forum NDEF,
/// the same numbers as Android's `NdefRecord.TNF_*`) and `type` and
/// `payload` are hex. The app moves these bytes and nothing else, so the
/// record layout lives here. Any other key a client sends, such as a `uri`
/// it decoded itself, is ignored: the bytes are what the tag holds.
const tnfWellKnown = 1;
const tnfExternal = 4;

/// The link OmniFlow writes on a tag, and the app's NDEF intent filter.
const tagUriPrefix = 'omniflow://tag/';

/// The `applicationId` in `packages/omniflow_app/android/app/build.gradle.kts`.
/// The Android Application Record names it so Android opens the app for a
/// tag even when it is closed. A test keeps the two equal.
const omniflowApplicationId = 'com.jashnm.omniflow_app';

/// The tag thing id a tag link carries. Tag links come from tags anyone can
/// write, so the id is held to this pattern exactly, with no decoding.
final tagIdPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

/// Bounds on one scan's records. A type length is one byte in NDEF, and
/// the largest common tags hold under 8 KB.
const maxNdefRecords = 16;
const maxNdefTypeBytes = 255;
const maxNdefPayloadBytes = 8192;

final _androidPackage = RegExp(
  r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$',
);

/// The URI prefixes a URI record abbreviates to one byte (NFC Forum URI
/// RTD, table 3). Codes past the end are reserved.
const _uriPrefixes = [
  '',
  'http://www.',
  'https://www.',
  'http://',
  'https://',
  'tel:',
  'mailto:',
  'ftp://anonymous:anonymous@',
  'ftp://ftp.',
  'ftps://',
  'sftp://',
  'smb://',
  'nfs://',
  'ftp://',
  'dav://',
  'news:',
  'telnet://',
  'imap:',
  'rtsp://',
  'urn:',
  'pop:',
  'sip:',
  'sips:',
  'tftp:',
  'btspp://',
  'btl2cap://',
  'btgoep://',
  'tcpobex://',
  'irdaobex://',
  'file://',
  'urn:epc:id:',
  'urn:epc:tag:',
  'urn:epc:pat:',
  'urn:epc:raw:',
  'urn:epc:',
  'urn:nfc:',
];

final _hexDigits = RegExp(r'^[0-9A-Fa-f]*$');

List<int>? _hexBytes(Object? hex, int maxBytes) {
  if (hex is! String || hex.length.isOdd || hex.length > maxBytes * 2) {
    return null;
  }
  if (!_hexDigits.hasMatch(hex)) return null;
  return [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

String _hex(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

String? _utf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// One record read back: its `tnf` and `type` as text, plus `uri` for a
/// URI record and `text` for a text record, when their bytes are valid
/// UTF-8 and a URI record's prefix code is not reserved. Throws `invalid`
/// for a record that is not `{tnf: 0..7, type: hex, payload: hex}` within
/// the bounds above.
Map<String, Object?> decodeNdefRecord(Object? record) {
  final tnf = record is Map ? record['tnf'] : null;
  final type = record is Map
      ? _hexBytes(record['type'] ?? '', maxNdefTypeBytes)
      : null;
  final payload = record is Map
      ? _hexBytes(record['payload'] ?? '', maxNdefPayloadBytes)
      : null;
  if (tnf is! int || tnf < 0 || tnf > 7 || type == null || payload == null) {
    throw ApiError(
      'invalid',
      'an NDEF record is {tnf: 0 to 7, type: hex, payload: hex}, with a type '
          'of at most $maxNdefTypeBytes bytes and a payload of at most '
          '$maxNdefPayloadBytes',
    );
  }
  final typeText = utf8.decode(type, allowMalformed: true);
  final decoded = <String, Object?>{'tnf': tnf, 'type': typeText};
  if (tnf == tnfWellKnown && typeText == 'U' && payload.isNotEmpty) {
    final rest = _utf8(payload.sublist(1));
    if (payload.first < _uriPrefixes.length && rest != null) {
      decoded['uri'] = _uriPrefixes[payload.first] + rest;
    }
  } else if (tnf == tnfWellKnown && typeText == 'T' && payload.isNotEmpty) {
    final status = payload.first;
    final language = status & 0x3f;
    if (1 + language <= payload.length) {
      final body = payload.sublist(1 + language);
      final text = status & 0x80 == 0
          ? _utf8(body)
          : String.fromCharCodes([
              for (var i = 0; i + 1 < body.length; i += 2)
                body[i] << 8 | body[i + 1],
            ]);
      if (text != null) decoded['text'] = text;
    }
  }
  return decoded;
}

/// Every record of [records], decoded. Null when [records] is null.
List<Map<String, Object?>>? decodeNdef(Object? records) {
  if (records == null) return null;
  if (records is! List || records.length > maxNdefRecords) {
    throw ApiError(
      'invalid',
      'ndef must be a list of at most $maxNdefRecords records',
    );
  }
  return [for (final r in records) decodeNdefRecord(r)];
}

/// The tag thing id an `omniflow://tag/<id>` record names, or null when
/// the tag carries no OmniFlow link. Throws `invalid` for an OmniFlow link
/// whose id is not exactly [tagIdPattern] (a path, a query, an escape, a
/// capital), and for two links naming different ids.
String? tagIdFromNdef(List<Map<String, Object?>>? records) {
  String? found;
  for (final r in records ?? const <Map<String, Object?>>[]) {
    final uri = r['uri'];
    if (uri is! String || !uri.startsWith(tagUriPrefix)) continue;
    final id = uri.substring(tagUriPrefix.length);
    if (!tagIdPattern.hasMatch(id)) {
      throw ApiError(
        'invalid',
        'the tag link does not name a tag id. A tag id is lower snake case, '
            'up to 64 characters',
      );
    }
    if (found != null && found != id) {
      throw ApiError('invalid', 'the tag carries links to two tags');
    }
    found = id;
  }
  return found;
}

/// A URI record for [uri], written out in full (prefix code 0).
Map<String, Object?> uriRecord(String uri) => {
  'tnf': tnfWellKnown,
  'type': _hex(utf8.encode('U')),
  'payload': _hex([0, ...utf8.encode(uri)]),
};

/// What the phone writes on the tag thing [tagId]: the `omniflow://tag/`
/// link, then an Android Application Record for [androidPackage], so
/// Android opens the app for the tag even when it is closed.
List<Map<String, Object?>> tagRecords(
  String tagId, {
  String androidPackage = omniflowApplicationId,
}) {
  if (!tagIdPattern.hasMatch(tagId)) {
    throw ApiError(
      'invalid',
      'a tag id written on a tag is lower snake case, up to 64 characters',
    );
  }
  if (!_androidPackage.hasMatch(androidPackage)) {
    throw ApiError('invalid', 'androidPackage is a Java package name');
  }
  return [
    uriRecord('$tagUriPrefix$tagId'),
    {
      'tnf': tnfExternal,
      'type': _hex(utf8.encode('android.com:pkg')),
      'payload': _hex(utf8.encode(androidPackage)),
    },
  ];
}
