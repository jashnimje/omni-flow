import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_bar.dart';
import '../devices/board.dart';
import '../devices/channels.dart';
import '../devices/device.dart';
import '../devices/device_service.dart';
import '../devices/discovery.dart';
import '../devices/http_channel.dart';
import '../devices/serial_channel.dart';
import '../devices/tuya_channel.dart';
import '../dag/cards.dart';
import '../dag/expression.dart';
import '../dag/flow.dart';
import '../dag/flow_engine.dart';
import '../dag/links.dart';
import '../dag/node_types.dart';
import '../dag/validator.dart';
import '../devices/wiz_push.dart';
import '../zones/zones.dart';
import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/driver_registry.dart';
import '../manifest/validation.dart';
import '../storage/database.dart';
import '../storage/secret_store.dart';
import '../template/template_renderer.dart';
import '../transports/host_exec.dart';
import '../transports/packet_tap.dart';
import '../transports/udp_transport.dart';

/// A failure the core API reports as a result instead of throwing.
class ApiError implements Exception {
  ApiError(this.type, this.message, {this.issues = const []});

  final String type;
  final String message;
  final List<ValidationIssue> issues;

  Map<String, Object?> toJson() => {
    'type': type,
    'message': message,
    if (issues.isNotEmpty) 'issues': issues.map((i) => i.toJson()).toList(),
  };
}

/// The engine behind one core API. Every caller (the CLI, the app's service,
/// later the MCP tools) sends a command name and a JSON object, and gets a
/// JSON object back: `{"ok": true, ...}` or `{"ok": false, "error": {...}}`.
class OmniEngine {
  OmniEngine._(
    this._db,
    this._lock,
    this.registry,
    this.devices,
    this._secrets,
    this.discovery,
    this._tap,
    this.serial,
    this._udp,
    this._closers,
  ) {
    flows = FlowEngine(_EngineFlowHost(this));
    serial.events.listen((e) => _boardEvent(e.json, e.deviceId));
    _udp.incoming.listen((d) {
      final Object? json;
      try {
        json = jsonDecode(d.text);
      } on FormatException {
        return;
      }
      if (json is Map && json['node'] is String && json['event'] is String) {
        _boardEvent(Map<String, Object?>.from(json), null, d.address.address);
      }
    });
    devices.events.listen(
      (e) => _emit({
        'event': 'device.stateChanged',
        'device': _deviceJson(e.device),
      }),
    );
    _tap?.stream.listen(
      (p) => _emit({
        'event': 'packet.captured',
        'transport': p.transport,
        'direction': p.direction.name,
        'remote': p.remote,
        'text': p.text,
        'at': p.timestamp.toUtc().toIso8601String(),
      }),
    );
  }

  /// Opens the engine whose data lives in [home].
  static Future<OmniEngine> open({
    required Directory home,
    required SecretStore secrets,
    PacketTap? tap,
    Future<List<InternetAddress>> Function()? discoveryTargets,
  }) async {
    await home.create(recursive: true);
    final file = File('${home.path}/omniflow.sqlite');
    final lock = await DatabaseLock.acquire(file);
    final db = OmniDatabase.file(file);
    final registry = DriverRegistry.withBuiltIns();
    for (final json in await DriftManifestStore(db).all()) {
      registry.register(jsonDecode(json));
    }
    final udp = await UdpTransport.bind(tap: tap);
    final tuya = TuyaChannel(secrets, tap: tap);
    final serial = SerialChannel(tap: tap);
    final discovery = UdpDiscovery(udp, targets: discoveryTargets);
    final udpJson = UdpJsonChannel(udp);
    final devices = DeviceService(
      registry: registry,
      store: DriftDeviceStore(db),
      locator: discovery.locator,
      channels: {
        TransportType.udp: udpJson,
        TransportType.omniflow: BoardChannel(udp: udpJson, serial: serial),
        TransportType.tuya: tuya,
        TransportType.http: HttpChannel(tap: tap),
        TransportType.serial: serial,
        TransportType.exec: ExecChannel(hostExecutors(secrets)),
      },
    );
    final engine = OmniEngine._(
      db,
      lock,
      registry,
      devices,
      secrets,
      discovery,
      tap,
      serial,
      udp,
      [() async => udp.close(), tuya.close, serial.close, devices.close],
    );
    await engine._loadFlowState();
    return engine;
  }

  final OmniDatabase _db;
  final DatabaseLock _lock;
  final DriverRegistry registry;
  final DeviceService devices;
  final SecretStore _secrets;
  final UdpDiscovery discovery;
  final PacketTap? _tap;
  final SerialChannel serial;
  final UdpTransport _udp;
  final List<Future<void> Function()> _closers;
  late final FlowEngine flows;
  final _hubTimers = <Timer>[];

