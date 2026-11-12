import 'dart:async';

import 'canonical.dart';
import 'conditions.dart';
import 'executor.dart';
import 'flow.dart';
import 'sun.dart';

/// Everything the flow engine needs from the rest of the engine.
abstract interface class FlowHost {
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    String? flowId,
  });
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId, {
    String? flowId,
  });
  Future<void> saveGlobal(String name, Object? value);
  Future<void> saveTrace(Map<String, Object?> trace);

  /// Whether [flowId] has a run in the log for the daily time [scheduled]
  /// (its `scheduled` timestamp), so a restart does not run it twice.
  Future<bool> ranAt(String flowId, String scheduled);

  /// Notes that [flowId] starts its daily time [scheduled], before it runs,
  /// so a run cut off by a restart is not caught up again.
  Future<void> markScheduled(String flowId, String scheduled);
  void emit(Map<String, Object?> event);
  Stream<Map<String, Object?>> get events;
}

/// Runs enabled flows: turns engine events and timers into trigger firings,
/// and gives each FlowRunner its effects.
class FlowEngine implements FlowEffects {
  FlowEngine(
    this._host, {
    this._clock = const SystemFlowClock(),
    Map<String, Object?> globals = const {},
  }) {
    _openedAt = _clock.now();
    this.globals.addAll(globals);
    _subscription = _host.events.listen(_onEvent);
  }

  final FlowHost _host;
  final FlowClock _clock;
  final _runners = <String, FlowRunner>{};
  final _timers = <String, List<Timer>>{};

  /// Daily triggers missed while the engine was down are caught up only when
  /// it has just opened, and only this long after their time.
  static const catchUpWindow = Duration(minutes: 15);
  late final DateTime _openedAt;
  final _caughtUp = <String>{};
  late final StreamSubscription<Map<String, Object?>> _subscription;
  bool _timersOn = false;
  final _pending = <Future<void>>{};

  /// Keeps background work (runs, trace and variable writes) so close() can wait for it.
  void _track(Future<void> work) {
    _pending.add(work);
    work.whenComplete(() => _pending.remove(work)).ignore();
  }

  @override
  final Map<String, Object?> globals = {};

  @override
  final Map<String, Map<String, Object?>> deviceStates = {};

  @override
  Stream<Map<String, Object?>> get events => _host.events;

  Iterable<String> get loadedFlows => _runners.keys;

  /// Makes [flows] the running set. Disabled flows are not loaded. A flow
  /// whose spec is unchanged keeps its runner, so its in-flight runs, gate
  /// and cooldown state and timer countdowns carry on. Returns the flows
  /// that could not be loaded, by id, with the reason.
  Map<String, String> load(Iterable<FlowSpec> flows) {
    final wanted = {for (final f in flows.where((f) => f.enabled)) f.id: f};
    for (final id in _runners.keys.toList()) {
      final next = wanted[id];
      if (next != null &&
          canonicalJson(next.toJson()) ==
              canonicalJson(_runners[id]!.flow.toJson())) {
        continue;
      }
      _runners.remove(id)!.cancelAll();
      _cancelTimers(id);
    }
    final failures = <String, String>{};
    for (final f in wanted.values) {
      if (_runners.containsKey(f.id)) continue;
      try {
        final runner = FlowRunner(f, this, clock: _clock, onTrace: _onTrace);
        _runners[f.id] = runner;
        if (_timersOn) _startTimers(runner);
      } catch (e) {
        _runners.remove(f.id);
        _cancelTimers(f.id);
        failures[f.id] = e is ArgumentError ? '${e.message}' : '$e';
      }
    }
    return failures;
  }

  HomeLocation? _home;

  /// Where home is, for sun triggers. Null until the user sets it, and a
  /// sun trigger then never fires.
  HomeLocation? get homeLocation => _home;

