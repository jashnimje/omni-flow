import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/automation_commands.dart';
import 'package:omniflow_engine/src/api/command_args.dart';
import 'package:omniflow_engine/src/api/engine_core.dart';
import 'package:omniflow_engine/src/api/engine_flow_host.dart';
import 'package:omniflow_engine/src/api/flow_commands.dart';
import 'package:omniflow_engine/src/api/link_commands.dart';
import 'package:omniflow_engine/src/api/stored_flows.dart';
import 'package:omniflow_engine/src/api/things_runtime.dart';

/// The automation, flow and link commands on an engine core of their own,
/// over a database file in [home], so they run before the engine's command
/// table lists `automation.*`. It is an [EngineConnection], so the MCP
/// server and the CLI can drive it too.
class AutomationHarness implements EngineConnection {
  AutomationHarness._(this.home, this.db, this._udp, this.core) {
    core.flows = FlowEngine(EngineFlowHost(core));
    core.devices.events.listen(
      (e) => core.emit({
        'event': 'device.stateChanged',
        'device': core.deviceJson(e.device),
      }),
    );
    final things = ThingsRuntime(core);
    stored = StoredFlows(core, things);
    flowCommands = FlowCommands(core, stored);
    linkCommands = LinkCommands(core, flowCommands);
    automations = AutomationCommands(core, stored, flowCommands, linkCommands);
    _commands = {
      ...automations.commands,
      // An agent the user allowed to set up: its saves come untrusted, as
      // OmniEngine's agent.call sends them, with the issues kept.
      'agent.call': (args) async {
        final command = stringArg(args, 'command');
        final inner = Map<String, Object?>.from(
          args['args'] as Map? ?? const {},
        );
        final result = await handle(command, agentArgs(command, inner));
        if (result['ok'] != true) {
          final error = result['error'] as Map;
          throw ApiError(
            '${error['type']}',
            '${error['message']}',
            issues: [
              for (final i in (error['issues'] as List? ?? const []))
                if (i is Map)
                  ValidationIssue('${i['path']}', '${i['message']}'),
            ],
          );
        }
        return {...result}..remove('ok');
      },
      'flow.save': flowCommands.save,
      'flow.get': flowCommands.get,
      'flow.list': flowCommands.list,
      'flow.enable': flowCommands.enable,
      'flow.remove': flowCommands.remove,
      'link.create': linkCommands.create,
      'link.list': linkCommands.list,
      'link.remove': linkCommands.remove,
    };
  }

  /// The household: a lamp, a host that runs commands, a person, two
  /// places and an NFC tag.
  static const things = [
    Device(
      id: 'lamp',
      name: 'Lamp',
      driverId: 'philips_wiz_udp',
      host: '127.0.0.1',
      state: {'state': false, 'dimming': 10},
    ),
    // TEST-NET: a broken guard fails to connect instead of running here.
    Device(
      id: 'mac_mini',
      name: 'Mac',
      driverId: 'macos_host',
      host: '192.0.2.1',
    ),
    Device(
      id: 'jade',
      name: 'Jade',
      driverId: personDriverId,
      host: virtualHost,
      state: {'home': false, 'place': null},
    ),
    Device(
      id: 'home',
      name: 'Home',
      driverId: placeDriverId,
      host: virtualHost,
    ),
    Device(
      id: 'office',
      name: 'Office',
      driverId: placeDriverId,
      host: virtualHost,
      settings: {'zone': 'work'},
    ),
    Device(
      id: 'front_door',
      name: 'Front door',
      driverId: nfcTagDriverId,
      host: virtualHost,
      settings: {'uid': '04A22B1C'},
    ),
  ];

  /// Opens the harness on [home], adding [things] to a new database.
  static Future<AutomationHarness> open(
    Directory home, {
    bool addThings = true,
  }) async {
    final db = OmniDatabase.file(File('${home.path}/omniflow.sqlite'));
    if (addThings) {
      for (final d in things) {
        await DriftDeviceStore(db).put(d);
      }
    }
    final udp = await UdpTransport.bind();
    final secrets = InMemorySecretStore();
    final registry = DriverRegistry.withBuiltIns();
    final serial = SerialChannel();
    final udpJson = UdpJsonChannel(udp);
    final core = EngineCore(
      db: db,
      registry: registry,
      devices: DeviceService(
        registry: registry,
        store: DriftDeviceStore(db),
        channels: {TransportType.virtual: const VirtualChannel()},
      ),
      secrets: secrets,
      discovery: DeviceDiscovery(udp: UdpDiscovery(udp)),
      tap: null,
      serial: serial,
      mqtt: MqttChannel(secrets),
      boardChannel: BoardChannel(udp: udpJson, serial: serial),
      http: HttpChannel(secrets: secrets),
      tv: TvWebSocketChannel(secrets),
      adb: AdbChannel(secrets),
    );
    final harness = AutomationHarness._(home, db, udp, core);
    await harness.stored.migrateStored();
    await harness.stored.loadState();
    return harness;
  }

  final Directory home;
  final OmniDatabase db;
  final UdpTransport _udp;
  final EngineCore core;
  late final StoredFlows stored;
  late final FlowCommands flowCommands;
  late final LinkCommands linkCommands;
  late final AutomationCommands automations;
  late final Map<String, CommandHandler> _commands;

  /// Like `OmniEngine.handle`: never throws.
  @override
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> args,
  ) async {
    final handler = _commands[command];
    if (handler == null) {
      return _failure(ApiError('unknown_command', 'no command $command'));
    }
    try {
      return {'ok': true, ...await handler(args)};
    } on ApiError catch (e) {
      return _failure(e);
    } on ValidationException catch (e) {
      return _failure(ApiError('invalid', e.subject, issues: e.issues));
    } on ArgumentError catch (e) {
      return _failure(ApiError('invalid', '${e.message}'));
    } on StateError catch (e) {
      return _failure(ApiError('not_ready', e.message));
    }
  }

  static Map<String, Object?> _failure(ApiError e) => {
    'ok': false,
    'error': e.toJson(),
  };

  @override
  Future<Stream<Map<String, Object?>>> events({bool packets = false}) async =>
      core.events;

  /// The harness stays open across CLI commands, which close their
  /// connection after each one; [shutdown] closes it.
  @override
  Future<void> close() async {}

  Future<void> shutdown() async {
    await core.flows.close();
    await core.settle();
    await core.devices.close();
    _udp.close();
    await db.close();
    await core.closeEvents();
  }
}
