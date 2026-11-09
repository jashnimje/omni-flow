import 'dart:async';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/engine_core.dart';
import 'package:omniflow_engine/src/api/host_key_commands.dart';
import 'package:test/test.dart';

void main() {
  late OmniDatabase db;
  late UdpTransport udp;
  late InMemorySecretStore secrets;
  late EngineCore core;
  late Map<String, String> offered;
  late HostKeyCommands commands;

  setUp(() async {
    db = OmniDatabase.memory();
    udp = await UdpTransport.bind();
    secrets = InMemorySecretStore();
    final registry = DriverRegistry.withBuiltIns();
    final serial = SerialChannel();
    core = EngineCore(
      db: db,
      registry: registry,
      devices: DeviceService(
        registry: registry,
        store: DriftDeviceStore(db),
        channels: const {},
      ),
      secrets: secrets,
      discovery: DeviceDiscovery(udp: UdpDiscovery(udp)),
      tap: null,
      serial: serial,
      mqtt: MqttChannel(secrets),
      boardChannel: BoardChannel(udp: UdpJsonChannel(udp), serial: serial),
      http: HttpChannel(secrets: secrets),
      tv: TvWebSocketChannel(secrets),
      adb: AdbChannel(secrets),
    );
    offered = {'10.0.0.7:2222': 'ssh-ed25519 SHA256:aaa'};
    commands = HostKeyCommands(
      core,
      probe: (host, port) async =>
          offered['$host:$port'] ??
          (throw TransportTimeoutException('cannot reach $host:$port')),
    );
    final store = DriftDeviceStore(db);
    await store.put(
      const Device(
        id: 'mini',
        name: 'Mac mini',
        driverId: 'macos_host',
        host: '10.0.0.7',
        port: 2222,
        settings: {'username': 'jade'},
      ),
    );
    await store.put(
      const Device(
        id: 'me',
        name: 'This Mac',
        driverId: 'macos_host',
        host: 'local',
      ),
    );
    await store.put(
      const Device(
        id: 'lamp',
        name: 'Lamp',
        driverId: 'philips_wiz_udp',
        host: '10.0.0.5',
      ),
    );
  });

  tearDown(() async {
    udp.close();
    await db.close();
  });

  Future<Map<String, Object?>> run(Map<String, Object?> args) =>
      commands.hostKey(args);

  Future<String?> pin() => secrets.read(HostKeyPins.keyFor('10.0.0.7', 2222));

  test('show reports the pinned key and the offered one', () async {
    expect(await run({'id': 'mini'}), {
      'id': 'mini',
      'host': '10.0.0.7',
      'port': 2222,
      'pinned': null,
      'offered': 'ssh-ed25519 SHA256:aaa',
    });
    await secrets.write(
      HostKeyPins.keyFor('10.0.0.7', 2222),
      'ssh-ed25519 SHA256:old',
    );
    final shown = await run({'id': 'mini', 'action': 'show'});
    expect(shown['pinned'], 'ssh-ed25519 SHA256:old');
    expect(shown['matches'], isFalse);
  });

  test('show of an unreachable host still gives the pin', () async {
    offered.clear();
    await secrets.write(
      HostKeyPins.keyFor('10.0.0.7', 2222),
      'ssh-ed25519 SHA256:old',
    );
    final shown = await run({'id': 'mini'});
    expect(shown['pinned'], 'ssh-ed25519 SHA256:old');
    expect(shown['offered'], isNull);
    expect(shown['error'], contains('cannot reach'));
    expect(shown.containsKey('matches'), isFalse);
  });

  test(
    'accept pins the offered key only when it is the reviewed one',
    () async {
      await secrets.write(
        HostKeyPins.keyFor('10.0.0.7', 2222),
        'ssh-ed25519 SHA256:old',
      );
      await expectLater(
        run({'id': 'mini', 'action': 'accept', 'fingerprint': 'SHA256:zzz'}),
        throwsA(isA<ApiError>().having((e) => e.type, 'type', 'conflict')),
      );
      expect(await pin(), 'ssh-ed25519 SHA256:old');
      await expectLater(
        run({'id': 'mini', 'action': 'accept'}),
        throwsA(isA<ApiError>().having((e) => e.type, 'type', 'invalid')),
      );
      final accepted = await run({
        'id': 'mini',
        'action': 'accept',
        'fingerprint': 'SHA256:aaa',
      });
      expect(accepted['pinned'], 'ssh-ed25519 SHA256:aaa');
      expect(accepted['previous'], 'ssh-ed25519 SHA256:old');
      expect(await pin(), 'ssh-ed25519 SHA256:aaa');
      final again = await run({
        'id': 'mini',
        'action': 'accept',
        'fingerprint': 'ssh-ed25519 SHA256:aaa',
      });
      expect(again['previous'], 'ssh-ed25519 SHA256:aaa');
    },
  );

  test('accept of an unreachable host pins nothing', () async {
    offered.clear();
    await expectLater(
      run({'id': 'mini', 'action': 'accept', 'fingerprint': 'SHA256:aaa'}),
      throwsA(isA<TransportTimeoutException>()),
    );
    expect(await pin(), isNull);
  });

  test('clear removes the pin, so the next connection pins anew', () async {
    await secrets.write(
      HostKeyPins.keyFor('10.0.0.7', 2222),
      'ssh-ed25519 SHA256:old',
    );
    expect((await run({'id': 'mini', 'action': 'clear'}))['cleared'], isTrue);
    expect(await pin(), isNull);
    expect((await run({'id': 'mini', 'action': 'clear'}))['cleared'], isFalse);
    await HostKeyPins(secrets)
        .verify('10.0.0.7', 2222, 'ssh-ed25519', 'SHA256:new');
    expect(await pin(), 'ssh-ed25519 SHA256:new');
  });

  test('only a device reached over SSH has a host key', () async {
    for (final id in ['me', 'lamp']) {
      await expectLater(
        run({'id': id}),
        throwsA(isA<ApiError>().having((e) => e.type, 'type', 'invalid')),
        reason: id,
      );
    }
    await expectLater(
      run({'id': 'mini', 'action': 'forget'}),
      throwsA(isA<ApiError>().having((e) => e.type, 'type', 'invalid')),
    );
    await expectLater(
      run({'id': 'nobody'}),
      throwsA(isA<ApiError>().having((e) => e.type, 'type', 'not_found')),
    );
  });

  test('a changed host key is a host_key error naming both keys', () {
    final error = hostKeyError(
      HostKeyMismatchException(
        '10.0.0.7:2222',
        'ssh-ed25519 SHA256:old',
        'ssh-ed25519 SHA256:new',
      ),
    );
    expect(error.type, 'host_key');
    expect(error.message, contains('SHA256:old'));
    expect(error.message, contains('SHA256:new'));
    expect(error.message, contains('device.hostkey'));
  });

  group('the host key probe', () {
    test('a closed port is a transport timeout', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      await expectLater(
        probeSshHostKey('127.0.0.1', port),
        throwsA(isA<TransportTimeoutException>()),
      );
    });

    test(
      'a server that hangs up before its key is a transport timeout',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        server.listen((s) {
          s.write('SSH-2.0-Fake\r\n');
          unawaited(s.flush().then((_) => s.destroy()));
        });
        await expectLater(
          probeSshHostKey('127.0.0.1', server.port),
          throwsA(isA<TransportTimeoutException>()),
        );
      },
    );

    test('a server that never speaks times out', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await server.close();
      });
      server.listen(held.add);
      await expectLater(
        probeSshHostKey(
          '127.0.0.1',
          server.port,
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<TransportTimeoutException>()),
      );
    });
  });
}