  /// Unsolicited board lines (button presses, knob turns) become
  /// `board.event`. Replies (ack, error, describe) are not events. A pin
  /// change, a hello or a boot from an OmniFlow board also updates that
  /// board's device. [from] is the sender's address for a UDP message.
  void _boardEvent(
    Map<String, Object?> json,
    String? deviceId, [
    String? from,
  ]) {
    final type = json['event'];
    if (type is! String || const {'ack', 'error', 'describe'}.contains(type)) {
      return;
    }
    _emit({
      'event': 'board.event',
      'type': type,
      'node': json['node'],
      'deviceId': ?deviceId,
      'payload': json,
    });
    _track(_onBoardMessage(json, deviceId, from));
  }

  final _pending = <Future<void>>{};

  /// Runs background work so a failure becomes an event, and so close()
  /// waits for it instead of closing the database under it.
  void _track(Future<void> work) {
    final tracked = work.catchError((Object e) {
      _emit({'event': 'board.error', 'error': '$e'});
    });
    _pending.add(tracked);
    tracked.whenComplete(() => _pending.remove(tracked));
  }

  Future<void> _onBoardMessage(
    Map<String, Object?> json,
    String? deviceId,
    String? from,
  ) async {
    final type = json['event'];
    final device = deviceId != null
        ? await DriftDeviceStore(_db).get(deviceId)
        : await _boardByNode(json['node']);
    if (type == 'hello') return _onHello(json, device, from);
    if (device == null) return;
    final manifest = registry[device.driverId];
    if (!isBoardDriver(manifest)) return;
    if (type == 'boot') {
      await provisionBoard(device.id);
    } else if (type == 'pin.changed') {
      final value = json['value'];
      final pin = boardPinsOf(
        device,
        manifest!,
      ).where((p) => p.pin == json['pin']).firstOrNull;
      if (pin == null || value is! num) return;
      await devices.mergeState(device.id, {pin.name: pin.stateValue(value)});
    }
  }

  Future<Device?> _boardByNode(Object? node) async {
    if (node is! String) return null;
    for (final d in await DriftDeviceStore(_db).all()) {
      if (isBoardDriver(registry[d.driverId]) &&
          d.stableId?.toLowerCase() == node.toLowerCase()) {
        return d;
      }
    }
    return null;
  }

  final _provisioned = <String>{};
  final _boardUptime = <String, int>{};
  final _provisioning = <String, Future<Map<String, Object?>>>{};

  /// A board says hello at boot and every 30 seconds. A new board is
  /// reported as `board.found`. A known one gets its address updated if it
  /// moved, and its pins set up again when this engine has not set it up yet
  /// or the board has lost its setup (it reports how many pins are `set`, 0
  /// after a reboot). Otherwise a describe keeps this engine its event target.
  Future<void> _onHello(
    Map<String, Object?> json,
    Device? device,
    String? from,
  ) async {
    if (from == null) return;
    final port = json['port'] is int ? json['port'] as int : null;
    if (device == null) {
      _emit({
        'event': 'board.found',
        'node': json['node'],
        'board': json['board'],
        'host': from,
        'port': ?port,
      });
      return;
    }
    var d = device;
    final defaultPort = registry[d.driverId]?.transport.port;
    final wantPort = port == defaultPort ? null : port;
    if (!isSerialHost(d.host) && (d.host != from || d.port != wantPort)) {
      d = await devices.updateDevice(
        d.id,
        (old) => Device(
          id: old.id,
          name: old.name,
          driverId: old.driverId,
          host: from,
          port: wantPort,
          room: old.room,
          stableId: old.stableId,
          settings: old.settings,
          state: old.state,
          lastSeen: old.lastSeen,
        ),
      );
    }
    final up = json['up'];
    final before = _boardUptime[d.id];
    if (up is int) _boardUptime[d.id] = up;
    final lostSetup =
        json['set'] == 0 && boardPinsOf(d, registry[d.driverId]!).isNotEmpty;
    final rebooted = up is int && before != null && up < before;
    if (!_provisioned.contains(d.id) || lostSetup || rebooted) {
      await provisionBoard(d.id);
    } else {
      await devices.sendCommand(d.id, const {'cmd': 'describe'});
      await devices.mergeState(d.id, const {});
    }
  }

  /// Brings a board to its configured pins: checks them against what the
  /// board offers, sets each mode, restores outputs from the remembered
  /// state, starts watching inputs, and seeds their state. Safe to repeat.
  Future<Map<String, Object?>> provisionBoard(String id) =>
      _provisioning[id] ??= _provision(id).whenComplete(() {
        _provisioning.remove(id);
      });

