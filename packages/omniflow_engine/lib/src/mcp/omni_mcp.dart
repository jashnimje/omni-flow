import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../api/omni_engine.dart';
import '../manifest/driver_manifest.dart';
import '../version.dart';

/// Pins a Pico W must never be given as outputs: the CYW43 radio (23, 24, 25,
/// 29) and the pins the firmware itself uses (IR 15, button 14, knob 26).
const _reservedPicoPins = {14, 15, 23, 24, 25, 26, 29};

/// The MCP server: one tool per core API need, each a thin call into
/// [OmniEngine.handle], so an agent can do nothing the CLI cannot.
///
/// An agent is not the user. Flows it deploys are saved untrusted, so a flow
/// that drives a host-command driver waits for approval, and it cannot
/// register a driver that runs host commands at all.
McpServer createOmniMcpServer(OmniEngine engine) {
  final server = McpServer(
    const Implementation(name: 'omniflow', version: omniflowEngineVersion),
    options: const McpServerOptions(
      capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
    ),
  );

  CallToolResult reply(Map<String, Object?> result) => CallToolResult(
    content: [
      TextContent(text: const JsonEncoder.withIndent('  ').convert(result)),
    ],
    isError: result['ok'] != true,
  );

  CallToolResult refuse(String type, String message) => reply({
    'ok': false,
    'error': {'type': type, 'message': message},
  });

  final freeObject = JsonSchema.object(additionalProperties: true);

  server.registerTool(
    'discover_devices_and_capabilities',
    description:
        'Lists every device with its driver, current state and the capabilities it accepts, '
        'with each capability\'s params. Optionally only one room.',
    inputSchema: JsonSchema.object(properties: {'room': JsonSchema.string()}),
    callback: (args, _) async => reply(
      await engine.handle('device.list', {
        'withCapabilities': true,
        if (args['room'] != null) 'room': args['room'],
      }),
    ),
  );

  server.registerTool(
    'invoke_device_capability',
    description:
        'Runs one capability on one device now, for example a lamp brightness.',
    inputSchema: JsonSchema.object(
      properties: {
        'deviceId': JsonSchema.string(),
        'capabilityId': JsonSchema.string(),
        'params': freeObject,
      },
      required: ['deviceId', 'capabilityId'],
    ),
    callback: (args, _) async {
      final manifest = await _driverOf(engine, args['deviceId']);
      if (manifest?.isHighRisk ?? false) {
        return refuse(
          'needs_user',
          '${args['deviceId']} runs host commands. Ask the user to run it, or deploy a flow for approval',
        );
      }
      return reply(
        await engine.handle('device.invoke', {
          'id': args['deviceId'],
          'capability': args['capabilityId'],
          'params': args['params'] ?? const {},
        }),
      );
    },
  );

  server.registerTool(
    'register_custom_driver_manifest',
    description:
        'Validates and stores a .omni_driver.json manifest (schema v1). '
        'Drivers that run host commands must be added by the user with omni driver register.',
    inputSchema: JsonSchema.object(
      properties: {'manifest': freeObject},
      required: ['manifest'],
    ),
    callback: (args, _) async {
      final checked = await engine.handle('driver.validate', {
        'manifest': args['manifest'],
      });
      if (checked['ok'] != true) return reply(checked);
      if (checked['highRisk'] == true) {
        return refuse(
          'needs_user',
          'this driver runs host commands, so only the user can register it',
        );
      }
      return reply(
        await engine.handle('driver.register', {'manifest': args['manifest']}),
      );
    },
  );

  server.registerTool(
    'deploy_automation_flow_dag',
    description:
        'Validates and saves a flow (schema v1). Every validation issue comes back at once. '
        'A flow that drives a host-command device is stored disabled until the user approves it.',
    inputSchema: JsonSchema.object(
      properties: {'flow': freeObject},
      required: ['flow'],
    ),
    callback: (args, _) async => reply(
      await engine.handle('flow.save', {
        'flow': args['flow'],
        'trusted': false,
      }),
    ),
  );

  server.registerTool(
    'list_flows',
    description:
        'Lists flows with whether they are enabled, approved and running.',
    inputSchema: JsonSchema.object(),
    callback: (_, _) async => reply(await engine.handle('flow.list', {})),
  );

  server.registerTool(
    'simulate_flow_dry_run',
    description:
        'Runs a saved flow without sending anything and returns the trace of every node. '
        '"at" is the local time to pretend it is (ISO 8601), "msg" the trigger message.',
    inputSchema: JsonSchema.object(
      properties: {
        'flowId': JsonSchema.string(),
        'at': JsonSchema.string(),
        'trigger': JsonSchema.string(),
        'msg': freeObject,
      },
      required: ['flowId'],
    ),
    callback: (args, _) async => reply(
      await engine.handle('flow.dryRun', {
        'id': args['flowId'],
        if (args['at'] != null) 'at': args['at'],
        if (args['trigger'] != null) 'trigger': args['trigger'],
        if (args['msg'] != null) 'msg': args['msg'],
      }),
    ),
  );

  server.registerTool(
    'sniff_live_packets',
    description: 'Captures packets the engine sends and receives for a few seconds (1 to 10).',
    inputSchema: JsonSchema.object(
      properties: {'seconds': JsonSchema.number()},
    ),
    callback: (args, _) async {
      final seconds = (args['seconds'] is num ? args['seconds'] as num : 3)
          .clamp(1, 10);
      final packets = <Map<String, Object?>>[];
      final sub = engine.events
          .where((e) => e['event'] == 'packet.captured')
          .listen(packets.add);
      await Future<void>.delayed(
        Duration(milliseconds: (seconds * 1000).round()),
      );
      await sub.cancel();
      return reply({'ok': true, 'packets': packets.take(200).toList()});
    },
  );

  server.registerTool(
    'generate_mcu_firmware',
    description:
        'Produces the config.json for a Pico W running firmware/pico_w (main.py and nec.py), '
        'from a node id, beacon name and output pins. Radio and firmware pins are refused. Flashing stays manual.',
    inputSchema: JsonSchema.object(
      properties: {
        'nodeId': JsonSchema.string(),
        'bleName': JsonSchema.string(),
        'outPins': JsonSchema.array(items: JsonSchema.integer()),
        'udpPort': JsonSchema.integer(),
      },
      required: ['nodeId'],
    ),
    callback: (args, _) async {
      final nodeId = args['nodeId'];
      if (nodeId is! String || !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(nodeId)) {
        return refuse('invalid', 'nodeId must be lower snake case');
      }
      final pins = (args['outPins'] as List? ?? const [16, 17, 18])
          .map((p) => p as num)
          .map((p) => p.toInt())
          .toList();
      final bad = pins
          .where((p) => p < 0 || p > 28 || _reservedPicoPins.contains(p))
          .toList();
      if (bad.isNotEmpty) {
        return refuse(
          'invalid',
          'pins $bad are reserved (radio 23, 24, 25, 29; firmware 14, 15, 26) or out of range',
        );
      }
      final config = {
        'node_id': nodeId,
        'ble_name': args['bleName'] ?? 'OMNI_${nodeId.toUpperCase()}',
        'ssid': '<your 2.4 GHz Wi-Fi>',
        'password': '<your Wi-Fi password>',
        'udp_port': args['udpPort'] ?? 38950,
        'out_pins': pins,
      };
      return reply({
        'ok': true,
        'files': {'config.json': config},
        'steps': [
          'Fill in ssid and password in config.json.',
          'Copy firmware/pico_w/main.py, firmware/pico_w/nec.py and config.json to the Pico W (mpremote cp).',
          'Add it: omni device add $nodeId --driver omniflow_mcu_node --host <its IP>',
        ],
      });
    },
  );

  return server;
}

Future<DriverManifest?> _driverOf(OmniEngine engine, Object? deviceId) async {
  if (deviceId is! String) return null;
  final got = await engine.handle('device.get', {'id': deviceId});
  if (got['ok'] != true) return null;
  return engine.registry[(got['device'] as Map)['driver'] as String];
}
