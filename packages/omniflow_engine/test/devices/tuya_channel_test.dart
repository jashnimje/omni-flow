import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../support/tuya_frames.dart';

const localKey = '0123456789abcdef';
const devId = 'bf0000000000000000test';
final remoteNonce = Uint8List.fromList(utf8.encode('device-nonce-016'));

/// A loopback Tuya plug: acknowledges control and pushes its new status,
/// answers status queries, and can be told to stay silent or fail. For
/// v3.4 and v3.5 it runs the device side of the session handshake first.
class FakePlug {
  FakePlug._(this._server, this.version) {
    _server.listen(_serve);
  }

  static Future<FakePlug> start({String version = '3.3'}) async => FakePlug._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    version,
  );

  final ServerSocket _server;
  final String version;
  final received = <TuyaFrame>[];
  final dps = <String, Object?>{'1': false};
  int connections = 0;
  int disconnects = 0;
  bool silent = false;
  bool answerHeartbeats = true;
  int retcode = 0;

  /// The key the plug proves in the handshake, another one to fake a
  /// device that holds a different key.
  String proofKey = localKey;

  /// Session keys agreed, one per connection.
  final sessionKeys = <Uint8List>[];

  /// Plain text sent, encrypted, instead of the control acknowledgement.
  String? refuseWith;

  /// A frame no codec can decode, sent before every reply.
  bool garbageFirst = false;

  int get port => _server.port;

  bool get _legacy => version == '3.3';

  void _serve(Socket socket) {
    connections++;
    final splitter = TuyaFrameSplitter();
    final keyBytes = Uint8List.fromList(utf8.encode(localKey));
    var codec = TuyaCodec(localKey, version: version);
    Uint8List? clientNonce;
    // The channel may drop the connection first, which resets this side.
    unawaited(socket.done.catchError((Object _) {}));
    socket.listen(onDone: () => disconnects++, onError: (Object _) {}, (
      Uint8List chunk,
    ) {
      for (final raw in splitter.add(chunk)) {
        final handshake = codec.decodeBytes(raw, fromDevice: false);
        if (handshake.command == TuyaCommand.sessionKeyStart) {
          clientNonce = handshake.plain;
          final proof = TuyaSession.hmac(
            Uint8List.fromList(utf8.encode(proofKey)),
            clientNonce!,
          );
          socket.add(
            codec.encodeBytes(
              seq: handshake.seq,
              command: TuyaCommand.sessionKeyResponse,
              payload: Uint8List.fromList([...remoteNonce, ...proof]),
              retcode: 0,
            ),
          );
          continue;
        }
        if (handshake.command == TuyaCommand.sessionKeyFinish) {
          expect(handshake.plain, TuyaSession.hmac(keyBytes, remoteNonce));
          final session = TuyaSession.sessionKey(
            version,
            keyBytes,
            clientNonce!,
            remoteNonce,
          );
          sessionKeys.add(session);
          codec = codec.withSessionKey(session);
          continue;
        }
        final frame = codec.decode(raw, fromDevice: false);
        received.add(frame);
        if (silent) continue;
        if (garbageFirst) {
          socket.add(
            rawTuyaFrame(frame.command, [
              ...tuyaRetcode(0),
              ...ascii.encode('3.3'),
              0,
            ]),
          );
        }
        final refusal = refuseWith;
        final isControl =
            frame.command == TuyaCommand.control ||
            frame.command == TuyaCommand.controlNew;
        if (isControl && refusal != null) {
          socket.add(
            rawTuyaFrame(frame.command, seq: frame.seq, [
              ...tuyaRetcode(0),
              ...tuyaEncrypt(localKey, utf8.encode(refusal)),
            ]),
          );
        } else if (frame.command == TuyaCommand.heartbeat) {
          if (answerHeartbeats) {
            socket.add(
              codec.encode(
                seq: frame.seq,
                command: TuyaCommand.heartbeat,
                body: null,
                retcode: 0,
              ),
            );
          }
        } else if (isControl) {
          final sent = _legacy
              ? frame.body!['dps']
              : (frame.body!['data'] as Map)['dps'];
          dps.addAll(Map<String, Object?>.from(sent as Map));
          socket.add(
            codec.encode(
              seq: frame.seq,
              command: frame.command,
              body: null,
              retcode: retcode,
            ),
          );
          socket.add(
            codec.encode(
              seq: 0,
              command: TuyaCommand.status,
              body: _legacy
                  ? {'devId': devId, 'dps': Map.of(dps)}
                  : {
                      'protocol': 4,
                      't': 1700000000,
                      'data': {'dps': Map.of(dps)},
                    },
              retcode: 0,
            ),
          );
        } else if (frame.command == TuyaCommand.dpQuery ||
            frame.command == TuyaCommand.dpQueryNew) {
          socket.add(
            codec.encode(
              seq: frame.seq,
              command: frame.command,
              body: _legacy
                  ? {'devId': devId, 'dps': Map.of(dps)}
                  : {
                      'protocol': 4,
                      't': 1700000000,
                      'data': {'dps': Map.of(dps)},
                    },
              retcode: 0,
            ),
          );
        }
      }
    });
  }

  Future<void> close() => _server.close();
}