  Future<Map<String, Object?>> _provision(String id) async {
    final device = await _device(id);
    final manifest = registry[device.driverId];
    if (!isBoardDriver(manifest)) {
      throw ApiError('invalid', '$id is not an OmniFlow board');
    }
    final pins = boardPinsOf(device, manifest!);
    final describe =
        (await devices.sendCommand(id, const {'cmd': 'describe'})).json ??
        const {};
    final problems = pinsUnsupportedBy(pins, describe);
    if (problems.isNotEmpty) throw ApiError('invalid', problems.join('; '));
    final node = describe['node'];
    if (device.stableId == null && node is String) {
      await devices.updateDevice(id, (d) => d.copyWith(stableId: node));
    }
    final current = await _device(id);
    final seeded = <String, Object?>{};
    for (final command in pinSetupCommands(pins, current.state)) {
      final reply = (await devices.sendCommand(id, command)).json;
      final value = reply?['value'];
      if (command['cmd'] == 'pin.watch' && value is num) {
        final pin = pins.firstWhere((p) => p.pin == command['pin']);
        seeded[pin.name] = pin.stateValue(value);
      }
    }
    final updated = await devices.mergeState(id, seeded);
    _provisioned.add(id);
    return {
      'id': id,
      'board': describe['board'],
      'fw': describe['fw'],
      'pins': [for (final p in pins) p.name],
      'state': updated.state,
    };
  }

  Future<void> _loadFlowState() async {
    flows.globals.addAll(await DriftGlobalStore(_db).all());
    for (final d in await DriftDeviceStore(_db).all()) {
      flows.deviceStates[d.id] = d.state;
    }
    flows.setZones([
      for (final z in await DriftZoneStore(_db).all()) ZoneSpec.parse(z),
    ]);
    await _reloadFlows();
  }

  Future<void> _reloadFlows() async {
    flows.load([
      for (final r in await DriftFlowStore(_db).all())
        if (r.enabled && r.approved) FlowSpec.parse(r.json),
    ]);
  }

  Future<FlowReferences> _references() async {
    final devices = {
      for (final d in await DriftDeviceStore(_db).all())
        d.id: manifestFor(registry, d),
    };
    return FlowReferences(
      devices: devices.keys.toSet(),
      zones: {
        for (final z in await DriftZoneStore(_db).all()) z['id'] as String,
      },
      flows: {
        for (final f in await DriftFlowStore(_db).all()) f.json['id'] as String,
      },
      capabilityOf: (d, c) => devices[d]?.capability(c),
    );
  }

  /// True when a flow drives a device whose driver runs host commands.
  Future<bool> _isHighRisk(FlowSpec flow) async {
    final devices = {
      for (final d in await DriftDeviceStore(_db).all()) d.id: d.driverId,
    };
    return flow.nodes.any(
      (n) =>
          (n.type == 'device_capability' || n.type == 'device_toggle') &&
          (registry[devices[n.config['deviceId']] ?? '']?.isHighRisk ?? false),
    );
  }

  /// Runs flows on their own: WiZ pushes, time and interval triggers, a zone
  /// tick every second, and each device's state poll. `omni hub` calls this.
  Future<void> startHub({
    int wizListenPort = 38900,
    int boardHelloPort = 38951,
  }) async {
    await startWizPush(listenPort: wizListenPort);
    if (boardHelloPort > 0) await _listenForHellos(boardHelloPort);
    for (final d in await DriftDeviceStore(_db).all()) {
      if (isBoardDriver(registry[d.driverId])) _track(_provisionQuietly(d.id));
    }
    flows.startTimers();
    _hubTimers.add(
      Timer.periodic(
        const Duration(seconds: 1),
        (_) => flows.zoneTick(DateTime.now()),
      ),
    );
    for (final d in await DriftDeviceStore(_db).all()) {
      final poll = registry[d.driverId]?.statePoll;
      final seconds = poll?['intervalSeconds'];
      if (seconds is! int || seconds <= 0) continue;
      _hubTimers.add(
        Timer.periodic(Duration(seconds: seconds), (_) async {
          try {
            await devices.refreshState(d.id);
          } catch (e) {
            _emit({
              'event': 'device.pollFailed',
              'device': d.id,
              'error': '$e',
            });
          }
        }),
      );
    }
  }

  Future<void> _provisionQuietly(String id) async {
    try {
      await provisionBoard(id);
    } catch (e) {
      _emit({'event': 'board.offline', 'device': id, 'error': '$e'});
    }
  }

  UdpTransport? _helloSocket;

  /// Listens for the hello every OmniFlow board on Wi-Fi broadcasts.
  Future<void> _listenForHellos(int port) async {
    final socket = _helloSocket ??= await UdpTransport.bind(
      port: port,
      tap: _tap,
    );
    socket.incoming.listen((d) {
      final Object? json;
      try {
        json = jsonDecode(d.text);
      } on FormatException {
        return;
      }
      if (json is Map && json['event'] == 'hello') {
        _boardEvent(Map<String, Object?>.from(json), null, d.address.address);
      }
    });
  }

