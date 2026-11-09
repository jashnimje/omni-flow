import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'add_commands.dart';
import 'api_error.dart';
import 'automation_commands.dart';
import 'board_commands.dart';
import 'board_runtime.dart';
import 'command_args.dart';
import 'device_commands.dart';
import 'engine_core.dart';
import 'engine_flow_host.dart';
import 'flow_commands.dart';
import 'host_key_commands.dart';
import 'hub_runtime.dart';
import 'link_commands.dart';
import 'nfc_tags.dart';
import 'pairing_commands.dart';
import 'state_commands.dart';
import 'stored_flows.dart';
import 'things_runtime.dart';
import '../dag/expression.dart';
import '../dag/flow_engine.dart';
import '../devices/adb/adb_channel.dart';
import '../devices/board.dart';
import '../devices/channels.dart';
import '../devices/device_service.dart';
import '../devices/discovery.dart';
import '../devices/discovery/mdns_discovery.dart';
import '../devices/discovery/tuya_broadcast.dart';
import '../devices/http_channel.dart';
import '../devices/mqtt_channel.dart';
import '../devices/serial_channel.dart';
import '../devices/tuya_channel.dart';
import '../devices/tv/tv_socket.dart';
import '../devices/tv/tv_channel.dart';
import '../devices/virtual_channel.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/driver_registry.dart';
import '../manifest/validation.dart';
import '../storage/database.dart';
import '../storage/secret_store.dart';
import '../template/template_renderer.dart';
import '../transports/host_exec.dart';
import '../transports/packet_tap.dart';
import '../transports/ssh_executor.dart';
import '../transports/udp_transport.dart';

export 'api_error.dart';

/// The engine behind one core API. Every caller (the CLI, the app's service,
/// later the MCP tools) sends a command name and a JSON object, and gets a
/// JSON object back: `{"ok": true, ...}` or `{"ok": false, "error": {...}}`.
class OmniEngine {
  OmniEngine._(
    this._core,
    this._lock,
    UdpTransport udp,
    TuyaChannel tuya,
    this._closers,
  ) : registry = _core.registry,
      devices = _core.devices,
      discovery = _core.discovery,
      serial = _core.serial {
    flows = _core.flows = FlowEngine(EngineFlowHost(_core));
    _inputs.addAll([
      serial.events.listen((e) => _boards.boardEvent(e.json, e.deviceId)),
      _core.mqtt.events.listen(
        (e) => _core.track(devices.applyPush(e.deviceId, e.state).then((_) {})),
      ),
      tuya.pushes.listen(
        (p) => _core.track(devices.applyPush(p.deviceId, p.body).then((_) {})),
      ),
      udp.incoming.listen((d) {
        final Object? json;
        try {
          json = jsonDecode(d.text);
        } on FormatException {
          return;
        }
        if (json is Map && json['node'] is String && json['event'] is String) {
          _core.track(
            _boards.udpBoardMessage(Map<String, Object?>.from(json), d.address),
          );
        }
      }),
      _core.events.listen(_addCommands.observe),
    ]);
    devices.events.listen(
      (e) => _core.emit({
        'event': 'device.stateChanged',
        'device': _core.deviceJson(e.device),
      }),
    );
    _core.tap?.stream.listen(
      (p) => _core.emit({
        'event': 'packet.captured',
        'transport': p.transport,
        'direction': p.direction.name,
        'remote': p.remote,
        'text': p.text,
        'at': p.timestamp.toUtc().toIso8601String(),
      }),
    );
  }

