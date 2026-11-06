import 'dart:async';

import 'package:json_path/json_path.dart';

import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/driver_registry.dart';
import '../template/template_renderer.dart';
import '../transports/udp_transport.dart';
import 'channels.dart';
import 'device.dart';

/// A JSONPath naming one top-level key: `$.dimming` or `$['1']`.
final _topLevelKey = RegExp(
  r"^\$(?:\.([A-Za-z_][A-Za-z0-9_]*)|\['([^']+)'\])$",
);

class DeviceNotFoundException implements Exception {
  DeviceNotFoundException(this.message);

  final String message;

  @override
  String toString() => 'DeviceNotFoundException: $message';
}

/// Finds a device's current address from its stable id, through discovery.
typedef DeviceLocator = Future<String?> Function(
  DriverManifest driver,
  String stableId,
);

class DeviceStateChanged {
  const DeviceStateChanged(this.device);

  final Device device;
}

class InvokeResult {
  const InvokeResult(this.device, this.reply);

  final Device device;
  final ChannelReply reply;
}

/// Sends capability commands to devices and keeps their state current.
///
/// Commands to one device run one at a time, in order. A command that times
/// out triggers one discovery lookup by stable id, and is retried once at
/// the new address if the device moved.
class DeviceService {
  DeviceService({
    required this._registry,
    required this._store,
    required this._channels,
    this._locator,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final DriverRegistry _registry;
  final DeviceStore _store;
  final Map<TransportType, DriverChannel> _channels;
  final DeviceLocator? _locator;
  final DateTime Function() _clock;
  final _queues = <String, Future<void>>{};
  final _events = StreamController<DeviceStateChanged>.broadcast();

  Stream<DeviceStateChanged> get events => _events.stream;

  /// Validates [params] against the capability, renders and sends the
  /// command, and records the resulting state.
  Future<InvokeResult> invoke(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params,
  ) => _serialised(deviceId, () async {
    final (device, manifest) = await _resolve(deviceId);
    final capability = manifest.capability(capabilityId);
    if (capability == null) {
      throw DeviceNotFoundException(
        '${manifest.id} has no capability $capabilityId',
      );
    }
    final validated = capability.validateParams(params);
    final (current, reply) = await _sendHealing(
      device,
      manifest,
      capability.command,
      validated,
    );
    final state = _optimisticState(current.state, capability, validated);
    final updated = current.copyWith(state: state, lastSeen: _clock());
    await _save(updated);
    return InvokeResult(updated, reply);
  });

  /// Runs the driver's poll command and replaces the device state with what it returns.
  Future<Device> refreshState(String deviceId) =>
      _serialised(deviceId, () async {
        final (device, manifest) = await _resolve(deviceId);
        final poll = manifest.statePoll;
        if (poll == null || poll['command'] == null) {
          throw DeviceNotFoundException('${manifest.id} has no statePoll');
        }
        final (current, reply) = await _sendHealing(
          device,
          manifest,
          poll['command'],
          const {},
        );
        final polled = _extractObject(reply.json, poll['jsonPath'] as String?);
        final updated = current.copyWith(
          state: polled ?? current.state,
          lastSeen: _clock(),
        );
        await _save(updated);
        return updated;
      });

  /// Merges a pushed state packet (WiZ syncPilot) into the device state.
  Future<Device?> applyPush(String deviceId, Map<String, Object?> message) =>
      _serialised(deviceId, () async {
        final (device, manifest) = await _resolve(deviceId);
        final push = manifest.statePush;
        if (push == null) return null;
        final method = push['method'];
        if (method != null && message['method'] != method) return null;
        final pushed = _extractObject(message, push['jsonPath'] as String?);
        if (pushed == null) return null;
        final updated = device.copyWith(
          state: {...device.state, ...pushed},
          lastSeen: _clock(),
        );
        await _save(updated);
        return updated;
      });

  Future<T> _serialised<T>(String deviceId, Future<T> Function() task) {
    final previous = _queues[deviceId] ?? Future<void>.value();
    final result = previous.then((_) => task());
    final tail = result.then<void>((_) {}, onError: (_) {});
    _queues[deviceId] = tail;
    tail.whenComplete(() {
      if (identical(_queues[deviceId], tail)) _queues.remove(deviceId);
    });
    return result;
  }

  Future<(Device, DriverManifest)> _resolve(String deviceId) async {
    final device = await _store.get(deviceId);
    if (device == null) throw DeviceNotFoundException('no device $deviceId');
    final manifest = _registry[device.driverId];
    if (manifest == null) {
      throw DeviceNotFoundException(
        'device $deviceId uses unknown driver ${device.driverId}',
      );
    }
    return (device, manifest);
  }

  Future<(Device, ChannelReply)> _sendHealing(
    Device device,
    DriverManifest manifest,
    Object? command,
    Map<String, Object?> params,
  ) async {
    final channel = _channels[manifest.transport.type];
    if (channel == null) {
      throw UnsupportedError(
        'no channel for transport ${manifest.transport.type.wireName}',
      );
    }
    ChannelRequest requestFor(Device d) => ChannelRequest(
      device: d,
      manifest: manifest,
      command: command,
      context: TemplateContext(
        params: params,
        state: d.state,
        device: d.settings,
      ),
    );
    try {
      return (device, await channel.send(requestFor(device)));
    } on TransportTimeoutException {
      final locator = _locator;
      final stableId = device.stableId;
      if (locator == null || stableId == null) rethrow;
      final host = await locator(manifest, stableId);
      if (host == null || host == device.host) rethrow;
      final moved = device.copyWith(host: host);
      await _store.put(moved);
      return (moved, await channel.send(requestFor(moved)));
    }
  }

  /// Writes the commanded value into state where the capability reads it,
  /// when that is a simple `$.key` path. The next push or poll corrects it.
  Map<String, Object?> _optimisticState(
    Map<String, Object?> state,
    CapabilitySpec capability,
    Map<String, Object?> params,
  ) {
    final path = capability.stateJsonPath;
    final value = params['value'];
    final match = path == null ? null : _topLevelKey.firstMatch(path);
    if (match == null || value == null) return state;
    return {...state, (match.group(1) ?? match.group(2))!: value};
  }

  Map<String, Object?>? _extractObject(
    Map<String, Object?>? json,
    String? path,
  ) {
    if (json == null) return null;
    final value = path == null
        ? json
        : JsonPath(path).readValues(json).firstOrNull;
    return value is Map ? Map<String, Object?>.from(value) : null;
  }

  Future<void> _save(Device device) async {
    await _store.put(device);
    if (!_events.isClosed) _events.add(DeviceStateChanged(device));
  }

  Future<void> close() => _events.close();
}
