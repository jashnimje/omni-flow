import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../api/local_client.dart';
import '../api/omni_engine.dart';
import '../version.dart';

typedef _Board = ({String fqbn, bool wifi, String pins});

const _agentFindMethods = ['udp_broadcast', 'mdns', 'tuya_broadcast', 'hello'];

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

/// The MCP server over an engine opened in this process.
McpServer createOmniMcpServer(OmniEngine engine) =>
    createOmniMcpServerFor(InProcessConnection(engine));

/// The MCP server: one tool per core API need, each a thin call into
/// [EngineConnection.handle], so an agent can do nothing the CLI cannot,
/// whether the engine is in this process or in a running hub.
///
/// An agent is not the user. Flows it deploys are saved untrusted, so a flow
/// that drives a host-command driver waits for approval, and it cannot
/// register a driver that runs host commands at all. Pairing a device and
/// trusting an SSH host key are the user's steps: an invoke never starts a
/// pairing prompt, and the tools for both refuse with `needs_user`.
McpServer createOmniMcpServerFor(EngineConnection engine) {
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
      final drivers = await engine.handle('driver.list', {});
      if (drivers['ok'] != true) return reply(drivers);
      final driver = _driverEntry(drivers, await _driverIdOf(engine, args));
      if (driver?['highRisk'] == true) {
        return refuse(
          'needs_user',
          '${args['deviceId']} runs host commands. Ask the user to run it, or deploy a flow for approval',
        );
      }
      final result = await engine.handle('device.invoke', {
        'id': args['deviceId'],
        'capability': args['capabilityId'],
        'params': args['params'] ?? const {},
        'allowPairing': false,
      });
      // The engine's own message also offers Pair in the app, which pairs
      // the phone's engine, not this one.
      if (result['error'] case {'type': 'needs_user'}) {
        return refuse('needs_user', _pairCommandFor('${args['deviceId']}'));
      }
      return reply(result);
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
      final drivers = await engine.handle('driver.list', {});
      if (drivers['ok'] != true) return reply(drivers);
      final existing = _driverEntry(drivers, id);
      if (existing != null && existing['builtIn'] != true) {
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
    'create_rule',
    description:
        'Saves a rule: when any trigger fires, only if every condition holds, run the steps in '
        'order. rule is {name, when: [...], onlyIf?: [...], then: [...], mode?}. '
        'A trigger is {on: "thing.key", event: true, match?} (an event like front_door.scanned), '
        '{on: "thing.key", change: {to?: value}} (a state change, like jade.home to true), '
        '{on: "thing.key", crosses: {above | below: number}}, {time: "HH:MM", days?: ["mon", ...]}, '
        '{interval: seconds} or {manual: true}. Several triggers start the same steps. '
        'A condition is {state: "thing.key" | var: "\$Name" | msg: "key", op: "==" | "!=" | "<" | '
        '"<=" | ">" | ">=", value}, {between: ["HH:MM", "HH:MM"]}, {days: [...]}, {not: condition}, '
        '{anyOf: [...]} or {allOf: [...]}. '
        'A step is {do: "thing.action", params?}, {toggle: "thing.action"}, {wait: ms}, '
        '{waitFor: {on, event | change | crosses, timeoutMs, onTimeout?: [steps]}} (a timeout ends '
        'the rule after onTimeout), {if: [conditions], then: [steps], else?: [steps]}, '
        '{together: [[steps], [steps]]} (side by side, then on), {notify: {title}}, '
        '{set: {var: "\$Name", value}} or {run: "automation_id"}. Shorthand strings work in any list: '
        '"home:entered", "nfc:front_door", "time:18:00", "lamp.power=true", "wait:2s", '
        '"notify:Welcome home". Issues come back at rule paths like then[2].do. A rule whose id '
        '(from its name) another rule has is refused with exists: give it another name. Saved untrusted: '
        'a rule that drives a host-command device waits for the user to approve it.',
    inputSchema: JsonSchema.object(
      properties: {'rule': freeObject},
      required: ['rule'],
    ),
    callback: (args, _) async => reply(
      await engine.handle('automation.save', {
        'form': 'rule',
        'spec': args['rule'],
        'trusted': false,
      }),
    ),
  );

  server.registerTool(
    'find_things',
    description:
        'Looks for devices on the local network at once (UDP broadcast, mDNS, Tuya broadcasts, '
        'board hellos) and returns candidates grouped by driver, with a suggested id and '
        'knownAs when one is a device already. Drivers no method finds are listed under '
        'manual. Adding a find is the user\'s step: they run omni add, or use Add in the app. '
        'windowMs is how long to listen, 100 to 60000.',
    inputSchema: JsonSchema.object(
      properties: {
        'windowMs': JsonSchema.integer(),
        'drivers': JsonSchema.array(items: JsonSchema.string()),
      },
    ),
    callback: (args, _) async => reply(
      await engine.handle('thing.add', {
        if (args['windowMs'] != null) 'windowMs': args['windowMs'],
        if (args['drivers'] != null) 'drivers': args['drivers'],
        // Opening a USB port resets an ESP32 or an Uno, which an agent
        // must not do to a board that is running.
        'methods': _agentFindMethods,
      }),
    ),
  );

  server.registerTool(
    'next_setup_step',
    description:
        'What a device still needs before it works: pair (the user at the device), secret '
        '(a token or key only the user stores), configure (settings such as board pins) or '
        'done, with the instruction to give the user.',
    inputSchema: JsonSchema.object(
      properties: {'deviceId': JsonSchema.string()},
      required: ['deviceId'],
    ),
    callback: (args, _) async =>
        reply(await engine.handle('thing.next', {'id': args['deviceId']})),
  );

  server.registerTool(
    'configure_board_pins',
    description:
        'Names the pins of an OmniFlow board device and sets them up on the board. pins maps a '
        'name to {"pin": GPIO, "mode": "in" | "in_pullup" | "out" | "pwm" | "servo" | "adc"}, '
        'optionally "watch": {"ms", "delta"} or false, and "invert": true for an out pin that is '
        'active low (a relay module that switches on at LOW), or false for an in_pullup pin that '
        'reads true when high. Each pin becomes a capability: out a toggle, pwm 0 to 100, servo 0 '
        'to 180, inputs a sensor in the device state. Replaces all pins, so start from the device\'s '
        'pins setting in discover_devices_and_capabilities and keep each "invert".',
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
    'describe_board',
    description:
        'What an OmniFlow board offers: each GPIO with its capabilities (in, pullup, out, pwm, '
        'servo, adc), whether IR and RF outputs are set, the pins set now, and warnings for '
        'strapping pins. An offline board gives the last describe it sent (live: false).',
    inputSchema: JsonSchema.object(
      properties: {'deviceId': JsonSchema.string()},
      required: ['deviceId'],
    ),
    callback: (args, _) async =>
        reply(await engine.handle('board.describe', {'id': args['deviceId']})),
  );

  server.registerTool(
    'pair_device',
    description:
        'Pairing a TV, a Hue bridge or a Home Assistant token is done by the user, because it '
        'needs someone at the device. This tool never pairs. It returns the command for the '
        'user to run on this computer, omni device pair for a TV or Hue bridge and omni secret '
        'set for a token or key. Call it when a device fails with needs_user or missing_secret.',
    inputSchema: JsonSchema.object(
      properties: {'deviceId': JsonSchema.string()},
      required: ['deviceId'],
    ),
    callback: (args, _) async {
      final id = args['deviceId'];
      if (id is! String) return refuse('invalid', 'deviceId is a string');
      final got = await engine.handle('device.get', {'id': id});
      if (got['ok'] != true) return reply(got);
      final drivers = await engine.handle('driver.list', {});
      if (drivers['ok'] != true) return reply(drivers);
      final driver = _driverEntry(
        drivers,
        (got['device'] as Map)['driver'] as String?,
      );
      final pairing = driver?['pairing'];
      if (pairing != null && pairing != 'secret') {
        return refuse('needs_user', _pairCommandFor(id));
      }
      final secrets = [
        for (final s in (driver?['settings'] as List? ?? const []).cast<Map>())
          if (s['secret'] == true) s['key'] as String,
      ];
      if (secrets.isEmpty) {
        return refuse('invalid', '$id needs no pairing and no secret');
      }
      return refuse(
        'needs_user',
        'only the user can store a secret for $id: ask them to run '
            '${secrets.map((k) => 'omni secret set $id $k').join(' and ')} '
            'on this computer',
      );
    },
  );

  server.registerTool(
    'trust_ssh_host_key',
    description:
        'Accepting or clearing a host\'s SSH host key is a trust decision for the user. This '
        'tool never changes a pin: it returns the command for the user. Call it when a host '
        'device fails with host_key.',
    inputSchema: JsonSchema.object(
      properties: {'deviceId': JsonSchema.string()},
      required: ['deviceId'],
    ),
    callback: (args, _) async => refuse(
      'needs_user',
      'only the user can trust a host key: ask them to run '
          'omni device hostkey ${args['deviceId']}, check the key, then '
          'omni device hostkey ${args['deviceId']} --accept <fingerprint>',
    ),
  );

  server.registerTool(
    'list_flows',
    description:
        'Lists flows with whether they are enabled, approved and running.',
    inputSchema: JsonSchema.object(),
    callback: (_, _) async => reply(await engine.handle('flow.list', {})),
  );

  // Read only: naming, writing or scanning a tag stays with the user, so
  // agent-written text never names a tag or fakes a scan.
  server.registerTool(
    'list_tags',
    description:
        'Lists the NFC tags the user has named, with their ids, for rules that start '
        'when one is scanned ("when": ["nfc:<tag id>"]). Naming, writing and scanning '
        'a tag are the user\'s steps, in the app or with omni tag.',
    inputSchema: JsonSchema.object(),
    callback: (_, _) async => reply(await engine.handle('tag.list', {})),
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
      final Stream<Map<String, Object?>> events;
      try {
        events = await engine.events(packets: true);
      } on LocalSocketException catch (e) {
        return refuse('unavailable', e.message);
      }
      final sub = events
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

Future<String?> _driverIdOf(
  EngineConnection engine,
  Map<String, dynamic> args,
) async {
  final deviceId = args['deviceId'];
  if (deviceId is! String) return null;
  final got = await engine.handle('device.get', {'id': deviceId});
  if (got['ok'] != true) return null;
  return (got['device'] as Map)['driver'] as String?;
}

/// Where the user pairs a device for the engine this MCP server drives. The
/// app's Pair button pairs the phone's own engine, so it is not offered.
String _pairCommandFor(String deviceId) =>
    '$deviceId is not paired with this OmniFlow engine yet. Only the user '
    'can pair it: ask them to run omni device pair $deviceId on this computer';

/// The `driver.list` entry for [id], which carries `builtIn` and `highRisk`.
Map<String, Object?>? _driverEntry(Map<String, Object?> list, String? id) {
  if (id == null) return null;
  for (final d in (list['drivers'] as List).cast<Map>()) {
    if (d['id'] == id) return Map<String, Object?>.from(d);
  }
  return null;
}
