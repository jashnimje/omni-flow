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
      // On a TV a raw setting or an app's data, state or presence is the
      // user's change, even though the TV's other capabilities are not.
      if (driver?['transport'] == 'adb') {
        final risk = await engine.handle('tv.capabilityRisk', {
          'id': args['deviceId'],
          'capability': args['capabilityId'],
        });
        if (risk['ok'] != true) return reply(risk);
        if (risk['highRisk'] == true) {
          return refuse(
            'needs_user',
            '${args['capabilityId']} changes ${args['deviceId']} beyond the remote. '
                'Ask the user to run it, or deploy a rule for their approval',
          );
        }
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
    'describe_omniflow',
    description:
        'Start here. Everything set up in OmniFlow in one reply: every thing (devices, the '
        'phone, people, places, NFC tags) with its driver, room, state and the capabilities it '
        'accepts with their params, the rooms, places, tags, scenes, variables, every automation '
        'with its full spec, the rule templates, every driver with its settings and how it is '
        'found and paired, and agentAccess: what you may change (read or setup), the commands '
        'each level opens and the ones only the user may send. Plan from this, then make each '
        'change with omniflow_call or the specific tools.',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (_, _) async => reply(await engine.handle('agent.describe', {})),
  );

  server.registerTool(
    'omniflow_call',
    description:
        'Sends one OmniFlow core API command, the same one the app and the omni CLI use, so '
        'you can do anything the app does that your access allows, with no screen. '
        'describe_omniflow lists the commands open at your access level (agentAccess.readCommands '
        'and setupCommands). Common ones: thing.add {candidate | driver, host, name?, room?, '
        'settings?} after device.discover, thing.configure {id, settings}, thing.next {id}, '
        'device.organize {id, name?, room?, favourite?}, room.save {name}, zone.save (a place, '
        'shaped as zone.list returns it), tag.save, scene.save {name, actions}, '
        'automation.save {form: "rule", '
        'spec, replace?} (the rule language is in create_rule), automation.dry_run {form, spec} or '
        '{id}, automation.enable {id, enabled}, automation.run {id}, automation.remove {id}, '
        'tv.apps {id}, tv.key {id, key}. Saves are untrusted, so a high-risk automation (TV '
        'settings, app management, host commands) waits for the user to approve it. Commands '
        'only the user may send come back as needs_user with the reason.',
    inputSchema: JsonSchema.object(
      properties: {'command': JsonSchema.string(), 'args': freeObject},
      required: ['command'],
    ),
    callback: (args, _) async => reply(
      await engine.handle('agent.call', {
        'command': args['command'],
        'args': args['args'] ?? const <String, Object?>{},
      }),
    ),
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
        '{together: [[steps], [steps]]} (side by side, then on), '
        '{repeat: {do: [steps], times?: 1-1000, until?: [conditions], every?: ms}} (checks '
        'until before each pass, needs times or until), '
        '{try: [steps], otherwise?: [steps]} (a device step in try that fails runs otherwise '
        'instead of the rest), {notify: {title}}, '
        '{set: {var: "\$Name", value}}, {run: "automation_id"}, or last in then '
        '{keep: {target: "thing.action", value, while: [conditions], release?}}, which holds the '
        'value while the conditions hold and sends release (the opposite of a true or false value '
        'when left out, nothing when null) once they stop; a rule of keep steps alone needs no '
        'when. A failed step is logged and the rest still run unless the rule sets '
        'stopOnError: true. Shorthand strings work in any list: '
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

  server.registerTool(
    'list_automations',
    description:
        'Lists every rule, link, scene and flow with its sentence in plain words, whether it is '
        'on and approved, the things it reads or drives, and its last run. device or tag keeps '
        'those that use that thing, needsYou those waiting for approval or failing, source one '
        'form (rule, link, graph, scene).',
    inputSchema: JsonSchema.object(
      properties: {
        'device': JsonSchema.string(),
        'tag': JsonSchema.string(),
        'needsYou': JsonSchema.boolean(),
        'source': JsonSchema.string(),
      },
    ),
    callback: (args, _) async => reply(
      await engine.handle('automation.list', {
        for (final key in const ['device', 'tag', 'needsYou', 'source'])
          if (args[key] != null) key: args[key],
      }),
    ),
  );

  server.registerTool(
    'list_rule_templates',
    description:
        'Lists rule templates (arrive home, leave home all off, motion light, tag toggle, '
        'bedtime) with their placeholders. With id and values, returns that template\'s rule '
        'filled in, ready for create_rule.',
    inputSchema: JsonSchema.object(
      properties: {'id': JsonSchema.string(), 'values': freeObject},
    ),
    callback: (args, _) async => reply(
      await engine.handle('automation.templates', {
        if (args['id'] != null) 'id': args['id'],
        if (args['values'] != null) 'values': args['values'],
      }),
    ),
  );

  server.registerTool(
    'list_scenes',
    description: 'Lists scenes: named sets of device actions run together.',
    inputSchema: JsonSchema.object(),
    callback: (_, _) async => reply(await engine.handle('scene.list', {})),
  );

  server.registerTool(
    'save_scene',
    description:
        'Saves a scene: {name, icon?, actions: [{do: "thing.action", params?}] or shorthand '
        'like "lamp.power=false", id?}. With no id it gets one from its name. Saved untrusted: '
        'a scene that drives a high-risk device waits for the user to approve it, and one the '
        'user saved goes back to waiting when you change it.',
    inputSchema: JsonSchema.object(
      properties: {
        'id': JsonSchema.string(),
        'name': JsonSchema.string(),
        'icon': JsonSchema.string(),
        'actions': JsonSchema.array(),
      },
      required: ['name', 'actions'],
    ),
    callback: (args, _) async => reply(
      await engine.handle('scene.save', {
        for (final key in const ['id', 'name', 'icon', 'actions'])
          if (args[key] != null) key: args[key],
        'trusted': false,
      }),
    ),
  );

  server.registerTool(
    'run_scene',
    description: 'Runs an approved scene now.',
    inputSchema: JsonSchema.object(
      properties: {'id': JsonSchema.string()},
      required: ['id'],
    ),
    callback: (args, _) async =>
        reply(await engine.handle('scene.run', {'id': args['id']})),
  );

  server.registerTool(
    'list_rooms',
    description:
        'Lists the rooms in the user\'s order, with how many devices each has.',
    inputSchema: JsonSchema.object(),
    callback: (_, _) async => reply(await engine.handle('room.list', {})),
  );

  server.registerTool(
    'organize_device',
    description:
        'Renames a device, moves it to a room (an id or name; a new name adds the room; "" '
        'takes it out), stars it as a favourite, or sets its order in its room. Only the keys '
        'given change.',
    inputSchema: JsonSchema.object(
      properties: {
        'deviceId': JsonSchema.string(),
        'name': JsonSchema.string(),
        'room': JsonSchema.string(),
        'favourite': JsonSchema.boolean(),
        'order': JsonSchema.integer(),
      },
      required: ['deviceId'],
    ),
    callback: (args, _) async => reply(
      await engine.handle('device.organize', {
        'id': args['deviceId'],
        for (final key in const ['name', 'room', 'favourite', 'order'])
          if (args.containsKey(key)) key: args[key],
      }),
    ),
  );

  server.registerTool(
    'device_history',
    description:
        'A device\'s recent state changes, newest first: when, which key, the value, and by '
        'which automation or the user. key, limit (1 to 500, default 100) and since (ISO 8601) '
        'narrow it.',
    inputSchema: JsonSchema.object(
      properties: {
        'deviceId': JsonSchema.string(),
        'key': JsonSchema.string(),
        'limit': JsonSchema.integer(),
        'since': JsonSchema.string(),
      },
      required: ['deviceId'],
    ),
    callback: (args, _) async => reply(
      await engine.handle('device.history', {
        'id': args['deviceId'],
        for (final key in const ['key', 'limit', 'since'])
          if (args[key] != null) key: args[key],
      }),
    ),
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

  _registerTvTools(server, engine, reply, refuse);

  return server;
}

/// The TV tools: an agent reads a TV's state, apps, settings and files.
/// Every change (keys, text, volume, apps, settings, files, install and the
/// shell) is the user's, so `tv_change` only says what the user runs.
void _registerTvTools(
  McpServer server,
  EngineConnection engine,
  CallToolResult Function(Map<String, Object?>) reply,
  CallToolResult Function(String, String) refuse,
) {
  Future<CallToolResult> read(String command, Map<String, Object?> args) async {
    final result = await engine.handle(command, {
      ...args,
      'allowPairing': false,
    });
    if (result['error'] case {'type': 'needs_user'}) {
      return refuse('needs_user', _pairCommandFor('${args['id']}'));
    }
    return reply(result);
  }

  final device = {'deviceId': JsonSchema.string()};

  server.registerTool(
    'tv_state',
    description:
        'Reads an Android TV now: power (on, asleep or off), the app on screen and its '
        'activity, playback (playing, paused, stopped or null), volume, volumeMax and muted.',
    inputSchema: JsonSchema.object(properties: device, required: ['deviceId']),
    callback: (args, _) => read('tv.state', {'id': args['deviceId']}),
  );

  server.registerTool(
    'tv_remote_keys',
    description:
        'The remote keys an Android TV takes, grouped (power, navigation, volume, channel, '
        'media, numbers, colors, inputs, system), each with its key name and Android key code.',
    inputSchema: JsonSchema.object(properties: device, required: ['deviceId']),
    callback: (args, _) => read('tv.keys', {'id': args['deviceId']}),
  );

  server.registerTool(
    'tv_list_apps',
    description:
        'Lists the apps on an Android TV with package, label when known, versionName, '
        'versionCode, system, enabled and launchable. filter is user, system or all.',
    inputSchema: JsonSchema.object(
      properties: {
        ...device,
        'filter': JsonSchema.string(enumValues: ['user', 'system', 'all']),
        'launchableOnly': JsonSchema.boolean(),
      },
      required: ['deviceId'],
    ),
    callback: (args, _) => read('tv.apps', {
      'id': args['deviceId'],
      if (args['filter'] != null) 'filter': args['filter'],
      if (args['launchableOnly'] != null)
        'launchableOnly': args['launchableOnly'],
    }),
  );

  server.registerTool(
    'tv_app_info',
    description:
        'Details of one app on an Android TV: version, size, install and update times, '
        'SDK levels and whether it is enabled and launchable.',
    inputSchema: JsonSchema.object(
      properties: {...device, 'package': JsonSchema.string()},
      required: ['deviceId', 'package'],
    ),
    callback: (args, _) => read('tv.app', {
      'id': args['deviceId'],
      'package': args['package'],
      'action': 'info',
    }),
  );

  server.registerTool(
    'tv_settings',
    description:
        'Reads Android TV settings. view "catalog" gives the curated settings by category '
        'with type, range and the live value; "list" every setting, optionally of one '
        'namespace (system, secure, global); "get" one setting by namespace and key.',
    inputSchema: JsonSchema.object(
      properties: {
        ...device,
        'view': JsonSchema.string(enumValues: ['catalog', 'list', 'get']),
        'namespace': JsonSchema.string(
          enumValues: ['system', 'secure', 'global'],
        ),
        'key': JsonSchema.string(),
      },
      required: ['deviceId'],
    ),
    callback: (args, _) {
      final id = args['deviceId'];
      return switch (args['view'] ?? 'catalog') {
        'catalog' => read('tv.settings.catalog', {'id': id}),
        'list' => read('tv.settings.list', {
          'id': id,
          if (args['namespace'] != null) 'namespace': args['namespace'],
        }),
        'get' => read('tv.settings.get', {
          'id': id,
          'namespace': args['namespace'],
          'key': args['key'],
        }),
        _ => Future.value(refuse('invalid', 'view is catalog, list or get')),
      };
    },
  );

  server.registerTool(
    'tv_files',
    description:
        'Reads the file system of an Android TV. view "list" lists a folder, "stat" one '
        'path. Paths are absolute, such as /sdcard/Download.',
    inputSchema: JsonSchema.object(
      properties: {
        ...device,
        'view': JsonSchema.string(enumValues: ['list', 'stat']),
        'path': JsonSchema.string(),
      },
      required: ['deviceId', 'path'],
    ),
    callback: (args, _) => read(
      args['view'] == 'stat' ? 'tv.files.stat' : 'tv.files.list',
      {'id': args['deviceId'], 'path': args['path']},
    ),
  );

  server.registerTool(
    'tv_change',
    description:
        'Changing an Android TV is the user\'s step: pressing keys, typing, volume, opening, '
        'stopping, clearing, disabling, installing or uninstalling apps, changing or deleting '
        'settings, copying, moving, uploading, downloading or deleting files, and the shell. '
        'This tool changes nothing. It returns the omni command for the user to run, or the '
        'app screen to use. For a change that should run on its own, deploy a rule: one '
        'that changes settings or apps waits for the user to approve it.',
    inputSchema: JsonSchema.object(
      properties: {
        ...device,
        'change': JsonSchema.string(
          enumValues: [
            'remote',
            'text',
            'volume',
            'apps',
            'install',
            'settings',
            'files',
            'shell',
          ],
        ),
      },
      required: ['deviceId', 'change'],
    ),
    callback: (args, _) async {
      final id = args['deviceId'];
      final example = switch (args['change']) {
        'remote' => 'omni tv $id remote <key>',
        'text' => 'omni tv $id text <text>',
        'volume' => 'omni tv $id volume <level>',
        'apps' =>
          'omni tv $id apps open|stop|clear-cache|clear-data|disable|enable|uninstall <package>',
        'install' => 'omni tv $id apps install <file.apk>',
        'settings' =>
          'omni tv $id settings set|delete <namespace> <key> [value]',
        'files' => 'omni tv $id files get|put|cp|mv|rm|mkdir|rename ...',
        _ => 'omni tv $id shell',
      };
      return refuse(
        'needs_user',
        'only the user can change $id: ask them to run $example on this computer, '
            'or to use the TV screen in the OmniFlow app',
      );
    },
  );
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