  /// Opens the engine whose data lives in [home]. Tests pass [mdns] and
  /// [tuyaDiscovery] so discovery and address healing stay off the network.
  static Future<OmniEngine> open({
    required Directory home,
    required SecretStore secrets,
    PacketTap? tap,
    Future<List<InternetAddress>> Function()? discoveryTargets,
    MdnsDiscovery? mdns,
    TuyaDiscovery? tuyaDiscovery,
  }) async {
    await home.create(recursive: true);
    final file = File('${home.path}/omniflow.sqlite');
    final lock = await DatabaseLock.acquire(file);
    OmniDatabase? db;
    UdpTransport? udp;
    OmniEngine? engine;
    // A failed open must not keep the lock, or every later open in this
    // process, and the CLI, hub and app, are locked out.
    try {
      db = OmniDatabase.file(file);
      final registry = DriverRegistry.withBuiltIns();
      final driverIssues = <Map<String, Object?>>[];
      for (final json in await DriftManifestStore(db).all()) {
        try {
          registry.register(jsonDecode(json));
        } catch (e) {
          driverIssues.add(loadIssue('driver', _idIn(json), e));
        }
      }
      udp = await UdpTransport.bind(tap: tap);
      final tuya = TuyaChannel(secrets, tap: tap);
      final serial = SerialChannel(tap: tap);
      final discovery = DeviceDiscovery(
        udp: UdpDiscovery(udp, targets: discoveryTargets),
        tuya: tuyaDiscovery ?? TuyaDiscovery(tap: tap),
        mdns: mdns,
      );
      final udpJson = UdpJsonChannel(udp);
      final mqtt = MqttChannel(secrets, tap: tap);
      final boardChannel = BoardChannel(udp: udpJson, serial: serial);
      final http = HttpChannel(tap: tap, secrets: secrets);
      final tv = TvWebSocketChannel(secrets, tap: tap);
      EngineCore? core;
      final adb = AdbChannel(
        secrets,
        onPairingPrompt: (id) => core?.emit({
          'event': 'device.pairingPrompt',
          'deviceId': id,
          'message': 'Look at the TV and choose Allow',
        }),
      );
      final devices = DeviceService(
        registry: registry,
        store: DriftDeviceStore(db),
        locator: discovery.locator,
        channels: {
          TransportType.udp: udpJson,
          TransportType.omniflow: boardChannel,
          TransportType.tuya: tuya,
          TransportType.http: http,
          TransportType.serial: serial,
          TransportType.exec: ExecChannel(hostExecutors(secrets)),
          TransportType.mqtt: mqtt,
          TransportType.websocket: tv,
          TransportType.adb: adb,
          TransportType.virtual: const VirtualChannel(),
        },
      );
      final socket = udp;
      engine = OmniEngine._(
        core = EngineCore(
          db: db,
          registry: registry,
          devices: devices,
          secrets: secrets,
          discovery: discovery,
          tap: tap,
          serial: serial,
          mqtt: mqtt,
          boardChannel: boardChannel,
          http: http,
          tv: tv,
          adb: adb,
        ),
        lock,
        socket,
        tuya,
        [
          () async => socket.close(),
          tuya.close,
          serial.close,
          mqtt.close,
          tv.close,
          adb.close,
          devices.close,
        ],
      );
      engine._core.issues['driver'] = driverIssues;
      await _backfillStableIds(engine._core);
      await engine._things.migrateZoneRows();
      await engine._things.reload(quiet: true);
      await engine._stored.migrateStored();
      await engine._stored.loadState();
      return engine;
    } catch (_) {
      if (engine != null) {
        await engine.close();
      } else {
        udp?.close();
        try {
          await db?.close();
        } finally {
          await lock.release();
        }
      }
      rethrow;
    }
  }

  /// Devices added before their driver read a stable id from a setting get
  /// it now, so address healing works for them too.
  static Future<void> _backfillStableIds(EngineCore core) async {
    final store = DriftDeviceStore(core.db);
    for (final d in await store.all()) {
      if (d.stableId != null) continue;
      final manifest = core.registry[d.driverId];
      final id = manifest == null
          ? null
          : stableIdFromSettings(manifest, d.settings);
      if (id != null) await store.put(d.copyWith(stableId: id));
    }
  }

  static Object? _idIn(String json) {
    try {
      final decoded = jsonDecode(json);
      return decoded is Map ? decoded['id'] : null;
    } on FormatException {
      return null;
    }
  }

  final EngineCore _core;
  final DatabaseLock _lock;
  final DriverRegistry registry;
  final DeviceService devices;
  final DeviceDiscovery discovery;
  final SerialChannel serial;
  final List<Future<void> Function()> _closers;
  final _inputs = <StreamSubscription<Object?>>[];
  late final FlowEngine flows;

