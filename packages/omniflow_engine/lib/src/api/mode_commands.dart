import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'house_things.dart';
import 'things_runtime.dart' show personDriverId;
import '../storage/database.dart';

/// `home.json` read and written a key at a time, so the home location,
/// the mode and the alert switches share it without losing each other.
class HomeFile {
  HomeFile(Directory home) : _file = File('${home.path}/home.json');

  final File _file;
  Future<void> _last = Future.value();

  Future<Map<String, Object?>> read() async {
    try {
      final json = jsonDecode(await _file.readAsString());
      if (json is Map) return Map<String, Object?>.from(json);
    } on FileSystemException {
      // Never written.
    } on FormatException {
      // A damaged file reads as empty, and the next write replaces it.
    }
    return {};
  }

  /// Sets [values] and keeps every other key. Writes run one at a time.
  Future<void> update(Map<String, Object?> values) {
    final next = _last.then((_) async {
      final json = {...await read(), ...values};
      final temp = File('${_file.path}.tmp');
      await temp.writeAsString(jsonEncode(json), flush: true);
      await temp.rename(_file.path);
    });
    _last = next.catchError((Object _) {});
    return next;
  }
}

/// The house mode: Home, Away, Night, Vacation and the user's own, kept in
/// `home.json`. A change raises `home.modeChanged` and the event `changed`
/// on the [houseModeThing], and the mode is that thing's state, so rules
/// start on it and check it. With `followPresence` on, the mode goes to
/// Away when the last person leaves and to Home when someone gets back.
class HouseModes {
  HouseModes(this._core, this._file);

  final EngineCore _core;
  final HomeFile _file;

  static const _maxCustom = 20;

  var _mode = builtInModes.first;
  final _custom = <String>[];
  var _followPresence = false;
  bool? _anyoneHome;
  StreamSubscription<Map<String, Object?>>? _sub;

  String get mode => _mode;

  Map<String, CommandHandler> get commands => {
    'home.mode': get,
    'home.mode.set': set,
  };

  Future<void> open() async {
    final json = await _file.read();
    _custom
      ..clear()
      ..addAll([
        for (final m in json['modes'] as List? ?? const [])
          if (m is String && houseIdOf(m) != null) m,
      ]);
    _followPresence = json['modeFollowsPresence'] == true;
    final saved = json['mode'];
    _mode = saved is String && _ids.contains(saved) ? saved : builtInModes[0];
    _seed();
    _anyoneHome = await _peopleHome();
    _sub = _core.events.listen(_observe);
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
  }

  void _seed() => _core.flows.deviceStates[houseModeThing] = {'mode': _mode};

  List<String> get _ids => [
    ...builtInModes,
    for (final c in _custom) houseIdOf(c)!,
  ];

  String _nameOf(String id) =>
      _custom.where((c) => houseIdOf(c) == id).firstOrNull ?? houseNameOf(id);

  Map<String, Object?> _json() => {
    'mode': _mode,
    'name': _nameOf(_mode),
    'modes': [
      for (final id in builtInModes)
        {'id': id, 'name': houseNameOf(id), 'builtIn': true},
      for (final c in _custom)
        {'id': houseIdOf(c), 'name': c, 'builtIn': false},
    ],
    'followPresence': _followPresence,
  };

  Future<Map<String, Object?>> get(Map<String, Object?> _) async => _json();

  /// `{mode?, modes?, followPresence?}`: the mode now (an id or a name),
  /// the user's own modes by name, and whether presence moves the mode.
  Future<Map<String, Object?>> set(Map<String, Object?> args) async {
    final follow = args['followPresence'];
    if (follow != null && follow is! bool) {
      throw ApiError('invalid', 'followPresence must be true or false');
    }
    if (args.containsKey('modes')) await _setCustom(args['modes']);
    if (follow is bool && follow != _followPresence) {
      _followPresence = follow;
      _anyoneHome = await _peopleHome();
      await _file.update({'modeFollowsPresence': follow});
    }
    final mode = optStringArg(args, 'mode');
    if (mode != null) await setMode(mode, by: changedBy(args));
    return _json();
  }

  static String changedBy(Map<String, Object?> args) =>
      optStringArg(args, 'by') ?? 'user';

