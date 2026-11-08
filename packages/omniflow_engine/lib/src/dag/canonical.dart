import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// JSON with every object's keys sorted, so equal values encode the same.
String canonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) => switch (value) {
  Map m => {
    for (final e
        in m.entries.toList()..sort((a, b) => '${a.key}'.compareTo('${b.key}')))
      '${e.key}': _sorted(e.value),
  },
  List l => [for (final e in l) _sorted(e)],
  _ => value,
};

/// Lower-case hex SHA-256 of [text] as UTF-8.
String sha256Hex(String text) => SHA256Digest()
    .process(Uint8List.fromList(utf8.encode(text)))
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();