  late final _boards = BoardRuntime(
    _core,
    capabilitiesChanged: () => _stored.reloadFlows(),
  );
  late final _things = ThingsRuntime(_core);
  late final _hub = HubRuntime(_core, _boards, _things);
  late final _stored = StoredFlows(_core, _things);
  late final _flowCommands = FlowCommands(_core, _stored);
  late final _linkCommands = LinkCommands(_core, _flowCommands);
  late final _automationCommands = AutomationCommands(
    _core,
    _stored,
    _flowCommands,
    _linkCommands,
  );
  late final _boardCommands = BoardCommands(_core, _boards);
  late final _deviceCommands = DeviceCommands(
    _core,
    _boards,
    _hub,
    _stored,
    _things,
  );
  late final _stateCommands = StateCommands(_core, _things, _deviceCommands);
  late final _hostKeyCommands = HostKeyCommands(_core);
  late final _pairingCommands = PairingCommands(_core);
  late final _addCommands = AddCommands(_core, _deviceCommands);
  late final _tagCommands = TagCommands(_core, _things, _deviceCommands);

  /// Stored records that could not be loaded, by kind (driver, zone, flow).
  /// They stay in the database and are reported, so one bad row never
  /// keeps the engine from opening.
  List<Map<String, Object?>> get loadIssues => _core.loadIssues;

  /// Everything the engine reports as it happens, as JSON messages:
  /// `device.stateChanged`, `wiz.firstBeat`, and `packet.captured` when the
  /// engine was opened with a packet tap.
  Stream<Map<String, Object?>> get events => _core.events;

  /// Brings a board to its configured pins: checks them against what the
  /// board offers, sets each mode, restores outputs from the remembered
  /// state, starts watching inputs, and seeds their state. Safe to repeat.
  /// A call while a setup is running waits for it and then runs once more,
  /// so pins saved meanwhile reach the board.
  Future<Map<String, Object?>> provisionBoard(String id) =>
      _boards.provisionBoard(id);

  /// Runs flows on their own: WiZ pushes, time and interval triggers, a zone
  /// tick every second, and each device's state poll. `omni hub` and the
  /// `hub.start` command call this. A second call while it runs does nothing.
  Future<void> startHub({
    int wizListenPort = 38900,
    int boardHelloPort = 38951,
  }) =>
      _hub.start(wizListenPort: wizListenPort, boardHelloPort: boardHelloPort);

  /// Stops what [startHub] started. Commands keep working.
  Future<void> stopHub() => _hub.stop();

  /// Starts live state from every WiZ device that has a stable id (its MAC).
  Future<int> startWizPush({int listenPort = 38900}) =>
      _hub.startWizPush(listenPort: listenPort);

