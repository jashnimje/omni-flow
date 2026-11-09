import 'dart:io';

import 'api_error.dart';
import 'engine_core.dart';
import '../devices/board.dart';
import '../devices/channels.dart';
import '../devices/device.dart';
import '../devices/device_service.dart';
import '../manifest/driver_registry.dart';
import '../storage/database.dart';
import '../template/template_renderer.dart';
import '../transports/udp_transport.dart';

/// What the engine does with OmniFlow boards as they talk to it: board
/// events, hellos, moves, and bringing a board to its configured pins.
class BoardRuntime {
  BoardRuntime(this._core);

  final EngineCore _core;

  OmniDatabase get _db => _core.db;
  DriverRegistry get _registry => _core.registry;
  DeviceService get _devices => _core.devices;
  void _emit(Map<String, Object?> event) => _core.emit(event);
  void _track(Future<void> work) => _core.track(work);

  final _provisioned = <String>{};
  final _boardUptime = <String, int>{};
  final _provisioning = <String, Future<Map<String, Object?>>>{};
  final _provisionQueued = <String, Future<Map<String, Object?>>>{};

  /// The board [id] is to be set up again when the hub next sees it.
  void markNotSetUp(String id) => _provisioned.remove(id);

  /// Drops what this engine remembers about the board [id].
  void forget(String id) {
    _provisioned.remove(id);
    _boardUptime.remove(id);
    _track(DriftBoardDescribeStore(_db).remove(id).then((_) {}));
  }

  /// Asks the board [id] to describe itself and keeps the reply, so an
  /// offline board still shows what it last offered. Throws what the send
  /// throws, a [TransportTimeoutException] when the board does not answer.
  Future<Map<String, Object?>> describeBoard(String id) async {
    final reply = (await _devices.sendCommand(id, const {
      'cmd': 'describe',
    })).json;
    final describe = boardDescribeOf(reply ?? const {});
    if (describe.isNotEmpty) await _remember(id, describe);
    return describe;
  }

  Future<void> _remember(String id, Map<String, Object?> describe) =>
      DriftBoardDescribeStore(_db).put(id, describe, DateTime.now().toUtc());

  /// Unsolicited board lines (button presses, knob turns) become
  /// `board.event`. Replies (ack, error, describe) are not events. A pin
  /// change, a hello or a boot from an OmniFlow board also updates that
  /// board's device. [from] is the sender's address for a UDP message.
  void boardEvent(Map<String, Object?> json, String? deviceId, [String? from]) {
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
  Future<void> udpBoardMessage(
    Map<String, Object?> json,
    InternetAddress from,
  ) async {
    if (!isLocalNetworkAddress(from)) return;
    final devices = await DriftDeviceStore(_db).all();
    final sender = devices
        .where((d) => d.host == from.address)
        .where(
          (d) =>
              !isBoardDriver(_registry[d.driverId]) ||
              d.stableId == null ||
              d.stableId!.toLowerCase() == '${json['node']}'.toLowerCase(),
        )
        .firstOrNull;
    if (sender == null) return;
    boardEvent(json, sender.id, from.address);
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
    final manifest = _registry[device.driverId];
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
      await _devices.mergeState(device.id, {pin.name: pin.stateValue(value)});
    }
  }

  Future<Device?> _boardByNode(Object? node) async {
    if (node is! String) return null;
    for (final d in await DriftDeviceStore(_db).all()) {
      if (isBoardDriver(_registry[d.driverId]) &&
          d.stableId?.toLowerCase() == node.toLowerCase()) {
        return d;
      }
    }
    return null;
  }

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
      final board = _registry['omniflow_board'];
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
    final defaultPort = _registry[d.driverId]?.transport.port;
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
        d = await _devices.updateDevice(
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
        json['set'] == 0 && boardPinsOf(d, _registry[d.driverId]!).isNotEmpty;
    final rebooted = up is int && before != null && up < before;
    if (!_provisioned.contains(d.id) || lostSetup || rebooted) {
      await provisionBoard(d.id);
    } else {
      await describeBoard(d.id);
      await _devices.mergeState(d.id, const {});
    }
  }

  /// Whether a describe sent to [host] and [port] comes back from [node].
  Future<bool> _answersAs(Device d, String host, int? port, String node) async {
    final manifest = _registry[d.driverId];
    if (manifest == null) return false;
    try {
      final reply = await _core.boardChannel.send(
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
    final device = await _core.device(id);
    final manifest = _registry[device.driverId];
    if (!isBoardDriver(manifest)) {
      throw ApiError('invalid', '$id is not an OmniFlow board');
    }
    final pins = boardPinsOf(device, manifest!);
    final describe = await describeBoard(id);
    final problems = pinsUnsupportedBy(pins, describe);
    if (problems.isNotEmpty) throw ApiError('invalid', problems.join('; '));
    // The board answered at the stored address, so its name is the truth,
    // also after a rename over USB.
    final node = describe['node'];
    if (node is String &&
        device.stableId?.toLowerCase() != node.toLowerCase()) {
      await _devices.updateDevice(id, (d) => d.copyWith(stableId: node));
    }
    final current = await _core.device(id);
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
        reply = (await _devices.sendCommand(id, command)).json;
      } on CommandFailedException catch (e) {
        refused.add('${command['cmd']} pin ${command['pin']}: ${e.message}');
        continue;
      }
      final value = reply?['value'];
      if ((command['cmd'] == 'pin.watch' || command['cmd'] == 'pin.write') &&
          value is num) {
        final pin = pins.firstWhere((p) => p.pin == command['pin']);
        seeded[pin.name] = pin.stateValue(value);
      }
    }
    final updated = await _devices.mergeState(id, seeded);
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
      'warnings': strappingPinWarnings(pins, describe),
    };
  }

  Future<void> provisionQuietly(String id) async {
    try {
      await provisionBoard(id);
    } catch (e) {
      _emit({'event': 'board.offline', 'device': id, 'error': '$e'});
    }
  }
}
