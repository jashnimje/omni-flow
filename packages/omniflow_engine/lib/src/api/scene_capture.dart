import 'api_error.dart';
import 'automation_commands.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'room_control.dart';
import 'stored_flows.dart';
import 'versions.dart' show keepingVersionsOf;
import '../devices/board.dart' show manifestFor;
import '../devices/device.dart';
import '../devices/device_service.dart' show stateKeyOf;
import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../storage/database.dart';

/// The scene actions that put [device] back the way it is now: its power,
/// and while on, its levels (brightness, volume), white temperature or
/// colour. Only what the device reports is kept, and nothing high risk.
List<Map<String, Object?>> capturedActions(
  Device device,
  DriverManifest manifest, {
  bool Function(CapabilitySpec)? highRisk,
}) {
  final state = device.state;
  Object? read(CapabilitySpec c) => state[stateKeyOf(c.stateJsonPath)];
  bool settable(CapabilitySpec c) => !(highRisk?.call(c) ?? false);
  Map<String, Object?> step(CapabilitySpec c, Map<String, Object?> params) => {
    'do': '${device.id}.${c.id}',
    'params': params,
  };

  final out = <Map<String, Object?>>[];
  final toggles = [
    for (final c in manifest.capabilities)
      if (c.type == CapabilityType.toggle && c.stateJsonPath != null) c,
  ];
  final power =
      toggles.where((c) => c.id == 'power').firstOrNull ?? toggles.firstOrNull;
  if (power != null && settable(power)) {
    final on = toggleIsOn(power, read(power));
    if (on != null) {
      out.add(step(power, {'value': on}));
      // A light told its brightness turns on, so an off device stays off.
      if (!on) return out;
    }
  }
  for (final c in toggles) {
    if (c == power || !settable(c)) continue;
    final on = toggleIsOn(c, read(c));
    if (on != null) out.add(step(c, {'value': on}));
  }
  for (final c in manifest.capabilities) {
    if (c.type != CapabilityType.level || !settable(c)) continue;
    final value = read(c);
    if (value is num) out.add(step(c, {'value': _fit(c, value)}));
  }
  final temp = manifest.capabilities
      .where((c) => c.type == CapabilityType.colorTemp && settable(c))
      .firstOrNull;
  final rgb = manifest.capabilities
      .where((c) => c.type == CapabilityType.colorRgb && settable(c))
      .firstOrNull;
  final white = temp == null ? null : read(temp);
  if (temp != null && white is num) {
    out.add(step(temp, {'value': _fit(temp, white)}));
  } else if (rgb != null &&
      ['r', 'g', 'b'].every((k) => state[k] is num) &&
      // A WiZ bulb on its white channels reports r, g and b all 0, which
      // as a colour would turn it off.
      ['r', 'g', 'b'].any((k) => (state[k] as num) > 0)) {
    out.add(
      step(rgb, {
        for (final k in ['r', 'g', 'b'])
          k: (state[k] as num).round().clamp(0, 255),
      }),
    );
  }
  return out;
}

/// [value] inside the capability's own range, whole when it takes whole
/// numbers.
num _fit(CapabilitySpec c, num value) {
  final spec = c.params['value'];
  var v = value;
  if (spec?.min case final num min when v < min) v = min;
  if (spec?.max case final num max when v > max) v = max;
  return spec?.integer == true ? v.round() : v;
}

/// `scene.capture {name, devices?: [ids], room?, icon?, color?, id?}`:
/// saves a scene of how those devices are now.
class SceneCapture {
  SceneCapture(this._core, this._stored, this._automations);

  final EngineCore _core;
  final StoredFlows _stored;
  final AutomationCommands _automations;

  Map<String, CommandHandler> get commands => {'scene.capture': capture};

  Future<Map<String, Object?>> capture(Map<String, Object?> args) async {
    final ids = args['devices'];
    final room = optStringArg(args, 'room');
    if ((ids == null) == (room == null)) {
      throw ApiError('invalid', 'give devices (a list of ids) or a room');
    }
    final List<Device> devices;
    if (room != null) {
      devices = (await roomWithDevices(_core, room)).$2;
    } else {
      if (ids is! List || ids.isEmpty || ids.any((i) => i is! String)) {
        throw ApiError('invalid', 'devices must be a list of device ids');
      }
      final store = DriftDeviceStore(_core.db);
      devices = [
        for (final id in ids.cast<String>().toSet())
          await store.get(id) ?? (throw ApiError('not_found', 'no device $id')),
      ];
    }
    final actions = <Map<String, Object?>>[];
    final skipped = <String>[];
    for (final d in devices) {
      final manifest = manifestFor(_core.registry, d);
      final found = manifest == null
          ? const <Map<String, Object?>>[]
          : capturedActions(
              d,
              manifest,
              highRisk: (c) => _stored.capabilityIsHighRisk(manifest, c),
            );
      found.isEmpty ? skipped.add(d.id) : actions.addAll(found);
    }
    if (actions.isEmpty) {
      throw ApiError(
        'invalid',
        'none of these devices report a state a scene can set',
      );
    }
    // Capturing over a scene keeps the one it replaces, as a save does.
    final saved = await keepingVersionsOf(
      _core.db,
      () => _automations.saveScene({
        'id': ?optStringArg(args, 'id'),
        'name': args['name'],
        'icon': ?args['icon'],
        'color': ?args['color'],
        'actions': actions,
      }, args['trusted'] == true),
    );
    // A state older than the device's poll window may no longer be true.
    final now = DateTime.now();
    final stale = [
      for (final d in devices)
        if (!skipped.contains(d.id))
          if (_core.onlineWindowOf(d) case final window?
              when !d.isOnline(now, window))
            {
              'id': d.id,
              'name': d.name,
              'lastSeen': ?d.lastSeen?.toUtc().toIso8601String(),
            },
    ];
    return {...saved, 'actions': actions, 'skipped': skipped, 'stale': stale};
  }
}
