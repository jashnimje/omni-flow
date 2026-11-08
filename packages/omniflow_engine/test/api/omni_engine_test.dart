import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// An emulated WiZ bulb on loopback that answers every request with success.
Future<UdpTransport> fakeBulb(List<Map> received) async {
  final bulb = await UdpTransport.bind();
  bulb.incoming.listen((d) {
    final request = jsonDecode(d.text) as Map;
    received.add(request);
    bulb.send(
      d.address,
      d.port,
      utf8.encode(
        jsonEncode({
          'method': request['method'],
          'result': {'success': true},
        }),
      ),
    );
  });
  return bulb;
}

void main() {
  late Directory home;
  late InMemorySecretStore secrets;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_home');
    secrets = InMemorySecretStore();
  });
  tearDown(() => home.delete(recursive: true));

  Future<OmniEngine> open() => OmniEngine.open(home: home, secrets: secrets);

  group('core API', () {
    test('lists the built-in drivers', () async {
      final engine = await open();
      addTearDown(engine.close);
      final result = await engine.handle('driver.list', {});
      final ids = (result['drivers'] as List).map((d) => (d as Map)['id']);
      expect(result['ok'], isTrue);
      expect(
        ids,
        containsAll([
          'philips_wiz_udp',
          'tuya_plug',
          'macos_host',
          'omniflow_board',
        ]),
      );
    });

    test(
      'an unknown command and missing args come back as error results',
      () async {
        final engine = await open();
        addTearDown(engine.close);
        expect(await engine.handle('device.fly', {}), {
          'ok': false,
          'error': {
            'type': 'unknown_command',
            'message': 'no command device.fly',
          },
        });
        final missing = await engine.handle('device.invoke', {'id': 'x'});
        expect((missing['error'] as Map)['type'], 'invalid');
      },
    );

    test('a secret can never be stored as a device setting', () async {
      final engine = await open();
      addTearDown(engine.close);
      final result = await engine.handle('device.add', {
        'id': 'plug',
        'driver': 'tuya_plug',
        'host': '10.0.0.8',
        'settings': {'devId': 'bf00', 'localKey': '0123456789abcdef'},
      });
      expect(result['ok'], isFalse);
      expect(
        ((result['error'] as Map)['message'] as String),
        contains('is a secret'),
      );
    });

    test('adding a device reports secrets still to set, and secret.set stores them in the secret store', () async {
      final engine = await open();
      addTearDown(engine.close);
      final added = await engine.handle('device.add', {
        'id': 'plug',
        'driver': 'tuya_plug',
        'host': '10.0.0.8',
        'settings': {'devId': 'bf00'},
      });
      expect(added['missingSecrets'], ['localKey']);
      final stored = await engine.handle('secret.set', {
        'deviceId': 'plug',
        'key': 'localKey',
        'value': 'k' * 16,
      });
      expect(stored['ok'], isTrue);
      expect(await secrets.read('device/plug/localKey'), 'k' * 16);
      final wrong = await engine.handle('secret.set', {
        'deviceId': 'plug',
        'key': 'devId',
        'value': 'x',
      });
      expect(wrong['ok'], isFalse);
    });

    test('invalid params come back with every issue', () async {
      final engine = await open();
      addTearDown(engine.close);
      await engine.handle('device.add', {
        'id': 'lamp',
        'driver': 'philips_wiz_udp',
        'host': '10.0.0.5',
      });
      final result = await engine.handle('device.invoke', {
        'id': 'lamp',
        'capability': 'color_temp',
        'params': {'value': 9000, 'colour': 'red'},
      });
      expect((result['error'] as Map)['type'], 'invalid');
      expect(((result['error'] as Map)['issues'] as List), hasLength(2));
    });

    test('devices and user drivers survive a restart, and a second engine is refused', () async {
      var engine = await open();
      await engine.handle('device.add', {
        'id': 'lamp',
        'driver': 'philips_wiz_udp',
        'host': '10.0.0.5',
      });
      await engine.handle('driver.register', {
        'manifest': {
          'schemaVersion': 1,
          'id': 'my_gadget',
          'name': 'Gadget',
          'category': 'misc',
          'transport': {'type': 'http'},
          'capabilities': [
            {
              'id': 'ping',
              'type': 'action',
              'command': {'path': '/ping'},
            },
          ],
        },
      });
      await expectLater(open(), throwsA(isA<DatabaseInUseException>()));
      await engine.close();
      engine = await open();
      addTearDown(engine.close);
      expect(
        ((await engine.handle('device.list', {}))['devices'] as List).single,
        containsPair('id', 'lamp'),
      );
      expect(engine.registry['my_gadget'], isNotNull);
    });
  });

  group('omni CLI', () {
    Future<(int, String)> omni(
      List<String> args, {
      String stdinText = '',
    }) async {
      final out = StringBuffer();
      final code = await OmniCommandRunner(
        out: out,
        input: Stream.value(utf8.encode(stdinText)),
        engineFactory: (h, {tap}) =>
            OmniEngine.open(home: h, secrets: secrets, tap: tap),
      ).run(['--home', home.path, ...args]);
      return (code, out.toString());
    }

    test('add, invoke and list a WiZ bulb end to end', () async {
      final received = <Map>[];
      final bulb = await fakeBulb(received);
      addTearDown(bulb.close);

      final (addCode, _) = await omni([
        'device', 'add', 'desk_lamp', '--driver', 'philips_wiz_udp', //
        '--host',
        '127.0.0.1',
        '--port',
        '${bulb.localPort}',
        '--name',
        'Desk lamp',
      ]);
      expect(addCode, 0);

      final (invokeCode, invokeOut) = await omni([
        'device',
        'invoke',
        'desk_lamp',
        'color_temp',
        'value=3000',
        'brightness=80',
      ]);
      expect(invokeCode, 0, reason: invokeOut);
      expect(received.single, {
        'id': 1,
        'method': 'setPilot',
        'params': {'state': true, 'temp': 3000, 'dimming': 80},
      });

      final (_, listOut) = await omni(['device', 'list']);
      final device =
          ((jsonDecode(listOut) as Map)['devices'] as List).single as Map;
      expect(device['state'], {'temp': 3000});
    });

    test(
      'watch registers with WiZ bulbs and prints their pushed state',
      () async {
        final bulb = await UdpTransport.bind();
        addTearDown(bulb.close);
        bulb.incoming.listen((d) {
          final m = jsonDecode(d.text) as Map;
          if (m['method'] != 'registration') return;
          bulb.send(
            d.address,
            d.port,
            utf8.encode(
              jsonEncode({
                'method': 'syncPilot',
                'params': {'mac': 'a8bb50aabbcc', 'state': true, 'dimming': 42},
              }),
            ),
          );
        });
        await omni([
          'device', 'add', 'desk_lamp', '--driver', 'philips_wiz_udp', //
          '--host',
          '127.0.0.1',
          '--port',
          '${bulb.localPort}',
          '--stable-id',
          'A8BB50AABBCC',
        ]);
        final (code, out) = await omni([
          'watch',
          '--seconds',
          '0.6',
          '--wiz-port',
          '0',
          '--packets',
        ]);
        expect(code, 0, reason: out);
        final events = [
          for (final line in const LineSplitter().convert(out))
            jsonDecode(line) as Map,
        ];
        expect(events.first, {'event': 'watch.started', 'wizBulbs': 1});
        final changed = events.firstWhere(
          (e) => e['event'] == 'device.stateChanged',
        );
        expect(
          (changed['device'] as Map)['state'],
          containsPair('dimming', 42),
        );
        expect(
          events.where((e) => e['event'] == 'packet.captured'),
          isNotEmpty,
        );
      },
    );

    test('a failing command exits 1 and prints the error', () async {
      final (code, out) = await omni(['device', 'get', 'nothing']);
      expect(code, 1);
      expect((jsonDecode(out) as Map)['error'], {
        'type': 'not_found',
        'message': 'no device nothing',
      });
    });

    test('secret set reads the value from stdin, not argv', () async {
      await omni([
        'device',
        'add',
        'plug',
        '--driver',
        'tuya_plug',
        '--host',
        '10.0.0.8',
        '--set',
        'devId=bf00',
      ]);
      final (code, _) = await omni([
        'secret',
        'set',
        'plug',
        'localKey',
      ], stdinText: '0123456789abcdef\n');
      expect(code, 0);
      expect(await secrets.read('device/plug/localKey'), '0123456789abcdef');
    });

    test('driver validate reports the issues in a file', () async {
      final file = File('${home.path}/bad.omni_driver.json')
        ..writeAsStringSync('{"schemaVersion": 1, "id": "x"}');
      final (code, out) = await omni(['driver', 'validate', file.path]);
      expect(code, 1);
      expect(((jsonDecode(out) as Map)['error'] as Map)['issues'], isNotEmpty);
    });

    test('key=value keeps JSON types and leaves text as text', () {
      expect(
        parseKeyValues([
          'value=80',
          'on=true',
          'hex=0x20DF10EF',
          'name=Focus mode',
        ]),
        {'value': 80, 'on': true, 'hex': '0x20DF10EF', 'name': 'Focus mode'},
      );
      expect(() => parseKeyValues(['novalue']), throwsA(isA<UsageException>()));
    });
  });
}
