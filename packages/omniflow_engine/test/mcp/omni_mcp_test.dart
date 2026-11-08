import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

Map<String, Object?> body(CallToolResult r) =>
    jsonDecode((r.content.single as TextContent).text) as Map<String, Object?>;

void main() {
  late Directory home;
  late OmniEngine engine;
  late McpClient client;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_mcp');
    engine = await OmniEngine.open(home: home, secrets: InMemorySecretStore());
    await engine.handle('device.add', {
      'id': 'desk_lamp',
      'driver': 'philips_wiz_udp',
      'host': '127.0.0.1',
      'room': 'Study',
    });
    await engine.handle('device.add', {
      'id': 'mac_mini',
      'driver': 'macos_host',
      'host': 'local',
    });
    final toServer = StreamController<List<int>>();
    final toClient = StreamController<List<int>>();
    await createOmniMcpServer(
      engine,
    ).connect(IOStreamTransport(stream: toServer.stream, sink: toClient.sink));
    client = McpClient(
      const Implementation(name: 'test', version: '1'),
      options: const McpClientOptions(capabilities: ClientCapabilities()),
    );
    await client.connect(
      IOStreamTransport(stream: toClient.stream, sink: toServer.sink),
    );
  });

  tearDown(() async {
    await client.close();
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<CallToolResult> call(
    String name, [
    Map<String, dynamic> args = const {},
  ]) => client.callTool(CallToolRequest(name: name, arguments: args));

  test('lists the ten tools', () async {
    final tools = (await client.listTools()).tools.map((t) => t.name).toSet();
    expect(tools, {
      'discover_devices_and_capabilities',
      'invoke_device_capability',
      'register_custom_driver_manifest',
      'deploy_automation_flow_dag',
      'list_flows',
      'simulate_flow_dry_run',
      'sniff_live_packets',
      'generate_mcu_firmware',
      'link_devices',
      'configure_board_pins',
    });
  });

  test(
    'discovery shows capabilities with their params, filtered by room',
    () async {
      final result = await call('discover_devices_and_capabilities', {
        'room': 'Study',
      });
      final device = (body(result)['devices'] as List).single as Map;
      expect(device['id'], 'desk_lamp');
      final colorTemp = (device['capabilities'] as List).cast<Map>().firstWhere(
        (c) => c['id'] == 'color_temp',
      );
      expect((colorTemp['params'] as Map)['value'], {
        'type': 'number',
        'min': 2200,
        'max': 6500,
        'unit': 'K',
      });
    },
  );

  test('an invalid flow comes back as an error with every issue', () async {
    final result = await call('deploy_automation_flow_dag', {
      'flow': {
        'schemaVersion': 1,
        'id': 'bad',
        'name': 'Bad',
        'nodes': [
          {'id': 'a', 'type': 'manual'},
          {
            'id': 'b',
            'type': 'device_capability',
            'config': {'deviceId': 'ghost', 'capabilityId': 'x'},
          },
          {'id': 'c', 'type': 'teleport'},
        ],
        'edges': [],
      },
    });
    expect(result.isError, isTrue);
    final issues = (((body(result)['error'] as Map)['issues']) as List)
        .map((i) => (i as Map)['message'])
        .join('\n');
    expect(
      issues,
      allOf(
        contains('no device ghost'),
        contains('unknown node type teleport'),
        contains('not reachable'),
      ),
    );
  });

  test('an agent-deployed flow that drives a host-command device waits for approval', () async {
    final result = await call('deploy_automation_flow_dag', {
      'flow': {
        'schemaVersion': 1,
        'id': 'wake',
        'name': 'Wake',
        'nodes': [
          {'id': 'go', 'type': 'manual'},
          {
            'id': 'w',
            'type': 'device_capability',
            'config': {'deviceId': 'mac_mini', 'capabilityId': 'display_wake'},
          },
        ],
        'edges': [
          {
            'id': 'e',
            'from': {'node': 'go', 'port': 'out'},
            'to': {'node': 'w', 'port': 'in'},
          },
        ],
      },
    });
    expect(result.isError, isFalse);
    expect((body(result)['highRisk'], body(result)['approved']), (true, false));
    expect(engine.flows.loadedFlows, isEmpty);
  });

  test('an agent cannot run a host-command device directly', () async {
    final result = await call('invoke_device_capability', {
      'deviceId': 'mac_mini',
      'capabilityId': 'display_wake',
    });
    expect(result.isError, isTrue);
    expect((body(result)['error'] as Map)['type'], 'needs_user');
  });

  test('an agent cannot register a driver that runs host commands, but can register others', () async {
    Map<String, Object?> manifest(String id, String transport) => {
      'schemaVersion': 1,
      'id': id,
      'name': id,
      'category': 'misc',
      'transport': {'type': transport},
      'capabilities': [
        {
          'id': 'go',
          'type': 'action',
          'command': transport == 'exec' ? ['true'] : {'path': '/go'},
        },
      ],
    };
    final exec = await call('register_custom_driver_manifest', {
      'manifest': manifest('sneaky', 'exec'),
    });
    expect(exec.isError, isTrue);
    expect(engine.registry['sneaky'], isNull);
    final http = await call('register_custom_driver_manifest', {
      'manifest': manifest('fan', 'http'),
    });
    expect(http.isError, isFalse);
    expect(engine.registry['fan'], isNotNull);
  });

  test(
    'firmware steps name the board, its flash command and the USB setup',
    () async {
      final bad = await call('generate_mcu_firmware', {'board': 'zx81'});
      expect(bad.isError, isTrue);
      final good = await call('generate_mcu_firmware', {
        'board': 'pico_w',
        'name': 'desk',
        'port': '/dev/cu.usbmodem1101',
      });
      final steps = (body(good)['steps'] as List).join('\n');
      expect(body(good)['fqbn'], 'rp2040:rp2040:rpipicow');
      expect(
        steps,
        contains(
          '--fqbn rp2040:rp2040:rpipicow --upload --port /dev/cu.usbmodem1101',
        ),
      );
      expect(steps, contains('omni board setup /dev/cu.usbmodem1101 --ssid'));
      final uno = await call('generate_mcu_firmware', {'board': 'uno'});
      expect((body(uno)['steps'] as List).join(), isNot(contains('--ssid')));
    },
  );

  test('a dry run through MCP returns the trace', () async {
    await engine.handle('flow.save', {
      'flow': {
        'schemaVersion': 1,
        'id': 'on',
        'name': 'On',
        'nodes': [
          {'id': 'go', 'type': 'manual'},
          {
            'id': 'l',
            'type': 'device_capability',
            'config': {
              'deviceId': 'desk_lamp',
              'capabilityId': 'power',
              'params': {'value': true},
            },
          },
        ],
        'edges': [
          {
            'id': 'e',
            'from': {'node': 'go', 'port': 'out'},
            'to': {'node': 'l', 'port': 'in'},
          },
        ],
      },
    });
    final result = await call('simulate_flow_dry_run', {'flowId': 'on'});
    expect(((body(result)['run'] as Map)['outcome']), 'completed');
  });

  test(
    'omni mcp speaks MCP over real stdio',
    () async {
      final ownHome = await Directory.systemTemp.createTemp('omni_mcp_stdio');
      addTearDown(() => ownHome.delete(recursive: true));
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'omniflow_engine:omni',
        '--home',
        ownHome.path,
        'mcp',
      ]);
      final stderrText = StringBuffer();
      process.stderr.transform(utf8.decoder).listen(stderrText.write);
      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      void send(Map<String, Object?> m) => process.stdin.writeln(jsonEncode(m));
      send({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': {},
          'clientInfo': {'name': 't', 'version': '1'},
        },
      });
      final init = jsonDecode(
        await lines.first.timeout(const Duration(seconds: 60)),
      ) as Map;
      expect(
        ((init['result'] as Map)['serverInfo'] as Map)['name'],
        'omniflow',
      );
      send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
      send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
      final list = jsonDecode(
        await lines
            .firstWhere((l) => l.contains('"id":2'))
            .timeout(const Duration(seconds: 20)),
      ) as Map;
      expect(((list['result'] as Map)['tools'] as List), hasLength(10));
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
    },
    testOn: 'mac-os',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
