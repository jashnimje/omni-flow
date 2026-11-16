import 'api_error.dart';
import 'command_args.dart';
import 'device_history.dart' show callerOf;
import 'engine_core.dart';
import 'error_of.dart';
import 'smart_lights.dart' show kelvinToDevice, percentToDevice;
import 'stored_flows.dart';
import '../devices/board.dart' show manifestFor;
import '../devices/device.dart';
import '../devices/device_service.dart' show stateKeyOf;
import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../storage/database.dart';

/// The category a light's driver has.
const lightingCategory = 'lighting';

/// The room [room] names, by id or by name in any case, with its devices
/// in the user's order.
Future<(Room, List<Device>)> roomWithDevices(
  EngineCore core,
  String room,
) async {
  final wanted = room.trim().toLowerCase();
  final match = (await DriftRoomStore(core.db).all())
      .where((r) => r.id == room || r.name.trim().toLowerCase() == wanted)
      .firstOrNull;
  if (match == null) throw ApiError('not_found', 'there is no room $room');
  final devices = [
    for (final d in await DriftDeviceStore(core.db).all())
      if (d.room == match.id) d,
  ]..sort((a, b) => (a.order ?? 1 << 30).compareTo(b.order ?? 1 << 30));
  return (match, devices);
}

/// Whether a toggle's reported [raw] state is on. Stored state is already
/// `true` or `false` for a device with on and off words, and a raw word is
/// read through the capability's own decoding.
bool? toggleIsOn(CapabilitySpec toggle, Object? raw) {
  final value = toggle.fromDevice(raw);
  return value is bool ? value : null;
}

/// [value] in a light's own units as a percent of its range, 0 to 100.
num devicePercent(CapabilitySpec capability, num value) {
  final max = capability.params['value']?.max ?? 100;
  if (max <= 0) return value;
  return (value * 100 / max).clamp(0, 100);
}

/// Whether [capability] is a light's brightness, which a room takes in
/// percent.
bool _isBrightness(CapabilitySpec c) =>
    c.type == CapabilityType.level &&
    (c.id == 'brightness' || c.id == 'dimmer');

/// Whether [capability] is a white temperature, which a room takes in
/// kelvin.
bool _isWhite(CapabilitySpec c) =>
    c.id == 'color_temp' &&
    (c.type == CapabilityType.colorTemp || c.type == CapabilityType.level);

/// A room as one light: `room.invoke {room, capability, params?, only?}`
/// sends to every device in it that has the capability, and `room.state
/// {room}` sums the room up.
class RoomControl {
  RoomControl(this._core, this._stored);

  final EngineCore _core;
  final StoredFlows _stored;

  Map<String, CommandHandler> get commands => {
    'room.invoke': invoke,
    'room.state': state,
  };

  DriverManifest? _manifest(Device d) => manifestFor(_core.registry, d);

  static bool _isLight(DriverManifest? m) => m?.category == lightingCategory;

  /// `{room, capability, params?, only?: "lights"}`. Every device that has
  /// the capability gets it, one failing does not stop the rest, and the
  /// reply says how each went. A high-risk capability is never sent here:
  /// it goes through `device.invoke`.
  Future<Map<String, Object?>> invoke(Map<String, Object?> args) async {
    final (room, devices) = await roomWithDevices(
      _core,
      stringArg(args, 'room'),
    );
    final capability = stringArg(args, 'capability');
    final params = args['params'] == null
        ? const <String, Object?>{}
        : objectArg(args, 'params');
    final only = optStringArg(args, 'only');
    if (only != null && only != 'lights') {
      throw ApiError('invalid', 'only must be lights');
    }
    final value = params['value'];
    if (value is num &&
        (capability == 'brightness' || capability == 'dimmer') &&
        (value < 0 || value > 100 || !value.isFinite)) {
      throw ApiError('invalid', 'a room takes brightness from 0 to 100 %');
    }
    if (value is num && capability == 'color_temp' && !value.isFinite) {
      throw ApiError('invalid', 'a room takes white in kelvin');
    }
    final results = <Map<String, Object?>>[];
    for (final d in devices) {
      final manifest = _manifest(d);
      final spec = manifest?.capability(capability);
      if (manifest == null || spec == null) continue;
      final sent = value is! num
          ? params
          : _isBrightness(spec)
          ? {...params, 'value': percentToDevice(spec, value)}
          : _isWhite(spec)
          ? {...params, 'value': kelvinToDevice(spec, value)}
          : params;
      if (only == 'lights' && !_isLight(manifest)) continue;
      if (_stored.capabilityIsHighRisk(manifest, spec)) {
        results.add({
          'id': d.id,
          'name': d.name,
          'ok': false,
          'error': {
            'type': 'needs_user',
            'message':
                '$capability on ${d.name} is high risk, so it is sent '
                'to the device on its own',
          },
        });
        continue;
      }
      try {
        final result = await _core.devices.invoke(
          d.id,
          capability,
          sent,
          allowPairing: false,
          by: callerOf(args),
        );
        results.add({
          'id': d.id,
          'name': d.name,
          'ok': true,
          'state': result.device.state,
        });
      } catch (e) {
        results.add({
          'id': d.id,
          'name': d.name,
          'ok': false,
          'error': apiErrorOf(e).toJson(),
        });
      }
    }
    if (results.isEmpty) {
      throw ApiError('not_found', 'nothing in ${room.name} can do $capability');
    }
    return {
      'room': {'id': room.id, 'name': room.name},
      'results': results,
      'sent': results.where((r) => r['ok'] == true).length,
    };
  }

  /// `{room}`: its lights, how many are on, and their average brightness
  /// as a percent of each light's own range.
  /// A light that is offline counts in `offline`, not as on, since its
  /// stored state is only what it last said.
  Future<Map<String, Object?>> state(Map<String, Object?> args) async {
    final (room, devices) = await roomWithDevices(
      _core,
      stringArg(args, 'room'),
    );
    var lights = 0;
    var on = 0;
    var offline = 0;
    final now = DateTime.now();
    final levels = <num>[];
    final things = <Map<String, Object?>>[];
    for (final d in devices) {
      final manifest = _manifest(d);
      if (!_isLight(manifest)) continue;
      lights++;
      final window = _core.onlineWindowOf(d);
      final reachable = window == null || d.isOnline(now, window);
      if (!reachable) {
        offline++;
        things.add({'id': d.id, 'name': d.name, 'online': false});
        continue;
      }
      final power = manifest!.capability('power');
      final isOn = power == null
          ? null
          : toggleIsOn(power, d.state[stateKeyOf(power.stateJsonPath)]);
      if (isOn == true) on++;
      final level =
          manifest.capability('brightness') ?? manifest.capability('dimmer');
      final value = level == null
          ? null
          : d.state[stateKeyOf(level.stateJsonPath)];
      final percent = value is num
          ? devicePercent(level!, value).round()
          : null;
      if (isOn == true && percent != null) levels.add(percent);
      things.add({
        'id': d.id,
        'name': d.name,
        'on': ?isOn,
        'brightness': ?percent,
      });
    }
    return {
      'room': {'id': room.id, 'name': room.name},
      'devices': devices.length,
      'lights': lights,
      'lightsOn': on,
      'offline': offline,
      'anyOn': on > 0,
      if (levels.isNotEmpty)
        'brightness': (levels.reduce((a, b) => a + b) / levels.length).round(),
      'things': things,
    };
  }
}
