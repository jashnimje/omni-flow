import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'add_commands.dart';
import 'agent_policy.dart';
import 'android_pair_commands.dart';
import 'api_error.dart';
import 'automation_commands.dart';
import 'backup_commands.dart';
import 'board_commands.dart';
import 'board_runtime.dart';
import 'command_args.dart';
import 'device_commands.dart';
import 'engine_core.dart';
import 'engine_flow_host.dart';
import 'error_of.dart';
import 'flow_commands.dart';
import 'home_commands.dart';
import 'house_helpers.dart';
import 'home_stats_commands.dart';
import 'host_key_commands.dart';
import 'hub_runtime.dart';
import 'link_commands.dart';
import 'nfc_tags.dart';
import 'organize_commands.dart';
import 'pairing_commands.dart';
import 'rule_parse.dart';
import 'suggestions.dart';
import 'rules_core_commands.dart';
import 'phone_actions.dart';
import 'smart_home.dart';
import 'state_commands.dart';
import 'stored_flows.dart';
import 'things_runtime.dart';
import 'tv_commands.dart';
import 'tv_pointer_commands.dart';
import '../dag/flow_engine.dart';
import '../devices/adb/adb_channel.dart';
import '../devices/board.dart';
import '../devices/channels.dart';
import '../devices/device_service.dart';
import '../devices/discovery.dart';
import '../devices/discovery/mdns_discovery.dart';
import '../devices/discovery/thing_finder.dart' show renamedOldDefaultName;
import '../devices/discovery/tuya_broadcast.dart';
import '../devices/http_channel.dart';
import '../devices/mqtt_channel.dart';
import '../devices/serial_channel.dart';
import '../devices/tuya_channel.dart';
import '../devices/tv/tv_channel.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/driver_registry.dart';
import '../manifest/validation.dart' show ValidationIssue;
import '../storage/database.dart';
import '../storage/secret_store.dart';
import '../transports/packet_tap.dart';
import '../transports/udp_transport.dart';
import '../version.dart';

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
    flows.asks.personOf = _things.personOfThing;
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
    devices.events.listen(_core.history.record);
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
    SerialLinks? serialLinks,
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
      final serial = SerialChannel(tap: tap, links: serialLinks);
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
      final phone = PhoneActions();
      final adb = AdbChannel(
        secrets,
        onPairingPrompt: (id) => core?.emit({
          'event': 'device.pairingPrompt',
          'deviceId': id,
          'message': 'Look at the TV and choose Allow',
        }),
        locateTls: (guid) => locateAdbTlsConnect(discovery.mdns, guid),
        onMoved: (id, host, port) async {
          if (core case final c?) await recordAdbMove(c, id, host, port);
        },
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
          TransportType.virtual: PhoneChannel(phone),
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
          phone.close,
        ],
      );
      engine._phone = phone;
      phone.attach(
        engine._core,
        engine._things,
        runScene: (id) => engine!.handle('scene.run', {'id': id}),
      );
      engine._agentAccess = AgentAccessStore(home);
      engine._homeLocation = HomeLocationStore(home);
      engine.flows.homeLocation = await engine._homeLocation.read();
      final built = engine;
      built._smartHome = SmartHome(
        built._core,
        home,
        hubRunning: () => built._hub.running,
        call: built.handle,
      );
      await built._smartHome.load();
      built._closers.add(built._smartHome.close);
      engine._core.issues['driver'] = driverIssues;
      engine._core.agentDrivers.addAll(await DriftManifestStore(db).byAgent());
      await engine._core.loadRooms();
      await engine._core.history.seed();
      await _backfillStableIds(engine._core);
      await _renameOldDefaultNames(engine._core);
      await engine._things.migrateZoneRows();
      await engine._things.reload(quiet: true, restore: true);
      await engine._stored.migrateStored();
      await engine._stored.loadState();
      engine._house = await HouseHelpers.open(
        engine._core,
        home,
        engine._stored,
        engine._automationCommands,
      );
      engine._closers.add(engine._house.close);
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

  /// Things added before finds were named by what they are still carry the
  /// old default, a driver name with an id suffix or an adb instance. Those
  /// names, and only those, get today's name. A name the user typed never
  /// matches the old default, so it stays.
  static Future<void> _renameOldDefaultNames(EngineCore core) async {
    final store = DriftDeviceStore(core.db);
    for (final d in await store.all()) {
      final manifest = core.registry[d.driverId];
      if (manifest == null) continue;
      final name = renamedOldDefaultName(manifest, d);
      if (name != null) await store.put(d.copyWith(name: name));
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
  late final _hub = HubRuntime(
    _core,
    _boards,
    _things,
    tvPoll: (id) => _tvCommands.poll(id),
  );
  late final _tvCommands = TvCommands(_core, _stored);
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
  late final _organizeCommands = OrganizeCommands(_core);
  late final HouseHelpers _house;
  late final HomeLocationStore _homeLocation;
  late final SmartHome _smartHome;
  late final _homeCommands = HomeCommands(_core, _stored, _homeLocation);
  late final _backupCommands = BackupCommands(
    _core,
    _stored,
    _things,
    _homeCommands,
    removeThing: (id) async {
      await _deviceCommands.remove({'id': id});
    },
    resetThing: (id) {
      _hub.stopLive(id);
      _boards.markNotSetUp(id);
      _core.tv.forget(id);
      _core.adb.forget(id);
    },
    house: _house,
  );

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

  late final AgentAccessStore _agentAccess;
  late final PhoneActions _phone;

  /// A capability that would make a flow wait for approval (a host
  /// command, a TV setting or an app's data) is the user's to run.
  Future<void> _refuseHighRiskInvoke(Map<String, Object?> args) async {
    final device = await _core.device(stringArg(args, 'id'));
    final manifest = _core.registry[device.driverId];
    final capability = manifest?.capability(stringArg(args, 'capability'));
    if (manifest == null || capability == null) return;
    if (manifest.isHighRisk ||
        _stored.capabilityIsHighRisk(manifest, capability)) {
      throw ApiError(
        'needs_user',
        '${capability.id} on ${device.id} is high risk, so only you can '
            'run it. An automation that does it waits for your approval',
      );
    }
  }

  late final Map<String, CommandHandler> _commands = {
    // What an agent may do, and the commands each level opens. Setting it
    // is the user's: MCP refuses agent.access.set.
    'agent.access': (_) async => {
      'access': (await _agentAccess.read()).name,
      'levels': {
        for (final a in AgentAccess.values)
          a.name: a == AgentAccess.read
              ? 'read everything, try rules out, save automations that wait '
                    'for you where they are high risk'
              : 'also find, add, configure and organize things, places, '
                    'rooms, tags and scenes, and save, enable, run and remove '
                    'automations',
      },
      'readCommands': agentReadCommands.toList()..sort(),
      'setupCommands': agentSetupCommands.toList()..sort(),
      'userOnly': agentUserOnly,
    },
    'agent.access.set': (args) async {
      final access = AgentAccess.parse(args['access']);
      if (access == null) {
        throw ApiError(
          'invalid',
          'access must be ${AgentAccess.values.map((a) => a.name).join(' or ')}',
        );
      }
      await _agentAccess.write(access);
      _core.emit({'event': 'agent.accessChanged', 'access': access.name});
      return {'access': access.name};
    },
    // One command an agent sends for any other, under its access level:
    // refused with needs_user and the reason, or run with the arguments an
    // agent never chooses (untrusted saves, no pairing prompts).
    'agent.call': (args) async {
      final command = stringArg(args, 'command');
      final inner = args['args'] == null
          ? const <String, Object?>{}
          : objectArg(args, 'args');
      if (command.startsWith('agent.') &&
          command != 'agent.access' &&
          command != 'agent.describe') {
        throw ApiError(
          'needs_user',
          '$command cannot be called through agent.call',
        );
      }
      final why = agentRefusal(command, inner, await _agentAccess.read());
      if (why != null) throw ApiError('needs_user', why);
      if (command == 'device.invoke') await _refuseHighRiskInvoke(inner);
      // The engine's state decides these: a high-risk automation runs only
      // when the user starts it, and the globals it reads are not an agent's
      // to set.
      if (command == 'automation.run' ||
          command == 'scene.run' ||
          command == 'var.set' ||
          command == 'var.remove' ||
          command == 'device.discover') {
        final risk = await _stored.riskSummary();
        if ((command == 'automation.run' || command == 'scene.run') &&
            risk.flows.contains(inner['id'])) {
          throw ApiError(
            'needs_user',
            '${inner['id']} is high risk (it runs commands on a device), so '
                'only you can run it',
          );
        }
        if (command.startsWith('var.') &&
            risk.globals.contains(inner['name'])) {
          throw ApiError(
            'needs_user',
            '${inner['name']} is read by a high-risk automation, so only you '
                'can change it',
          );
        }
        final driver = _core.registry['${inner['driver']}'];
        if (command == 'device.discover' &&
            driver?.transport.type == TransportType.serial) {
          throw ApiError(
            'needs_user',
            'finding a USB device opens its port, which resets the board',
          );
        }
      }
      final result = await handle(command, agentArgs(command, inner));
      if (result['ok'] != true) {
        final error = result['error'] as Map;
        // The issues carry the paths an agent fixes, so they go back too.
        throw ApiError(
          '${error['type']}',
          '${error['message']}',
          issues: [
            for (final i in (error['issues'] as List? ?? const []))
              if (i is Map) ValidationIssue('${i['path']}', '${i['message']}'),
          ],
        );
      }
      return {...result}..remove('ok');
    },
    // Everything an agent needs to plan a change, in one reply.
    'agent.describe': (_) async {
      Future<Object?> read(String command, [String? key]) async {
        final r = await handle(command, const {});
        if (r['ok'] != true) return {'error': r['error']};
        return key == null ? ({...r}..remove('ok')) : r[key];
      }

      final automations = await handle('automation.list', const {});
      return {
        'engine': await read('engine.status'),
        'agentAccess': await read('agent.access'),
        'things': await read('device.list', 'devices'),
        'rooms': await read('room.list', 'rooms'),
        'places': await read('zone.list'),
        'tags': await read('tag.list'),
        'scenes': await read('scene.list'),
        'variables': await read('var.list'),
        // Whether sun rules can be saved, without saying where home is.
        'homeLocationSet': flows.homeLocation != null,
        'automations': [
          for (final a in (automations['automations'] as List? ?? const []))
            if (a is Map)
              {
                ...a,
                'spec': (await handle('automation.get', {
                  'id': a['id'],
                }))['spec'],
              },
        ],
        'templates': await read('automation.templates', 'templates'),
        'drivers': [
          for (final d
              in (await handle('driver.list', const {}))['drivers'] as List? ??
                  const [])
            if (d is Map)
              {
                for (final k in [
                  'id',
                  'name',
                  'category',
                  'transport',
                  'discovery',
                  'pairing',
                  'settings',
                  'secrets',
                  'capabilities',
                ])
                  if (d[k] != null) k: d[k],
              },
        ],
      };
    },
    'engine.status': (_) async => {
      'version': omniflowEngineVersion,
      'startedAt': _openedAt.toUtc().toIso8601String(),
      'uptimeSeconds': DateTime.now().difference(_openedAt).inSeconds,
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
    'hub.clients': _hub.clientList,
    'hub.discover': _hub.discover,
    'hub.stop': (_) async {
      await stopHub();
      return {'running': false};
    },
    'driver.list': _deviceCommands.driverList,
    'driver.validate': _deviceCommands.driverValidate,
    'driver.register': _deviceCommands.driverRegister,
    'driver.approve': _deviceCommands.driverApprove,
    'device.add': _deviceCommands.add,
    'board.provision': _boardCommands.provision,
    'board.describe': _boardCommands.describe,
    'board.pins': _boardCommands.pins,
    'board.setup': _boardCommands.setup,
    'board.flash': _boardCommands.flash,
    'board.ports': _boardCommands.ports,
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
    'phone.app': _stateCommands.phoneApp,
    'phone.notification': _stateCommands.phoneNotification,
    'phone.bluetooth': _stateCommands.phoneBluetooth,
    'phone.screen': _stateCommands.phoneScreen,
    'phone.dnd': _stateCommands.phoneDnd,
    ..._phone.commands,
    ..._tagCommands.commands,
    'device.discover': _deviceCommands.discover,
    'device.list': _deviceCommands.list,
    'device.get': _deviceCommands.get,
    'device.remove': _deviceCommands.remove,
    'device.invoke': _deviceCommands.invoke,
    'device.refresh': _deviceCommands.refresh,
    'device.pair': _pairingCommands.pair,
    'device.hostkey': _hostKeyCommands.hostKey,
    'device.history': _core.history.history,
    ..._organizeCommands.commands,
    ..._house.commands,
    'presence.set': _stateCommands.presenceSet,
    ..._homeCommands.commands,
    ...HomeStatsCommands(_core).commands,
    ...SuggestionCommands(_core, _automationCommands).commands,
    ...RuleParseCommands(_core, _automationCommands).commands,
    ..._smartHome.commands,
    ..._backupCommands.commands,
    'secret.set': _deviceCommands.secretSet,
    'web.secret.set': _deviceCommands.webSecretSet,
    ..._tvCommands.commands,
    ...TvPointerCommands(_core, _tvCommands).commands,
    ...AndroidPairCommands(_core).commands,
    // Last: it keeps a version on every save, so it takes over the save
    // commands above and passes each one on.
    ...RulesCoreCommands(
      _core,
      _automationCommands,
      _flowCommands,
      _linkCommands,
    ).commands,
  };

  /// When this engine opened, for the uptime `engine.status` reports.
  final _openedAt = DateTime.now();

  Iterable<String> get commandNames => _commands.keys;

  /// Who is connected to the hub's control socket.
  HubClients get hubClients => _hub.clients;

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
    } catch (e) {
      return _failure(apiErrorOf(e));
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
