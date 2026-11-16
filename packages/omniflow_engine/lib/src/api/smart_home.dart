import 'dart:async';
import 'dart:io';

import 'api_error.dart';
import 'away_lighting.dart';
import 'command_args.dart';
import 'energy_commands.dart';
import 'engine_core.dart';
import 'error_of.dart';
import 'home_commands.dart' show houseLocation;
import 'houses.dart';
import 'smart_lights.dart';
import 'sun_lighting_runtime.dart';
import 'weather.dart';
import '../devices/device.dart';
import '../devices/device_service.dart';
import '../storage/database.dart';

/// Runs another engine command and returns its reply, which never throws.
typedef EngineCall = Future<Map<String, Object?>> Function(
  String command,
  Map<String, Object?> args,
);

/// The smart-home helpers that work on their own: the weather at home,
/// lights that follow the sun, away lighting and energy. Each keeps its
/// settings in a small file next to the database, and their timed work
/// runs once a minute while the hub runs.
///
/// Sun-following lights and away lighting are each house's own: one of
/// each per house, chosen by a command's `house` (the first house when it
/// names none), with the first house in the files named as before houses
/// and each other house in `sunlight.<house>.json` and
/// `awaylight.<house>.json`. Energy keeps one meter, with a price per house.
class SmartHome {
  SmartHome(
    this._core,
    Directory home, {
    required this.hubRunning,
    required this._call,
    WeatherSource? weather,
  }) : _home = home,
       weather = weather ?? weatherSourceOverride ?? WeatherSource() {
    _openHouse(firstHouseId);
    energy = EnergyCommands(_core, JsonFileStore(home, 'energy.json'));
    _subscription = _core.devices.events.listen(_observe, onDone: _stop);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (hubRunning()) unawaited(tick(DateTime.now()));
    });
  }

  /// Where weather comes from in tests, which serve it on loopback.
  static WeatherSource? weatherSourceOverride;

  final EngineCore _core;
  final Directory _home;
  final bool Function() hubRunning;
  final EngineCall _call;
  final WeatherSource weather;
  final _suns = <String, SunLighting>{};
  final _aways = <String, AwayLighting>{};
  StreamSubscription<Map<String, Object?>>? _houses;
  late final EnergyCommands energy;

  /// The first house's sun-following lights, as before houses.
  SunLighting get sun => sunOf(firstHouseId);

  /// The first house's away lighting, as before houses.
  AwayLighting get away => awayOf(firstHouseId);

  SunLighting sunOf(String house) => _suns[house] ?? _suns.values.first;

  AwayLighting awayOf(String house) => _aways[house] ?? _aways.values.first;

  static String _fileOf(String name, String house) =>
      house == firstHouseId ? '$name.json' : '$name.$house.json';

  /// Makes [house]'s sun lighting and away lighting, unless it has them.
  bool _openHouse(String house) {
    if (_suns.containsKey(house)) return false;
    _suns[house] = SunLighting(
      _core,
      JsonFileStore(_home, _fileOf('sunlight', house)),
      house: house,
    );
    _aways[house] = AwayLighting(
      _core,
      JsonFileStore(_home, _fileOf('awaylight', house)),
      (command, args) => _call(command, {...args, 'house': house}),
      house: house,
    );
    return true;
  }

  /// Opens every house's helpers, and those of a house added later.
  Future<void> _loadHouses() async {
    final ids = {for (final h in _core.houses.all) h.id};
    for (final gone in _suns.keys.where((k) => !ids.contains(k)).toList()) {
      if (gone == firstHouseId) continue;
      _suns.remove(gone);
      await _aways.remove(gone)?.flush();
    }
    for (final id in ids) {
      if (_openHouse(id)) {
        await _suns[id]!.load();
        await _aways[id]!.load();
      }
    }
  }

  /// The house a command names, or the first house.
  String _houseOf(Map<String, Object?> args) => _core.houses.target(args);
  late final StreamSubscription<DeviceStateChanged> _subscription;
  late final Timer _timer;
  final _seen = <String, Map<String, Object?>>{};
  final _weatherNext = <String, DateTime>{};
  var _ticking = false;

  Future<void> load() async {
    await sun.load();
    await away.load();
    await energy.load();
    await _loadHouses();
    _houses = _core.events
        .where((e) => e['event'] == housesChangedEvent)
        .listen((_) => _core.track(_loadHouses()));
  }

  Map<String, CommandHandler> get commands => {
    for (final name in sun.commands.keys)
      name: (args) async {
        final house = _houseOf(args);
        final targets = args['targets'] ?? args['target'];
        await _core.houses.checkNames({'things': targets}, house);
        return sunOf(house).commands[name]!(args);
      },
    for (final name in away.commands.keys)
      name: (args) async {
        final house = _houseOf(args);
        await _core.houses.checkNames({'things': args['lights']}, house);
        return awayOf(house).commands[name]!(args);
      },
    ...energy.commands,
    'weather.add': addWeather,
    'weather.refresh': refreshWeather,
  };

  void _observe(DeviceStateChanged e) {
    final now = DateTime.now();
    final before = _seen[e.device.id];
    _seen[e.device.id] = e.device.state;
    energy.observe(e, now);
    for (final sun in _suns.values) {
      sun.observe(e, now, hubRunning: hubRunning());
    }
    for (final away in _aways.values) {
      away.observe(e, before);
    }
  }

  void _stop() => _timer.cancel();

  /// A removed device: its energy totals, its place in sun and away
  /// lighting and what they last saw of it go, so a device added again
  /// under the same id starts clean.
  Future<void> forget(String id) async {
    _seen.remove(id);
    _weatherNext.remove(id);
    energy.meter.forget(id);
    await energy.forgetSaved();
    for (final sun in _suns.values) {
      await sun.forgetTarget(id);
    }
    for (final away in _aways.values) {
      await away.forgetLight(id);
    }
  }

  /// Stops the minute tick and saves what is not saved yet, as the engine
  /// closes.
  Future<void> close() async {
    _timer.cancel();
    await _subscription.cancel();
    await _houses?.cancel();
    await _flush();
  }

  Future<void> _flush() async {
    try {
      await energy.flush();
      for (final away in _aways.values) {
        await away.flush();
      }
    } on FileSystemException {
      // The home folder went away with the engine.
    }
  }

  /// The minute's work: the weather when it is due, the sun curve, the
  /// away replay, and saving the energy totals. A failure becomes an event.
  Future<void> tick(DateTime now) async {
    if (_ticking) return;
    _ticking = true;
    try {
      for (final step in [
        () => _weatherDue(now),
        for (final sun in _suns.values) () => sun.tick(now),
        for (final away in _aways.values) () => away.tick(now),
        () => energy.flush(),
      ]) {
        try {
          await step();
        } catch (e) {
          _core.emit({'event': 'smarthome.error', ...errorFields(e)});
        }
      }
    } finally {
      _ticking = false;
    }
  }

  Future<List<Device>> _weatherThings() async => [
    for (final d in await DriftDeviceStore(_core.db).all())
      if (d.driverId == weatherDriverId) d,
  ];

  Future<void> _weatherDue(DateTime now) async {
    for (final d in await _weatherThings()) {
      final updated = DateTime.tryParse('${d.state['updated_at']}');
      final next = _weatherNext[d.id];
      if (next != null && now.isBefore(next)) continue;
      if (updated != null && now.difference(updated) < weatherEvery) continue;
      try {
        await _refreshOne(d, now);
      } catch (_) {
        // _refreshOne reported it and set the retry.
      }
    }
  }

  Future<Device> _refreshOne(Device d, DateTime now) async {
    // The weather where the thing's own house is.
    final home = houseLocation(
      _core,
      _core.houses.thingHouses[d.id] ?? _core.houses.defaultId,
    );
    if (home == null) {
      _weatherNext[d.id] = now.add(weatherRetry);
      if (d.state['problem'] == weatherNeedsHome) return d;
      return _core.devices.mergeState(d.id, {'problem': weatherNeedsHome});
    }
    try {
      final state = await weather.read(home, now);
      _weatherNext.remove(d.id);
      return await _core.devices.mergeState(d.id, state);
    } catch (e) {
      _weatherNext[d.id] = now.add(weatherRetry);
      if (weatherStalePatch(d.state, now) case final stale?) {
        await _core.devices.mergeState(d.id, stale);
      }
      _core.emit({
        'event': 'weather.failed',
        'device': d.id,
        ...errorFields(e),
      });
      rethrow;
    }
  }

  /// `{id?}`: asks for the weather now, for one weather thing or all.
  Future<Map<String, Object?>> refreshWeather(Map<String, Object?> args) async {
    final id = optStringArg(args, 'id');
    final things = [
      for (final d in await _weatherThings())
        if (id == null || d.id == id) d,
    ];
    if (id != null && things.isEmpty) {
      throw ApiError('not_found', 'no weather thing $id');
    }
    final out = <Map<String, Object?>>[];
    for (final d in things) {
      try {
        out.add(_core.deviceJson(await _refreshOne(d, DateTime.now())));
      } on ApiError {
        rethrow;
      } catch (e) {
        throw ApiError(
          'unavailable',
          'Could not get the weather: ${errorFields(e)['error'] ?? e}',
        );
      }
    }
    return {'weather': out};
  }

  /// `{name?, room?, house?}`: adds the weather at the house as a thing,
  /// then reads it.
  Future<Map<String, Object?>> addWeather(Map<String, Object?> args) async {
    final house = _houseOf(args);
    if (houseLocation(_core, house) == null) {
      throw ApiError(
        'invalid',
        'Weather needs to know where home is. Set it in Settings, Home '
            'location, then add the weather again',
      );
    }
    final added = await _call('thing.add', {
      'driver': weatherDriverId,
      'name': optStringArg(args, 'name') ?? 'Weather at home',
      'room': ?optStringArg(args, 'room'),
      'house': house,
    });
    if (added['ok'] != true) {
      final error = added['error'] as Map? ?? const {};
      throw ApiError('${error['type']}', '${error['message']}');
    }
    final id = added['id'] as String?;
    String? problem;
    if (id != null) {
      try {
        await _refreshOne(await _core.device(id), DateTime.now());
      } catch (e) {
        problem =
            'Added. The weather will show once the weather service answers';
      }
    }
    return {...added..remove('ok'), 'problem': ?problem};
  }

  /// Whether [d] is a light the helpers can drive.
  bool isLight(Device d) => lightPartsOf(_core.registry[d.driverId]) != null;
}
