import 'dart:async';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../support/mini_broker.dart';

/// The MQTT channel on its own, against brokers the test starts and stops.
void main() {
  final manifest = DriverRegistry.withBuiltIns()['mqtt_switch']!;
  late InMemorySecretStore secrets;
  late MqttChannel channel;
  final brokers = <MiniBroker>[];

  Device lamp(String id, int port) => Device(
    id: id,
    name: id,
    driverId: 'mqtt_switch',
    host: '127.0.0.1',
    port: port,
    settings: const {
      'commandTopic': 'lamp/set',
      'stateTopic': 'lamp/state',
      'username': 'omni',
    },
  );

  Future<MiniBroker> broker({int port = 0, String password = 'pw'}) async {
    final b = await MiniBroker.start(
      username: 'omni',
      password: password,
      port: port,
    );
    brokers.add(b);
    return b;
  }

  Future<ChannelReply> power(Device device, bool on) => channel.send(
    ChannelRequest(
      device: device,
      manifest: manifest,
      command: manifest.capability('power')!.command,
      context: TemplateContext(
        params: {'value': on ? 'ON' : 'OFF'},
        device: device.settings,
      ),
    ),
  );

  Future<int> freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  setUp(() async {
    secrets = InMemorySecretStore();
    channel = MqttChannel(secrets);
  });

  tearDown(() async {
    await channel.close();
    for (final b in brokers) {
      await b.close();
    }
    brokers.clear();
  });

  test('a watch made while the broker is down starts once it is up', () async {
    final port = await freePort();
    final device = lamp('lamp', port);
    await secrets.write(deviceSecretKey('lamp', 'password'), 'pw');
    await expectLater(
      channel.watch(device, manifest),
      throwsA(isA<TransportTimeoutException>()),
    );

    final b = await broker(port: port);
    final state = channel.events.first;
    await power(device, true);
    b.inject('lamp/state', 'ON', retain: true);
    final message = await state.timeout(const Duration(seconds: 5));
    expect(message.deviceId, 'lamp');
    expect(message.state, {'state': 'ON'});
  });

  test('the same topic on two brokers reaches only its own device', () async {
    final first = await broker();
    final second = await broker();
    final a = lamp('a', first.port);
    final b = lamp('b', second.port);
    for (final id in ['a', 'b']) {
      await secrets.write(deviceSecretKey(id, 'password'), 'pw');
    }
    await channel.watch(a, manifest);
    await channel.watch(b, manifest);
    final seen = <String>[];
    channel.events.listen((m) => seen.add('${m.deviceId} ${m.state['state']}'));

    first.inject('lamp/state', 'ON', retain: true);
    second.inject('lamp/state', 'OFF', retain: true);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (seen.length < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(seen..sort(), ['a ON', 'b OFF']);
  });

  test('resetBroker reconnects with the password set since', () async {
    final port = await freePort();
    final old = await broker(port: port, password: 'one');
    final device = lamp('lamp', port);
    await secrets.write(deviceSecretKey('lamp', 'password'), 'one');
    final first = old.published.first;
    await power(device, true);
    expect(await first.timeout(const Duration(seconds: 5)), ('lamp/set', 'ON'));

    await old.close();
    brokers.remove(old);
    final rotated = await broker(port: port, password: 'two');
    await secrets.write(deviceSecretKey('lamp', 'password'), 'two');
    await channel.resetBroker(device, manifest);
    final second = rotated.published.first;
    await power(device, false);
    expect(await second.timeout(const Duration(seconds: 5)), (
      'lamp/set',
      'OFF',
    ));
  });
}