  final _events = StreamController<Map<String, Object?>>.broadcast();
  WizPushManager? _wizPush;

  /// Everything the engine reports as it happens, as JSON messages:
  /// `device.stateChanged`, `wiz.firstBeat`, and `packet.captured` when the
  /// engine was opened with a packet tap.
  Stream<Map<String, Object?>> get events => _events.stream;

  void _emit(Map<String, Object?> event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Starts live state from every WiZ device that has a stable id (its MAC).
  Future<int> startWizPush({int listenPort = 38900}) async {
    final bulbs = [
      for (final d in await DriftDeviceStore(_db).all())
        if (d.driverId == 'philips_wiz_udp' && d.stableId != null) d,
    ];
    final push = _wizPush ??= await WizPushManager.start(
      devices: devices,
      listenPort: listenPort,
      tap: _tap,
    );
    push.firstBeats.listen(
      (b) => _emit({
        'event': 'wiz.firstBeat',
        'host': b.host,
        if (b.mac != null) 'mac': b.mac,
      }),
    );
    await push.watch(bulbs);
    return bulbs.length;
  }

  late final Map<
    String,
    Future<Map<String, Object?>> Function(Map<String, Object?> args)
  >
  _commands = {
    'driver.list': (_) async => {
      'drivers': [
        for (final m in registry.all)
          {
            'id': m.id,
            'name': m.name,
            'category': m.category,
            'transport': m.transport.type.wireName,
            'builtIn': registry.isBuiltIn(m.id),
            'capabilities': m.capabilities.map((c) => c.id).toList(),
          },
      ],
    },
    'driver.validate': (args) async {
      final m = DriverManifest.parse(_object(args, 'manifest'));
      return {'id': m.id, 'highRisk': m.isHighRisk};
    },
    'driver.register': (args) async {
      final json = _object(args, 'manifest');
      final m = registry.register(json);
      await DriftManifestStore(_db)
          .put(m.id, jsonEncode(json), DateTime.now().toUtc());
      return {'id': m.id, 'highRisk': m.isHighRisk};
    },
    'device.add': _addDevice,
    ..._boardCommands,
    ..._linkCommands,
    ..._flowCommands,
    'device.discover': (args) async {
      final driverId = _string(args, 'driver');
      final manifest = registry[driverId];
      if (manifest == null) throw ApiError('not_found', 'no driver $driverId');
      final windowMs = args['windowMs'];
      if (manifest.transport.type == TransportType.serial) {
        return {'found': await serial.discover(manifest)};
      }
      final onUsb = isBoardDriver(manifest) && args['serial'] != false
          ? await serial.discover(
              manifest,
              window: const Duration(milliseconds: 3000),
            )
          : const <Map<String, Object?>>[];
      final found = await discovery.discover(
        manifest,
        window: Duration(milliseconds: windowMs is int ? windowMs : 2000),
        portOverride: args['port'] as int?,
      );
      final known = {
        for (final d in await DriftDeviceStore(_db).all())
          if (d.driverId == driverId && d.stableId != null)
            d.stableId!.toLowerCase(): d.id,
      };
      return {
        'found': [
          for (final f in [...onUsb, for (final f in found) f.toJson()])
            {
              ...f,
              if (known['${f['stableId']}'.toLowerCase()] != null)
                'knownAs': known['${f['stableId']}'.toLowerCase()],
            },
        ],
      };
    },
    'device.list': (args) async => {
      'devices': [
        for (final d in await DriftDeviceStore(_db).all())
          if (args['room'] == null || args['room'] == d.room)
            {
              ..._deviceJson(d),
              if (args['withCapabilities'] == true)
                'capabilities': _capabilitiesJson(d),
            },
      ],
    },
    'device.get': (args) async => {
      'device': _deviceJson(await _device(_string(args, 'id'))),
    },
    'device.remove': (args) async => {
      'removed': await DriftDeviceStore(_db).remove(_string(args, 'id')),
    },
    'device.invoke': (args) async {
      final result = await devices.invoke(
        _string(args, 'id'),
        _string(args, 'capability'),
        args['params'] == null ? const {} : _object(args, 'params'),
      );
      return {'device': _deviceJson(result.device), 'reply': result.reply.json};
    },
    'device.refresh': (args) async => {
      'device': _deviceJson(await devices.refreshState(_string(args, 'id'))),
    },
    'secret.set': (args) async {
      final device = await _device(_string(args, 'deviceId'));
      final key = _string(args, 'key');
      final manifest = registry[device.driverId]!;
      if (!manifest.settings.any((s) => s.key == key && s.secret)) {
        throw ApiError(
          'invalid',
          '$key is not a secret setting of ${manifest.id}',
        );
      }
      await _secrets.write(
        deviceSecretKey(device.id, key),
        _string(args, 'value'),
      );
      return {'stored': deviceSecretKey(device.id, key)};
    },
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

  Future<Map<String, Object?>> _addDevice(Map<String, Object?> args) async {
    final id = _string(args, 'id');
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(id)) {
      throw ApiError('invalid', 'device id must be lower snake case');
    }
    final driverId = _string(args, 'driver');
    final manifest = registry[driverId];
    if (manifest == null) throw ApiError('not_found', 'no driver $driverId');
    final settings = args['settings'] == null
        ? <String, Object?>{}
        : _object(args, 'settings');
    for (final key in settings.keys) {
      final spec = manifest.settings.where((s) => s.key == key).firstOrNull;
      if (spec == null) {
        throw ApiError('invalid', '$key is not a setting of $driverId');
      }
      if (spec.secret) {
        throw ApiError(
          'invalid',
          '$key is a secret. Store it with omni secret set, never in device settings',
        );
      }
    }
    if (isBoardDriver(manifest)) {
      parseBoardPins(
        settings['pins'],
        reserved: {for (final c in manifest.capabilities) c.id},
      );
    }
    final port = args['port'];
    if (port != null && (port is! int || port < 1 || port > 65535)) {
      throw ApiError('invalid', 'port must be 1 to 65535');
    }
    final device = Device(
      id: id,
      name: args['name'] is String ? args['name'] as String : id,
      driverId: driverId,
      host: _string(args, 'host'),
      port: port as int?,
      room: args['room'] as String?,
      stableId: args['stableId'] as String?,
      settings: settings,
    );
    await DriftDeviceStore(_db).put(device);
    final missingSecrets = [
      for (final s in manifest.settings.where((s) => s.secret))
        if (await _secrets.read(deviceSecretKey(id, s.key)) == null) s.key,
    ];
    Map<String, Object?>? board;
    String? boardError;
    if (isBoardDriver(manifest) && args['provision'] != false) {
      try {
        board = await provisionBoard(id);
      } catch (e) {
        boardError = e is ApiError ? e.message : '$e';
      }
    }
    return {
      'device': _deviceJson(await _device(id)),
      if (missingSecrets.isNotEmpty) 'missingSecrets': missingSecrets,
      'provisioned': ?board,
      'provisionError': ?boardError,
    };
  }

  Future<Device> _device(String id) async {
    final device = await DriftDeviceStore(_db).get(id);
    if (device == null) throw ApiError('not_found', 'no device $id');
    return device;
  }

  /// Each capability of a device with the params it accepts, for UIs and agents.
  List<Map<String, Object?>> _capabilitiesJson(Device device) => [
    for (final c
        in manifestFor(registry, device)?.capabilities ??
            const <CapabilitySpec>[])
      {
        'id': c.id,
        'type': c.type.wireName,
        'label': c.label,
        'highRisk': registry[device.driverId]!.isHighRisk,
        if (stateKeyOf(c.stateJsonPath) != null)
          'stateKey': stateKeyOf(c.stateJsonPath),
        'params': {
          for (final p in c.params.entries)
            p.key: {
              'type': p.value.type.wireName,
              if (p.value.min != null) 'min': p.value.min,
              if (p.value.max != null) 'max': p.value.max,
              if (p.value.unit != null) 'unit': p.value.unit,
              if (p.value.values.isNotEmpty) 'values': p.value.values,
              if (p.value.optional) 'optional': true,
            },
        },
      },
  ];

  static Map<String, Object?> _deviceJson(Device d) => {
    'id': d.id,
    'name': d.name,
    'driver': d.driverId,
    'host': d.host,
    if (d.port != null) 'port': d.port,
    if (d.room != null) 'room': d.room,
    if (d.stableId != null) 'stableId': d.stableId,
    'settings': d.settings,
    'state': d.state,
    if (d.lastSeen != null) 'lastSeen': d.lastSeen!.toIso8601String(),
  };

  static String _string(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is String && value.isNotEmpty) return value;
    throw ApiError('invalid', '$key is required');
  }

