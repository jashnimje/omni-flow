import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late InMemorySecretStore secrets;
  late UdpTransport bulb;
  final received = <Map>[];

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_cli');
    secrets = InMemorySecretStore();
    received.clear();
    bulb = await UdpTransport.bind();
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
  });

  tearDown(() async {
    bulb.close();
    await home.delete(recursive: true);
  });

  Future<(int, String)> omni(List<String> args) async {
    final out = StringBuffer();
    final code = await OmniCommandRunner(
      out: out,
      input: const Stream.empty(),
      engineFactory: (h, {tap}) =>
          OmniEngine.open(home: h, secrets: secrets, tap: tap),
    ).run(['--home', home.path, ...args]);
    return (code, out.toString());
  }

  Future<Map> ok(List<String> args) async {
    final (code, out) = await omni(args);
    expect(code, 0, reason: out);
    return jsonDecode(out) as Map;
  }

  test('save, list, run, dry-run and log a flow from the CLI', () async {
    await ok([
      'device',
      'add',
      'desk_lamp',
      '--driver',
      'philips_wiz_udp',
      '--host',
      '127.0.0.1',
      '--port',
      '${bulb.localPort}',
    ]);
    final file = File('${home.path}/dim.flow.json')
      ..writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'id': 'dim_lamp',
          'name': 'Dim the lamp',
          'nodes': [
            {'id': 'go', 'type': 'manual'},
            {
              'id': 'scale',
              'type': 'range_map',
              'config': {
                'inMin': 0,
                'inMax': 100,
                'outMin': 10,
                'outMax': 100,
                'source': 'payload.knob',
              },
            },
            {
              'id': 'lamp',
              'type': 'device_capability',
              'config': {
                'deviceId': 'desk_lamp',
                'capabilityId': 'brightness',
                'params': {'value': '{{msg.value}}'},
              },
            },
          ],
          'edges': [
            {
              'id': 'a',
              'from': {'node': 'go', 'port': 'out'},
              'to': {'node': 'scale', 'port': 'in'},
            },
            {
              'id': 'b',
              'from': {'node': 'scale', 'port': 'out'},
              'to': {'node': 'lamp', 'port': 'in'},
            },
          ],
        }),
      );
    expect((await ok(['flow', 'validate', file.path]))['highRisk'], isFalse);
    await ok(['flow', 'save', file.path]);
    expect(
      ((await ok(['flow', 'list']))['flows'] as List).single,
      containsPair('loaded', true),
    );

    final run = await ok(['flow', 'run', 'dim_lamp', 'knob=50']);
    expect(((run['runs'] as List).single as Map)['outcome'], 'completed');
    expect(received.single['params'], {'state': true, 'dimming': 55});

    final dry = await ok(['flow', 'dry-run', 'dim_lamp', 'knob=100']);
    final lamp = ((dry['run'] as Map)['nodes'] as List).cast<Map>().firstWhere(
      (n) => n['node'] == 'lamp',
    );
    expect(((lamp['output'] as Map)['result'] as Map)['params'], {
      'value': 100,
    });
    expect(received, hasLength(1));

    final log = await ok(['flow', 'log', 'dim_lamp']);
    expect((log['runs'] as List), hasLength(1));
  });

  test('var set keeps JSON types, and zones round-trip', () async {
    await ok(['var', 'set', 'HomeSsids', '["HomeNet"]']);
    await ok(['var', 'set', 'Mode', 'away']);
    expect((await ok(['var', 'list']))['variables'], {
      'HomeSsids': ['HomeNet'],
      'Mode': 'away',
    });
    final zone = File('${home.path}/desk.zone.json')
      ..writeAsStringSync('{"id":"desk","ble":{"matchName":"OMNI_PICO_DESK"}}');
    await ok(['zone', 'save', zone.path]);
    await ok(['sensor', 'wifi', 'HomeNet']);
    expect(
      (await ok(['var', 'list']))['variables'],
      containsPair('HomeWifiConnected', true),
    );
    expect(
      ((await ok(['zone', 'list']))['zones'] as List).single,
      containsPair('inside', false),
    );
  });

  test('a disabled flow is not loaded and cannot be run', () async {
    final file = File('${home.path}/f.json')
      ..writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'id': 'noop',
          'name': 'Noop',
          'nodes': [
            {'id': 'go', 'type': 'manual'},
            {
              'id': 'say',
              'type': 'notify',
              'config': {'title': 'hi'},
            },
          ],
          'edges': [
            {
              'id': 'a',
              'from': {'node': 'go', 'port': 'out'},
              'to': {'node': 'say', 'port': 'in'},
            },
          ],
        }),
      );
    await ok(['flow', 'save', file.path]);
    await ok(['flow', 'disable', 'noop']);
    expect(
      ((await ok(['flow', 'list']))['flows'] as List).single,
      containsPair('loaded', false),
    );
    final (code, out) = await omni(['flow', 'run', 'noop']);
    expect(code, 1);
    expect(((jsonDecode(out) as Map)['error'] as Map)['type'], 'not_ready');
  });

  test('the hub starts, reports its flows, and stops', () async {
    final (code, out) = await omni([
      'hub',
      '--seconds',
      '0.3',
      '--wiz-port',
      '0',
      '--hello-port',
      '0',
    ]);
    expect(code, 0, reason: out);
    final first = jsonDecode(const LineSplitter().convert(out).first) as Map;
    expect(first, {
      'event': 'hub.started',
      'flows': [],
      'socket': '${home.absolute.path}/omni.sock',
    });
    expect(
      FileSystemEntity.typeSync('${home.path}/omni.sock'),
      FileSystemEntityType.notFound,
    );
  });
}
