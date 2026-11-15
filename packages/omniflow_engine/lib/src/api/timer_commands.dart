import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'house_things.dart';

/// One named timer. A running timer keeps when it ends, so it survives a
/// restart and the app counts down from it. A paused one keeps what is left.
class HouseTimer {
  HouseTimer({
    required this.id,
    required this.name,
    required this.durationMs,
    this.endsAt,
    this.leftMs,
  });

  final String id;
  final String name;
  final int durationMs;

  /// When it ends, while running.
  DateTime? endsAt;

  /// What is left, while paused.
  int? leftMs;

  bool get paused => endsAt == null;

  int remainingMs(DateTime now) => paused
      ? leftMs ?? 0
      : endsAt!.difference(now).inMilliseconds.clamp(0, durationMs);

  Map<String, Object?> toJson(DateTime now) => {
    'id': id,
    'name': name,
    'durationMs': durationMs,
    'state': paused ? 'paused' : 'running',
    if (endsAt != null) 'endsAt': endsAt!.toUtc().toIso8601String(),
    'remainingMs': remainingMs(now),
  };

  static HouseTimer? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final duration = json['durationMs'];
    if (id is! String || name is! String || duration is! int) return null;
    final ends = json['endsAt'] is String
        ? DateTime.tryParse(json['endsAt'] as String)
        : null;
    final left = json['remainingMs'];
    if (ends == null && left is! int) return null;
    return HouseTimer(
      id: id,
      name: name,
      durationMs: duration,
      endsAt: ends,
      leftMs: ends == null ? left as int : null,
    );
  }
}

/// Named timers: `timer.list`, `timer.start {name, ms}`, `timer.cancel`,
/// `timer.pause` and `timer.resume {name}`, and the same as steps on the
/// [timersThing]. They are kept in `timers.json`, so one that ended while
/// the engine was closed ends as soon as it opens. An ending raises the
/// event `ended` on the timers thing, `timer.ended`, and a notification.
/// Every change sends `timer.changed` with the list.
class HouseTimers {
  HouseTimers(this._core, Directory home, {DateTime Function()? clock})
    : _file = File('${home.path}/timers.json'),
      _now = clock ?? DateTime.now;

  final EngineCore _core;
  final File _file;
  final DateTime Function() _now;
  final _timers = <String, HouseTimer>{};
  final _alarms = <String, Timer>{};
  Future<void> _lastWrite = Future.value();

  static const _max = 20;

  Map<String, CommandHandler> get commands => {
    'timer.list': list,
    'timer.start': start,
    'timer.cancel': cancel,
    'timer.pause': pause,
    'timer.resume': resume,
  };

  Future<void> open() async {
    try {
      final json = jsonDecode(await _file.readAsString());
      for (final t in (json is Map ? json['timers'] as List? : null) ?? []) {
        if (HouseTimer.fromJson(t) case final timer?) {
          _timers[timer.id] = timer;
        }
      }
    } on FileSystemException {
      // No timers yet.
    } on FormatException {
      // A damaged file holds no timers.
    }
    for (final t in _timers.values.toList()) {
      _schedule(t);
    }
  }

  Future<void> close() async {
    for (final a in _alarms.values) {
      a.cancel();
    }
    _alarms.clear();
    await _lastWrite;
  }

  List<Map<String, Object?>> _list() {
    final now = _now();
    final timers = _timers.values.toList()
      ..sort((a, b) => a.remainingMs(now).compareTo(b.remainingMs(now)));
    return [for (final t in timers) t.toJson(now)];
  }

  Future<Map<String, Object?>> list(Map<String, Object?> _) async => {
    'timers': _list(),
  };

  HouseTimer _named(Map<String, Object?> args) {
    final name = stringArg(args, 'name');
    final timer = _timers[houseIdOf(name)];
    if (timer == null) throw ApiError('not_found', 'no timer called $name');
    return timer;
  }

  /// `{name, ms}`: starts a timer, or starts one of that name again.
  Future<Map<String, Object?>> start(Map<String, Object?> args) async {
    final name = stringArg(args, 'name').trim();
    final id = houseIdOf(name);
    if (id == null || name.length > 40) {
      throw ApiError(
        'invalid',
        'a timer name needs a letter or a digit, up to 40',
      );
    }
    final ms = args['ms'];
    if (ms is! int || ms < 1000 || ms > timerMaxMs) {
      throw ApiError('invalid', 'ms must be 1000 to $timerMaxMs (a day)');
    }
    if (!_timers.containsKey(id) && _timers.length >= _max) {
      throw ApiError('invalid', 'at most $_max timers run at once');
    }
    final timer = HouseTimer(
      id: id,
      name: name,
      durationMs: ms,
      endsAt: _now().add(Duration(milliseconds: ms)),
    );
    _timers[id] = timer;
    _schedule(timer);
    await _changed();
    return {'timer': timer.toJson(_now())};
  }

  Future<Map<String, Object?>> cancel(Map<String, Object?> args) async {
    final timer = _named(args);
    _timers.remove(timer.id);
    _alarms.remove(timer.id)?.cancel();
    await _changed();
    return {'cancelled': timer.id};
  }

  Future<Map<String, Object?>> pause(Map<String, Object?> args) async {
    final timer = _named(args);
    if (!timer.paused) {
      timer
        ..leftMs = timer.remainingMs(_now())
        ..endsAt = null;
      _alarms.remove(timer.id)?.cancel();
      await _changed();
    }
    return {'timer': timer.toJson(_now())};
  }

  Future<Map<String, Object?>> resume(Map<String, Object?> args) async {
    final timer = _named(args);
    if (timer.paused) {
      timer
        ..endsAt = _now().add(Duration(milliseconds: timer.leftMs ?? 0))
        ..leftMs = null;
      _schedule(timer);
      await _changed();
    }
    return {'timer': timer.toJson(_now())};
  }

  /// A timer step from a flow: `timers.start {name, ms}` and the others.
  Future<Map<String, Object?>?> invoke(
    String capability,
    Map<String, Object?> params, {
    String? by,
  }) => switch (capability) {
    'start' => start(params),
    'cancel' => cancel(params),
    'pause' => pause(params),
    'resume' => resume(params),
    _ => throw ApiError('invalid', 'timers have no action $capability'),
  };

  void _schedule(HouseTimer t) {
    _alarms.remove(t.id)?.cancel();
    final ends = t.endsAt;
    if (ends == null) return;
    final left = ends.difference(_now());
    if (left <= Duration.zero) {
      _core.track(_end(t));
      return;
    }
    _alarms[t.id] = Timer(left, () => _core.track(_end(t)));
  }

  Future<void> _end(HouseTimer t) async {
    if (!identical(_timers[t.id], t)) return;
    _timers.remove(t.id);
    _alarms.remove(t.id);
    await _changed();
    _core.raiseEvent(timersThing, 'ended', {'timer': t.id, 'name': t.name});
    _core.emit({'event': 'timer.ended', 'timer': t.id, 'name': t.name});
    _core.emit({
      'event': 'flow.announce',
      'type': 'notify',
      'title': '${t.name} timer is done',
      'timer': t.id,
    });
  }

  Future<void> _changed() async {
    final json = jsonEncode({
      'timers': [for (final t in _timers.values) t.toJson(_now())],
    });
    final write = _lastWrite.then((_) async {
      final temp = File('${_file.path}.tmp');
      await temp.writeAsString(json, flush: true);
      await temp.rename(_file.path);
    });
    _lastWrite = write.catchError((Object _) {});
    await write;
    _core.emit({'event': 'timer.changed', 'timers': _list()});
  }
}
