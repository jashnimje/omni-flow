import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../support/tuya_frames.dart';

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

  test('a device reply with a return code matches tinytuya too', () {
    final v = vector('statusReply');
    final frame = codec.encode(
      seq: v['seq'] as int,
      command: v['cmd'] as int,
      body: Map<String, Object?>.from(v['body'] as Map),
      retcode: v['retcode'] as int,
    );
    expect(toHex(frame), v['frameHex']);
  });

  test('an acknowledgement with no body decodes to a null body', () {
    final ack = codec.encode(
      seq: 5,
      command: TuyaCommand.control,
      body: null,
      retcode: 0,
    );
    final frame = codec.decode(ack);
    expect(frame.retcode, 0);
    expect(frame.body, isNull);
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

  test('a local key must be 16 bytes, and the version must be known', () {
    expect(() => TuyaCodec('short'), throwsArgumentError);
    expect(
      () => TuyaCodec('0123456789abcdef', version: '3.2'),
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

  test('the splitter skips a prefix with an impossible length', () {
    final good = hex(vector('statusReply')['frameHex'] as String);
    final bogus =
        (ByteData(16)
              ..setUint32(0, 0x000055AA)
              ..setUint32(12, 0x7FFFFFFF))
            .buffer
            .asUint8List();
    final frames = TuyaFrameSplitter().add([...bogus, ...good]);
    expect(frames.map(toHex), [toHex(good)]);
  });

  group('a malformed device reply is a decode error, never a crash', () {
    final key = vectors['localKey'] as String;

    test('a 3.3 header cut short', () {
      final frame = rawTuyaFrame(TuyaCommand.status, [
        ...tuyaRetcode(0),
        ...ascii.encode('3.3'),
        0,
        0,
      ]);
      expect(() => codec.decode(frame), throwsA(isA<TuyaDecodeException>()));
    });

    test('plain text where JSON should be is the device refusing', () {
      final frame = rawTuyaFrame(TuyaCommand.control, [
        ...tuyaRetcode(0),
        ...tuyaEncrypt(key, utf8.encode('json obj data unvalid')),
      ]);
      expect(
        () => codec.decode(frame),
        throwsA(
          isA<TuyaDecodeException>()
              .having(
                (e) => e.deviceMessage,
                'deviceMessage',
                'json obj data unvalid',
              )
              .having((e) => e.command, 'command', TuyaCommand.control),
        ),
      );
    });

    test('binary that is not JSON carries no device message', () {
      final frame = rawTuyaFrame(TuyaCommand.status, [
        ...tuyaRetcode(0),
        ...tuyaEncrypt(key, [0x01, 0xFE, 0x7B, 0x00]),
      ]);
      expect(
        () => codec.decode(frame),
        throwsA(
          isA<TuyaDecodeException>().having(
            (e) => e.deviceMessage,
            'deviceMessage',
            isNull,
          ),
        ),
      );
    });
  });
}
