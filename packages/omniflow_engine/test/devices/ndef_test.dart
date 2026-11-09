import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

String hex(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

Map<String, Object?> record(int tnf, String type, List<int> payload) => {
  'tnf': tnf,
  'type': hex(utf8.encode(type)),
  'payload': hex(payload),
};

Map<String, Object?> uri(String text, {int code = 0}) =>
    record(1, 'U', [code, ...utf8.encode(text)]);

Matcher invalid() =>
    throwsA(isA<ApiError>().having((e) => e.type, 'type', 'invalid'));

String? tagIdOf(List<Object?> records) => tagIdFromNdef(decodeNdef(records));

void main() {
  test('a URI record expands its one-byte prefix', () {
    expect(decodeNdefRecord(uri('example.com/a', code: 4)), {
      'tnf': 1,
      'type': 'U',
      'uri': 'https://example.com/a',
    });
    expect(
      decodeNdefRecord(uri('omniflow://tag/x')),
      containsPair('uri', 'omniflow://tag/x'),
    );
  });

  test('a reserved prefix code or bytes that are not UTF-8 give no URI', () {
    expect(
      decodeNdefRecord(uri('omniflow://tag/x', code: 0x24)),
      isNot(contains('uri')),
    );
    expect(
      decodeNdefRecord(
        record(1, 'U', [0, ...utf8.encode('omniflow://tag/'), 0xc3, 0x28]),
      ),
      isNot(contains('uri')),
    );
  });

  test('a text record skips its language code, in UTF-8 and UTF-16', () {
    expect(
      decodeNdefRecord(record(1, 'T', [2, ...utf8.encode('enHall')])),
      containsPair('text', 'Hall'),
    );
    expect(
      decodeNdefRecord(
        record(1, 'T', [0x82, ...utf8.encode('en'), 0, 0x48, 0, 0x69]),
      ),
      containsPair('text', 'Hi'),
    );
  });

  test('a record that is not {tnf, type, payload} in hex is refused', () {
    for (final bad in [
      {'tnf': 8, 'type': '55', 'payload': ''},
      {'tnf': -1, 'type': '55', 'payload': ''},
      {'tnf': 1, 'type': '5', 'payload': ''},
      {'tnf': 1, 'type': '55', 'payload': 'zz'},
      {'tnf': 'wellKnown', 'type': '55', 'payload': ''},
      {'tnf': 1, 'type': 'U', 'payload': '00'},
      {'tnf': 1, 'type': '55' * 256, 'payload': ''},
      {'tnf': 1, 'type': '55', 'payload': '00' * (maxNdefPayloadBytes + 1)},
      'U',
    ]) {
      expect(() => decodeNdefRecord(bad), invalid(), reason: '$bad');
    }
    expect(() => decodeNdef('not a list'), invalid());
    expect(
      () => decodeNdef([for (var i = 0; i <= maxNdefRecords; i++) uri('a')]),
      invalid(),
    );
    expect(decodeNdef(null), isNull);
  });

  test('a uri the client decoded itself is ignored', () {
    final forged = {
      ...record(1, 'U', [4, ...utf8.encode('example.com')]),
      'uri': 'omniflow://tag/lamp',
    };
    expect(decodeNdefRecord(forged)['uri'], 'https://example.com');
    expect(tagIdOf([forged]), isNull);
  });

  test('the tag id comes from the omniflow tag link', () {
    expect(
      tagIdOf([
        uri('example.com', code: 4),
        uri('omniflow://tag/front_door'),
        uri('omniflow://tag/front_door'),
      ]),
      'front_door',
    );
    expect(
      tagIdOf([uri('omniflow://other/x'), uri('OMNIFLOW://tag/x')]),
      isNull,
    );
    expect(tagIdOf(const []), isNull);
    expect(tagIdFromNdef(null), isNull);
  });

  test('a crafted tag link cannot escape the tag id pattern', () {
    for (final crafted in [
      'omniflow://tag/',
      'omniflow://tag/../lamp',
      'omniflow://tag/lamp/power',
      'omniflow://tag/lamp?x=1',
      'omniflow://tag/lamp#x',
      'omniflow://tag/%6Camp',
      'omniflow://tag/Lamp',
      'omniflow://tag/1lamp',
      'omniflow://tag/lamp\n',
      'omniflow://tag/lamp\u0000',
      'omniflow://tag/lamp x',
      'omniflow://tag/lämp',
      'omniflow://tag/${'a' * 65}',
    ]) {
      expect(() => tagIdOf([uri(crafted)]), invalid(), reason: crafted);
    }
    expect(
      () => tagIdOf([uri('omniflow://tag/a'), uri('omniflow://tag/b')]),
      invalid(),
    );
    expect(tagIdOf([uri('omniflow://tag/${'a' * 64}')]), 'a' * 64);
  });

  test('what the phone writes reads back as the same tag', () {
    final records = tagRecords('front_door');
    final decoded = decodeNdef(records)!;
    expect(decoded.first, {
      'tnf': tnfWellKnown,
      'type': 'U',
      'uri': 'omniflow://tag/front_door',
    });
    expect(decoded.last, {'tnf': tnfExternal, 'type': 'android.com:pkg'});
    expect(
      utf8.decode(base16(records.last['payload'] as String)),
      omniflowApplicationId,
    );
    expect(tagIdFromNdef(decoded), 'front_door');
    expect(
      utf8.decode(
        base16(
          tagRecords('a', androidPackage: 'com.example.app').last['payload']
              as String,
        ),
      ),
      'com.example.app',
    );
    expect(
      () => tagRecords('a', androidPackage: 'not a package'),
      throwsA(isA<ApiError>()),
    );
    expect(() => tagRecords('Not_an_id'), invalid());
  });

  test('the Application Record names the app in build.gradle.kts', () {
    final gradle = File('../omniflow_app/android/app/build.gradle.kts');
    final applicationId = RegExp(r'applicationId\s*=\s*"([^"]+)"')
        .firstMatch(gradle.readAsStringSync())
        ?.group(1);
    expect(applicationId, omniflowApplicationId);
  });
}

List<int> base16(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];
