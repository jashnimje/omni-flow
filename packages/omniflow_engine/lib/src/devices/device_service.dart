import 'dart:async';

import 'package:json_path/json_path.dart';

import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/driver_registry.dart';
import '../template/template_renderer.dart';
import '../transports/udp_transport.dart';
import 'board.dart';
import 'channels.dart';
import 'device.dart';
import 'wiz_pilot.dart' show isWizPilot, wizStateAfter;

/// A JSONPath naming one top-level key: `$.dimming` or `$['1']`.
final _topLevelKey = RegExp(
  r"^\$(?:\.([A-Za-z_][A-Za-z0-9_]*)|\['([^']+)'\])$",
);

/// The top-level state key a capability reads, or null for deeper paths.
String? stateKeyOf(String? jsonPath) {
  final m = jsonPath == null ? null : _topLevelKey.firstMatch(jsonPath);
  return m == null ? null : (m.group(1) ?? m.group(2));
}

/// The device setting listing the secret settings a device refused commands
/// without (a WiZ bulb's home key), which makes those setup steps required.
const setupNeedsSetting = 'setupNeeds';

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
  const DeviceStateChanged(this.device, {this.by});

  final Device device;

  /// Who sent the command that changed it: an automation id or `user`.
  /// Null when the device reported the change itself.
  final String? by;
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

  /// Devices removed while commands to them were still queued or running.
  /// Those commands never write the device back.
  final _removed = <String>{};
  final _events = StreamController<DeviceStateChanged>.broadcast();

  Stream<DeviceStateChanged> get events => _events.stream;

  /// The stored device, or null when there is none or it was just removed.
  Future<Device?> device(String deviceId) async =>
      _removed.contains(deviceId) ? null : _store.get(deviceId);

  /// Deletes the device at once, without waiting for commands to it.
  Future<bool> removeDevice(String deviceId) async {
    _removed.add(deviceId);
    final removed = await _store.remove(deviceId);
    unawaited(_serialised(deviceId, () async => _removed.remove(deviceId)));
    return removed;
  }

  /// Validates [params] against the capability, renders and sends the
  /// command, and records the resulting state.
  Future<InvokeResult> invoke(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    bool allowPairing = true,
    String? by,
  }) => _serialised(deviceId, () async {
    final (device, manifest) = await _resolve(deviceId);
    return _invoke(
      device,
      manifest,
      _capability(manifest, capabilityId),
      params,
      allowPairing: allowPairing,
      by: by,
    );
  });

  /// Sends the opposite of the toggle's current state. The state is read in
  /// order with the other commands to the device, so two toggles at once
  /// flip it twice.
  Future<InvokeResult> toggle(
    String deviceId,
    String capabilityId, {
    bool allowPairing = true,
    String? by,
  }) => _serialised(deviceId, () async {
    final (device, manifest) = await _resolve(deviceId);
    final capability = _capability(manifest, capabilityId);
    final key = stateKeyOf(capability.stateJsonPath);
    if (key == null) {
      throw ArgumentError('$deviceId.$capabilityId cannot be toggled');
    }
    return _invoke(
      device,
      manifest,
      capability,
      {'value': device.state[key] != true},
      allowPairing: allowPairing,
      by: by,
    );
  });

  CapabilitySpec _capability(DriverManifest manifest, String capabilityId) =>
      manifest.capability(capabilityId) ??
      (throw DeviceNotFoundException(
        '${manifest.id} has no capability $capabilityId',
      ));

  Future<InvokeResult> _invoke(
    Device device,
    DriverManifest manifest,
    CapabilitySpec capability,
    Map<String, Object?> params, {
    bool allowPairing = true,
    String? by,
  }) async {
    if (!capability.type.hasCommand) {
      throw ArgumentError(
        '${device.id}.${capability.id} is a ${capability.type.wireName} and takes no command',
      );
    }
    final power = manifest.capability('power');
    if (capability.asksForZero(params) &&
        power != null &&
        power.type == CapabilityType.toggle) {
      return _invoke(
        device,
        manifest,
        power,
        {'value': false},
        allowPairing: allowPairing,
        by: by,
      );
    }
    final validated = capability.validateParams(params);
    final (Device, ChannelReply) sent;
    try {
      sent = await _sendHealing(device, manifest, capability.command, {
        ...capability.withDerived(validated, device.settings),
        'value': ?capability.toDevice(validated['value']),
      }, allowPairing: allowPairing);
    } on SecretNeededException catch (e) {
      await _markNeeds(device, e.secretKey);
      rethrow;
    }
    final (current, reply) = sent;
    var state = _optimisticState(current.state, capability, validated);
    if (isWizPilot(manifest) && reply.sent != null) {
      state = wizStateAfter(state, reply.sent!);
    }
    final updated = current.copyWith(state: state, lastSeen: _clock());
    await _save(updated, by: by);
    return InvokeResult(updated, reply);
  }

  /// Records in the device's [setupNeedsSetting] that it refuses commands
  /// until the secret setting [key] is stored, so its setup asks for it.
  Future<void> _markNeeds(Device device, String key) async {
    final current = await this.device(device.id) ?? device;
    final needs = current.settings[setupNeedsSetting];
    if (needs is List && needs.contains(key)) return;
    await _save(
      current.copyWith(
        settings: {
          ...current.settings,
          setupNeedsSetting: [...?(needs is List ? needs : null), key],
        },
      ),
    );
  }

  /// Runs the driver's poll command and replaces the device state with what
  /// it returns. A reply with none of the keys the capabilities read is not
  /// this device's state (a late ack to an earlier command), so the state
  /// stays as it was.
  ///
  /// With [allowPairing] false a device that is not paired yet fails with
  /// [PairingRequiredException] instead of raising a prompt on its screen.
  Future<Device> refreshState(String deviceId, {bool allowPairing = true}) =>
      _serialised(deviceId, () async {
        final (device, manifest) = await _resolve(deviceId);
        final poll = manifest.statePoll;
        if (poll == null || poll['command'] == null) {
          throw DeviceNotFoundException('${manifest.id} has no statePoll');
        }
        var (current, reply) = await _sendHealing(
          device,
          manifest,
          poll['command'],
          const {},
          allowPairing: allowPairing,
        );
        var polled = _extractObject(reply.json, poll['jsonPath'] as String?);
        // `also` lists more reads whose objects merge into the first, for
        // a device that spreads its state over several requests. Its
        // `keys` keep only those keys, so a second read cannot overwrite
        // a key of the first that means something else (a Shelly meter's
        // overpower watts against its relay's overpower flag).
        for (final extra in (poll['also'] as List?) ?? const []) {
          final (moved, more) = await _sendHealing(
            current,
            manifest,
            (extra as Map)['command'],
            const {},
            allowPairing: allowPairing,
          );
          current = moved;
          var part = _extractObject(more.json, extra['jsonPath'] as String?);
          if (part != null && extra['keys'] is List) {
            final keep = {...(extra['keys'] as List).cast<String>()};
            part = {
              for (final e in part.entries)
                if (keep.contains(e.key)) e.key: e.value,
            };
          }
          if (part != null) polled = {...?polled, ...part};
        }
        final keys = {
          for (final c in manifest.capabilities) ?stateKeyOf(c.stateJsonPath),
        };
        if (polled != null &&
            keys.isNotEmpty &&
            !keys.any(polled.containsKey)) {
          return current;
        }
        final updated = current.copyWith(
          state: polled == null ? current.state : _readBack(manifest, polled),
          lastSeen: _clock(),
        );
        await _save(updated);
        return updated;
      });

  /// Sends one literal command (no capability) and returns the reply. The
  /// board setup uses it for `describe`, `pin.mode` and `pin.watch`.
  Future<ChannelReply> sendCommand(
    String deviceId,
    Map<String, Object?> command,
  ) => _serialised(deviceId, () async {
    final (device, manifest) = await _resolve(deviceId);
    final (current, reply) = await _sendHealing(
      device,
      manifest,
      command,
      const {},
    );
    return reply;
  });

  /// Applies [change] to the stored device (a new host, new settings), in
  /// order with the commands to it.
  Future<Device> updateDevice(
    String deviceId,
    Device Function(Device) change,
  ) => _serialised(deviceId, () async {
    final device = await this.device(deviceId);
    if (device == null) throw DeviceNotFoundException('no device $deviceId');
    final updated = change(device);
    await _save(updated);
    return updated;
  });

  /// Merges [values] into the device state and marks it seen now.
  Future<Device> mergeState(String deviceId, Map<String, Object?> values) =>
      _serialised(deviceId, () async {
        final (device, _) = await _resolve(deviceId);
        final updated = device.copyWith(
          state: {...device.state, ...values},
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
        // `exclusive` lists key groups only one of which holds at a time (a
        // WiZ bulb is in white, colour or a scene): a push with keys of one
        // group drops the other groups' stale keys.
        final state = {...device.state};
        final groups = push['exclusive'];
        if (groups is List) {
          final lists = [
            for (final g in groups)
              if (g is List) g,
          ];
          for (final group in lists) {
            if (!group.any(pushed.containsKey)) continue;
            for (final other in lists) {
              if (!identical(other, group)) other.forEach(state.remove);
            }
          }
        }
        final updated = device.copyWith(
          state: {...state, ..._readBack(manifest, pushed)},
          lastSeen: _clock(),
        );
        await _save(updated);
        return updated;
      });

  /// Device words for on and off (`"ON"`) become `true` and `false` under
  /// each toggle's state key, so dashboards and links see one shape.
  Map<String, Object?> _readBack(
    DriverManifest manifest,
    Map<String, Object?> state,
  ) {
    final out = {...state};
    for (final c in manifest.capabilities) {
      final key = stateKeyOf(c.stateJsonPath);
      if (c.onOff != null && key != null && out.containsKey(key)) {
        out[key] = c.fromDevice(out[key]);
      }
    }
    return out;
  }

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
    final device = await this.device(deviceId);
    if (device == null) throw DeviceNotFoundException('no device $deviceId');
    final manifest = manifestFor(_registry, device);
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
    Map<String, Object?> params, {
    bool allowPairing = true,
  }) async {
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
      allowPairing: allowPairing,
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
      // An exec host is an address the user typed, never a discovery reply.
      if (locator == null ||
          stableId == null ||
          manifest.transport.type == TransportType.exec) {
        rethrow;
      }
      final host = await locator(manifest, stableId);
      if (host == null || host == device.host) rethrow;
      if (!_healsBlind(manifest)) {
        throw TransportTimeoutException(
          'no reply from ${device.id} at ${device.host}. A device announcing '
          'its id answers at $host, but ${device.id} sends secrets with its '
          'commands, and an announced id proves nothing. If that is the '
          'device, add ${device.id} again with host $host',
        );
      }
      final moved = device.copyWith(host: host);
      await _save(moved);
      return (moved, await channel.send(requestFor(moved)));
    }
  }

  /// Whether a device may follow a discovery reply to a new address
  /// unchecked. Any LAN host can copy the id a device announces, so only a
  /// driver without secrets moves blindly. A Tuya local key only encrypts
  /// and never goes on the wire, so a Tuya device moves too, and so does a
  /// WiZ bulb, whose home key only signs.
  static bool _healsBlind(DriverManifest manifest) =>
      manifest.transport.type == TransportType.tuya ||
      isWizPilot(manifest) ||
      !manifest.settings.any((s) => s.secret);

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

  Future<void> _save(Device device, {String? by}) async {
    if (_removed.contains(device.id)) return;
    await _store.put(device);
    if (!_events.isClosed) _events.add(DeviceStateChanged(device, by: by));
  }

  Future<void> close() => _events.close();
}
