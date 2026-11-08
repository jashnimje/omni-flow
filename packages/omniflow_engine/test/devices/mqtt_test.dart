import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../support/mini_broker.dart';

/// Tasmota, Zigbee2MQTT and a plain MQTT sensor behind one broker, with the
/// devices played by the test: it answers commands the way the firmware does.
void main() {
  late MiniBroker broker;
  late Directory home;
  late OmniEngine engine;
  final commands = <(String, String)>[];

  setUp(() async {
    broker = await MiniBroker.start(username: 'omni', password: 'broker-pw');
    commands.clear();
    broker.published.listen((m) {
      commands.add(m);
      final (topic, payload) = m;
      // Tasmota answers a POWER command on stat/<topic>/RESULT.
      if (topic == 'cmnd/desk_plug/POWER') {
        final on = payload.toUpperCase() == 'ON';
        broker.inject(
          'stat/desk_plug/RESULT',
          jsonEncode({'POWER': on ? 'ON' : 'OFF'}),
        );
      }
    });
    home = await Directory.systemTemp.createTemp('omni_mqtt');
    engine = await OmniEngine.open(home: home, secrets: InMemorySecretStore());
  });

  tearDown(() async {
    await engine.close();
    await broker.close();
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command -> $result');
    return result;
  }

  Future<void> add(
    String id,
    String driver,
    Map<String, Object?> settings,
  ) async {
    await ok('device.add', {
      'id': id,
      'driver': driver,
      'host': '127.0.0.1',
      'port': broker.port,
      'settings': {...settings, 'username': 'omni'},
    });
    await ok('secret.set', {
      'deviceId': id,
      'key': 'password',
      'value': 'broker-pw',
    });
  }

  Future<Map<String, Object?>> stateOf(
    String id,
    bool Function(Map<String, Object?>) test,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final d =
          (await engine.handle('device.get', {'id': id}))['device'] as Map;
      final state = Map<String, Object?>.from(d['state'] as Map);
      if (test(state)) return state;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    fail('state of $id never matched');
  }

  Future<void> sawCommand(String topic, String payload) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!commands.contains((topic, payload))) {
      if (DateTime.now().isAfter(deadline)) {
        fail('no $payload on $topic, got $commands');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('Tasmota: commands go out as ON and OFF, and its replies become true and false', () async {
    await add('desk_plug', 'tasmota_mqtt', {'topic': 'desk_plug'});
    await engine.startHub(wizListenPort: 0, boardHelloPort: 0);
    await sawCommand('cmnd/desk_plug/STATE', '');

    await ok('device.invoke', {
      'id': 'desk_plug',
      'capability': 'power',
      'params': {'value': true},
    });
    await sawCommand('cmnd/desk_plug/POWER', 'ON');
    await stateOf('desk_plug', (s) => s['POWER'] == true);

    // Switched by its own button: Tasmota publishes the new state.
    broker.inject('stat/desk_plug/POWER', 'OFF');
    await stateOf('desk_plug', (s) => s['POWER'] == false);
    broker.inject(
      'tele/desk_plug/STATE',
      jsonEncode({'POWER': 'ON', 'Dimmer': 40}),
    );
    await stateOf('desk_plug', (s) => s['POWER'] == true && s['Dimmer'] == 40);
  });

  test(
    'Zigbee2MQTT: a JSON set payload, and sensor state from the device topic',
    () async {
      await add('hall_light', 'zigbee2mqtt_device', {
        'friendlyName': 'hall_light',
      });
      await engine.startHub(wizListenPort: 0, boardHelloPort: 0);
      await sawCommand('zigbee2mqtt/hall_light/get', '{"state":""}');
      await ok('device.invoke', {
        'id': 'hall_light',
        'capability': 'power',
        'params': {'value': false},
      });
      await sawCommand('zigbee2mqtt/hall_light/set', '{"state":"OFF"}');
      broker.inject(
        'zigbee2mqtt/hall_light',
        jsonEncode({'state': 'ON', 'brightness': 120, 'temperature': 21.5}),
      );
      final state = await stateOf('hall_light', (s) => s['state'] == true);
      expect(state['brightness'], 120);
      expect(state['temperature'], 21.5);
    },
  );

  test('a link connects an MQTT sensor to a Tasmota plug', () async {
    await add('desk_plug', 'tasmota_mqtt', {'topic': 'desk_plug'});
    await add('room_temp', 'mqtt_sensor', {
      'stateTopic': 'home/room/temperature',
    });
    await engine.startHub(wizListenPort: 0, boardHelloPort: 0);
    await sawCommand('cmnd/desk_plug/STATE', '');
    broker.inject('home/room/temperature', '24');
    await stateOf('room_temp', (s) => s['value'] == 24);
    await ok('link.create', {
      'from': 'room_temp.value',
      'to': 'desk_plug.power',
      'mode': 'threshold',
      'above': 28,
      'set': true,
    });
    broker.inject('home/room/temperature', '29.5');
    await sawCommand('cmnd/desk_plug/POWER', 'ON');
    await stateOf('desk_plug', (s) => s['POWER'] == true);
  });

  test('a wrong broker password is an error, not a hang', () async {
    await ok('device.add', {
      'id': 'desk_plug',
      'driver': 'tasmota_mqtt',
      'host': '127.0.0.1',
      'port': broker.port,
      'settings': {'topic': 'desk_plug', 'username': 'omni'},
    });
    await ok('secret.set', {
      'deviceId': 'desk_plug',
      'key': 'password',
      'value': 'wrong',
    });
    final result = await engine
        .handle('device.invoke', {
          'id': 'desk_plug',
          'capability': 'power',
          'params': {'value': true},
        })
        .timeout(const Duration(seconds: 10));
    expect(result['ok'], isFalse);
    expect('${result['error']}', contains('refused'));
  });
}