  static Map<String, Object?> _object(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is Map) return Map<String, Object?>.from(value);
    throw ApiError('invalid', '$key must be an object');
  }

  static Map<String, Object?> _failure(ApiError e) => {
    'ok': false,
    'error': e.toJson(),
  };

  Map<String, Future<Map<String, Object?>> Function(Map<String, Object?> args)>
  get _flowCommands => {
    'flow.validate': (args) async {
      final flow = FlowSpec.parse(_object(args, 'flow'));
      final issues = validateFlow(flow, refs: await _references());
      if (issues.isNotEmpty) {
        throw ValidationException('flow ${flow.id}', issues);
      }
      return {'id': flow.id, 'highRisk': await _isHighRisk(flow)};
    },
    'flow.save': (args) async {
      final flow = FlowSpec.parse(_object(args, 'flow'));
      final issues = validateFlow(flow, refs: await _references());
      if (issues.isNotEmpty) {
        throw ValidationException('flow ${flow.id}', issues);
      }
      final highRisk = await _isHighRisk(flow);
      // A caller that is not the user (MCP, the architect, an import) passes
      // trusted: false, and a high-risk flow then waits for approval.
      final approved = args['trusted'] != false || !highRisk;
      await DriftFlowStore(_db).put(
        flow.id,
        flow.toJson(),
        enabled: flow.enabled,
        approved: approved,
        at: DateTime.now().toUtc(),
      );
      await _reloadFlows();
      return {'id': flow.id, 'highRisk': highRisk, 'approved': approved};
    },
    'flow.approve': (args) async {
      final id = _string(args, 'id');
      final record = await DriftFlowStore(_db).get(id);
      if (record == null) throw ApiError('not_found', 'no flow $id');
      await DriftFlowStore(_db).put(
        id,
        record.json,
        enabled: record.enabled,
        approved: true,
        at: DateTime.now().toUtc(),
      );
      await _reloadFlows();
      return {'id': id, 'approved': true};
    },
    'flow.list': (_) async => {
      'flows': [
        for (final r in await DriftFlowStore(_db).all())
          {
            'id': r.json['id'],
            'name': r.json['name'],
            'enabled': r.enabled,
            'approved': r.approved,
            'loaded': flows.loadedFlows.contains(r.json['id']),
          },
      ],
    },
    'flow.get': (args) async {
      final record = await DriftFlowStore(_db).get(_string(args, 'id'));
      if (record == null) throw ApiError('not_found', 'no flow ${args['id']}');
      return {
        'flow': record.json,
        'enabled': record.enabled,
        'approved': record.approved,
      };
    },
    'flow.remove': (args) async {
      final removed = await DriftFlowStore(_db).remove(_string(args, 'id'));
      await _reloadFlows();
      return {'removed': removed};
    },
    'flow.enable': (args) async {
      final id = _string(args, 'id');
      final record = await DriftFlowStore(_db).get(id);
      if (record == null) throw ApiError('not_found', 'no flow $id');
      final enabled = args['enabled'] != false;
      final json = {...record.json, 'enabled': enabled};
      await DriftFlowStore(_db).put(
        id,
        json,
        enabled: enabled,
        approved: record.approved,
        at: DateTime.now().toUtc(),
      );
      await _reloadFlows();
      return {'id': id, 'enabled': enabled};
    },
    'flow.run': (args) async {
      final traces = await flows.run(
        _string(args, 'id'),
        triggerId: args['trigger'] as String?,
        msg: args['msg'] == null ? const {} : _object(args, 'msg'),
      );
      return {'runs': traces.map((t) => t.toJson()).toList()};
    },
    'flow.dryRun': (args) async {
      final id = _string(args, 'id');
      final record = await DriftFlowStore(_db).get(id);
      if (record == null) throw ApiError('not_found', 'no flow $id');
      final flow = FlowSpec.parse(record.json);
      final trigger =
          args['trigger'] as String? ??
          flow.nodes
              .firstWhere(
                (n) =>
                    builtInNodeTypes[n.type]?.category == NodeCategory.trigger,
              )
              .id;
      final at = args['at'] is String
          ? DateTime.parse(args['at'] as String)
          : DateTime.now();
      final msg = args['msg'] == null
          ? <String, Object?>{}
          : _object(args, 'msg');
      final trace = await flows.dryRun(flow, trigger, {
        'trigger': 'dry_run',
        ...msg,
      }, at);
      return {'run': trace.toJson()};
    },
    'flow.log': (args) async => {
      'runs': await ExecutionLogStore(_db).recent(
        flowId: args['id'] as String?,
        limit: args['limit'] is int ? args['limit'] as int : 20,
      ),
    },
    'flow.cards': (args) async {
      final record = await DriftFlowStore(_db).get(_string(args, 'id'));
      if (record == null) throw ApiError('not_found', 'no flow ${args['id']}');
      final cards = projectCards(FlowSpec.parse(record.json));
      return cards == null
          ? {'tree': false}
          : {'tree': true, ...cards.toJson()};
    },
    'command.interpret': (args) async {
      final devices = [
        for (final d in await DriftDeviceStore(_db).all())
          if (manifestFor(registry, d) case final manifest?)
            CommandDevice(d.id, d.name, manifest),
      ];
      final flowList = [
        for (final f in await DriftFlowStore(_db).all())
          CommandFlow(f.json['id'] as String, f.json['name'] as String),
      ];
      return interpretCommand(
        _string(args, 'text'),
        devices,
        flowList,
      ).toJson();
    },
    'var.list': (_) async => {'variables': await DriftGlobalStore(_db).all()},
    'var.set': (args) async {
      final name = _string(args, 'name');
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
        throw ApiError('invalid', 'a variable name is letters, digits and _');
      }
      await flows.setGlobal(name, args['value']);
      return {'name': name, 'value': args['value']};
    },
    'var.remove': (args) async {
      final name = _string(args, 'name');
      flows.globals.remove(name);
      return {'removed': await DriftGlobalStore(_db).remove(name)};
    },
    'zone.save': (args) async {
      final zone = ZoneSpec.parse(_object(args, 'zone'));
      await DriftZoneStore(_db).put(zone.id, zone.toJson());
      flows.setZones([
        for (final z in await DriftZoneStore(_db).all()) ZoneSpec.parse(z),
      ]);
      return {'id': zone.id};
    },
    'zone.list': (_) async => {
      'zones': [
        for (final z in await DriftZoneStore(_db).all())
          {...z, 'inside': flows.zones.isInside(z['id'] as String)},
      ],
      'needBle': flows.zones.zonesNeedingBle.toList(),
    },
    'zone.remove': (args) async {
      final removed = await DriftZoneStore(_db).remove(_string(args, 'id'));
      flows.setZones([
        for (final z in await DriftZoneStore(_db).all()) ZoneSpec.parse(z),
      ]);
      return {'removed': removed};
    },
    'sensor.ble': (args) async {
      final rssi = args['rssi'];
      if (rssi is! num) throw ApiError('invalid', 'rssi must be a number');
      flows.bleReading(
        _string(args, 'name'),
        rssi.toDouble(),
        args['at'] is String
            ? DateTime.parse(args['at'] as String)
            : DateTime.now(),
      );
      return {'zones': flows.zones.states};
    },
    'sensor.wifi': (args) async {
      await flows.wifi(
        args['ssid'] as String?,
        args['bssid'] as String?,
        DateTime.now(),
      );
      return {'zones': flows.zones.states};
    },
  };

  Map<String, Future<Map<String, Object?>> Function(Map<String, Object?> args)>
  get _boardCommands => {
    'board.provision': (args) async => {
      'board': await provisionBoard(_string(args, 'id')),
    },
    'board.pins': (args) async {
      final id = _string(args, 'id');
      final device = await _device(id);
      final manifest = registry[device.driverId];
      if (!isBoardDriver(manifest)) {
        throw ApiError('invalid', '$id is not an OmniFlow board');
      }
      final pins = _object(args, 'pins');
      parseBoardPins(
        pins,
        reserved: {for (final c in manifest!.capabilities) c.id},
      );
      await devices.updateDevice(
        id,
        (d) => d.copyWith(settings: {...d.settings, 'pins': pins}),
      );
      try {
        return {'board': await provisionBoard(id)};
      } on ApiError {
        rethrow;
      } catch (e) {
        return {
          'device': _deviceJson(await _device(id)),
          'provisionError': '$e',
        };
      }
    },
    'board.setup': _setupBoard,
  };

  Map<String, Future<Map<String, Object?>> Function(Map<String, Object?> args)>
  get _linkCommands => {
    'link.create': (args) async {
      final from = LinkEnd.parse(_string(args, 'from'), 'from');
      final to = LinkEnd.parse(_string(args, 'to'), 'to');
      final mode = LinkMode.values
          .where((m) => m.name == args['mode'])
          .firstOrNull;
      if (mode == null) {
        throw ApiError('invalid', 'mode must be toggle, follow or threshold');
      }
      final source = await _device(from.deviceId);
      final sourceManifest = manifestFor(registry, source);
      final sourceCapability = sourceManifest?.capabilities
          .where((c) => stateKeyOf(c.stateJsonPath) == from.key)
          .firstOrNull;
      final knownKeys = {
        ...source.state.keys,
        for (final c
            in sourceManifest?.capabilities ?? const <CapabilitySpec>[])
          ?stateKeyOf(c.stateJsonPath),
      };
      if (!knownKeys.contains(from.key)) {
        throw ApiError(
          'not_found',
          '${from.deviceId} has no state ${from.key} (it has ${(knownKeys.toList()..sort()).join(', ')})',
        );
      }
      final target = manifestFor(
        registry,
        await _device(to.deviceId),
      )?.capability(to.key);
      if (target == null) {
        throw ApiError(
          'not_found',
          '${to.deviceId} has no capability ${to.key}',
        );
      }
      final range = sourceCapability?.params['value'];
      num bound(String key, num? fromCapability, num fallback) =>
          args[key] is num ? args[key] as num : fromCapability ?? fallback;
      final request = LinkRequest(
        from: from,
        to: to,
        mode: mode,
        target: target,
        above: args['above'] as num?,
        below: args['below'] as num?,
        set: args['set'],
        fromMin: bound('fromMin', range?.min, 0),
        fromMax: bound('fromMax', range?.max, 100),
        onValue: args.containsKey('onValue') ? args['onValue'] : true,
      );
      final Map<String, Object?> flow;
      try {
        flow = request.toFlow();
      } on ArgumentError catch (e) {
        throw ApiError('invalid', '${e.message}');
      }
      final saved = await _commands['flow.save']!({
        'flow': flow,
        'trusted': args['trusted'] != false,
      });
      return {...saved, 'name': request.name};
    },
    'link.list': (_) async => {
      'links': [
        for (final r in await DriftFlowStore(_db).all())
          if ((r.json['id'] as String).startsWith('link_'))
            {
              'id': r.json['id'],
              'name': r.json['name'],
              'enabled': r.enabled,
              'approved': r.approved,
            },
      ],
    },
    'link.remove': (args) async {
      final id = _string(args, 'id');
      if (!id.startsWith('link_')) {
        throw ApiError('invalid', '$id is not a link');
      }
      return _commands['flow.remove']!({'id': id});
    },
  };

  /// Sets up a board on a USB serial port: Wi-Fi, node name and IR pin, all
  /// kept in the board's flash. With Wi-Fi it waits until the board joins
  /// and returns its address. The password goes to the board only.
  Future<Map<String, Object?>> _setupBoard(Map<String, Object?> args) async {
    final port = _string(args, 'port');
    final manifest = registry['omniflow_board']!;
    final probe = Device(
      id: '_setup_${port.hashCode.abs()}',
      name: port,
      driverId: manifest.id,
      host: port,
    );
    Future<Map<String, Object?>> send(Map<String, Object?> command) async =>
        (await serial.send(
          ChannelRequest(
            device: probe,
            manifest: manifest,
            command: command,
            context: const TemplateContext(),
          ),
        )).json ??
        const {};
    try {
      // Opening the port resets an Uno or an ESP32, so the first describe
      // can go unanswered while the board boots.
      Map<String, Object?>? describe;
      for (var attempt = 0; describe == null; attempt++) {
        try {
          describe = await send(const {'cmd': 'describe'});
        } on TransportTimeoutException {
          if (attempt == 1) rethrow;
        }
      }
      if (args['name'] is String) {
        await send({'cmd': 'node.set', 'name': args['name']});
      }
      if (args['irPin'] is int) {
        await send({'cmd': 'ir.pin', 'pin': args['irPin']});
      }
      var wifi = await send(const {'cmd': 'wifi.status'});
      if (args['ssid'] is String) {
        await send({
          'cmd': 'wifi.set',
          'ssid': args['ssid'],
          'password': args['password'] is String ? args['password'] : '',
        });
        final timeoutMs = args['timeoutMs'] is int
            ? args['timeoutMs'] as int
            : 20000;
        final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
        do {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          wifi = await send(const {'cmd': 'wifi.status'});
        } while (wifi['connected'] != true &&
            DateTime.now().isBefore(deadline));
      }
      return {
        'node': wifi['node'] ?? describe['node'],
        'board': describe['board'],
        'fw': describe['fw'],
        'wifi': {
          'configured': wifi['configured'] == true,
          'connected': wifi['connected'] == true,
          'ip': ?wifi['ip'],
        },
      };
    } finally {
      await serial.release(probe.id);
    }
  }

  Future<void> close() async {
    for (final t in _hubTimers) {
      t.cancel();
    }
    await Future.wait([..._pending]);
    _helloSocket?.close();
    await flows.close();
    await _wizPush?.stop();
    for (final close in _closers) {
      await close();
    }
    await _db.close();
    await _lock.release();
    await _events.close();
  }
}

class _EngineFlowHost implements FlowHost {
  _EngineFlowHost(this._engine);

  final OmniEngine _engine;

  @override
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params,
  ) async =>
      (await _engine.devices.invoke(deviceId, capabilityId, params)).reply.json;

  @override
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId,
  ) async {
    final device = await _engine._device(deviceId);
    final capability = manifestFor(
      _engine.registry,
      device,
    )?.capability(capabilityId);
    final key = stateKeyOf(capability?.stateJsonPath);
    if (capability == null || key == null) {
      throw ApiError('invalid', '$deviceId.$capabilityId cannot be toggled');
    }
    final on = device.state[key] == true;
    return (await _engine.devices.invoke(deviceId, capabilityId, {
      'value': !on,
    })).reply.json;
  }

  @override
  Future<void> saveGlobal(String name, Object? value) =>
      DriftGlobalStore(_engine._db).put(name, value, DateTime.now().toUtc());

  @override
  Future<void> saveTrace(Map<String, Object?> trace) =>
      ExecutionLogStore(_engine._db).add(trace);

  @override
  void emit(Map<String, Object?> event) => _engine._emit(event);

  @override
  Stream<Map<String, Object?>> get events => _engine.events;
}