/// A heartbeat timer the test fires by hand, so no beat depends on how
/// busy the machine is.
class ManualHeartbeat {
  final beats = <void Function()>[];

  Timer start(Duration every, void Function() beat) {
    beats.add(beat);
    return _NoTimer();
  }

  void fire() => beats.last();
}

class _NoTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => true;

  @override
  int get tick => 0;
}

void main() {
  late FakePlug plug;
  late InMemorySecretStore secrets;
  late InMemoryDeviceStore store;
  late TuyaChannel channel;
  late DeviceService service;
  final clock = DateTime.utc(2023, 11, 14, 22, 13, 20);

  Future<void> addPlug({
    Map<String, Object?> settings = const {},
    String driver = 'tuya_plug',
  }) => store.put(
    Device(
      id: 'plug',
      name: 'Desk plug',
      driverId: driver,
      host: InternetAddress.loopbackIPv4.address,
      port: plug.port,
      settings: {'devId': devId, ...settings},
    ),
  );

  setUp(() async {
    plug = await FakePlug.start();
    secrets = InMemorySecretStore();
    store = InMemoryDeviceStore();
    channel = TuyaChannel(secrets, clock: () => clock);
    service = DeviceService(
      registry: DriverRegistry.withBuiltIns(),
      store: store,
      channels: {TransportType.tuya: channel},
    );
    await secrets.write(deviceSecretKey('plug', 'localKey'), localKey);
    await addPlug();
  });

  tearDown(() async {
    await channel.close();
    await plug.close();
  });

  test(
    'power on sends an encrypted control frame and records the state',
    () async {
      final result = await service.invoke('plug', 'power', {'value': true});
      final sent = plug.received.single;
      expect(sent.command, TuyaCommand.control);
      expect(sent.body, {
        'devId': devId,
        'uid': devId,
        't': '1700000000',
        'dps': {'1': true},
      });
      expect(result.device.state, {'1': true});
    },
  );

  test(
    'the status pushed after a control frame reaches the push stream',
    () async {
      final push = channel.pushes.first;
      await service.invoke('plug', 'power', {'value': true});
      final got = await push.timeout(const Duration(seconds: 2));
      expect(got.deviceId, 'plug');
      expect(got.body['dps'], {'1': true});
    },
  );

  test('a status query refreshes state, over the same connection', () async {
    await service.invoke('plug', 'power', {'value': true});
    final device = await service.refreshState('plug');
    expect(device.state, {'1': true});
    expect(plug.received.last.command, TuyaCommand.dpQuery);
    expect(plug.received.last.body!['gwId'], devId);
    expect(plug.connections, 1);
  });

  test('a missing local key fails before anything is sent', () async {
    await secrets.delete(deviceSecretKey('plug', 'localKey'));
    await expectLater(
      service.invoke('plug', 'power', {'value': true}),
      throwsA(isA<MissingSecretException>()),
    );
    expect(plug.received, isEmpty);
  });

  test('a refusal in plain text fails the command with its words', () async {
    plug.refuseWith = 'json obj data unvalid';
    await expectLater(
      service.invoke('plug', 'power', {'value': true}),
      throwsA(
        isA<CommandFailedException>().having(
          (e) => e.message,
          'message',
          contains('json obj data unvalid'),
        ),
      ),
    );
  });

  test(
    'an undecodable frame is skipped and the real reply still lands',
    () async {
      plug.garbageFirst = true;
      final result = await service.invoke('plug', 'power', {'value': true});
      expect(result.device.state['1'], true);
    },
  );

  group('heartbeat', () {
    late TuyaChannel beating;
    late DeviceService beatingService;
    late ManualHeartbeat heartbeat;
    late PacketTap tap;

    setUp(() {
      heartbeat = ManualHeartbeat();
      tap = PacketTap();
      beating = TuyaChannel(
        secrets,
        tap: tap,
        clock: () => clock,
        heartbeatEvery: Duration.zero,
        heartbeatTimer: heartbeat.start,
      );
      beatingService = DeviceService(
        registry: DriverRegistry.withBuiltIns(),
        store: store,
        channels: {TransportType.tuya: beating},
      );
    });

    tearDown(() => beating.close());

    Future<void> until(bool Function() done) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!done()) {
        if (DateTime.now().isAfter(deadline)) fail('never happened');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    int heartbeatsSent() =>
        plug.received.where((f) => f.command == TuyaCommand.heartbeat).length;

    int framesBack() =>
        tap.recent.where((p) => p.direction == PacketDirection.incoming).length;

    test('an idle connection sends heartbeats and stays open', () async {
      await beatingService.invoke('plug', 'power', {'value': true});
      await until(() => framesBack() == 2);
      for (var beat = 1; beat <= 4; beat++) {
        heartbeat.fire();
        await until(() => heartbeatsSent() == beat);
        await until(() => framesBack() == 2 + beat);
      }
      expect(plug.disconnects, 0);
      expect(plug.connections, 1);
    });

    test('two unanswered heartbeats close the connection', () async {
      plug.answerHeartbeats = false;
      await beatingService.invoke('plug', 'power', {'value': true});
      await until(() => framesBack() == 2);
      heartbeat.fire();
      heartbeat.fire();
      await until(() => heartbeatsSent() == 2);
      expect(plug.disconnects, 0);
      heartbeat.fire();
      await until(() => plug.disconnects == 1);
      expect(heartbeatsSent(), 2);
      await beatingService.invoke('plug', 'power', {'value': false});
      expect(plug.connections, 2);
    });
  });

  test('a non-zero return code is a failed command', () async {
    plug.retcode = 1;
    await expectLater(
      service.invoke('plug', 'power', {'value': true}),
      throwsA(isA<CommandFailedException>()),
    );
  });

  test('a silent device times out after its retries', () async {
    plug.silent = true;
    await expectLater(
      service.invoke('plug', 'power', {'value': true}),
      throwsA(isA<TransportTimeoutException>()),
    );
    expect(plug.received, hasLength(2));
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('an unreachable device is reported as a transport timeout, so healing can run', () async {
    final closedPort = plug.port;
    await plug.close();
    await store.put((await store.get('plug'))!.copyWith(host: '127.0.0.1'));
    final device = (await store.get('plug'))!;
    expect(device.port, closedPort);
    await expectLater(
      service.invoke('plug', 'power', {'value': true}),
      throwsA(isA<TransportTimeoutException>()),
    );
  });

  test('an unknown version setting is refused before connecting', () async {
    await addPlug(settings: {'version': '3.2'});
    await expectLater(
      service.invoke('plug', 'power', {'value': true}),
      throwsA(isA<ArgumentError>()),
    );
    expect(plug.connections, 0);
  });

  group('tuya_light', () {
    setUp(() => addPlug(driver: 'tuya_light'));

    test('colour goes as Tuya HSV hex on DP 24 in colour mode', () async {
      await service.invoke('plug', 'rgb', {'r': 0, 'g': 255, 'b': 0});
      expect(plug.received.single.body!['dps'], {
        '20': true,
        '21': 'colour',
        '24': '007803e803e8',
      });
    });

    test('brightness, white temperature and mode use DPs 22, 23, 21', () async {
      await service.invoke('plug', 'brightness', {'value': 500});
      await service.invoke('plug', 'color_temp', {'value': 0});
      final result = await service.invoke('plug', 'mode', {'value': 'scene'});
      expect(
        [for (final f in plug.received) f.body!['dps']],
        [
          {'20': true, '22': 500},
          {'20': true, '21': 'white', '23': 0},
          {'20': true, '21': 'scene'},
        ],
      );
      expect(result.device.state['21'], 'scene');
    });

    test('a mode outside the list is refused before sending', () async {
      await expectLater(
        service.invoke('plug', 'mode', {'value': 'disco'}),
        throwsA(isA<ValidationException>()),
      );
      expect(plug.received, isEmpty);
    });
  });

  for (final version in ['3.4', '3.5']) {
    group('protocol $version', () {
      setUp(() async {
        await plug.close();
        plug = await FakePlug.start(version: version);
        await addPlug(settings: {'version': version});
      });

      test('agrees a session key, then sends a 0x0d control frame', () async {
        final result = await service.invoke('plug', 'power', {'value': true});
        expect(plug.sessionKeys, hasLength(1));
        final sent = plug.received.single;
        expect(sent.command, TuyaCommand.controlNew);
        expect(sent.body, {
          'protocol': 5,
          't': 1700000000,
          'data': {
            'dps': {'1': true},
          },
        });
        expect(result.device.state, {'1': true});
      });

      test('a pushed status nested under data reaches the push stream as '
          'dps', () async {
        final push = channel.pushes.first;
        await service.invoke('plug', 'power', {'value': true});
        final got = await push.timeout(const Duration(seconds: 2));
        expect(got.body['dps'], {'1': true});
      });

      test('a 0x10 query refreshes state over the same session', () async {
        await service.invoke('plug', 'power', {'value': true});
        final device = await service.refreshState('plug');
        expect(device.state, {'1': true});
        expect(plug.received.last.command, TuyaCommand.dpQueryNew);
        expect(plug.received.last.body, isEmpty);
        expect(plug.connections, 1);
        expect(plug.sessionKeys, hasLength(1));
      });

      test('a device proving another key fails, naming no key', () async {
        plug.proofKey = 'fedcba9876543210';
        await expectLater(
          service.invoke('plug', 'power', {'value': true}),
          throwsA(
            isA<CommandFailedException>().having(
              (e) => e.message,
              'message',
              allOf(contains('session'), isNot(contains(localKey))),
            ),
          ),
        );
        expect(plug.received, isEmpty);
      });

      test('the packet tap holds no local key or session key', () async {
        final tap = PacketTap();
        final tapped = TuyaChannel(secrets, tap: tap, clock: () => clock);
        final tappedService = DeviceService(
          registry: DriverRegistry.withBuiltIns(),
          store: store,
          channels: {TransportType.tuya: tapped},
        );
        await tappedService.invoke('plug', 'power', {'value': true});
        await tapped.close();
        String hexOf(List<int> b) =>
            b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
        final all = tap.recent.map((p) => hexOf(p.bytes)).join();
        expect(tap.recent, isNotEmpty);
        expect(all, isNot(contains(hexOf(utf8.encode(localKey)))));
        expect(all, isNot(contains(hexOf(plug.sessionKeys.single))));
      });
    });
  }
}