  /// Moves home, and reschedules every running sun trigger to it.
  set homeLocation(HomeLocation? home) {
    _home = home;
    if (!_timersOn) return;
    for (final r in _runners.values) {
      if (r.flow.nodes.any((n) => n.type == 'sun')) _startTimers(r);
    }
  }

  /// Starts time_of_day, sun and interval triggers (the hub calls this).
  void startTimers() {
    if (_timersOn) return;
    _timersOn = true;
    for (final r in _runners.values) {
      _startTimers(r);
    }
  }

  /// Stops time_of_day and interval triggers until [startTimers] again.
  void stopTimers() {
    _timersOn = false;
    _cancelTimers();
  }

  final _dropped = <String, int>{};

  /// How many runs of each flow were dropped (running, cooldown, queue
  /// full) since the engine started. Dropped runs are not in the run log.
  Map<String, int> get droppedRuns => Map.unmodifiable(_dropped);

  /// Fires the manual triggers of [flowId], or [triggerId] when given.
  Future<List<RunTrace>> run(
    String flowId, {
    String? triggerId,
    Map<String, Object?> msg = const {},
    bool dryRun = false,
    FlowClock? clock,
  }) async {
    final runner = _runners[flowId];
    if (runner == null) {
      throw StateError('flow $flowId is not loaded (missing or disabled)');
    }
    final triggers = triggerId != null
        ? [triggerId]
        : [
            for (final n in runner.flow.nodes)
              if (n.type == 'manual') n.id,
          ];
    if (triggers.isEmpty) {
      throw StateError('flow $flowId has no manual trigger');
    }
    return Future.wait([
      for (final t in triggers)
        runner.fire(
          t,
          {
            'trigger': 'manual',
            'at': (clock ?? _clock).now().toIso8601String(),
            ...msg,
          },
          dryRun: dryRun,
          clock: clock,
        ),
    ]);
  }

  /// A dry run of an enabled or disabled flow.
  Future<RunTrace> dryRun(
    FlowSpec flow,
    String triggerId,
    Map<String, Object?> msg,
    DateTime at,
  ) => FlowRunner(
    flow,
    this,
    clock: InstantFlowClock(at),
  ).fire(triggerId, msg, dryRun: true);

  // FlowEffects ---------------------------------------------------------------

