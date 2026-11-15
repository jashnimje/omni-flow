import 'dart:async';
import 'dart:io';

import 'api_error.dart';
import 'away_lighting.dart';
import 'command_args.dart';
import 'energy_commands.dart';
import 'engine_core.dart';
import 'error_of.dart';
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
class SmartHome {
  SmartHome(
    this._core,
    Directory home, {
    required this.hubRunning,
    required EngineCall call,
    WeatherSource? weather,
  }) : _call = call,
       weather = weather ?? weatherSourceOverride ?? WeatherSource() {
    sun = SunLighting(_core, JsonFileStore(home, 'sunlight.json'));
    away = AwayLighting(_core, JsonFileStore(home, 'awaylight.json'), call);
    energy = EnergyCommands(_core, JsonFileStore(home, 'energy.json'));
    _subscription = _core.devices.events.listen(_observe, onDone: _stop);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (hubRunning()) unawaited(tick(DateTime.now()));
    });
  }

  /// Where weather comes from in tests, which serve it on loopback.
  static WeatherSource? weatherSourceOverride;

  final EngineCore _core;
  final bool Function() hubRunning;
  final EngineCall _call;
  final WeatherSource weather;
  late final SunLighting sun;
  late final AwayLighting away;
  late final EnergyCommands energy;
  late final StreamSubscription<DeviceStateChanged> _subscription;
  late final Timer _timer;
  final _seen = <String, Map<String, Object?>>{};
  final _weatherNext = <String, DateTime>{};
  var _ticking = false;

  Future<void> load() async {
    await sun.load();
    await away.load();
    await energy.load();
  }

  Map<String, CommandHandler> get commands => {
    ...sun.commands,
    ...away.commands,
    ...energy.commands,
    'weather.add': addWeather,
    'weather.refresh': refreshWeather,
  };

  void _observe(DeviceStateChanged e) {
    final now = DateTime.now();
    final before = _seen[e.device.id];
    _seen[e.device.id] = e.device.state;
    energy.observe(e, now);
    sun.observe(e, now, hubRunning: hubRunning());
    away.observe(e, before);
  }

  void _stop() => _timer.cancel();

  /// Stops the minute tick and saves what is not saved yet, as the engine
  /// closes.
  Future<void> close() async {
    _timer.cancel();
    await _subscription.cancel();
    await _flush();
  }

  Future<void> _flush() async {
    try {
      await energy.flush();
      await away.flush();
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
        () => sun.tick(now),
        () => away.tick(now),
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
    final home = _core.flows.homeLocation;
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

  /// `{name?, room?}`: adds the weather at home as a thing, then reads it.
  Future<Map<String, Object?>> addWeather(Map<String, Object?> args) async {
    if (_core.flows.homeLocation == null) {
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
