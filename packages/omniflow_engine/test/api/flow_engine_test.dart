import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../support/v1_drivers.dart';

/// A loopback WiZ bulb that records every command.
Future<(UdpTransport, List<Map>)> fakeBulb() async {
  final received = <Map>[];
  final bulb = await UdpTransport.bind();
  bulb.incoming.listen((d) {
    final m = jsonDecode(d.text) as Map;
    received.add(m);
    bulb.send(
      d.address,
      d.port,
      utf8.encode(
        jsonEncode({
          'method': m['method'],
          'result': {'success': true},
        }),
      ),
    );
  });
  return (bulb, received);
}

Future<void> settle([int ms = 150]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Map<String, Object?> edge(String from, String port, String to) => {
  'id': '$from-$to',
  'from': {'node': from, 'port': port},
  'to': {'node': to, 'port': 'in'},
};

void main() {
  late Directory home;
  late OmniEngine engine;
  late UdpTransport bulb;
  late List<Map> bulbReceived;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_flows');
    engine = await OmniEngine.open(home: home, secrets: InMemorySecretStore());
    (bulb, bulbReceived) = await fakeBulb();
    await engine.handle('device.add', {
      'id': 'desk_lamp',
      'driver': 'philips_wiz_udp',
      'host': '127.0.0.1',
      'port': bulb.localPort,
    });
  });

  tearDown(() async {
    await engine.close();
    bulb.close();
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command: $result');
    return result;
  }

  Map<String, Object?> eveningFlow() => {
    'schemaVersion': 1,
    'id': 'evening_desk',
    'name': 'Evening desk',
    'cooldownSeconds': 1800,
    'nodes': [
      {
        'id': 'trig',
        'type': 'zone_change',
        'config': {'zoneId': 'desk', 'transition': 'entered'},
      },
      {
        'id': 'cond',
        'type': 'all_of',
        'config': {
          'rules': [
            {'type': 'time_window', 'start': '00:00', 'end': '00:00'},
            {
              'type': 'var_equals',
              'name': r'$HomeWifiConnected',
              'value': true,
            },
          ],
        },
      },
      {
        'id': 'lamp',
        'type': 'device_capability',
        'config': {
          'deviceId': 'desk_lamp',
          'capabilityId': 'color_temp',
          'params': {'value': 3000, 'brightness': 80},
        },
      },
    ],
    'edges': [edge('trig', 'out', 'cond'), edge('cond', 'true', 'lamp')],
  };

  test('walking up to the desk on home Wi-Fi runs the evening flow', () async {
    await ok('zone.save', {
      'zone': {
        'id': 'desk',
        'ble': {'matchName': 'OMNI_PICO_DESK'},
      },
    });
    await ok('flow.save', {'flow': eveningFlow()});
    await ok('var.set', {
      'name': 'HomeSsids',
      'value': ['HomeNet'],
    });
    await ok('sensor.wifi', {'ssid': 'HomeNet'});
    final start = DateTime(2026, 11, 6, 19);
    for (var i = 0; i < 16; i++) {
      await ok('sensor.ble', {
        'name': 'OMNI_PICO_DESK',
        'rssi': -50,
        'at': start.add(Duration(milliseconds: 250 * i)).toIso8601String(),
      });
    }
    await settle();
    expect(bulbReceived.single, {
      'id': 1,
      'method': 'setPilot',
      'params': {'state': true, 'temp': 3000, 'dimming': 80},
    });
    final log = await ok('flow.log', {'id': 'evening_desk'});
    expect(((log['runs'] as List).single as Map)['outcome'], 'completed');
    expect(
      ((await ok('var.list', {}))['variables'] as Map)['Zone_desk'],
      isTrue,
    );
  });

  test('a button press on the board, over UDP, fires a flow', () async {
    final board = await UdpTransport.bind();
    addTearDown(board.close);
    board.incoming.listen((d) {
      final cmd = jsonDecode(d.text) as Map;
      board.send(
        d.address,
        d.port,
        utf8.encode(
          jsonEncode({'node': 'pico', 'event': 'describe', 'id': cmd['id']}),
        ),
      );
      board.send(
        d.address,
        d.port,
        utf8.encode(
          jsonEncode({'node': 'pico', 'event': 'button_press', 'gpio': 14}),
        ),
      );
    });
    await ok('driver.register', {
      'manifest': jsonDecode(v1DriverSources['v1_board_udp.omni_driver.json']!),
    });
    await ok('device.add', {
      'id': 'pico',
      'driver': 'omniflow_mcu_node',
      'host': '127.0.0.1',
      'port': board.localPort,
    });
    await ok('flow.save', {
      'flow': {
        'schemaVersion': 1,
        'id': 'button_lamp',
        'name': 'Button toggles lamp',
        'nodes': [
          {
            'id': 'press',
            'type': 'board_event',
            'config': {'event': 'button_press', 'node': 'pico'},
          },
          {
            'id': 'lamp',
            'type': 'device_capability',
            'config': {
              'deviceId': 'desk_lamp',
              'capabilityId': 'power',
              'params': {'value': true},
            },
          },
        ],
        'edges': [edge('press', 'out', 'lamp')],
      },
    });
    await ok('device.refresh', {'id': 'pico'});
    await settle(300);
    expect(bulbReceived.map((m) => m['method']), ['setState']);
  });

  test(
    'a high-risk flow from an untrusted caller waits for approval',
    () async {
      await ok('device.add', {
        'id': 'mac_mini',
        'driver': 'macos_host',
        'host': 'local',
      });
      final flow = {
        'schemaVersion': 1,
        'id': 'wake_mac',
        'name': 'Wake the Mac',
        'nodes': [
          {'id': 'go', 'type': 'manual'},
          {
            'id': 'wake',
            'type': 'device_capability',
            'config': {'deviceId': 'mac_mini', 'capabilityId': 'display_wake'},
          },
        ],
        'edges': [edge('go', 'out', 'wake')],
      };
      final saved = await ok('flow.save', {'flow': flow, 'trusted': false});
      expect((saved['highRisk'], saved['approved']), (true, false));
      final listed =
          ((await ok('flow.list', {}))['flows'] as List).single as Map;
      expect((listed['approved'], listed['loaded']), (false, false));
      expect(
        (await engine.handle('flow.run', {'id': 'wake_mac'}))['ok'],
        isFalse,
      );
      await ok('flow.approve', {'id': 'wake_mac'});
      expect(
        (((await ok('flow.list', {}))['flows'] as List).single
            as Map)['loaded'],
        isTrue,
      );
    },
  );

  test(
    'validation errors come back from flow.save, and nothing is stored',
    () async {
      final bad = eveningFlow();
      (bad['nodes'] as List).add({'id': 'loose', 'type': 'manual'});
      (bad['nodes'] as List)[0] = {
        'id': 'trig',
        'type': 'zone_change',
        'config': {'zoneId': 'nowhere', 'transition': 'entered'},
      };
      final result = await engine.handle('flow.save', {'flow': bad});
      expect(result['ok'], isFalse);
      expect(
        ((result['error'] as Map)['issues'] as List).join(),
        contains('no zone nowhere'),
      );
      expect((await ok('flow.list', {}))['flows'], isEmpty);
    },
  );

  test('a dry run shows the commands and sends nothing', () async {
    await ok('zone.save', {
      'zone': {
        'id': 'desk',
        'ble': {'matchName': 'OMNI_PICO_DESK'},
      },
    });
    await ok('var.set', {'name': 'HomeWifiConnected', 'value': true});
    await ok('flow.save', {'flow': eveningFlow()});
    final result = await ok('flow.dryRun', {
      'id': 'evening_desk',
      'at': '2026-11-06T19:00:00',
    });
    final run = result['run'] as Map;
    expect(run['dryRun'], isTrue);
    final lamp = (run['nodes'] as List).cast<Map>().firstWhere(
      (n) => n['node'] == 'lamp',
    );
    expect(((lamp['output'] as Map)['result'] as Map)['params'], {
      'value': 3000,
      'brightness': 80,
    });
    await settle();
    expect(bulbReceived, isEmpty);
  });

  test('globals, flows and zones survive a restart', () async {
    await ok('zone.save', {
      'zone': {
        'id': 'desk',
        'ble': {'matchName': 'OMNI_PICO_DESK'},
      },
    });
    await ok('flow.save', {'flow': eveningFlow()});
    await ok('var.set', {'name': 'HomeMode', 'value': 'home'});
    await engine.close();
    engine = await OmniEngine.open(home: home, secrets: InMemorySecretStore());
    expect(
      ((await ok('var.list', {}))['variables'] as Map)['HomeMode'],
      'home',
    );
    expect(engine.flows.loadedFlows, ['evening_desk']);
    expect(
      ((await ok('zone.list', {}))['zones'] as List).single,
      containsPair('id', 'desk'),
    );
  });

  test('next time of day follows the local calendar', () {
    final now = DateTime(2026, 11, 6, 19, 30);
    expect(nextTimeOfDay(now, '07:00'), DateTime(2026, 11, 7, 7));
    expect(nextTimeOfDay(now, '20:00'), DateTime(2026, 11, 6, 20));
    expect(
      nextTimeOfDay(now, '07:00', days: ['mon']),
      DateTime(2026, 11, 9, 7),
    );
  });
}
