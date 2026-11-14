import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// Golden frames from tinytuya: tool/gen_tuya_session_vectors.py.
final vectors = jsonDecode(
  File('test/fixtures/tuya_v34_v35_vectors.json').readAsStringSync(),
) as Map<String, Object?>;

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final localKey = Uint8List.fromList(
    utf8.encode(vectors['localKey'] as String),
  );

  for (final version in ['3.4', '3.5']) {
    group('v$version matches tinytuya', () {
      final v =
          vectors['v${version.replaceAll('.', '')}'] as Map<String, Object?>;
      Map<String, Object?> step(String name) => v[name] as Map<String, Object?>;
      Uint8List frameOf(String name) => hex(step(name)['frameHex'] as String);
      final localNonce = hex(v['localNonceHex'] as String);
      final remoteNonce = hex(v['remoteNonceHex'] as String);
      final sessionKey = hex(v['sessionKeyHex'] as String);
      final clientIv = v['clientIvHex'] == null
          ? null
          : hex(v['clientIvHex'] as String);
      Uint8List fixedIv(int length) => clientIv!;
      final handshake = TuyaCodec.withKey(
        localKey,
        version: version,
        random: fixedIv,
      );
      final session = handshake.withSessionKey(sessionKey);

      test('step 1 sends the client nonce under the local key', () {
        final frame = handshake.encodeBytes(
          seq: 1,
          command: TuyaCommand.sessionKeyStart,
          payload: localNonce,
        );
        expect(toHex(frame), step('step1')['frameHex']);
      });

      test('the device answer proves the key and yields its nonce', () {
        final answer = handshake.decodeBytes(frameOf('step2'));
        expect(answer.command, TuyaCommand.sessionKeyResponse);
        expect(answer.retcode, 0);
        expect(
          TuyaSession.remoteNonce(answer.plain!, localKey, localNonce),
          remoteNonce,
        );
      });

      test('an answer under another key fails the proof', () {
        final answer = handshake.decodeBytes(frameOf('step2'));
        final otherKey = Uint8List.fromList(utf8.encode('fedcba9876543210'));
        expect(
          TuyaSession.remoteNonce(answer.plain!, otherKey, localNonce),
          isNull,
        );
      });

      test('step 3 answers with the HMAC of the device nonce', () {
        final frame = handshake.encodeBytes(
          seq: 2,
          command: TuyaCommand.sessionKeyFinish,
          payload: TuyaSession.hmac(localKey, remoteNonce),
        );
        expect(toHex(frame), step('step3')['frameHex']);
      });

      test('both nonces give the session key tinytuya derives', () {
        expect(
          toHex(
            TuyaSession.sessionKey(version, localKey, localNonce, remoteNonce),
          ),
          v['sessionKeyHex'],
        );
      });

      test('a control frame under the session key', () {
        final frame = session.encode(
          seq: 3,
          command: TuyaCommand.controlNew,
          body: Map<String, Object?>.from(step('control')['body'] as Map),
        );
        expect(toHex(frame), step('control')['frameHex']);
        final back = session.decode(frame, fromDevice: false);
        expect(back.body, step('control')['body']);
      });

      test('a status push decodes, version header and all', () {
        final push = session.decode(frameOf('push'));
        expect(push.command, TuyaCommand.status);
        expect(push.retcode, 0);
        expect(push.body, step('push')['body']);
      });

      test('a flipped byte fails the check', () {
        final bytes = frameOf('push')..[24] ^= 0x01;
        expect(
          () => session.decode(bytes),
          throwsA(isA<TuyaDecodeException>()),
        );
      });

      test('a frame under the local key does not decode as the session', () {
        expect(
          () => session.decode(frameOf('step2')),
          throwsA(isA<TuyaDecodeException>()),
        );
      });

      test('the splitter cuts these frames from a stream', () {
        final a = frameOf('step2');
        final b = frameOf('push');
        final stream = [0x01, ...a, ...b];
        final splitter = TuyaFrameSplitter();
        final frames = <Uint8List>[];
        for (var i = 0; i < stream.length; i += 5) {
          frames.addAll(
            splitter.add(stream.sublist(i, (i + 5).clamp(0, stream.length))),
          );
        }
        expect(frames.map(toHex), [toHex(a), toHex(b)]);
      });
    });
  }

  test('v3.4 query matches tinytuya', () {
    final v = vectors['v34'] as Map<String, Object?>;
    final query = v['query'] as Map<String, Object?>;
    final session = TuyaCodec.withKey(
      hex(v['sessionKeyHex'] as String),
      version: '3.4',
    );
    final frame = session.encode(
      seq: 4,
      command: TuyaCommand.dpQueryNew,
      body: const {},
    );
    expect(toHex(frame), query['frameHex']);
  });

  test('an unknown version is refused', () {
    expect(
      () => TuyaCodec('0123456789abcdef', version: '3.6'),
      throwsUnsupportedError,
    );
  });
}
