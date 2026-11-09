import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/add_commands.dart';
import 'package:omniflow_engine/src/api/board_runtime.dart';
import 'package:omniflow_engine/src/api/command_args.dart';
import 'package:omniflow_engine/src/api/device_commands.dart';
import 'package:omniflow_engine/src/api/engine_core.dart';
import 'package:omniflow_engine/src/api/engine_flow_host.dart';
import 'package:omniflow_engine/src/api/hub_runtime.dart';
import 'package:omniflow_engine/src/api/pairing_commands.dart';
import 'package:omniflow_engine/src/api/stored_flows.dart';
import 'package:omniflow_engine/src/api/things_runtime.dart';
import 'package:omniflow_engine/src/devices/discovery/board_hellos.dart';
import 'package:omniflow_engine/src/devices/discovery/thing_finder.dart';

import '../devices/fake_mdns.dart';

/// The add commands on an engine core of their own, for commands the
/// engine's command table does not list yet. Every network method is a
/// loopback fake or off, and secrets stay in memory.
class AddHarness implements EngineConnection {
  AddHarness._(this.db, this.udp, this.secrets, this.core);

  static Future<AddHarness> open({
    MdnsDiscovery? mdns,
    TuyaDiscovery? tuya,
    List<InternetAddress> udpTargets = const [],
    SerialProbe? serial,
    RecentHellos? hellos,
    DriverRegistry? registry,
  }) async {
    final db = OmniDatabase.memory();
    final udp = await UdpTransport.bind();
    final secrets = InMemorySecretStore();
    final drivers = registry ?? DriverRegistry.withBuiltIns();
    final discovery = DeviceDiscovery(
      udp: UdpDiscovery(udp, targets: () async => udpTargets),
      tuya:
          tuya ??
          TuyaDiscovery(
            bind: (_) =>
                RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
          ),
      mdns: mdns ?? MdnsDiscovery(client: () => FakeMdns(const [])),
      tuyaMinimumWindow: const Duration(milliseconds: 200),
    );
    final serialChannel = SerialChannel();
    final udpJson = UdpJsonChannel(udp);
    final boardChannel = BoardChannel(udp: udpJson, serial: serialChannel);
    final http = HttpChannel(secrets: secrets);
    final tv = TvWebSocketChannel(secrets);
    final adb = AdbChannel(secrets);
    final core = EngineCore(
      db: db,
      registry: drivers,
      devices: DeviceService(
        registry: drivers,
        store: DriftDeviceStore(db),
        channels: {
          TransportType.udp: udpJson,
          TransportType.omniflow: boardChannel,
          TransportType.http: http,
          TransportType.websocket: tv,
          TransportType.adb: adb,
          TransportType.virtual: const VirtualChannel(),
        },
      ),
      secrets: secrets,
      discovery: discovery,
      tap: null,
      serial: serialChannel,
      mqtt: MqttChannel(secrets),
      boardChannel: boardChannel,
      http: http,
      tv: tv,
      adb: adb,
    );
    core.flows = FlowEngine(EngineFlowHost(core));
    final things = ThingsRuntime(core);
    final boards = BoardRuntime(core);
    final hub = HubRuntime(core, boards, things);
    final stored = StoredFlows(core, things);
    final deviceCommands = DeviceCommands(core, boards, hub, stored, things);
    final h = AddHarness._(db, udp, secrets, core);
    h.add = AddCommands(
      core,
      deviceCommands,
      finder: ThingFinder(
        discovery: discovery,
        serial: serial ?? (_, _) async => const [],
        hellos: hellos,
      ),
    );
    h.commands = {
      'thing.add': h.add.add,
      'thing.next': deviceCommands.next,
      'thing.configure': deviceCommands.configure,
      'device.add': deviceCommands.add,
      'device.get': deviceCommands.get,
      'device.remove': deviceCommands.remove,
      'device.pair': PairingCommands(core).pair,
      'secret.set': deviceCommands.secretSet,
      'driver.register': deviceCommands.driverRegister,
    };
    return h;
  }

  final OmniDatabase db;
  final UdpTransport udp;
  final InMemorySecretStore secrets;
  final EngineCore core;
  late final AddCommands add;
  late final Map<String, CommandHandler> commands;

  /// Runs a command the way `OmniEngine.handle` does: never throws.
  @override
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> args,
  ) async {
    final handler = commands[command];
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
    } on TvPairingException catch (e) {
      return _failure(ApiError('pairing_failed', e.message));
    }
  }

  static Map<String, Object?> _failure(ApiError e) => {
    'ok': false,
    'error': e.toJson(),
  };

  /// [handle], expecting success.
  Future<Map<String, Object?>> ok(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await handle(command, args);
    if (result['ok'] != true) {
      throw StateError('$command failed: $result');
    }
    return result;
  }

  @override
  Future<Stream<Map<String, Object?>>> events({bool packets = false}) async =>
      core.events;

  /// The CLI closes its connection after each command; the harness stays
  /// open until [shutdown].
  @override
  Future<void> close() async {}

  Future<void> shutdown() async {
    await core.settle();
    await core.flows.close();
    await core.serial.close();
    await core.tv.close();
    await core.adb.close();
    await core.mqtt.close();
    await core.devices.close();
    udp.close();
    await db.close();
    await core.closeEvents();
  }
}