  Future<void> _setCustom(Object? raw) async {
    if (raw is! List || raw.any((m) => m is! String)) {
      throw ApiError('invalid', 'modes must be a list of mode names');
    }
    final names = [
      for (final m in raw.cast<String>())
        if (m.trim().isNotEmpty) m.trim(),
    ];
    if (names.length > _maxCustom) {
      throw ApiError('invalid', 'a home has at most $_maxCustom own modes');
    }
    final seen = {...builtInModes};
    for (final n in names) {
      final id = houseIdOf(n);
      if (id == null || n.length > 40) {
        throw ApiError('invalid', '"$n" needs a letter or a digit, up to 40');
      }
      if (!seen.add(id)) {
        throw ApiError('exists', 'there is already a mode called $n');
      }
    }
    _custom
      ..clear()
      ..addAll(names);
    await _file.update({'modes': names});
    if (!_ids.contains(_mode)) await setMode(builtInModes.first, by: 'user');
  }

  /// Moves the house to [mode], an id or a name. Saying the mode it is in
  /// changes nothing and raises nothing.
  Future<Map<String, Object?>> setMode(
    String mode, {
    required String by,
  }) async {
    final wanted = mode.trim();
    final id =
        _ids.where((i) => i == wanted).firstOrNull ??
        _ids.where((i) => i == houseIdOf(wanted)).firstOrNull;
    if (id == null) {
      throw ApiError(
        'not_found',
        'there is no mode $mode. The modes are '
            '${_ids.map(_nameOf).join(', ')}',
      );
    }
    final previous = _mode;
    if (id == previous) return _json();
    _mode = id;
    await _file.update({'mode': id});
    _seed();
    _core.emit({
      'event': 'home.modeChanged',
      'mode': id,
      'name': _nameOf(id),
      'previous': previous,
      'by': by,
    });
    _core.raiseEvent(houseModeThing, 'changed', {
      'mode': id,
      'previous': previous,
    });
    return _json();
  }

  /// `house_mode.set {mode}` from a flow.
  Future<Map<String, Object?>?> invoke(
    String capability,
    Map<String, Object?> params, {
    String? by,
  }) async {
    if (capability != 'set') {
      throw ApiError('invalid', 'the mode has no action $capability');
    }
    final mode = params['mode'];
    if (mode is! String) throw ApiError('invalid', 'mode must be a mode id');
    return setMode(mode, by: by ?? 'automation');
  }

  Future<bool> _peopleHome() async {
    for (final d in await DriftDeviceStore(_core.db).all()) {
      if (d.driverId == personDriverId && d.state['home'] == true) return true;
    }
    return false;
  }

  void _observe(Map<String, Object?> e) {
    if (!_followPresence || e['event'] != 'device.stateChanged') return;
    final device = e['device'];
    if (device is! Map || device['driver'] != personDriverId) return;
    _core.track(_followPeople());
  }

  /// Acts on a change only: someone leaving or arriving. A mode the user
  /// picked while the house stays as it is, stays.
  Future<void> _followPeople() async {
    final home = await _peopleHome();
    if (home == _anyoneHome) return;
    _anyoneHome = home;
    if (!home && _mode != 'away' && _mode != 'vacation') {
      await setMode('away', by: 'presence');
    } else if (home && (_mode == 'away' || _mode == 'vacation')) {
      await setMode('home', by: 'presence');
    }
  }

  /// What a backup keeps under `home`.
  Map<String, Object?> backupJson() => {
    'mode': _mode,
    if (_custom.isNotEmpty) 'modes': List.of(_custom),
    if (_followPresence) 'modeFollowsPresence': true,
  };

  /// Takes the mode settings a backup's `home` holds. A backup from before
  /// modes keeps what is here.
  Future<void> restore(Object? home) async {
    if (home is! Map) return;
    if (home['modes'] is List) await _setCustom(home['modes']);
    if (home['modeFollowsPresence'] is bool) {
      await set({'followPresence': home['modeFollowsPresence']});
    }
    if (home['mode'] case final String m when _ids.contains(m)) {
      await setMode(m, by: 'backup');
    }
  }
}
