import 'engine_calls.dart' show Json;
import 'engine_client.dart';

/// Every call the home helpers make (the house mode, named timers, a room
/// as one light, a scene saved from how things are now, and the built-in
/// alerts), with the fields read back from each result.
abstract final class HouseCalls {
  static const mode = 'home.mode';
  static const modeSet = 'home.mode.set';
  static const modeChanged = 'home.modeChanged';
  static const timers = 'timer.list';
  static const timerStart = 'timer.start';
  static const timerCancel = 'timer.cancel';
  static const timerPause = 'timer.pause';
  static const timerResume = 'timer.resume';
  static const timersChanged = 'timer.changed';
  static const roomInvoke = 'room.invoke';
  static const roomState = 'room.state';
  static const sceneCapture = 'scene.capture';
  static const alerts = 'alerts.get';
  static const alertsSet = 'alerts.set';

  /// The things the engine itself is, which rules name like any thing.
  static const modeThing = 'house_mode';
  static const timersThing = 'timers';
}

/// One house mode: Home, Away, Night, Vacation, or one the user added.
class HouseMode {
  const HouseMode(this.id, this.name, {this.builtIn = true});

  factory HouseMode.fromJson(Json j) => HouseMode(
    '${j['id']}',
    '${j['name'] ?? j['id']}',
    builtIn: j['builtIn'] != false,
  );

  final String id;
  final String name;
  final bool builtIn;
}

/// The mode now and every mode, as `home.mode` gives them.
class HouseModes {
  const HouseModes({
    required this.mode,
    required this.modes,
    this.followPresence = false,
  });

  /// Null when the engine gave no mode (an older engine).
  static HouseModes? fromJson(Json j) {
    final mode = j['mode'];
    if (mode is! String) return null;
    return HouseModes(
      mode: mode,
      modes: [
        for (final m in (j['modes'] as List? ?? const []))
          if (m is Map) HouseMode.fromJson(Map<String, Object?>.from(m)),
      ],
      followPresence: j['followPresence'] == true,
    );
  }

  final String mode;
  final List<HouseMode> modes;
  final bool followPresence;

  String get name => nameOf(mode);

  String nameOf(String id) =>
      modes.where((m) => m.id == id).firstOrNull?.name ?? modeName(id);

  List<String> get custom => [
    for (final m in modes)
      if (!m.builtIn) m.name,
  ];
}

/// An id read as a name, as the engine words it: `movie_night` is "Movie
/// night".
String modeName(String id) {
  final words = id.replaceAll('_', ' ').trim();
  return words.isEmpty ? id : '${words[0].toUpperCase()}${words.substring(1)}';
}

/// A name as the id the engine gives it: lower case, other characters `_`.
String houseIdOf(String name) => name
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

/// One named timer. A running one counts down from [endsAt], so the strip
/// needs no tick event.
class HouseTimer {
  const HouseTimer({
    required this.id,
    required this.name,
    required this.durationMs,
    required this.paused,
    this.endsAt,
    this.remainingMs = 0,
  });

  factory HouseTimer.fromJson(Json j) => HouseTimer(
    id: '${j['id']}',
    name: '${j['name'] ?? j['id']}',
    durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
    paused: j['state'] == 'paused',
    endsAt: DateTime.tryParse('${j['endsAt']}'),
    remainingMs: (j['remainingMs'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String name;
  final int durationMs;
  final bool paused;
  final DateTime? endsAt;
  final int remainingMs;

  Duration left(DateTime now) {
    final ends = endsAt;
    if (paused || ends == null) return Duration(milliseconds: remainingMs);
    final d = ends.difference(now);
    return d.isNegative ? Duration.zero : d;
  }
}

List<HouseTimer> timersOf(Object? list) => [
  for (final t in (list as List? ?? const []))
    if (t is Map) HouseTimer.fromJson(Map<String, Object?>.from(t)),
];

/// `12:05` or `1:02:05`: what is left on a timer.
String countdownText(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// How a room's lights are, as `room.state` gives it.
class RoomLights {
  const RoomLights({
    required this.id,
    required this.name,
    required this.lights,
    required this.lightsOn,
    this.offline = 0,
    this.brightness,
  });

  static RoomLights? fromJson(Json j) {
    final room = j['room'];
    if (room is! Map) return null;
    return RoomLights(
      id: '${room['id']}',
      name: '${room['name'] ?? room['id']}',
      lights: (j['lights'] as num?)?.toInt() ?? 0,
      lightsOn: (j['lightsOn'] as num?)?.toInt() ?? 0,
      offline: (j['offline'] as num?)?.toInt() ?? 0,
      brightness: (j['brightness'] as num?)?.toInt(),
    );
  }

  final String id;
  final String name;
  final int lights;
  final int lightsOn;

  /// Lights that are not answering, left out of [lightsOn].
  final int offline;
  final int? brightness;

  bool get anyOn => lightsOn > 0;

  String get summary {
    final reachable = lights - offline;
    if (reachable <= 0) return lights == 1 ? 'Offline' : 'All offline';
    final on = lightsOn == 0
        ? 'All off'
        : lightsOn == reachable
        ? (brightness == null ? 'All on' : 'All on, $brightness%')
        : '$lightsOn of $reachable on';
    return offline == 0 ? on : '$on, $offline offline';
  }
}

/// The built-in alerts and whether each is on.
class HouseAlerts {
  const HouseAlerts({required this.offline, required this.battery});

  factory HouseAlerts.fromJson(Json j) => HouseAlerts(
    offline: j['offline'] != false,
    battery: j['battery'] != false,
  );

  final bool offline;
  final bool battery;
}

/// The calls, on one client. Each returns the engine's reply as it came.
class HouseApi {
  const HouseApi(this._client);

  final EngineClient _client;

  Future<Json> modes() => _client.call(HouseCalls.mode);

  Future<Json> setMode(String mode) =>
      _client.call(HouseCalls.modeSet, {'mode': mode});

  Future<Json> setModes(List<String> names) =>
      _client.call(HouseCalls.modeSet, {'modes': names});

  Future<Json> followPresence(bool on) =>
      _client.call(HouseCalls.modeSet, {'followPresence': on});

  Future<Json> timers() => _client.call(HouseCalls.timers);

  Future<Json> cancelTimer(String name) =>
      _client.call(HouseCalls.timerCancel, {'name': name});

  Future<Json> pauseTimer(String name) =>
      _client.call(HouseCalls.timerPause, {'name': name});

  Future<Json> resumeTimer(String name) =>
      _client.call(HouseCalls.timerResume, {'name': name});

  Future<Json> roomState(String room) =>
      _client.call(HouseCalls.roomState, {'room': room});

  /// Sends one capability to every light in [room].
  Future<Json> roomLights(String room, String capability, Json params) =>
      _client.call(HouseCalls.roomInvoke, {
        'room': room,
        'capability': capability,
        'params': params,
        'only': 'lights',
      });

  Future<Json> captureScene(String name, List<String> devices) => _client.call(
    HouseCalls.sceneCapture,
    {'name': name, 'devices': devices, 'trusted': true},
  );

  Future<Json> alerts() => _client.call(HouseCalls.alerts);

  Future<Json> setAlerts({bool? offline, bool? battery}) => _client.call(
    HouseCalls.alertsSet,
    {'offline': ?offline, 'battery': ?battery},
  );
}
