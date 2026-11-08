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
import '../devices/mqtt_channel.dart';
import '../devices/serial_channel.dart';
import '../devices/tuya_channel.dart';
import '../dag/canonical.dart';
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
import '../manifest/param_spec.dart';
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
    this._mqtt,
    this._tuya,
    this._boardChannel,
    this._closers,
  ) {
    flows = FlowEngine(_EngineFlowHost(this));
    _inputs.addAll([
      serial.events.listen((e) => _boardEvent(e.json, e.deviceId)),
      _mqtt.events.listen(
        (e) => _track(devices.applyPush(e.deviceId, e.state).then((_) {})),
      ),
      _tuya.pushes.listen(
        (p) => _track(devices.applyPush(p.deviceId, p.body).then((_) {})),
      ),
      _udp.incoming.listen((d) {
        final Object? json;
        try {
          json = jsonDecode(d.text);
        } on FormatException {
          return;
        }
        if (json is Map && json['node'] is String && json['event'] is String) {
          _track(_udpBoardMessage(Map<String, Object?>.from(json), d.address));
        }
      }),
    ]);
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
          driverIssues.add(_issue('driver', _idIn(json), e));
        }
      }
      udp = await UdpTransport.bind(tap: tap);
      final tuya = TuyaChannel(secrets, tap: tap);
      final serial = SerialChannel(tap: tap);
      final discovery = UdpDiscovery(udp, targets: discoveryTargets);
      final udpJson = UdpJsonChannel(udp);
      final mqtt = MqttChannel(secrets, tap: tap);
      final boardChannel = BoardChannel(udp: udpJson, serial: serial);
      final devices = DeviceService(
        registry: registry,
        store: DriftDeviceStore(db),
        locator: discovery.locator,
        channels: {
          TransportType.udp: udpJson,
          TransportType.omniflow: boardChannel,
          TransportType.tuya: tuya,
          TransportType.http: HttpChannel(tap: tap),
          TransportType.serial: serial,
          TransportType.exec: ExecChannel(hostExecutors(secrets)),
          TransportType.mqtt: mqtt,
        },
      );
      final socket = udp;
      engine = OmniEngine._(
        db,
        lock,
        registry,
        devices,
        secrets,
        discovery,
        tap,
        serial,
        socket,
        mqtt,
        tuya,
        boardChannel,
        [
          () async => socket.close(),
          tuya.close,
          serial.close,
          mqtt.close,
          devices.close,
        ],
      );
      engine._issues['driver'] = driverIssues;
      await engine._loadFlowState();
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

  static Map<String, Object?> _issue(String kind, Object? id, Object error) => {
    'kind': kind,
    'id': ?id,
    'error': switch (error) {
      ApiError e => e.message,
      ArgumentError e => '${e.message}',
      ValidationException e =>
        '${e.subject}: ${e.issues.map((i) => i.toJson()).join('; ')}',
      _ => '$error',
    },
  };

  static Object? _idIn(String json) {
    try {
      final decoded = jsonDecode(json);
      return decoded is Map ? decoded['id'] : null;
    } on FormatException {
      return null;
    }
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
  final MqttChannel _mqtt;
  final TuyaChannel _tuya;
  final BoardChannel _boardChannel;
  final List<Future<void> Function()> _closers;
  final _inputs = <StreamSubscription<Object?>>[];
  var _hubRunning = false;
  Future<void>? _hubStart;
  late final FlowEngine flows;
  final _hubTimers = <Timer>[];
  final _polls = <String, Timer>{};

  /// Stored records that could not be loaded, by kind (driver, zone, flow).
  /// They stay in the database and are reported, so one bad row never
  /// keeps the engine from opening.
  final _issues = <String, List<Map<String, Object?>>>{};

  List<Map<String, Object?>> get loadIssues => [
    for (final list in _issues.values) ...list,
  ];

  void _setIssues(String kind, List<Map<String, Object?>> issues) {
    final before = {
      for (final i in _issues[kind] ?? const []) canonicalJson(i),
    };
    _issues[kind] = issues;
    for (final i in issues) {
      if (!before.contains(canonicalJson(i))) {
        _emit({'event': 'engine.loadIssue', ...i});
      }
    }
  }

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

  /// A board message over UDP counts only when it comes from the local
  /// network and from the address of a device the user added, so a stray or
  /// spoofed sender elsewhere cannot fire flows or change state.
  Future<void> _udpBoardMessage(
    Map<String, Object?> json,
    InternetAddress from,
  ) async {
    if (!isLocalNetworkAddress(from)) return;
    final devices = await DriftDeviceStore(_db).all();
    final sender = devices
        .where((d) => d.host == from.address)
        .where(
          (d) =>
              !isBoardDriver(registry[d.driverId]) ||
              d.stableId == null ||
              d.stableId!.toLowerCase() == '${json['node']}'.toLowerCase(),
        )
        .firstOrNull;
    if (sender == null) return;
    _boardEvent(json, sender.id, from.address);
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
    final node = '${json['node']}';
    if (device == null) {
      final board = registry['omniflow_board'];
      final addPort = port == board?.transport.port ? null : port;
      _emit({
        'event': 'board.found',
        'node': json['node'],
        'board': json['board'],
        'host': from,
        'port': ?port,
        'add': {
          'id': node.toLowerCase().replaceAll('-', '_'),
          'name': node,
          'driver': 'omniflow_board',
          'host': from,
          'port': ?addPort,
          'stableId': node,
        },
      });
      return;
    }
    var d = device;
    final defaultPort = registry[d.driverId]?.transport.port;
    final wantPort = port == defaultPort ? null : port;
    if (!isSerialHost(d.host) && (d.host != from || d.port != wantPort)) {
      // A hello is unauthenticated, so it only moves a board that no longer
      // answers where it was and does answer, as itself, at the new address.
      if (await _answersAs(d, d.host, d.port, node)) {
        if (d.host != from) {
          _emit({
            'event': 'board.conflict',
            'device': d.id,
            'node': node,
            'host': from,
          });
          return;
        }
      } else if (await _answersAs(d, from, wantPort, node)) {
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
        _emit({
          'event': 'board.moved',
          'device': d.id,
          'host': from,
          'port': ?wantPort,
        });
      } else {
        return;
      }
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

  /// Whether a describe sent to [host] and [port] comes back from [node].
  Future<bool> _answersAs(Device d, String host, int? port, String node) async {
    final manifest = registry[d.driverId];
    if (manifest == null) return false;
    try {
      final reply = await _boardChannel.send(
        ChannelRequest(
          device: Device(
            id: d.id,
            name: d.name,
            driverId: d.driverId,
            host: host,
            port: port,
          ),
          manifest: manifest,
          command: const {'cmd': 'describe'},
          context: const TemplateContext(),
        ),
      );
      return '${reply.json?['node']}'.toLowerCase() == node.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  final _provisionQueued = <String, Future<Map<String, Object?>>>{};

  /// Brings a board to its configured pins: checks them against what the
  /// board offers, sets each mode, restores outputs from the remembered
  /// state, starts watching inputs, and seeds their state. Safe to repeat.
  /// A call while a setup is running waits for it and then runs once more,
  /// so pins saved meanwhile reach the board.
  Future<Map<String, Object?>> provisionBoard(String id) {
    final running = _provisioning[id];
    if (running == null) return _startProvision(id);
    return _provisionQueued[id] ??= running
        .then((_) {}, onError: (Object _) {})
        .then((_) {
          _provisionQueued.remove(id);
          return _startProvision(id);
        });
  }

  Future<Map<String, Object?>> _startProvision(String id) {
    late final Future<Map<String, Object?>> started;
    started = _provision(id).whenComplete(() {
      if (identical(_provisioning[id], started)) _provisioning.remove(id);
    });
    _provisioning[id] = started;
    return started;
  }

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
    // The board answered at the stored address, so its name is the truth,
    // also after a rename over USB.
    final node = describe['node'];
    if (node is String &&
        device.stableId?.toLowerCase() != node.toLowerCase()) {
      await devices.updateDevice(id, (d) => d.copyWith(stableId: node));
    }
    final current = await _device(id);
    final seeded = <String, Object?>{};
    // One refused command does not stop the rest of the setup; every
    // refusal is reported at the end.
    final refused = <String>[];
    for (final command in pinSetupCommands(
      pins,
      current.state,
      current: pinsSetOnBoard(describe),
    )) {
      final Map<String, Object?>? reply;
      try {
        reply = (await devices.sendCommand(id, command)).json;
      } on CommandFailedException catch (e) {
        refused.add('${command['cmd']} pin ${command['pin']}: ${e.message}');
        continue;
      }
      final value = reply?['value'];
      if (command['cmd'] == 'pin.watch' && value is num) {
        final pin = pins.firstWhere((p) => p.pin == command['pin']);
        seeded[pin.name] = pin.stateValue(value);
      }
    }
    final updated = await devices.mergeState(id, seeded);
    if (refused.isNotEmpty) {
      throw ApiError('device_error', 'the board refused ${refused.join('; ')}');
    }
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
    await _reloadZones();
    await _reloadFlows();
  }

  Future<void> _reloadZones() async {
    final zones = <ZoneSpec>[];
    final issues = <Map<String, Object?>>[];
    for (final z in await DriftZoneStore(_db).all()) {
      try {
        zones.add(ZoneSpec.parse(z));
      } catch (e) {
        issues.add(_issue('zone', z['id'], e));
      }
    }
    flows.setZones(zones);
    _setIssues('zone', issues);
  }

  static const _trustedKey = '_trusted';

  /// The flow JSON of a stored record, without the engine's own marks.
  static Map<String, Object?> _flowJsonOf(FlowRecord r) =>
      {...r.json}..remove(_trustedKey);

  /// Whether the user saved or approved this version of the flow.
  static bool _trustedOf(FlowRecord? r) => r?.json[_trustedKey] == true;

  /// What the user reviews before approving: a hash of the flow JSON.
  static String _revisionOf(Map<String, Object?> flowJson) =>
      sha256Hex(canonicalJson(flowJson));

  Future<void> _putFlow(
    String id,
    Map<String, Object?> flowJson, {
    required bool enabled,
    required bool approved,
    required bool trusted,
  }) => DriftFlowStore(_db).put(
    id,
    {...flowJson, if (trusted) _trustedKey: true},
    enabled: enabled,
    approved: approved,
    at: DateTime.now().toUtc(),
  );

  /// Every stored flow that parses, by id. The rest are load issues.
  Future<(List<FlowRecord>, Map<String, FlowSpec>, List<Map<String, Object?>>)>
  _storedFlows() async {
    final records = await DriftFlowStore(_db).all();
    final specs = <String, FlowSpec>{};
    final issues = <Map<String, Object?>>[];
    for (final r in records) {
      try {
        specs[r.json['id'] as String] = FlowSpec.parse(_flowJsonOf(r));
      } catch (e) {
        issues.add(_issue('flow', r.json['id'], e));
      }
    }
    return (records, specs, issues);
  }

  /// Loads every enabled, approved flow. An untrusted flow that became high
  /// risk after it was approved (a device or driver under it now runs host
  /// commands) loses its approval and waits for the user again.
  Future<void> _reloadFlows() async {
    final (records, specs, issues) = await _storedFlows();
    final risky = await _highRiskFlows(specs.values);
    final load = <FlowSpec>[];
    for (final r in records) {
      final spec = specs[r.json['id']];
      if (spec == null) continue;
      var approved = r.approved;
      if (approved && !_trustedOf(r) && risky.contains(spec.id)) {
        approved = false;
        await _putFlow(
          spec.id,
          _flowJsonOf(r),
          enabled: r.enabled,
          approved: false,
          trusted: false,
        );
        _emit({'event': 'flow.approvalRevoked', 'flow': spec.id});
      }
      if (r.enabled && approved) load.add(spec);
    }
    for (final e in flows.load(load).entries) {
      issues.add({'kind': 'flow', 'id': e.key, 'error': e.value});
    }
    _setIssues('flow', issues);
  }

  Future<FlowReferences> _references() async {
    final devices = {
      for (final d in await DriftDeviceStore(_db).all())
        d.id: manifestFor(registry, d),
    };
    final (_, specs, _) = await _storedFlows();
    return FlowReferences(
      devices: devices.keys.toSet(),
      zones: {
        for (final z in await DriftZoneStore(_db).all()) z['id'] as String,
      },
      flows: {
        for (final f in await DriftFlowStore(_db).all()) f.json['id'] as String,
      },
      capabilityOf: (d, c) => devices[d]?.capability(c),
      calls: {for (final f in specs.values) f.id: runFlowTargets(f)},
    );
  }

  /// True when [flow], saved over the stored flows, would be high risk.
  Future<bool> _isHighRisk(FlowSpec flow) async {
    final (_, specs, _) = await _storedFlows();
    return (await _highRiskFlows({...specs, flow.id: flow}.values))
        .contains(flow.id);
  }

  static final _globalRef = RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)');

  /// The ids of the high-risk flows among [all]: a flow that drives a device
  /// whose driver runs host commands, that starts a high-risk flow with
  /// run_flow (it could pass arguments the target renders), or that sets a
  /// global a high-risk flow reads.
  Future<Set<String>> _highRiskFlows(Iterable<FlowSpec> all) async {
    final drivers = {
      for (final d in await DriftDeviceStore(_db).all()) d.id: d.driverId,
    };
    final risky = {
      for (final f in all)
        if (f.nodes.any(
          (n) =>
              (n.type == 'device_capability' || n.type == 'device_toggle') &&
              (registry[drivers[n.config['deviceId']] ?? '']?.isHighRisk ??
                  false),
        ))
          f.id,
    };
    Set<String> written(FlowSpec f) => {
      for (final n in f.nodes)
        if (n.type == 'set_variable' &&
            n.config['name'] is String &&
            (n.config['name'] as String).startsWith(r'$'))
          (n.config['name'] as String).substring(1),
    };
    Set<String> read(FlowSpec f) => {
      for (final n in f.nodes)
        for (final m in _globalRef.allMatches(
          jsonEncode(
            n.type == 'set_variable'
                ? ({...n.config}..remove('name'))
                : n.config,
          ),
        ))
          m.group(1)!,
    };
    for (var grew = true; grew;) {
      grew = false;
      final readByRisky = {
        for (final f in all)
          if (risky.contains(f.id)) ...read(f),
      };
      for (final f in all) {
        if (risky.contains(f.id)) continue;
        if (runFlowTargets(f).any(risky.contains) ||
            written(f).any(readByRisky.contains)) {
          grew = risky.add(f.id);
        }
      }
    }
    return risky;
  }

  /// Runs flows on their own: WiZ pushes, time and interval triggers, a zone
  /// tick every second, and each device's state poll. `omni hub` and the
  /// `hub.start` command call this. A second call while it runs does nothing.
  Future<void> startHub({
    int wizListenPort = 38900,
    int boardHelloPort = 38951,
  }) => _hubStart ??= _startHub(wizListenPort, boardHelloPort);

  Future<void> _startHub(int wizListenPort, int boardHelloPort) async {
    Future<void> listen(int port, Future<void> Function() bind) async {
      try {
        await bind();
      } on SocketException catch (e) {
        throw ApiError(
          'unavailable',
          'cannot listen on UDP port $port (${e.osError?.message ?? e.message}). '
              'Is another omni hub or watch running?',
        );
      }
    }

    try {
      await listen(
        wizListenPort,
        () => startWizPush(listenPort: wizListenPort),
      );
      if (boardHelloPort > 0) {
        await listen(boardHelloPort, () => _listenForHellos(boardHelloPort));
      }
      _hubRunning = true;
      for (final d in await DriftDeviceStore(_db).all()) {
        _startLive(d);
      }
      flows.startTimers();
      _hubTimers.add(
        Timer.periodic(
          const Duration(seconds: 1),
          (_) => flows.zoneTick(DateTime.now()),
        ),
      );
    } catch (_) {
      await stopHub();
      rethrow;
    }
  }

  /// Stops what [startHub] started. Commands keep working.
  Future<void> stopHub() async {
    _hubStart = null;
    _hubRunning = false;
    for (final t in _hubTimers) {
      t.cancel();
    }
    _hubTimers.clear();
    for (final id in _polls.keys.toList()) {
      _stopLive(id);
    }
    for (final d in await DriftDeviceStore(_db).all()) {
      _mqtt.unwatch(d.id);
    }
    flows.stopTimers();
    _helloSocket?.close();
    _helloSocket = null;
    final push = _wizPush;
    _wizPush = null;
    await push?.stop();
  }

  /// Starts what keeps a device's state live in the hub: board setup, the
  /// MQTT topics it publishes on, its state poll and WiZ pushes.
  void _startLive(Device d, {bool provision = true}) {
    final manifest = registry[d.driverId];
    if (provision && isBoardDriver(manifest)) {
      _track(_provisionQuietly(d.id));
    }
    if (manifest?.transport.type == TransportType.mqtt) {
      _track(
        _mqtt.watch(d, manifest!).catchError((Object e) {
          _emit({'event': 'device.offline', 'device': d.id, 'error': '$e'});
        }),
      );
    }
    if (d.driverId == 'philips_wiz_udp' && d.stableId != null) {
      _track(_wizPush?.add(d) ?? Future.value());
    }
    _polls.remove(d.id)?.cancel();
    final seconds = manifest?.statePoll?['intervalSeconds'];
    if (seconds is int && seconds > 0) {
      final id = d.id;
      _polls[id] = Timer.periodic(Duration(seconds: seconds), (_) async {
        try {
          await devices.refreshState(id);
        } catch (e) {
          _emit({'event': 'device.pollFailed', 'device': id, 'error': '$e'});
        }
      });
    }
  }

  void _stopLive(String id) {
    _polls.remove(id)?.cancel();
    _mqtt.unwatch(id);
    _wizPush?.remove(id);
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
    if (_helloSocket != null) return;
    final socket = _helloSocket = await UdpTransport.bind(
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
      if (json is Map &&
          json['event'] == 'hello' &&
          json['node'] is String &&
          isLocalNetworkAddress(d.address)) {
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
    var push = _wizPush;
    if (push == null) {
      push = _wizPush = await WizPushManager.start(
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
      push.errors.listen((e) => _emit({'event': 'wiz.error', 'error': '$e'}));
    }
    await push.watch(bulbs);
    return bulbs.length;
  }

  late final Map<
    String,
    Future<Map<String, Object?>> Function(Map<String, Object?> args)
  >
  _commands = {
    'engine.status': (_) async => {
      'hubRunning': _hubRunning,
      'flows': flows.loadedFlows.toList(),
      'loadIssues': loadIssues,
    },
    'hub.start': (args) async {
      // The long names match startHub's parameters.
      await startHub(
        wizListenPort:
            _optInt(args, 'wizPort') ?? _optInt(args, 'wizListenPort') ?? 38900,
        boardHelloPort:
            _optInt(args, 'helloPort') ??
            _optInt(args, 'boardHelloPort') ??
            38951,
      );
      return {'running': true, 'flows': flows.loadedFlows.toList()};
    },
    'hub.stop': (_) async {
      await stopHub();
      return {'running': false};
    },
    'driver.list': (_) async => {
      'drivers': [
        for (final m in registry.all)
          {
            'id': m.id,
            'name': m.name,
            'category': m.category,
            'transport': m.transport.type.wireName,
            'builtIn': registry.isBuiltIn(m.id),
            'highRisk': m.isHighRisk,
            'capabilities': m.capabilities.map((c) => c.id).toList(),
          },
      ],
      'loadIssues': loadIssues,
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
      await _reloadFlows();
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
        window: Duration(milliseconds: _optInt(args, 'windowMs') ?? 2000),
        portOverride: _optInt(args, 'port'),
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
    'device.remove': (args) async {
      final id = _string(args, 'id');
      final device = await DriftDeviceStore(_db).get(id);
      _stopLive(id);
      _provisioned.remove(id);
      _boardUptime.remove(id);
      flows.deviceStates.remove(id);
      await serial.release(id);
      final removed = await devices.removeDevice(id);
      for (final s
          in registry[device?.driverId ?? '']?.settings ??
              const <SettingSpec>[]) {
        if (s.secret) await _secrets.delete(deviceSecretKey(id, s.key));
      }
      final disabled = <String>[];
      for (final r in await DriftFlowStore(_db).all()) {
        if (!r.enabled || !_mentionsDevice(r.json['nodes'], id)) continue;
        await _putFlow(
          r.json['id'] as String,
          {..._flowJsonOf(r), 'enabled': false},
          enabled: false,
          approved: r.approved,
          trusted: _trustedOf(r),
        );
        disabled.add(r.json['id'] as String);
      }
      await _reloadFlows();
      return {'removed': removed, 'flows': disabled};
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
      // The broker connection read the old password, so it reconnects now.
      if (manifest.transport.type == TransportType.mqtt) {
        await _mqtt.resetBroker(device, manifest);
      }
      return {'stored': deviceSecretKey(device.id, key)};
    },
  };

  /// Whether a node list refers to [deviceId] anywhere in its configs,
  /// conditions included.
  static bool _mentionsDevice(Object? value, String deviceId) =>
      switch (value) {
        Map m =>
          m['deviceId'] == deviceId ||
              m.values.any((v) => _mentionsDevice(v, deviceId)),
        List l => l.any((v) => _mentionsDevice(v, deviceId)),
        _ => false,
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
    final replace = args['replace'] == true;
    if (!replace && await DriftDeviceStore(_db).get(id) != null) {
      throw ApiError(
        'exists',
        'a device $id exists. Remove it first, or pass replace: true',
      );
    }
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
      name: _optString(args, 'name') ?? id,
      driverId: driverId,
      host: _string(args, 'host'),
      port: port as int?,
      room: _optString(args, 'room'),
      stableId: _optString(args, 'stableId'),
      settings: settings,
    );
    if (replace) {
      _stopLive(id);
      _provisioned.remove(id);
    }
    await DriftDeviceStore(_db).put(device);
    final missingSecrets = [
      for (final s in manifest.settings.where((s) => s.secret))
        if (await _secrets.read(deviceSecretKey(id, s.key)) == null) s.key,
    ];
    if (_hubRunning) _startLive(device, provision: false);
    Map<String, Object?>? board;
    String? boardError;
    if (isBoardDriver(manifest) && args['provision'] != false) {
      try {
        board = await provisionBoard(id);
      } catch (e) {
        boardError = e is ApiError ? e.message : '$e';
      }
    } else if (_hubRunning && isBoardDriver(manifest)) {
      _track(_provisionQuietly(id));
    }
    await _reloadFlows();
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

  /// A board says hello every 30 seconds.
  static const _boardOnlineWindow = Duration(seconds: 90);

  /// How long a device may go unseen and still count as online: three state
  /// polls, or three board hellos. Null when nothing reports it regularly.
  Duration? _onlineWindow(DriverManifest? manifest) {
    if (isBoardDriver(manifest)) return _boardOnlineWindow;
    final seconds = manifest?.statePoll?['intervalSeconds'];
    return seconds is int && seconds > 0
        ? Duration(seconds: 3 * seconds)
        : null;
  }

  Map<String, Object?> _deviceJson(Device d) {
    final manifest = registry[d.driverId];
    final window = _onlineWindow(manifest);
    return {
      'id': d.id,
      'name': d.name,
      'driver': d.driverId,
      'host': d.host,
      if (d.port != null) 'port': d.port,
      if (d.room != null) 'room': d.room,
      if (d.stableId != null) 'stableId': d.stableId,
      'board': isBoardDriver(manifest),
      if (window != null) 'online': d.isOnline(DateTime.now(), window),
      'settings': d.settings,
      'state': d.state,
      if (d.lastSeen != null) 'lastSeen': d.lastSeen!.toIso8601String(),
    };
  }

  static String _string(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is String && value.isNotEmpty) return value;
    throw ApiError('invalid', '$key is required');
  }

  static String? _optString(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value == null || value is String) return value as String?;
    throw ApiError('invalid', '$key must be a string');
  }

  static int? _optInt(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value == null || value is int) return value as int?;
    throw ApiError('invalid', '$key must be a whole number');
  }

  static num? _optNum(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value == null || value is num) return value as num?;
    throw ApiError('invalid', '$key must be a number');
  }

  static DateTime? _optDate(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value == null) return null;
    final parsed = value is String ? DateTime.tryParse(value) : null;
    if (parsed != null) return parsed;
    throw ApiError('invalid', '$key must be an ISO 8601 time');
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

  Future<Map<String, Object?>> _saveFlow(Map<String, Object?> args) async {
    final flow = FlowSpec.parse(_object(args, 'flow'));
    final issues = validateFlow(flow, refs: await _references());
    if (issues.isNotEmpty) {
      throw ValidationException('flow ${flow.id}', issues);
    }
    final highRisk = await _isHighRisk(flow);
    // Only the user's own tools (the CLI, the app) pass trusted: true.
    // Anything else (MCP, the architect, an import) is untrusted: its
    // high-risk flows wait for approval, and it cannot quietly replace a
    // flow the user saved or approved.
    final trusted = args['trusted'] == true;
    final existing = await DriftFlowStore(_db).get(flow.id);
    final approved = trusted || (!highRisk && !_trustedOf(existing));
    final json = flow.toJson();
    await _putFlow(
      flow.id,
      json,
      enabled: flow.enabled,
      approved: approved,
      trusted: trusted,
    );
    await _reloadFlows();
    return {
      'id': flow.id,
      'highRisk': highRisk,
      'approved': approved,
      'revision': _revisionOf(json),
    };
  }

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
    'flow.save': _saveFlow,
    'flow.approve': (args) async {
      final id = _string(args, 'id');
      final revision = _string(args, 'revision');
      final record = await DriftFlowStore(_db).get(id);
      if (record == null) throw ApiError('not_found', 'no flow $id');
      final json = _flowJsonOf(record);
      if (_revisionOf(json) != revision) {
        throw ApiError(
          'conflict',
          'flow $id changed since revision $revision. Review it again',
        );
      }
      await _putFlow(
        id,
        json,
        enabled: record.enabled,
        approved: true,
        trusted: true,
      );
      await _reloadFlows();
      return {'id': id, 'approved': true};
    },
    'flow.list': (_) async {
      final (records, specs, _) = await _storedFlows();
      final risky = await _highRiskFlows(specs.values);
      final dropped = flows.droppedRuns;
      return {
        'flows': [
          for (final r in records)
            {
              'id': r.json['id'],
              'name': r.json['name'],
              'enabled': r.enabled,
              'approved': r.approved,
              'highRisk': risky.contains(r.json['id']),
              'loaded': flows.loadedFlows.contains(r.json['id']),
              'revision': _revisionOf(_flowJsonOf(r)),
              'dropped': dropped[r.json['id']] ?? 0,
            },
        ],
        'loadIssues': loadIssues,
      };
    },
    'flow.get': (args) async {
      final record = await DriftFlowStore(_db).get(_string(args, 'id'));
      if (record == null) throw ApiError('not_found', 'no flow ${args['id']}');
      final json = _flowJsonOf(record);
      return {
        'flow': json,
        'enabled': record.enabled,
        'approved': record.approved,
        'revision': _revisionOf(json),
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
      await _putFlow(
        id,
        {..._flowJsonOf(record), 'enabled': enabled},
        enabled: enabled,
        approved: record.approved,
        trusted: _trustedOf(record),
      );
      await _reloadFlows();
      return {'id': id, 'enabled': enabled};
    },
    'flow.run': (args) async {
      final traces = await flows.run(
        _string(args, 'id'),
        triggerId: _optString(args, 'trigger'),
        msg: args['msg'] == null ? const {} : _object(args, 'msg'),
      );
      return {'runs': traces.map((t) => t.toJson()).toList()};
    },
    'flow.dryRun': (args) async {
      final id = _string(args, 'id');
      final record = await DriftFlowStore(_db).get(id);
      if (record == null) throw ApiError('not_found', 'no flow $id');
      final flow = FlowSpec.parse(_flowJsonOf(record));
      final trigger =
          _optString(args, 'trigger') ??
          flow.nodes
              .where(
                (n) =>
                    builtInNodeTypes[n.type]?.category == NodeCategory.trigger,
              )
              .firstOrNull
              ?.id;
      if (trigger == null) throw ApiError('invalid', 'flow $id has no trigger');
      final at = _optDate(args, 'at') ?? DateTime.now();
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
        flowId: _optString(args, 'id'),
        limit: _optInt(args, 'limit') ?? 20,
      ),
    },
    'flow.cards': (args) async {
      final record = await DriftFlowStore(_db).get(_string(args, 'id'));
      if (record == null) throw ApiError('not_found', 'no flow ${args['id']}');
      final cards = projectCards(FlowSpec.parse(_flowJsonOf(record)));
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
      await _reloadZones();
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
      await _reloadZones();
      return {'removed': removed};
    },
    'sensor.ble': (args) async {
      final rssi = args['rssi'];
      if (rssi is! num) throw ApiError('invalid', 'rssi must be a number');
      flows.bleReading(
        _string(args, 'name'),
        rssi.toDouble(),
        _optDate(args, 'at') ?? DateTime.now(),
      );
      return {'zones': flows.zones.states};
    },
    'sensor.wifi': (args) async {
      await flows.wifi(
        _optString(args, 'ssid'),
        _optString(args, 'bssid'),
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
      final parsed = parseBoardPins(
        pins,
        reserved: {for (final c in manifest!.capabilities) c.id},
      );
      // Checked against the board first, so a pin it cannot do never
      // replaces the pins that work. An offline board is checked when it
      // is next set up.
      Map<String, Object?>? describe;
      try {
        describe = (await devices.sendCommand(id, const {
          'cmd': 'describe',
        })).json;
      } on TransportTimeoutException {
        describe = null;
      }
      if (describe != null) {
        final problems = pinsUnsupportedBy(parsed, describe);
        if (problems.isNotEmpty) throw ApiError('invalid', problems.join('; '));
      }
      final previous = device.settings;
      await devices.updateDevice(
        id,
        (d) => d.copyWith(settings: {...d.settings, 'pins': pins}),
      );
      try {
        return {'board': await provisionBoard(id)};
      } on ApiError {
        await devices.updateDevice(id, (d) => d.copyWith(settings: previous));
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

  /// What a link from [source] can be, for the app to offer only links
  /// that can fire.
  static ({bool onOff, bool number}) _sourceKind(
    CapabilitySpec? capability,
    Object? current,
  ) => (
    onOff: capability?.type == CapabilityType.toggle || current is bool,
    number:
        const {
          CapabilityType.level,
          CapabilityType.colorTemp,
        }.contains(capability?.type) ||
        current is num,
  );

  Future<(Device, LinkEnd, CapabilitySpec?, Set<String>)> _linkSource(
    String text,
  ) async {
    final from = LinkEnd.parse(text, 'from');
    final source = await _device(from.deviceId);
    final manifest = manifestFor(registry, source);
    final capability = manifest?.capabilities
        .where((c) => stateKeyOf(c.stateJsonPath) == from.key)
        .firstOrNull;
    final knownKeys = {
      ...source.state.keys,
      for (final c in manifest?.capabilities ?? const <CapabilitySpec>[])
        ?stateKeyOf(c.stateJsonPath),
    };
    return (source, from, capability, knownKeys);
  }

  Map<String, Future<Map<String, Object?>> Function(Map<String, Object?> args)>
  get _linkCommands => {
    'link.create': (args) async {
      final (source, from, sourceCapability, knownKeys) = await _linkSource(
        _string(args, 'from'),
      );
      final to = LinkEnd.parse(_string(args, 'to'), 'to');
      final mode = LinkMode.values
          .where((m) => m.name == args['mode'])
          .firstOrNull;
      if (mode == null) {
        throw ApiError('invalid', 'mode must be toggle, follow or threshold');
      }
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
      // Each mode reads the source differently: a threshold compares a
      // number, a toggle waits for one value (on, unless onValue says),
      // and a follow copies the value, so both ends must be on/off, or
      // both numbers.
      final kind = _sourceKind(sourceCapability, source.state[from.key]);
      switch (mode) {
        case LinkMode.follow:
          final targetIsOnOff = target.type == CapabilityType.toggle;
          if ((kind.onOff && !targetIsOnOff) ||
              (kind.number && targetIsOnOff)) {
            throw ApiError(
              'invalid',
              '$to cannot follow $from: one is on/off and the other a number. Use a threshold link',
            );
          }
        case LinkMode.threshold:
          if (kind.onOff) {
            throw ApiError(
              'invalid',
              '$from is on/off, so it never crosses a number. Use a toggle or follow link',
            );
          }
        case LinkMode.toggle:
          if (kind.number && !args.containsKey('onValue')) {
            throw ApiError(
              'invalid',
              '$from is a number, so it is never on. Use a threshold link, or give onValue',
            );
          }
      }
      final range = sourceCapability?.params['value'];
      num bound(String key, num? fromCapability, num fallback) =>
          _optNum(args, key) ?? fromCapability ?? fallback;
      final request = LinkRequest(
        from: from,
        to: to,
        mode: mode,
        target: target,
        above: _optNum(args, 'above'),
        below: _optNum(args, 'below'),
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
      if (args['replace'] != true &&
          await DriftFlowStore(_db).get(request.id) != null) {
        throw ApiError(
          'exists',
          'this link exists as ${request.id}. Pass replace: true to save it again',
        );
      }
      final saved = await _saveFlow({
        'flow': flow,
        'trusted': args['trusted'] == true,
      });
      return {...saved, 'name': request.name};
    },
    'link.options': (args) async {
      final (source, from, sourceCapability, knownKeys) = await _linkSource(
        _string(args, 'from'),
      );
      if (!knownKeys.contains(from.key)) {
        throw ApiError(
          'not_found',
          '${from.deviceId} has no state ${from.key}',
        );
      }
      final kind = _sourceKind(sourceCapability, source.state[from.key]);
      final modes = [
        if (!kind.number) 'toggle',
        'follow',
        if (!kind.onOff) 'threshold',
      ];
      return {
        'from': '$from',
        'modes': modes,
        'targets': [
          for (final d in await DriftDeviceStore(_db).all())
            for (final c
                in manifestFor(registry, d)?.capabilities ??
                    const <CapabilitySpec>[])
              if (_targetModes(c, kind).isNotEmpty)
                {
                  'to': '${d.id}.${c.id}',
                  'type': c.type.wireName,
                  'modes': _targetModes(c, kind),
                },
        ],
      };
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

  /// The link modes that can drive capability [c] from a source of [kind],
  /// the same checks link.create and LinkRequest.toFlow make.
  static List<String> _targetModes(
    CapabilitySpec c,
    ({bool onOff, bool number}) kind,
  ) {
    final value = c.params['value'];
    final isToggle = c.type == CapabilityType.toggle;
    final takesNumber = value?.type == ParamType.number;
    return [
      if (isToggle && !kind.number) 'toggle',
      if (value != null &&
          (isToggle || takesNumber) &&
          !(kind.onOff && !isToggle) &&
          !(kind.number && isToggle))
        'follow',
      if (value != null && !kind.onOff) 'threshold',
    ];
  }

  static final _boardName = RegExp(r'^[a-z][a-z0-9_-]{0,22}$');

  /// Sets up a board on a USB serial port: Wi-Fi, node name and IR pin, all
  /// kept in the board's flash. With Wi-Fi it waits until the board joins
  /// and returns its address. The password goes to the board only.
  Future<Map<String, Object?>> _setupBoard(Map<String, Object?> args) async {
    final port = _string(args, 'port');
    final name = _optString(args, 'name');
    if (name != null && !_boardName.hasMatch(name)) {
      throw ApiError(
        'invalid',
        'name is lower snake case, at most 23 characters, like desk_board',
      );
    }
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
      if (name != null) {
        await send({'cmd': 'node.set', 'name': name});
        await _renameBoard(port, describe['node'], name);
      }
      if (args['irPin'] is int) {
        await send({'cmd': 'ir.pin', 'pin': args['irPin']});
      }
      var wifi = await send(const {'cmd': 'wifi.status'});
      if (args['ssid'] is String) {
        // A Pico W stops answering serial for up to 15 s while it joins, so a
        // late ack or a silent status poll is waited out until the deadline.
        final timeoutMs = _optInt(args, 'timeoutMs') ?? 30000;
        final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
        try {
          await send({
            'cmd': 'wifi.set',
            'ssid': args['ssid'],
            'password': args['password'] is String ? args['password'] : '',
          });
        } on TransportTimeoutException {
          // Joining: the status poll below tells whether it worked.
        }
        do {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          try {
            wifi = await send(const {'cmd': 'wifi.status'});
          } on TransportTimeoutException {
            continue;
          }
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

  /// A board device follows its board's new name: the one on this port, or
  /// the one known by the old name, so its events are not dropped.
  Future<void> _renameBoard(String port, Object? oldNode, String name) async {
    for (final d in await DriftDeviceStore(_db).all()) {
      if (!isBoardDriver(registry[d.driverId])) continue;
      final onPort = d.host == port;
      final byName =
          oldNode is String &&
          d.stableId?.toLowerCase() == oldNode.toLowerCase();
      if (onPort || byName) {
        await devices.updateDevice(d.id, (old) => old.copyWith(stableId: name));
      }
    }
  }

  /// Stops the inputs first so nothing new starts, waits for the work in
  /// flight, then closes the database and releases the lock whatever failed.
  Future<void> close() async {
    try {
      for (final t in _hubTimers) {
        t.cancel();
      }
      for (final t in _polls.values) {
        t.cancel();
      }
      _helloSocket?.close();
      await _wizPush?.stop();
      for (final s in _inputs) {
        await s.cancel();
      }
      await flows.close();
      while (_pending.isNotEmpty) {
        await Future.wait([..._pending]);
      }
      for (final close in _closers) {
        try {
          await close();
        } catch (_) {
          // The database and lock still have to be released.
        }
      }
    } finally {
      try {
        await _db.close();
      } finally {
        await _lock.release();
        await _events.close();
      }
    }
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
  ) async => (await _engine.devices.toggle(deviceId, capabilityId)).reply.json;

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