  @override
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    String? flowId,
  }) => _host.invokeDevice(deviceId, capabilityId, params, flowId: flowId);

  @override
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId, {
    String? flowId,
  }) => _host.toggleDevice(deviceId, capabilityId, flowId: flowId);

  @override
  Future<void> runFlow(String flowId, Map<String, Object?> msg) async {
    await run(flowId, msg: {'from': 'run_flow', ...msg});
  }

  @override
  void announce(Map<String, Object?> payload) =>
      _host.emit({'event': 'flow.announce', ...payload});

  @override
  Future<void> setGlobal(String name, Object? value) async {
    final changed = globals[name] != value;
    globals[name] = value;
    await _host.saveGlobal(name, value);
    if (changed) {
      _host.emit({'event': 'variable.changed', 'name': name, 'value': value});
    }
  }

  // Triggers -----------------------------------------------------------------

  Iterable<(FlowRunner, NodeSpec)> _triggers(String type) sync* {
    for (final r in _runners.values) {
      for (final n in r.flow.nodes) {
        if (n.type == type) yield (r, n);
      }
    }
  }

  void _fire(FlowRunner r, NodeSpec n, Map<String, Object?> msg) {
    _track(
      r.fire(n.id, {
        'trigger': n.type,
        'at': _clock.now().toIso8601String(),
        ...msg,
      }),
    );
  }

  void _onEvent(Map<String, Object?> e) {
    switch (e['event']) {
      case 'device.stateChanged':
        final device = e['device'] as Map;
        final id = device['id'] as String;
        final state = Map<String, Object?>.from(device['state'] as Map);
        final before = deviceStates[id] ?? const {};
        deviceStates[id] = state;
        for (final (r, n) in _triggers('on')) {
          final c = n.config;
          if (c['thing'] != id || c['event'] == true) continue;
          final key = c['key'] as String?;
          if (key == null) {
            // Heartbeats and polls save the device with nothing changed.
            if (canonicalJson(before) == canonicalJson(state)) continue;
          } else if (!stateTriggerFires(c, before[key], state[key])) {
            continue;
          }
          _fire(r, n, {
            'payload': state,
            'thing': id,
            'deviceId': id,
            if (key != null) ...{
              'key': key,
              'value': state[key],
              'previous': before[key],
            },
          });
        }
      case 'thing.event':
        final payload = e['payload'] is Map
            ? Map<String, Object?>.from(e['payload'] as Map)
            : const <String, Object?>{};
        for (final (r, n) in _triggers('on')) {
          final c = n.config;
          if (c['event'] != true ||
              c['thing'] != e['thing'] ||
              c['key'] != e['key'] ||
              !payloadMatches(c['match'], payload)) {
            continue;
          }
          _fire(r, n, {
            'payload': payload,
            'thing': e['thing'],
            'deviceId': e['thing'],
            'key': e['key'],
          });
        }
    }
  }

  void _onTrace(RunTrace trace) {
    // A busy trigger on a single-mode flow would otherwise push real runs
    // out of the bounded log.
    if (trace.outcome == RunOutcome.dropped) {
      _dropped[trace.flowId] = (_dropped[trace.flowId] ?? 0) + 1;
    } else {
      _track(_host.saveTrace(trace.toJson()));
    }
    _host.emit({
      'event': 'run.finished',
      'flow': trace.flowId,
      'run': trace.runId,
      'outcome': trace.outcome.name,
      if (trace.reason != null) 'reason': trace.reason,
    });
  }

  void _startTimers(FlowRunner r) {
    _cancelTimers(r.flow.id);
    for (final n in r.flow.nodes) {
      if (n.type == 'interval') {
        final every = Duration(seconds: n.config['seconds'] as int);
        _timers
            .putIfAbsent(r.flow.id, () => [])
            .add(Timer.periodic(every, (_) => _fire(r, n, {})));
      } else if (n.type == 'time_of_day' || n.type == 'sun') {
        _scheduleDaily(r, n);
      }
    }
  }

  /// When the daily trigger [n] fires next after [now], or with [previous]
  /// when it last fired at or before [now]. Null when it never does: a sun
  /// trigger with no home set, or a polar night or day.
  DateTime? _dailyTime(NodeSpec n, DateTime now, {bool previous = false}) {
    final days = (n.config['days'] as List?)?.cast<String>();
    if (n.type == 'time_of_day') {
      final at = n.config['at'] as String;
      return previous
          ? previousTimeOfDay(now, at, days: days)
          : nextTimeOfDay(now, at, days: days);
    }
    final home = _home;
    final event = SunEvent.parse(n.config['event']);
    if (home == null || event == null) return null;
    final offset = (n.config['offsetMinutes'] as int?) ?? 0;
    return previous
        ? previousSunTrigger(
            now,
            event,
            home,
            offsetMinutes: offset,
            days: days,
          )
        : nextSunTrigger(now, event, home, offsetMinutes: offset, days: days);
  }

  void _scheduleDaily(FlowRunner r, NodeSpec n) {
    _catchUp(r, n);
    final next = _dailyTime(n, _clock.now());
    if (next == null) return;
    final timer = Timer(next.difference(_clock.now()), () {
      final scheduled = next.toIso8601String();
      _track(() async {
        await _host.markScheduled(r.flow.id, scheduled);
        _fire(r, n, {'scheduled': scheduled});
      }());
      _scheduleDaily(r, n);
    });
    _timers.putIfAbsent(r.flow.id, () => []).add(timer);
  }

  /// Runs a daily trigger once whose time passed within [catchUpWindow]
  /// before the engine opened (a reboot, Android restarting the service)
  /// and that has no run for it yet.
  void _catchUp(FlowRunner r, NodeSpec n) {
    final key = '${r.flow.id}/${n.id}';
    final now = _clock.now();
    final last = _dailyTime(n, now, previous: true);
    // A sun trigger with no home yet has nothing to catch up, and may once
    // home is set.
    if (last == null && n.type == 'sun' && _home == null) return;
    if (!_caughtUp.add(key)) return;
    if (now.difference(_openedAt) > const Duration(minutes: 1)) return;
    if (last == null || now.difference(last) > catchUpWindow) return;
    final scheduled = last.toIso8601String();
    _track(() async {
      if (await _host.ranAt(r.flow.id, scheduled)) return;
      await _host.markScheduled(r.flow.id, scheduled);
      _fire(r, n, {'scheduled': scheduled, 'caughtUp': true});
    }());
  }

  /// Cancels the timers of [flowId], or of every flow.
  void _cancelTimers([String? flowId]) {
    for (final id in flowId == null ? _timers.keys.toList() : [flowId]) {
      for (final t in _timers.remove(id) ?? const <Timer>[]) {
        t.cancel();
      }
    }
  }

  Future<void> close() async {
    _cancelTimers();
    _timersOn = false;
    for (final r in _runners.values) {
      r.cancelAll();
    }
    await _subscription.cancel();
    // One failed trace write must not stop close() from finishing.
    while (_pending.isNotEmpty) {
      await Future.wait([
        for (final p in List.of(_pending)) p.catchError((Object _) {}),
      ]);
    }
  }
}

