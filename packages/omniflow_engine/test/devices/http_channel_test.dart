import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// A loopback Shelly Gen2 switch: Switch.Set and Switch.GetStatus over GET.
class FakeShelly {
  FakeShelly._(this._server) {
    _server.listen((req) async {
      requests.add(req.uri);
      final res = req.response..headers.contentType = ContentType.json;
      if (failWith != null) {
        res.statusCode = failWith!;
        res.write('{"code":-103,"message":"boom"}');
      } else if (req.uri.path == '/rpc/Switch.Set') {
        final wasOn = output;
        output = req.uri.queryParameters['on'] == 'true';
        res.write(jsonEncode({'was_on': wasOn}));
      } else if (req.uri.path == '/rpc/Switch.GetStatus') {
        res.write(
          jsonEncode({
            'id': 0,
            'source': 'http',
            'output': output,
            'apower': 12.5,
          }),
        );
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
  }

  static Future<FakeShelly> start() async =>
      FakeShelly._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final requests = <Uri>[];
  bool output = false;
  int? failWith;

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}

class RecordingExecutor implements HostExecutor {
  final calls = <List<String>>[];

  @override
  Future<CommandResult> run(
    List<String> argv, {
    String? stdin,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(argv);
    return const CommandResult(
      exitCode: 0,
      stdout: '',
      stderr: '',
      duration: Duration.zero,
    );
  }
}

void main() {
  group('Shelly over the HTTP channel', () {
    late FakeShelly shelly;
    late InMemoryDeviceStore store;
    late DeviceService service;

    setUp(() async {
      shelly = await FakeShelly.start();
      store = InMemoryDeviceStore();
      service = DeviceService(
        registry: DriverRegistry.withBuiltIns(),
        store: store,
        channels: {TransportType.http: HttpChannel()},
      );
      await store.put(
        Device(
          id: 'heater',
          name: 'Heater',
          driverId: 'shelly_plus_switch',
          host: '127.0.0.1',
          port: shelly.port,
        ),
      );
    });
    tearDown(() => shelly.close());

    test('power on calls Switch.Set and records the output', () async {
      final result = await service.invoke('heater', 'power', {'value': true});
      expect(shelly.requests.single.toString(), '/rpc/Switch.Set?id=0&on=true');
      expect(result.reply.json, {'was_on': false});
      expect(result.device.state, {'output': true});
    });

    test('refresh reads Switch.GetStatus', () async {
      shelly.output = true;
      final device = await service.refreshState('heater');
      expect(device.state, containsPair('apower', 12.5));
      expect(device.state['output'], isTrue);
    });

    test('an HTTP error status fails the command', () async {
      shelly.failWith = 500;
      await expectLater(
        service.invoke('heater', 'power', {'value': true}),
        throwsA(isA<CommandFailedException>()),
      );
    });

    test(
      'a device that never answers is a transport timeout after the retry',
      () async {
        final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final held = <Socket>[];
        silent.listen(held.add);
        addTearDown(() async {
          for (final s in held) {
            s.destroy();
          }
          await silent.close();
        });
        await store.put(
          (await store.get('heater'))!.copyWith(host: '127.0.0.1'),
        );
        await store.put(
          Device(
            id: 'mute',
            name: 'Mute',
            driverId: 'shelly_plus_switch',
            host: '127.0.0.1',
            port: silent.port,
          ),
        );
        await expectLater(
          service.invoke('mute', 'power', {'value': true}),
          throwsA(isA<TransportTimeoutException>()),
        );
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  });

  group('linux_host over the exec channel', () {
    late RecordingExecutor executor;
    late DeviceService service;

    setUp(() async {
      executor = RecordingExecutor();
      final store = InMemoryDeviceStore();
      service = DeviceService(
        registry: DriverRegistry.withBuiltIns(),
        store: store,
        channels: {TransportType.exec: ExecChannel((_) => executor)},
      );
      await store.put(
        const Device(
          id: 'pi',
          name: 'Pi',
          driverId: 'linux_host',
          host: '192.168.1.30',
          settings: {'username': 'pi'},
        ),
      );
    });

    test('restarts a service with non-interactive sudo', () async {
      await service.invoke('pi', 'service_restart', {
        'value': 'zigbee2mqtt.service',
      });
      expect(executor.calls.single, [
        'sudo',
        '-n',
        'systemctl',
        'restart',
        'zigbee2mqtt.service',
      ]);
    });

    test('a service name with shell characters is rejected', () async {
      await expectLater(
        service.invoke('pi', 'service_restart', {'value': 'x; reboot'}),
        throwsA(isA<ValidationException>()),
      );
      expect(executor.calls, isEmpty);
    });
  });
}
