import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_bar.dart';
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
        _boardEvent(Map<String, Object?>.from(json), null);
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
    final devices = DeviceService(
      registry: registry,
      store: DriftDeviceStore(db),
      locator: discovery.locator,
      channels: {
        TransportType.udp: UdpJsonChannel(udp),
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
  /// `board.event`. Replies (ack, error, describe) are not events.
  void _boardEvent(Map<String, Object?> json, String? deviceId) {
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
      for (final d in await DriftDeviceStore(_db).all()) d.id: d.driverId,
    };
    return FlowReferences(
      devices: devices.keys.toSet(),
      zones: {
        for (final z in await DriftZoneStore(_db).all()) z['id'] as String,
      },
      flows: {
        for (final f in await DriftFlowStore(_db).all()) f.json['id'] as String,
      },
      capabilityOf: (d, c) => registry[devices[d] ?? '']?.capability(c),
    );
  }

  /// True when a flow drives a device whose driver runs host commands.
  Future<bool> _isHighRisk(FlowSpec flow) async {
    final devices = {
      for (final d in await DriftDeviceStore(_db).all()) d.id: d.driverId,
    };
    return flow.nodes.any(
      (n) =>
          n.type == 'device_capability' &&
          (registry[devices[n.config['deviceId']] ?? '']?.isHighRisk ?? false),
    );
  }

  /// Runs flows on their own: WiZ pushes, time and interval triggers, a zone
  /// tick every second, and each device's state poll. `omni hub` calls this.
  Future<void> startHub({int wizListenPort = 38900}) async {
    await startWizPush(listenPort: wizListenPort);
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
    ..._flowCommands,
    'device.discover': (args) async {
      final driverId = _string(args, 'driver');
      final manifest = registry[driverId];
      if (manifest == null) throw ApiError('not_found', 'no driver $driverId');
      final windowMs = args['windowMs'];
      if (manifest.transport.type == TransportType.serial) {
        return {'found': await serial.discover(manifest)};
      }
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
          for (final f in found)
            {
              ...f.toJson(),
              if (known[f.stableId?.toLowerCase()] != null)
                'knownAs': known[f.stableId?.toLowerCase()],
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
                'capabilities': _capabilitiesJson(d.driverId),
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
    return {
      'device': _deviceJson(device),
      if (missingSecrets.isNotEmpty) 'missingSecrets': missingSecrets,
    };
  }

  Future<Device> _device(String id) async {
    final device = await DriftDeviceStore(_db).get(id);
    if (device == null) throw ApiError('not_found', 'no device $id');
    return device;
  }

  /// Each capability of a driver with the params it accepts, for UIs and agents.
  List<Map<String, Object?>> _capabilitiesJson(String driverId) => [
    for (final c
        in registry[driverId]?.capabilities ?? const <CapabilitySpec>[])
      {
        'id': c.id,
        'type': c.type.wireName,
        'label': c.label,
        'highRisk': registry[driverId]!.isHighRisk,
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
          if (registry[d.driverId] != null)
            CommandDevice(d.id, d.name, registry[d.driverId]!),
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

  Future<void> close() async {
    for (final t in _hubTimers) {
      t.cancel();
    }
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
