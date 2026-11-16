import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'home_commands.dart' show houseLocation;
import 'houses.dart' show firstHouseId;
import '../dag/sun.dart' show HomeLocation;
import 'error_of.dart';
import 'smart_lights.dart';
import 'sun_lighting.dart';
import '../devices/board.dart' show manifestFor;
import '../devices/device.dart';
import '../devices/device_service.dart';
import '../manifest/capability.dart';
import '../storage/database.dart';

/// What the user asked to follow the sun: a light or a room, with its curve.
typedef SunTarget = ({bool room, SunCurve curve});

/// Lights that follow the sun: `sunlight.set`, `sunlight.get` and
/// `sunlight.apply`, and every [sunlightEvery] while the hub runs, each
/// followed light that is on is brought to the curve. A light someone
/// changes by hand is left alone for [sunlightPause].
class SunLighting {
  SunLighting(this._core, this._store, {this.house = firstHouseId});

  final EngineCore _core;
  final JsonFileStore _store;

  /// The house whose lights these are: the curve follows the sun where it
  /// is.
  final String house;

  HomeLocation? get _location => houseLocation(_core, house);

  final targets = <String, SunTarget>{};
  final _paused = <String, DateTime>{};

  /// What was last sent to each light, by state key, in its own units.
  final _sent = <String, Map<String, Object?>>{};

  /// Each followed light's state at its last change.
  final _seen = <String, Map<String, Object?>>{};
  DateTime? _lastApply;

  Map<String, CommandHandler> get commands => {
    'sunlight.set': set,
    'sunlight.get': get,
    'sunlight.apply': (_) => apply(DateTime.now()),
  };

  Future<void> load() async {
    final json = await _store.read();
    final saved = json['targets'];
    if (saved is! Map) return;
    for (final e in saved.entries) {
      if (e.value is! Map) continue;
      final v = Map<String, Object?>.from(e.value as Map);
      try {
        targets['${e.key}'] = (room: v['room'] == true, curve: SunCurve.of(v));
      } on ApiError {
        // A damaged entry is dropped, and the rest still follow the sun.
      }
    }
  }

  Future<void> _save() => _store.write({
    'targets': {
      for (final e in targets.entries)
        e.key: {'room': e.value.room, ...e.value.curve.toJson()},
    },
  });

  LightParts? _partsOf(Device d) =>
      lightPartsOf(manifestFor(_core.registry, d));

  /// `{targets: [id], enabled, minK?, maxK?, minBrightness?,
  /// maxBrightness?}`: a target is a light's id or a room's id.
  Future<Map<String, Object?>> set(Map<String, Object?> args) async {
    final raw = args['targets'] ?? args['target'];
    final ids = raw is String ? [raw] : raw;
    if (ids is! List || ids.isEmpty || ids.any((t) => t is! String)) {
      throw ApiError('invalid', 'targets must be a list of light or room ids');
    }
    final enabled = args['enabled'];
    if (enabled is! bool) {
      throw ApiError('invalid', 'enabled must be true or false');
    }
    // The curve follows the sun at home, so it cannot start before home
    // has a place on the map. The app, the CLI and an agent all hear this.
    if (enabled && _location == null) {
      throw ApiError(
        'invalid',
        'Follow the sun needs to know where ${_core.houses.nameOf(house)} is. '
            'Set it in Settings, This house, Home location (or omni home '
            'location set), then turn it on',
      );
    }
    final devices = await DriftDeviceStore(_core.db).all();
    for (final id in ids.cast<String>()) {
      if (!enabled) {
        targets.remove(id);
        continue;
      }
      final device = devices.where((d) => d.id == id).firstOrNull;
      final room = _core.roomNames.containsKey(id);
      if (device == null && !room) {
        throw ApiError('not_found', 'no light or room $id');
      }
      if (device != null && _partsOf(device) == null) {
        throw ApiError('invalid', '${device.name} is not a light');
      }
      final base = targets[id]?.curve ?? const SunCurve();
      targets[id] = (room: device == null, curve: SunCurve.of(args, base));
    }
    await _save();
    return get(const {});
  }

  /// The curve a light follows: its own when it was picked, else its room's.
  SunCurve? curveFor(Device d) =>
      targets[d.id]?.curve ?? (d.room == null ? null : targets[d.room]?.curve);

  /// `{target?}`: every target with its lights, which are paused, and
  /// today's curve for [target] (or the default curve) every 30 minutes.
  Future<Map<String, Object?>> get(Map<String, Object?> args) async {
    final now = DateTime.now();
    final target = optStringArg(args, 'target');
    final devices = await DriftDeviceStore(_core.db).all();
    final home = _location;
    final curve = targets[target]?.curve ?? const SunCurve();
    return {
      'targets': [
        for (final e in targets.entries)
          {
            'id': e.key,
            'kind': e.value.room ? 'room' : 'light',
            'name': e.value.room
                ? _core.roomNames[e.key] ?? e.key
                : devices.where((d) => d.id == e.key).firstOrNull?.name ??
                      e.key,
            ...e.value.curve.toJson(),
            'lights': [
              for (final d in lightsOf([e.key], devices, _partsOf)) d.id,
            ],
          },
      ],
      'paused': [
        for (final e in _paused.entries)
          if (e.value.isAfter(now))
            {'id': e.key, 'until': e.value.toIso8601String()},
      ],
      'curve': curve.toJson(),
      if (home == null)
        'problem': 'Set where home is first: lights follow the sun at home'
      else ...{
        'now': () {
          final elevation = sunElevation(now, home);
          final v = curve.at(elevation, peakElevation(now, home));
          return {
            'elevation': double.parse(elevation.toStringAsFixed(1)),
            'kelvin': v.kelvin,
            'brightness': v.brightness,
          };
        }(),
        'preview': curve.preview(now, home),
      },
    };
  }

