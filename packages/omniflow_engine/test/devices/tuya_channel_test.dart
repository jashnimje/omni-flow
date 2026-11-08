import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../support/tuya_frames.dart';

const localKey = '0123456789abcdef';
const devId = 'bf0000000000000000test';

/// A loopback Tuya plug: acknowledges control and pushes its new status,
/// answers status queries, and can be told to stay silent or fail.
class FakePlug {
  FakePlug._(this._server) {
    _server.listen(_serve);
  }

  static Future<FakePlug> start() async =>
      FakePlug._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  final codec = TuyaCodec(localKey);
  final received = <TuyaFrame>[];
  final dps = <String, Object?>{'1': false};
  int connections = 0;
  int disconnects = 0;
  bool silent = false;
  bool answerHeartbeats = true;
  int retcode = 0;

  /// Plain text sent, encrypted, instead of the control acknowledgement.
  String? refuseWith;

  /// A frame no codec can decode, sent before every reply.
  bool garbageFirst = false;

  int get port => _server.port;

  void _serve(Socket socket) {
    connections++;
    final splitter = TuyaFrameSplitter();
    // The channel may drop the connection first, which resets this side.
    unawaited(socket.done.catchError((Object _) {}));
    socket.listen(onDone: () => disconnects++, onError: (Object _) {}, (
      Uint8List chunk,
    ) {
      for (final raw in splitter.add(chunk)) {
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
        if (frame.command == TuyaCommand.control && refusal != null) {
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
        } else if (frame.command == TuyaCommand.control) {
          dps.addAll(Map<String, Object?>.from(frame.body!['dps'] as Map));
          socket.add(
            codec.encode(
              seq: frame.seq,
              command: TuyaCommand.control,
              body: null,
              retcode: retcode,
            ),
          );
          socket.add(
            codec.encode(
              seq: 0,
              command: TuyaCommand.status,
              body: {'devId': devId, 'dps': Map.of(dps)},
              retcode: 0,
            ),
          );
        } else if (frame.command == TuyaCommand.dpQuery) {
          socket.add(
            codec.encode(
              seq: frame.seq,
              command: TuyaCommand.dpQuery,
              body: {'devId': devId, 'dps': Map.of(dps)},
              retcode: 0,
            ),
          );
        }
      }
    });
  }

  Future<void> close() => _server.close();
}

void main() {
  late FakePlug plug;
  late InMemorySecretStore secrets;
  late InMemoryDeviceStore store;
  late TuyaChannel channel;
  late DeviceService service;
  final clock = DateTime.utc(2023, 11, 14, 22, 13, 20);

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
    await store.put(
      Device(
        id: 'plug',
        name: 'Desk plug',
        driverId: 'tuya_plug',
        host: InternetAddress.loopbackIPv4.address,
        port: plug.port,
        settings: const {'devId': devId},
      ),
    );
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

    setUp(() {
      beating = TuyaChannel(
        secrets,
        clock: () => clock,
        heartbeatEvery: const Duration(milliseconds: 100),
      );
      beatingService = DeviceService(
        registry: DriverRegistry.withBuiltIns(),
        store: store,
        channels: {TransportType.tuya: beating},
      );
    });

    tearDown(() => beating.close());

    Future<void> until(bool Function() done) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!done()) {
        if (DateTime.now().isAfter(deadline)) fail('never happened');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('an idle connection sends heartbeats and stays open', () async {
      await beatingService.invoke('plug', 'power', {'value': true});
      await until(
        () =>
            plug.received
                .where((f) => f.command == TuyaCommand.heartbeat)
                .length >=
            3,
      );
      expect(plug.disconnects, 0);
      expect(plug.connections, 1);
    });

    test('two unanswered heartbeats close the connection', () async {
      plug.answerHeartbeats = false;
      await beatingService.invoke('plug', 'power', {'value': true});
      await until(() => plug.disconnects == 1);
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
}
