import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../api/omni_engine.dart';
import '../manifest/driver_manifest.dart';
import '../version.dart';

typedef _Board = ({String fqbn, bool wifi, String pins});

/// The boards firmware/omniflow_node builds for, and the pins each offers
/// (the board profiles in omni_core.cpp).
const Map<String, _Board> _boards = {
  'esp32': (
    fqbn: 'esp32:esp32:esp32',
    wifi: true,
    pins:
        'GPIO 0, 2, 4, 5, 12-19, 21-23, 25-27, 32, 33 any mode (1 and 3 are USB serial); '
        '34-39 input only; analog on 32-39',
  ),
  'esp8266': (
    fqbn: 'esp8266:esp8266:nodemcuv2',
    wifi: true,
    pins: 'GPIO 0, 2, 4, 5, 12-15 any mode; 16 digital only; A0 (17) analog',
  ),
  'pico_w': (
    fqbn: 'rp2040:rp2040:rpipicow',
    wifi: true,
    pins: 'GPIO 0-22 any mode; 26-28 also analog; 23, 24, 25, 29 belong to the radio',
  ),
  'uno': (
    fqbn: 'arduino:avr:uno',
    wifi: false,
    pins: 'D2-D13 (pwm on 3, 5, 6, 9, 10, 11); A0-A5 as 14-19 with analog',
  ),
};

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
      // Replacing a user driver changes what that user's devices and
      // approved flows do, so that is the user's call too.
      final id = checked['id'] as String;
      if (engine.registry[id] != null && !engine.registry.isBuiltIn(id)) {
        return refuse(
          'needs_user',
          'a user driver $id exists. Only the user can replace it (omni driver register)',
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
        'A flow that drives a host-command device, or starts or feeds one that does, is stored '
        'but not loaded until the user approves it (approved: false). An existing flow the user '
        'saved or approved is replaced only as unapproved.',
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
    'link_devices',
    description:
        'Connects two devices in one step, saved as a flow. mode "toggle": each time from turns on '
        '(a button press) flip to. "follow": to copies from, scaled to its range. "threshold": when '
        'from goes above or below a number, set to to "set". from is device.stateKey, to is '
        'device.capability, for example desk_board.button and lamp.power.',
    inputSchema: JsonSchema.object(
      properties: {
        'from': JsonSchema.string(),
        'to': JsonSchema.string(),
        'mode': JsonSchema.string(
          enumValues: ['toggle', 'follow', 'threshold'],
        ),
        'above': JsonSchema.number(),
        'below': JsonSchema.number(),
        // Any JSON value: true, a number, a string.
        'set': JsonSchema.fromJson(const {}),
      },
      required: ['from', 'to', 'mode'],
    ),
    callback: (args, _) async =>
        reply(await engine.handle('link.create', {...args, 'trusted': false})),
  );

  server.registerTool(
    'configure_board_pins',
    description:
        'Names the pins of an OmniFlow board device and sets them up on the board. pins maps a '
        'name to {"pin": GPIO, "mode": "in" | "in_pullup" | "out" | "pwm" | "servo" | "adc"}, '
        'optionally "watch": {"ms", "delta"} or false. Each pin becomes a capability: out a toggle, '
        'pwm 0 to 100, servo 0 to 180, inputs a sensor in the device state. Replaces all pins.',
    inputSchema: JsonSchema.object(
      properties: {'deviceId': JsonSchema.string(), 'pins': freeObject},
      required: ['deviceId', 'pins'],
    ),
    callback: (args, _) async => reply(
      await engine.handle('board.pins', {
        'id': args['deviceId'],
        'pins': args['pins'],
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
        'How to put OmniFlow on a board. Every board runs the same firmware (firmware/omniflow_node), '
        'so nothing is generated: this returns the flash command for the board type, the USB setup '
        'command, and the pins the board offers. board is esp32, esp8266, pico_w or uno.',
    inputSchema: JsonSchema.object(
      properties: {
        'board': JsonSchema.string(enumValues: _boards.keys.toList()),
        'name': JsonSchema.string(),
        'port': JsonSchema.string(),
      },
      required: ['board'],
    ),
    callback: (args, _) async {
      final board = _boards[args['board']];
      if (board == null) {
        return refuse(
          'invalid',
          'board must be one of ${_boards.keys.join(', ')}',
        );
      }
      final name = args['name'];
      if (name != null &&
          (name is! String ||
              !RegExp(r'^[a-z][a-z0-9_]{0,22}$').hasMatch(name))) {
        return refuse(
          'invalid',
          'name is lower snake case, at most 23 characters',
        );
      }
      final port = args['port'] is String
          ? args['port'] as String
          : '<USB port>';
      final id = name ?? 'my_board';
      return reply({
        'ok': true,
        'board': args['board'],
        'fqbn': board.fqbn,
        'pins': board.pins,
        'steps': [
          'Install arduino-cli and the board core (firmware/omniflow_node/README.md).',
          'arduino-cli compile --fqbn ${board.fqbn} --upload --port $port firmware/omniflow_node',
          if (board.wifi)
            'omni board setup $port --ssid <Wi-Fi name> --name $id   (asks for the password)'
          else
            'omni board setup $port --name $id   (no Wi-Fi: it stays on USB)',
          board.wifi
              ? 'omni device add $id --driver omniflow_board --host <IP from setup> --stable-id $id'
              : 'omni device add $id --driver omniflow_board --host $port --stable-id $id',
          'omni board pin $id relay <pin> out   (one line per pin)',
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