  /// Runs from the engine's minute tick while the hub runs.
  Future<void> tick(DateTime now) async {
    final last = _lastApply;
    if (targets.isEmpty) return;
    if (last != null && now.difference(last) < sunlightEvery) return;
    await apply(now);
  }

  /// Brings every followed light that is on, and not paused, to the curve.
  Future<Map<String, Object?>> apply(DateTime now, {String? only}) async {
    _lastApply = now;
    final home = _location;
    if (home == null) {
      return {
        'applied': const [],
        'problem': 'Set where home is first: lights follow the sun at home',
      };
    }
    final elevation = sunElevation(now, home);
    final peak = peakElevation(now, home);
    final applied = <String>[];
    final paused = <String>[];
    final off = <String>[];
    final failed = <String>[];
    final devices = await DriftDeviceStore(_core.db).all();
    for (final d in lightsOf(targets.keys, devices, _partsOf)) {
      if (only != null && d.id != only) continue;
      final parts = _partsOf(d)!;
      final curve = curveFor(d);
      if (curve == null) continue;
      if (!parts.isOn(d.state)) {
        off.add(d.id);
        continue;
      }
      if (_paused[d.id]?.isAfter(now) ?? false) {
        paused.add(d.id);
        continue;
      }
      final v = curve.at(elevation, peak);
      try {
        if (await _send(d, parts, v.kelvin, v.brightness)) applied.add(d.id);
      } catch (e) {
        failed.add(d.id);
        _core.emit({
          'event': 'sunlight.failed',
          'device': d.id,
          ...errorFields(e),
        });
      }
    }
    return {
      'applied': applied,
      'paused': paused,
      'off': off,
      if (failed.isNotEmpty) 'failed': failed,
    };
  }

  /// Sends what differs from the light's state. True when anything was sent.
  Future<bool> _send(
    Device d,
    LightParts parts,
    int kelvin,
    int percent,
  ) async {
    final temp = parts.colorTemp;
    final bright = parts.brightness;
    final tempValue = temp == null ? null : kelvinToDevice(temp, kelvin);
    final brightValue = bright == null
        ? null
        : percentToDevice(bright, percent);
    final tempKey = parts.colorTempKey;
    final brightKey = parts.brightnessKey;
    final tempSame =
        temp == null ||
        (tempKey != null && closeTo(temp, d.state[tempKey], tempValue));
    final brightSame =
        bright == null ||
        (brightKey != null && closeTo(bright, d.state[brightKey], brightValue));
    if (tempSame && brightSame) return false;
    final sent = {?tempKey: tempValue, ?brightKey: brightValue};
    Future<void> invoke(String capability, Map<String, Object?> params) => _core
        .devices
        .invoke(d.id, capability, params, allowPairing: false, by: sunlightBy);
    if (temp != null &&
        !tempSame &&
        bright != null &&
        temp.params.containsKey('brightness')) {
      await invoke(temp.id, {'value': tempValue, 'brightness': brightValue});
    } else {
      if (bright != null && !brightSame) {
        await invoke(bright.id, {'value': brightValue});
      }
      if (temp != null && !tempSame) {
        await invoke(temp.id, {'value': tempValue});
      }
    }
    _sent[d.id] = sent;
    return true;
  }

  /// A change to a followed light that the engine did not send pauses it.
  void observe(DeviceStateChanged e, DateTime now, {required bool hubRunning}) {
    final d = e.device;
    if (curveFor(d) == null) return;
    final parts = _partsOf(d);
    if (parts == null) return;
    final before = _seen[d.id];
    _seen[d.id] = d.state;
    if (before == null || e.by == sunlightBy) return;
    final sent = _sent[d.id] ?? const {};
    bool changedByHand(String? key, CapabilitySpec? cap) {
      if (key == null || cap == null) return false;
      final now = d.state[key];
      return !closeTo(cap, before[key], now) && !closeTo(cap, sent[key], now);
    }

    if (changedByHand(parts.brightnessKey, parts.brightness) ||
        changedByHand(parts.colorTempKey, parts.colorTemp)) {
      _paused[d.id] = now.add(sunlightPause);
      return;
    }
    // A light just turned on takes the curve at once.
    if (hubRunning && !parts.isOn(before) && parts.isOn(d.state)) {
      _core.track(apply(now, only: d.id).then((_) {}));
    }
  }

  /// Whether [id] is paused at [now], for tests and the light page.
  bool isPaused(String id, DateTime now) => _paused[id]?.isAfter(now) ?? false;

  void forget(String id) {
    _paused.remove(id);
    _sent.remove(id);
    _seen.remove(id);
  }

  /// A removed light: forgotten, and no longer followed on its own.
  Future<void> forgetTarget(String id) async {
    forget(id);
    if (targets.remove(id) != null) await _save();
  }
}