  late final Map<String, CommandHandler> _commands = {
    'engine.status': (_) async => {
      'hubRunning': _hub.running,
      'flows': flows.loadedFlows.toList(),
      'loadIssues': loadIssues,
    },
    'hub.start': (args) async {
      // The long names match startHub's parameters.
      await startHub(
        wizListenPort:
            optIntArg(args, 'wizPort') ??
            optIntArg(args, 'wizListenPort') ??
            38900,
        boardHelloPort:
            optIntArg(args, 'helloPort') ??
            optIntArg(args, 'boardHelloPort') ??
            38951,
      );
      return {'running': true, 'flows': flows.loadedFlows.toList()};
    },
    'hub.stop': (_) async {
      await stopHub();
      return {'running': false};
    },
    'driver.list': _deviceCommands.driverList,
    'driver.validate': _deviceCommands.driverValidate,
    'driver.register': _deviceCommands.driverRegister,
    'device.add': _deviceCommands.add,
    'board.provision': _boardCommands.provision,
    'board.describe': _boardCommands.describe,
    'board.pins': _boardCommands.pins,
    'board.setup': _boardCommands.setup,
    'board.periph': _boardCommands.periph,
    ..._automationCommands.commands,
    'thing.add': _addCommands.add,
    'thing.next': _deviceCommands.next,
    'thing.configure': _deviceCommands.configure,
    'link.create': _linkCommands.create,
    'link.options': _linkCommands.options,
    'link.list': _linkCommands.list,
    'link.remove': _linkCommands.remove,
    'flow.validate': _flowCommands.validate,
    'flow.save': _flowCommands.save,
    'flow.approve': _flowCommands.approve,
    'flow.list': _flowCommands.list,
    'flow.get': _flowCommands.get,
    'flow.remove': _flowCommands.remove,
    'flow.enable': _flowCommands.enable,
    'flow.run': _flowCommands.run,
    'flow.dryRun': _flowCommands.dryRun,
    'flow.log': _flowCommands.log,
    'flow.cards': _flowCommands.cards,
    'command.interpret': _flowCommands.interpret,
    'var.list': _stateCommands.varList,
    'var.set': _stateCommands.varSet,
    'var.remove': _stateCommands.varRemove,
    'zone.save': _stateCommands.zoneSave,
    'zone.list': _stateCommands.zoneList,
    'zone.remove': _stateCommands.zoneRemove,
    'sensor.ble': _stateCommands.phoneBle,
    'sensor.wifi': _stateCommands.phoneWifi,
    'phone.wifi': _stateCommands.phoneWifi,
    'phone.ble': _stateCommands.phoneBle,
    'phone.battery': _stateCommands.phoneBattery,
    ..._tagCommands.commands,
    'device.discover': _deviceCommands.discover,
    'device.list': _deviceCommands.list,
    'device.get': _deviceCommands.get,
    'device.remove': _deviceCommands.remove,
    'device.invoke': _deviceCommands.invoke,
    'device.refresh': _deviceCommands.refresh,
    'device.pair': _pairingCommands.pair,
    'device.hostkey': _hostKeyCommands.hostKey,
    'secret.set': _deviceCommands.secretSet,
  };

  Iterable<String> get commandNames => _commands.keys;

  /// Runs [command] with [args]. Never throws: every failure becomes an error result.
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
    } on DeviceNotFoundException catch (e) {
      return _failure(ApiError('not_found', e.message));
    } on TransportTimeoutException catch (e) {
      return _failure(ApiError('timeout', e.message));
    } on PairingRequiredException catch (e) {
      return _failure(ApiError('needs_user', e.message));
    } on TvCertificateMismatchException catch (e) {
      return _failure(ApiError('certificate_mismatch', e.message));
    } on AdbPairingException catch (e) {
      return _failure(ApiError('pairing_failed', e.message));
    } on TvPairingException catch (e) {
      return _failure(ApiError('pairing_failed', e.message));
    } on LinkButtonNotPressedException catch (e) {
      return _failure(ApiError('pairing_failed', e.message));
    } on SecretRejectedException catch (e) {
      return _failure(ApiError('secret_rejected', e.message));
    } on HostKeyMismatchException catch (e) {
      return _failure(hostKeyError(e));
    } on CommandFailedException catch (e) {
      return _failure(ApiError('device_error', e.message));
    } on MissingSecretException catch (e) {
      return _failure(
        ApiError(
          'missing_secret',
          'no secret stored for ${e.key}. Set it with omni secret set',
        ),
      );
    } on CommandTimeoutException catch (e) {
      return _failure(ApiError('timeout', e.toString()));
    } on TemplateException catch (e) {
      return _failure(ApiError('template', e.message));
    } on ArgumentError catch (e) {
      return _failure(ApiError('invalid', '${e.message}'));
    } on StateError catch (e) {
      return _failure(ApiError('not_ready', e.message));
    } on ExpressionException catch (e) {
      return _failure(ApiError('invalid', e.message));
    } catch (e) {
      return _failure(ApiError('internal', '$e'));
    }
  }

  static Map<String, Object?> _failure(ApiError e) => {
    'ok': false,
    'error': e.toJson(),
  };

  /// Stops the inputs first so nothing new starts, waits for the work in
  /// flight, then closes the database and releases the lock whatever failed.
  Future<void> close() async {
    try {
      await _hub.shutdown();
      for (final s in _inputs) {
        await s.cancel();
      }
      await flows.close();
      await _core.settle();
      for (final close in _closers) {
        try {
          await close();
        } catch (_) {
          // The database and lock still have to be released.
        }
      }
    } finally {
      try {
        await _core.db.close();
      } finally {
        await _lock.release();
        await _core.closeEvents();
      }
    }
  }
}
