@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../support/virtual_board.dart';

/// The engine against the real firmware protocol core, built natively with
/// simulated pins, over loopback UDP (a board on Wi-Fi) and a
/// pseudo-terminal (a board on USB).
void main() {
  late Directory home;
  late OmniEngine engine;
  final boards = <VirtualBoard>[];

  setUpAll(() async {
    if (await VirtualBoard.build() == null) {
      markTestSkipped('no C++ compiler for the virtual board');
    }
  });

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_board');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      discoveryTargets: () async => [InternetAddress.loopbackIPv4],
    );
  });

  tearDown(() async {
    for (final b in boards) {
      await b.stop();
    }
    boards.clear();
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<VirtualBoard> board({
    String node = 'virtual_board',
    bool pty = false,
    int? udpPort,
    int? helloTo,
  }) async {
    final b = await VirtualBoard.start(
      node: node,
      pty: pty,
      udp: !pty,
      udpPort: udpPort,
      helloTo: helloTo,
    );
    boards.add(b);
    return b;
  }

  Future<Map<String, Object?>> ok(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command -> $result');
    return result;
  }

  /// Waits for the device's state to satisfy [test].
  Future<Map<String, Object?>> stateOf(
    String id,
    bool Function(Map<String, Object?> state) test,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final device =
          (await engine.handle('device.get', {'id': id}))['device'] as Map;
      final state = Map<String, Object?>.from(device['state'] as Map);
      if (test(state)) return state;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('state of $id never matched');
  }

  Future<void> sim(String id, int pin, int value) => engine.devices.sendCommand(
    id,
    {'cmd': 'sim.set', 'pin': pin, 'value': value},
  );

  const pins = {
    'relay': {'pin': 2, 'mode': 'out'},
    'fan': {'pin': 4, 'mode': 'pwm'},
    'button': {
      'pin': 3,
      'mode': 'in_pullup',
      'watch': {'ms': 10},
    },
    'knob': {
      'pin': 16,
      'mode': 'adc',
      'watch': {'ms': 20, 'delta': 2},
    },
  };

  test('a Wi-Fi board: add, drive outputs, and see inputs as state', () async {
    final b = await board(node: 'desk_board');
    final added = await ok('device.add', {
      'id': 'desk',
      'driver': 'omniflow_board',
      'host': '127.0.0.1',
      'port': b.udpPort,
      'settings': {'pins': pins},
    });
    final provisioned = added['provisioned'] as Map;
    expect(provisioned['board'], 'host');
    expect(provisioned['pins'], ['relay', 'fan', 'button', 'knob']);
    expect((added['device'] as Map)['stableId'], 'desk_board');
    // The simulated button pin reads 0 at start, which is pressed for in_pullup.
    expect((added['device'] as Map)['state'], containsPair('button', true));

    final caps =
        ((await ok('device.list', {'withCapabilities': true}))['devices']
                    as List)
                .single['capabilities']
            as List;
    expect({
      for (final c in caps) (c as Map)['id']: c['type'],
    }, containsPair('relay', 'toggle'));

    await ok('device.invoke', {
      'id': 'desk',
      'capability': 'relay',
      'params': {'value': true},
    });
    await ok('device.invoke', {
      'id': 'desk',
      'capability': 'fan',
      'params': {'value': 40},
    });
    final read = await engine.devices.sendCommand('desk', {
      'cmd': 'pin.read',
      'pin': 2,
    });
    expect(read.json?['value'], 1);

    await sim('desk', 3, 1);
    await stateOf('desk', (s) => s['button'] == false);
    await sim('desk', 16, 70);
    final state = await stateOf('desk', (s) => s['knob'] == 70);
    expect(state, containsPair('relay', true));
    expect(state, containsPair('fan', 40));
  });

  test('a pin the board does not have is refused with the reason', () async {
    final b = await board();
    final added = await ok('device.add', {
      'id': 'desk',
      'driver': 'omniflow_board',
      'host': '127.0.0.1',
      'port': b.udpPort,
      'settings': {
        'pins': {
          'relay': {'pin': 25, 'mode': 'out'},
        },
      },
    });
    expect(
      added['provisionError'],
      contains('pin 25 is not available on host'),
    );
    final changed = await engine.handle('board.pins', {
      'id': 'desk',
      'pins': {
        'level': {'pin': 3, 'mode': 'adc'},
      },
    });
    expect(changed['ok'], isFalse);
    expect('${changed['error']}', contains('cannot do adc'));
  });

  test('a USB board over a serial port works the same way', () async {
    final b = await board(node: 'usb_board', pty: true);
    final added = await ok('device.add', {
      'id': 'bench',
      'driver': 'omniflow_board',
      'host': b.tty,
      'settings': {'pins': pins},
    });
    expect((added['provisioned'] as Map)['board'], 'host');
    await ok('device.invoke', {
      'id': 'bench',
      'capability': 'relay',
      'params': {'value': true},
    });
    await sim('bench', 3, 1);
    await stateOf('bench', (s) => s['button'] == false && s['relay'] == true);
  });

  test('the hub finds new boards, follows a moved one and restores it after a reboot', () async {
    final helloPort = await VirtualBoard.freePort();
    await engine.startHub(wizListenPort: 0, boardHelloPort: helloPort);
    final found = engine.events.firstWhere((e) => e['event'] == 'board.found');
    final first = await board(node: 'hall_board', helloTo: helloPort);
    final hello = await found.timeout(const Duration(seconds: 5));
    expect(hello, containsPair('node', 'hall_board'));
    expect(hello, containsPair('port', first.udpPort));

    // Added with a stale port: the next hello corrects it.
    await ok('device.add', {
      'id': 'hall',
      'driver': 'omniflow_board',
      'host': '127.0.0.1',
      'port': 9,
      'stableId': 'hall_board',
      'provision': false,
      'settings': {'pins': pins},
    });
    await stateOf('hall', (s) => s.containsKey('button'));
    await ok('device.invoke', {
      'id': 'hall',
      'capability': 'relay',
      'params': {'value': true},
    });

    // Reboot: the same board comes back with every pin unset.
    final port = first.udpPort;
    await first.stop();
    boards.remove(first);
    await board(node: 'hall_board', udpPort: port, helloTo: helloPort);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    Object? relay;
    while (DateTime.now().isBefore(deadline)) {
      try {
        relay = (await engine.devices.sendCommand('hall', {
          'cmd': 'pin.read',
          'pin': 2,
        })).json?['value'];
      } on CommandFailedException {
        relay = null; // not set up again yet
      }
      if (relay == 1) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(relay, 1, reason: 'the relay is switched back on after the reboot');
  });

  test('discovery finds a board on Wi-Fi by its describe reply', () async {
    final b = await board(node: 'shed_board');
    final result = await ok('device.discover', {
      'driver': 'omniflow_board',
      'port': b.udpPort,
      'serial': false,
      'windowMs': 400,
    });
    final found = (result['found'] as List).cast<Map>();
    expect(found.map((f) => f['stableId']), contains('shed_board'));
  });

  test('the Wi-Fi password never reaches the packet inspector', () async {
    final b = await board(node: 'fresh', pty: true);
    final tap = PacketTap();
    final captured = <String>[];
    tap.stream.listen((p) => captured.add(p.text));
    final tapped = await OmniEngine.open(
      home: await Directory.systemTemp.createTemp('omni_tap'),
      secrets: InMemorySecretStore(),
      tap: tap,
    );
    addTearDown(tapped.close);
    final result = await tapped.handle('board.setup', {
      'port': b.tty,
      'ssid': 'HomeNet',
      'password': 'hunter2-secret',
    });
    expect(result['ok'], isTrue, reason: '$result');
    expect(captured.join(), contains('wifi.set'));
    expect(captured.join(), isNot(contains('hunter2-secret')));
  });

  test(
    'links connect a button, a knob and a threshold across two boards',
    () async {
      final desk = await board(node: 'desk_board');
      final lamp = await board(node: 'lamp_board');
      await ok('device.add', {
        'id': 'desk',
        'driver': 'omniflow_board',
        'host': '127.0.0.1',
        'port': desk.udpPort,
        'settings': {
          'pins': {
            'button': {
              'pin': 3,
              'mode': 'in_pullup',
              'watch': {'ms': 10},
            },
            'knob': {
              'pin': 16,
              'mode': 'adc',
              'watch': {'ms': 10, 'delta': 0},
            },
          },
        },
      });
      await sim('desk', 3, 1); // released
      await stateOf('desk', (s) => s['button'] == false);
      await ok('device.add', {
        'id': 'lamp',
        'driver': 'omniflow_board',
        'host': '127.0.0.1',
        'port': lamp.udpPort,
        'settings': {
          'pins': {
            'relay': {'pin': 2, 'mode': 'out'},
            'arm': {'pin': 5, 'mode': 'servo'},
          },
        },
      });
      Future<Object?> pinOnLamp(int pin) async =>
          (await engine.devices.sendCommand('lamp', {
            'cmd': 'pin.read',
            'pin': pin,
          })).json?['value'];

      final toggle = await ok('link.create', {
        'from': 'desk.button',
        'to': 'lamp.relay',
        'mode': 'toggle',
      });
      expect(toggle['name'], 'desk.button toggles lamp.relay');
      await ok('link.create', {
        'from': 'desk.knob',
        'to': 'lamp.arm',
        'mode': 'follow',
      });
      await ok('link.create', {
        'from': 'desk.knob',
        'to': 'lamp.relay',
        'mode': 'threshold',
        'below': 20,
        'set': false,
      });
      expect((await ok('link.list', {}))['links'] as List, hasLength(3));

      // Press and release twice: on, then off.
      await sim('desk', 3, 0);
      await stateOf('lamp', (s) => s['relay'] == true);
      expect(await pinOnLamp(2), 1);
      await sim('desk', 3, 1);
      await stateOf('desk', (s) => s['button'] == false);
      await sim('desk', 3, 0);
      await stateOf('lamp', (s) => s['relay'] == false);
      expect(await pinOnLamp(2), 0);
      await sim('desk', 3, 1);

      // The knob at 50% puts the servo at 90 degrees.
      await sim('desk', 16, 50);
      await stateOf('lamp', (s) => s['arm'] == 90);
      expect(await pinOnLamp(5), 90);

      // Relay on, then the knob drops below 20: the threshold turns it off.
      await ok('device.invoke', {
        'id': 'lamp',
        'capability': 'relay',
        'params': {'value': true},
      });
      await sim('desk', 16, 10);
      await stateOf('lamp', (s) => s['relay'] == false);
      expect(await pinOnLamp(2), 0);

      final bad = await engine.handle('link.create', {
        'from': 'desk.knob',
        'to': 'lamp.arm',
        'mode': 'toggle',
      });
      expect(
        '${bad['error']}',
        contains('only an on/off toggle can be toggled'),
      );
      final unknown = await engine.handle('link.create', {
        'from': 'desk.door',
        'to': 'lamp.relay',
        'mode': 'toggle',
      });
      expect(
        '${unknown['error']}',
        contains('desk has no state door (it has button, knob)'),
      );
    },
  );
}