const _weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

/// Whether an `on` trigger [config] on a state key fires for a change from
/// [previous] to [value]: any change, a change to `change.to`, or a number
/// crossing `crosses.above` or `crosses.below`, once per crossing.
bool stateTriggerFires(
  Map<String, Object?> config,
  Object? previous,
  Object? value,
) {
  if (valuesEqual(previous, value)) return false;
  final crosses = config['crosses'];
  if (crosses is Map) {
    final above = crosses['above'];
    final below = crosses['below'];
    final limit = (above ?? below) as num;
    bool past(Object? v) => v is num && (above != null ? v > limit : v < limit);
    return past(value) && !past(previous);
  }
  final change = config['change'];
  if (change is Map && change.containsKey('to')) {
    return valuesEqual(value, change['to']);
  }
  return true;
}

/// Whether every value in [match] equals the payload's value at that key.
bool payloadMatches(Object? match, Map<String, Object?> payload) =>
    match is! Map ||
    match.entries.every((m) => valuesEqual(payload[m.key], m.value));

/// The next local time at `HH:MM` after [now], on one of [days] when given.
/// Built from local calendar fields, so a DST change moves it with the wall
/// clock: 07:00 stays 07:00, and it fires once.
/// The last time of day [hhmm] on [days] at or before [now], within a week.
DateTime? previousTimeOfDay(DateTime now, String hhmm, {List<String>? days}) {
  DateTime? last;
  var t = nextTimeOfDay(
    now.subtract(const Duration(days: 8)),
    hhmm,
    days: days,
  );
  while (!t.isAfter(now)) {
    last = t;
    t = nextTimeOfDay(t, hhmm, days: days);
  }
  return last;
}

DateTime nextTimeOfDay(DateTime now, String hhmm, {List<String>? days}) {
  final parts = hhmm.split(':');
  final hour = int.parse(parts[0]);
  final minute = int.parse(parts[1]);
  for (var add = 0; add <= 7; add++) {
    final candidate = DateTime(
      now.year,
      now.month,
      now.day + add,
      hour,
      minute,
    );
    if (!candidate.isAfter(now)) continue;
    if (days != null && !days.contains(_weekdays[candidate.weekday - 1])) {
      continue;
    }
    return candidate;
  }
  throw StateError('no matching day for $hhmm in $days');
}
