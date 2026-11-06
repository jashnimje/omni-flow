import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

class RecordingExecutor implements HostExecutor {
  final calls = <(List<String>, String?)>[];
  int exitCode = 0;

  @override
  Future<CommandResult> run(
    List<String> argv, {
    String? stdin,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((argv, stdin));
    return CommandResult(
      exitCode: exitCode,
      stdout: 'ok',
      stderr: exitCode == 0 ? '' : 'denied',
      duration: Duration.zero,
    );
  }
}

void main() {
  group('macos_host over the exec channel', () {
    late RecordingExecutor executor;
    late DeviceService service;
    late InMemoryDeviceStore store;

    setUp(() async {
      executor = RecordingExecutor();
      store = InMemoryDeviceStore();
      service = DeviceService(
        registry: DriverRegistry.withBuiltIns(),
        store: store,
        channels: {TransportType.exec: ExecChannel((_) => executor)},
      );
      await store.put(
        const Device(
          id: 'mac_mini',
          name: 'Mac mini',
          driverId: 'macos_host',
          host: '192.168.1.10',
          settings: {'username': 'jade'},
        ),
      );
    });

    test('volume renders one osascript argument', () async {
      await service.invoke('mac_mini', 'volume', {'value': 45});
      expect(executor.calls.single.$1, [
        'osascript',
        '-e',
        'set volume output volume 45',
      ]);
    });

    test('volume out of range never runs', () async {
      await expectLater(
        service.invoke('mac_mini', 'volume', {'value': 150}),
        throwsA(isA<ValidationException>()),
      );
      expect(executor.calls, isEmpty);
    });

    test('display wake and sleep take no params', () async {
      await service.invoke('mac_mini', 'display_wake', {});
      await service.invoke('mac_mini', 'display_sleep', {});
      expect(executor.calls.map((c) => c.$1.first), ['caffeinate', 'pmset']);
    });

    test(
      'a shortcut name is one argument and its input goes on stdin',
      () async {
        await service.invoke('mac_mini', 'run_shortcut', {
          'value': 'Focus; rm -rf ~',
          'stdin': 'hello',
        });
        expect(executor.calls.single.$1, [
          'shortcuts',
          'run',
          'Focus; rm -rf ~',
        ]);
        expect(executor.calls.single.$2, 'hello');
      },
    );

    test('a non-zero exit fails the command', () async {
      executor.exitCode = 1;
      await expectLater(
        service.invoke('mac_mini', 'display_wake', {}),
        throwsA(isA<CommandFailedException>()),
      );
    });
  });

  group('hostExecutors', () {
    final pick = hostExecutors(InMemorySecretStore());

    test('local runs on this machine, anything else over SSH', () {
      expect(
        pick(
          const Device(
            id: 'me',
            name: 'me',
            driverId: 'macos_host',
            host: 'local',
          ),
        ),
        isA<LocalExecutor>(),
      );
      final ssh = pick(
        const Device(
          id: 'mac_mini',
          name: 'Mac mini',
          driverId: 'macos_host',
          host: '192.168.1.10',
          port: 2222,
          settings: {'username': 'jade'},
        ),
      ) as SshExecutor;
      expect(
        (ssh.host, ssh.port, ssh.username, ssh.privateKeySecret),
        ('192.168.1.10', 2222, 'jade', 'device/mac_mini/sshPrivateKey'),
      );
    });

    test('SSH needs a username', () {
      expect(
        () => pick(
          const Device(
            id: 'x',
            name: 'x',
            driverId: 'macos_host',
            host: '10.0.0.2',
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('host key pinning', () {
    test(
      'pins on first use, accepts the same key, rejects a changed one',
      () async {
        final secrets = InMemorySecretStore();
        final pins = HostKeyPins(secrets);
        await pins.verify('mac', 22, 'ssh-ed25519', 'SHA256:aaa');
        expect(
          await secrets.read(HostKeyPins.keyFor('mac', 22)),
          'ssh-ed25519 SHA256:aaa',
        );
        await pins.verify('mac', 22, 'ssh-ed25519', 'SHA256:aaa');
        await expectLater(
          pins.verify('mac', 22, 'ssh-ed25519', 'SHA256:bbb'),
          throwsA(isA<HostKeyMismatchException>()),
        );
        await pins.clear('mac', 22);
        await pins.verify('mac', 22, 'ssh-ed25519', 'SHA256:bbb');
      },
    );

    test('pins are per host and port', () async {
      final pins = HostKeyPins(InMemorySecretStore());
      await pins.verify('mac', 22, 'ssh-ed25519', 'SHA256:aaa');
      await pins.verify('mac', 2222, 'ssh-ed25519', 'SHA256:bbb');
      await pins.verify('pi', 22, 'ssh-ed25519', 'SHA256:ccc');
    });
  });

  test('an unreachable SSH host is a transport timeout', () async {
    final secrets = InMemorySecretStore();
    await secrets.write('k', 'not a real key');
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final ssh = SshExecutor(
      host: '127.0.0.1',
      port: port,
      username: 'x',
      privateKeySecret: 'k',
      secrets: secrets,
    );
    await expectLater(
      ssh.run(['true']),
      throwsA(isA<TransportTimeoutException>()),
    );
  });

  test(
    'live: runs a command on a real Mac over SSH',
    () async {
      final env = Platform.environment;
      final secrets = InMemorySecretStore();
      await secrets.write('key', File(env['OMNI_SSH_KEY']!).readAsStringSync());
      final ssh = SshExecutor(
        host: env['OMNI_SSH_HOST']!,
        username: env['OMNI_SSH_USER']!,
        privateKeySecret: 'key',
        secrets: secrets,
      );
      final result = await ssh.run(['/usr/bin/printf', r'[%s]', 'a b; c']);
      expect(result.stdout, '[a b; c]');
    },
    tags: 'live',
    skip: Platform.environment['OMNI_SSH_HOST'] == null
        ? 'set OMNI_SSH_HOST, OMNI_SSH_USER, OMNI_SSH_KEY'
        : false,
  );
}
