import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// Golden frames from tinytuya: tool/gen_tuya_vectors.py.
final vectors = jsonDecode(
  File('test/fixtures/tuya_v33_vectors.json').readAsStringSync(),
) as Map<String, Object?>;

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Map<String, Object?> vector(String name) =>
    vectors[name] as Map<String, Object?>;

void main() {
  final codec = TuyaCodec(vectors['localKey'] as String);

  test('crc32 matches the standard check value', () {
    expect(crc32(ascii.encode('123456789')), 0xCBF43926);
  });

  group('encode matches tinytuya byte for byte', () {
    for (final name in ['control', 'statusQuery']) {
      test(name, () {
        final v = vector(name);
        final frame = codec.encode(
          seq: v['seq'] as int,
          command: v['cmd'] as int,
          body: Map<String, Object?>.from(v['body'] as Map),
        );
        expect(toHex(frame), v['frameHex']);
      });
    }
  });

  group('decode', () {
    test('a device status reply, with its return code', () {
      final v = vector('statusReply');
      final frame = codec.decode(hex(v['frameHex'] as String));
      expect(frame.seq, 2);
      expect(frame.command, TuyaCommand.dpQuery);
      expect(frame.retcode, 0);
      expect(frame.body, v['body']);
    });

    test('a client control frame, skipping the 3.3 header', () {
      final v = vector('control');
      final frame = codec.decode(
        hex(v['frameHex'] as String),
        fromDevice: false,
      );
      expect(frame.retcode, isNull);
      expect(frame.body, v['body']);
    });

    test('rejects a flipped byte as a CRC mismatch', () {
      final bytes = hex(vector('statusReply')['frameHex'] as String);
      bytes[20] ^= 0x01;
      expect(
        () => codec.decode(bytes),
        throwsA(
          isA<TuyaDecodeException>().having(
            (e) => e.message,
            'message',
            'CRC mismatch',
          ),
        ),
      );
    });

    test('rejects a frame encrypted with another key', () {
      final other = TuyaCodec('fedcba9876543210');
      expect(
        () => other.decode(hex(vector('statusReply')['frameHex'] as String)),
        throwsA(isA<TuyaDecodeException>()),
      );
    });

    test('rejects truncated frames and a bad prefix', () {
      final bytes = hex(vector('statusReply')['frameHex'] as String);
      expect(
        () => codec.decode(Uint8List.sublistView(bytes, 0, 20)),
        throwsA(isA<TuyaDecodeException>()),
      );
      final badPrefix = Uint8List.fromList(bytes)..[2] = 0x66;
      expect(
        () => codec.decode(badPrefix),
        throwsA(isA<TuyaDecodeException>()),
      );
    });
  });

  test('a local key must be 16 bytes, and only 3.3 is implemented', () {
    expect(() => TuyaCodec('short'), throwsArgumentError);
    expect(
      () => TuyaCodec('0123456789abcdef', version: '3.5'),
      throwsUnsupportedError,
    );
  });

  test('the splitter reassembles frames from arbitrary chunks', () {
    final a = hex(vector('statusReply')['frameHex'] as String);
    final b = codec.encode(
      seq: 9,
      command: TuyaCommand.heartbeat,
      body: const {},
    );
    final stream = [0x01, 0x02, ...a, ...b];
    final splitter = TuyaFrameSplitter();
    final frames = <Uint8List>[];
    for (var i = 0; i < stream.length; i += 7) {
      frames.addAll(
        splitter.add(stream.sublist(i, (i + 7).clamp(0, stream.length))),
      );
    }
    expect(frames.map(toHex), [toHex(a), toHex(b)]);
    expect(codec.decode(frames[1], fromDevice: false).seq, 9);
  });
}
