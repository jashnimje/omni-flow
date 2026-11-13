import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/tv/fake_tvs.dart';

Map<String, Object?> body(CallToolResult r) =>
    jsonDecode((r.content.single as TextContent).text) as Map<String, Object?>;

void main() {
  group('in process', () => _tools(viaHub: false));
  // The same tools and refusals, with the engine in a hub and the MCP
  // server reaching it through the hub's control socket.
  group(
    'through a running hub',
    () => _tools(viaHub: true),
    testOn: 'mac-os || linux',
  );
  _stdio();
}

void _tools({required bool viaHub}) {
  late Directory home;
  late OmniEngine engine;
  late PacketTap tap;
  late McpClient client;
  LocalServer? server;
  EngineConnection? connection;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_mcp');
    tap = PacketTap();
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      tap: tap,
    );
    // These tests are of an agent the user allowed to set the home up.
    await engine.handle('agent.access.set', {'access': 'setup'});
    await engine.handle('device.add', {
      'id': 'desk_lamp',
      'driver': 'philips_wiz_udp',
      'host': '127.0.0.1',
      'room': 'Study',
    });
    await engine.handle('device.add', {
      'id': 'mac_mini',
      'driver': 'macos_host',
      // TEST-NET: a broken guard fails to connect instead of running here.
      'host': '192.0.2.1',
    });
    final toServer = StreamController<List<int>>();
    final toClient = StreamController<List<int>>();
    final McpServer mcp;
    if (viaHub) {
      server = await LocalServer.start(engine, home: home);
      connection = await LocalClient.connect(server!.path);
      mcp = createOmniMcpServerFor(connection!);
    } else {
      mcp = createOmniMcpServer(engine);
    }
    await mcp.connect(
      IOStreamTransport(stream: toServer.stream, sink: toClient.sink),
    );
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
    await connection?.close();
    connection = null;
    await server?.close();
    server = null;
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<CallToolResult> call(
    String name, [
    Map<String, dynamic> args = const {},
  ]) => client.callTool(CallToolRequest(name: name, arguments: args));

  test('at read access every tool that changes the home is refused', () async {
    await engine.handle('agent.access.set', {'access': 'read'});
    Future<String?> refused(String tool, Map<String, dynamic> args) async {
      final r = await call(tool, args);
      final text = (r.content.first as TextContent).text;
      return r.isError == true && text.contains('needs_user') ? tool : text;
    }

    expect(
      await Future.wait([
        refused('invoke_device_capability', {
          'deviceId': 'desk_lamp',
          'capabilityId': 'power',
          'params': {'value': true},
        }),
        refused('create_rule', {
          'rule': {
            'name': 'Lamp on',
            'when': ['manual'],
            'then': ['desk_lamp.power=true'],
          },
        }),
        refused('link_devices', {
          'from': 'desk_lamp.power',
          'to': 'desk_lamp.power',
          'mode': 'follow',
        }),
        refused('find_things', {'windowMs': 100}),
        refused('run_scene', {'id': 'focus'}),
      ]),
      [
        'invoke_device_capability',
        'create_rule',
        'link_devices',
        'find_things',
        'run_scene',
      ],
    );
    expect(
      (await engine.handle('automation.list', {}))['automations'],
      isEmpty,
    );
  });

  test('a high-risk capability is refused even at setup', () async {
    final r = await engine.handle('agent.call', {
      'command': 'device.invoke',
      'args': {'id': 'mac_mini', 'capability': 'display_sleep', 'params': {}},
    });
    expect((r['error'] as Map)['type'], 'needs_user');
  });

  test(
    'an agent-made link to a host-command device waits for approval',
    () async {
      await engine.devices.mergeState('desk_lamp', {'dimming': 40});
      final result = await call('link_devices', {
        'from': 'desk_lamp.dimming',
        'to': 'mac_mini.volume',
        'mode': 'threshold',
        'above': 50,
        'set': 30,
      });
      expect(result.isError, isFalse, reason: '${body(result)}');
      expect(
        (body(result)['highRisk'], body(result)['approved']),
        (true, false),
      );
      expect(engine.flows.loadedFlows, isEmpty);
    },
  );

  test('an agent organizes devices and saves scenes, and a scene it saves '
      'is untrusted', () async {
    await engine.handle('agent.access.set', {'access': 'read'});
    final refused = body(
      await call('organize_device', {
        'deviceId': 'desk_lamp',
        'room': 'Office',
      }),
    );
    expect((refused['error'] as Map)['type'], 'needs_user');
    await engine.handle('agent.access.set', {'access': 'setup'});
    final moved = body(
      await call('organize_device', {
        'deviceId': 'desk_lamp',
        'room': 'Office',
        'favourite': true,
      }),
    );
    expect(moved['ok'], isTrue, reason: '$moved');
    expect((moved['device'] as Map)['roomId'], 'office');
    final rooms = body(await call('list_rooms'));
    expect(
      [for (final r in (rooms['rooms'] as List).cast<Map>()) r['id']],
      ['study', 'office'],
    );

    await engine.handle('scene.save', {
      'id': 'focus',
      'name': 'Focus',
      'actions': ['desk_lamp.brightness=80'],
      'trusted': true,
    });
    final replaced = body(
      await call('save_scene', {
        'id': 'focus',
        'name': 'Focus',
        'actions': ['desk_lamp.brightness=10'],
      }),
    );
    expect(replaced['ok'], isTrue, reason: '$replaced');
    expect(replaced['approved'], isFalse);
    final risky = body(
      await call('save_scene', {
        'name': 'Loud',
        'actions': ['mac_mini.volume=90'],
      }),
    );
    expect((risky['highRisk'], risky['approved']), (true, false));
    final run = body(await call('run_scene', {'id': 'loud'}));
    expect(run['ok'], isFalse, reason: 'an unapproved scene does not run');

    final waiting = body(await call('list_automations', {'needsYou': true}));
    expect(
      [for (final a in (waiting['automations'] as List).cast<Map>()) a['id']],
      ['focus', 'loud'],
    );
    final history = body(
      await call('device_history', {'deviceId': 'desk_lamp'}),
    );
    expect(history['entries'], isEmpty);
    final templates = body(await call('list_rule_templates'));
    expect(templates['templates'], hasLength(5));
  });

  test('the packet sniffer sees the engine\'s packets', () async {
    final sniffing = call('sniff_live_packets', {'seconds': 1});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    tap.record(
      CapturedPacket(
        transport: 'udp',
        direction: PacketDirection.outgoing,
        remote: '127.0.0.1:38899',
        bytes: utf8.encode('{"method":"getPilot"}'),
      ),
    );
    final packets = body(await sniffing)['packets'] as List;
    expect((packets.single as Map)['text'], '{"method":"getPilot"}');
  });

  test('lists the thirty-four tools', () async {
    final tools = (await client.listTools()).tools.map((t) => t.name).toSet();
    expect(tools, {
      'describe_omniflow',
      'omniflow_call',
      'discover_devices_and_capabilities',
      'invoke_device_capability',
      'register_custom_driver_manifest',
      'deploy_automation_flow_dag',
      'list_flows',
      'list_automations',
      'list_rule_templates',
      'list_scenes',
      'save_scene',
      'run_scene',
      'list_rooms',
      'organize_device',
      'device_history',
      'list_tags',
      'simulate_flow_dry_run',
      'sniff_live_packets',
      'generate_mcu_firmware',
      'link_devices',
      'create_rule',
      'find_things',
      'next_setup_step',
      'configure_board_pins',
      'describe_board',
      'pair_device',
      'trust_ssh_host_key',
      'tv_state',
      'tv_remote_keys',
      'tv_list_apps',
      'tv_app_info',
      'tv_settings',
      'tv_files',
      'tv_change',
    });
  });

  test('find_things never opens a USB port, and next_setup_step reads where '
      'a device stands', () async {
    final found = body(
      await call('find_things', {
        'drivers': ['nfc_tag'],
      }),
    );
    expect(found['ok'], isTrue, reason: '$found');
    expect(found['methods'], isNot(contains('serial')));
    expect(
      [for (final m in found['manual'] as List) (m as Map)['driver']],
      ['nfc_tag'],
    );
    final next = body(await call('next_setup_step', {'deviceId': 'mac_mini'}));
    expect((next['next'] as Map)['step'], 'configure');
    expect(
      [
        for (final k in (next['next'] as Map)['keys'] as List)
          (k as Map)['key'],
      ],
      ['username'],
    );
  });

  test(
    'list_tags reads the named tags, and no tool names or scans one',
    () async {
      await engine.handle('tag.save', {
        'id': 'front_door',
        'name': 'Front door',
        'uid': '04A22B1C',
      });
      final listed = body(await call('list_tags'));
      expect(listed['ok'], isTrue, reason: '$listed');
      expect(listed['tags'], [
        {'id': 'front_door', 'name': 'Front door', 'uid': '04A22B1C'},
      ]);
      final tools = (await client.listTools()).tools.map((t) => t.name);
      expect(tools.where((t) => t.contains('tag') || t.contains('nfc')), [
        'list_tags',
      ]);
    },
  );

  test('configure_board_pins tells an agent to keep active-low pins', () async {
    final pins = (await client.listTools()).tools.firstWhere(
      (t) => t.name == 'configure_board_pins',
    );
    expect(pins.description, contains('"invert": true'));
    expect(pins.description, contains('active low'));
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

  test(
    'an agent uses a TV like any device but never starts its pairing',
    () async {
      final tv = await FakeWebOsTv.start();
      addTearDown(tv.close);
      await engine.handle('device.add', {
        'id': 'lounge_tv',
        'driver': 'lg_webos_tv',
        'host': '127.0.0.1',
        'port': tv.port,
      });
      final unpaired = await call('invoke_device_capability', {
        'deviceId': 'lounge_tv',
        'capabilityId': 'mute',
        'params': {'value': true},
      });
      expect(unpaired.isError, isTrue);
      final error = body(unpaired)['error'] as Map;
      expect(error['type'], 'needs_user');
      // The app's Pair button pairs the phone's engine, not this one.
      expect(error['message'], contains('omni device pair lounge_tv'));
      expect(error['message'], isNot(contains('in the app')));
      expect(tv.prompts, 0, reason: 'no prompt appeared on the TV');

      final pair = body(await call('pair_device', {'deviceId': 'lounge_tv'}));
      expect((pair['error'] as Map)['message'], isNot(contains('in the app')));
      expect(
        (pair['error'] as Map)['message'],
        contains('omni device pair lounge_tv'),
      );

      expect(
        (await engine.handle('device.pair', {'id': 'lounge_tv'}))['ok'],
        isTrue,
      );
      final paired = await call('invoke_device_capability', {
        'deviceId': 'lounge_tv',
        'capabilityId': 'mute',
        'params': {'value': true},
      });
      expect(paired.isError, isFalse, reason: '${body(paired)}');
      expect(tv.prompts, 1);
    },
  );

  test('pairing and host keys stay with the user', () async {
    for (final (tool, command) in [
      ('pair_device', 'omni secret set mac_mini sshPrivateKey'),
      ('trust_ssh_host_key', 'omni device hostkey mac_mini'),
    ]) {
      final result = await call(tool, {'deviceId': 'mac_mini'});
      expect(result.isError, isTrue, reason: tool);
      final error = body(result)['error'] as Map;
      expect(error['type'], 'needs_user');
      expect(error['message'], contains(command));
    }
  });

  test(
    'pair_device gives the secret command to drivers with no pairing',
    () async {
      await engine.handle('device.add', {
        'id': 'plug',
        'driver': 'tuya_plug',
        'host': '127.0.0.1',
        'settings': {'devId': 'bf00'},
      });
      final plug = body(await call('pair_device', {'deviceId': 'plug'}));
      expect(
        (plug['error'] as Map)['message'],
        contains('omni secret set plug localKey'),
      );
      expect((plug['error'] as Map)['message'], isNot(contains('device pair')));

      final bulb = body(await call('pair_device', {'deviceId': 'desk_lamp'}));
      expect((bulb['error'] as Map)['type'], 'invalid');
    },
  );

  test('describe_board refuses a device that is not a board', () async {
    final result = await call('describe_board', {'deviceId': 'desk_lamp'});
    expect(result.isError, isTrue);
    expect((body(result)['error'] as Map)['type'], 'invalid');
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

    // What an agent's driver drives waits for the user until they approve it.
    await engine.handle('device.add', {
      'id': 'ceiling_fan',
      'driver': 'fan',
      // TEST-NET: a broken guard fails to connect instead of reaching it.
      'host': '192.0.2.7',
    });
    final invoke = await call('invoke_device_capability', {
      'deviceId': 'ceiling_fan',
      'capabilityId': 'go',
      'params': <String, Object?>{},
    });
    expect(invoke.isError, isTrue);
    expect((body(invoke)['error'] as Map)['type'], 'needs_user');
    expect(
      (body(invoke)['error'] as Map)['message'],
      contains('omni driver approve fan'),
    );
    final called = await engine.handle('agent.call', {
      'command': 'device.invoke',
      'args': {'id': 'ceiling_fan', 'capability': 'go'},
    });
    expect((called['error'] as Map)['type'], 'needs_user', reason: '$called');
    expect((called['error'] as Map)['message'], contains('high risk'));
    final rule = body(
      await call('create_rule', {
        'rule': {
          'name': 'Fan on',
          'when': ['manual'],
          'then': ['ceiling_fan.go'],
        },
      }),
    );
    expect((rule['highRisk'], rule['approved']), (true, false));
    final listed = await engine.handle('driver.list', {});
    final fan = (listed['drivers'] as List).cast<Map>().firstWhere(
      (d) => d['id'] == 'fan',
    );
    expect((fan['highRisk'], fan['byAgent']), (true, true));

    final approved = await engine.handle('driver.approve', {'id': 'fan'});
    expect(approved['ok'], isTrue, reason: '$approved');
    final agentApprove = await engine.handle('agent.call', {
      'command': 'driver.approve',
      'args': {'id': 'fan'},
    });
    expect((agentApprove['error'] as Map)['type'], 'needs_user');
    final relisted = await engine.handle('automation.list', {});
    final fanOn = (relisted['automations'] as List).cast<Map>().firstWhere(
      (a) => a['id'] == 'fan_on',
    );
    expect(fanOn['highRisk'], isFalse);
  });

  test('an agent\'s driver stays high risk after a restart', () async {
    final registered = await call('register_custom_driver_manifest', {
      'manifest': {
        'schemaVersion': 1,
        'id': 'fan',
        'name': 'Fan',
        'category': 'misc',
        'transport': {'type': 'http'},
        'capabilities': [
          {
            'id': 'go',
            'type': 'action',
            'command': {'path': '/go'},
          },
        ],
      },
    });
    expect(registered.isError, isFalse);
    await engine.close();
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      tap: tap,
    );
    final fan = ((await engine.handle('driver.list', {}))['drivers'] as List)
        .cast<Map>()
        .firstWhere((d) => d['id'] == 'fan');
    expect((fan['highRisk'], fan['byAgent']), (true, true));
  });

  test('an agent cannot replace a driver or a flow the user saved', () async {
    final userDriver = {
      'schemaVersion': 1,
      'id': 'fan',
      'name': 'Fan',
      'category': 'misc',
      'transport': {'type': 'http'},
      'capabilities': [
        {
          'id': 'go',
          'type': 'action',
          'command': {'path': '/go'},
        },
      ],
    };
    await engine.handle('driver.register', {'manifest': userDriver});
    final replaced = await call('register_custom_driver_manifest', {
      'manifest': {...userDriver, 'name': 'Not your fan'},
    });
    expect(replaced.isError, isTrue);
    expect((body(replaced)['error'] as Map)['type'], 'needs_user');
    expect(engine.registry['fan']!.name, 'Fan');

    Map<String, Object?> lampFlow(bool value) => {
      'schemaVersion': 1,
      'id': 'lamp_on',
      'name': 'Lamp',
      'nodes': [
        {'id': 'go', 'type': 'manual'},
        {
          'id': 'l',
          'type': 'device_capability',
          'config': {
            'deviceId': 'desk_lamp',
            'capabilityId': 'power',
            'params': {'value': value},
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
    };
    await engine.handle('flow.save', {'flow': lampFlow(true), 'trusted': true});
    final over = await call('deploy_automation_flow_dag', {
      'flow': lampFlow(false),
    });
    expect((body(over)['highRisk'], body(over)['approved']), (false, false));
    expect(engine.flows.loadedFlows, isEmpty);
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
}

void _stdio() {
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
      expect(((list['result'] as Map)['tools'] as List), hasLength(34));
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
    },
    testOn: 'mac-os',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
