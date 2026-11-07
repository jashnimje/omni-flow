import 'dart:async';

import '../zones/zones.dart';
import 'executor.dart';
import 'flow.dart';

/// Everything the flow engine needs from the rest of the engine.
abstract interface class FlowHost {
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params,
  );
  Future<void> saveGlobal(String name, Object? value);
  Future<void> saveTrace(Map<String, Object?> trace);
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
    this.globals.addAll(globals);
    _subscription = _host.events.listen(_onEvent);
  }

  final FlowHost _host;
  final FlowClock _clock;
  final _runners = <String, FlowRunner>{};
  final _timers = <String, List<Timer>>{};
  late final StreamSubscription<Map<String, Object?>> _subscription;
  ZoneTracker _zones = ZoneTracker(const []);
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

  ZoneTracker get zones => _zones;

  Iterable<String> get loadedFlows => _runners.keys;

  /// Replaces the running set of flows. Disabled flows are not loaded.
  void load(Iterable<FlowSpec> flows) {
    for (final r in _runners.values) {
      r.cancelAll();
    }
    _runners.clear();
    _cancelTimers();
    for (final f in flows.where((f) => f.enabled)) {
      _runners[f.id] = FlowRunner(f, this, clock: _clock, onTrace: _onTrace);
    }
    if (_timersOn) _startTimers();
  }

  void setZones(Iterable<ZoneSpec> zones) => _zones = ZoneTracker(zones);

  /// Starts time_of_day and interval triggers (the hub calls this).
  void startTimers() {
    _timersOn = true;
    _startTimers();
  }

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
    Map<String, Object?> params,
  ) => _host.invokeDevice(deviceId, capabilityId, params);

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
        for (final (r, n) in _triggers('device_state')) {
          if (n.config['deviceId'] != id) continue;
          final key = n.config['key'] as String?;
          if (key != null && before[key] == state[key]) continue;
          _fire(r, n, {
            'payload': state,
            'deviceId': id,
            if (key != null) 'value': state[key],
          });
        }
      case 'zone.changed':
        for (final (r, n) in _triggers('zone_change')) {
          if (n.config['zoneId'] == e['zone'] &&
              n.config['transition'] == e['transition']) {
            _fire(r, n, {'payload': e, 'zone': e['zone']});
          }
        }
      case 'board.event':
        for (final (r, n) in _triggers('board_event')) {
          if (n.config['event'] != e['type']) continue;
          if (n.config['node'] != null && n.config['node'] != e['node']) {
            continue;
          }
          _fire(r, n, {'payload': e['payload'], 'node': e['node']});
        }
      case 'wifi.changed':
        for (final (r, n) in _triggers('wifi_change')) {
          if (n.config['ssid'] == null || n.config['ssid'] == e['ssid']) {
            _fire(r, n, {'payload': e, 'ssid': e['ssid']});
          }
        }
    }
  }

  /// Feeds a BLE reading to the zones and emits any zone changes.
  void bleReading(String name, double rssi, DateTime at) =>
      _emitZones(_zones.bleReading(name, rssi, at));

  /// Feeds the current Wi-Fi. Keeps `$WifiSsid` and `$HomeWifiConnected`
  /// current; home networks are the global `$HomeSsids` list.
  Future<void> wifi(String? ssid, String? bssid, DateTime at) async {
    final homes = globals['HomeSsids'];
    await setGlobal('WifiSsid', ssid);
    await setGlobal(
      'HomeWifiConnected',
      ssid != null && homes is List && homes.contains(ssid),
    );
    _host.emit({'event': 'wifi.changed', 'ssid': ssid, 'bssid': bssid});
    _emitZones(_zones.wifi(ssid, bssid, at));
  }

  void zoneTick(DateTime at) => _emitZones(_zones.tick(at));

  void _emitZones(List<ZoneChange> changes) {
    for (final c in changes) {
      _track(
        setGlobal('Zone_${c.zoneId}', c.transition == ZoneTransition.entered),
      );
      _host.emit({'event': 'zone.changed', ...c.toJson()});
    }
  }

  void _onTrace(RunTrace trace) {
    final json = trace.toJson();
    _track(_host.saveTrace(json));
    _host.emit({
      'event': 'run.finished',
      'flow': trace.flowId,
      'run': trace.runId,
      'outcome': trace.outcome.name,
      if (trace.reason != null) 'reason': trace.reason,
    });
  }

  void _startTimers() {
    _cancelTimers();
    for (final (r, n) in _triggers('interval')) {
      final every = Duration(seconds: n.config['seconds'] as int);
      _timers
          .putIfAbsent(r.flow.id, () => [])
          .add(Timer.periodic(every, (_) => _fire(r, n, {})));
    }
    for (final (r, n) in _triggers('time_of_day')) {
      _scheduleDaily(r, n);
    }
  }

  void _scheduleDaily(FlowRunner r, NodeSpec n) {
    final next = nextTimeOfDay(
      _clock.now(),
      n.config['at'] as String,
      days: (n.config['days'] as List?)?.cast<String>(),
    );
    final timer = Timer(next.difference(_clock.now()), () {
      _fire(r, n, {'scheduled': next.toIso8601String()});
      _scheduleDaily(r, n);
    });
    _timers.putIfAbsent(r.flow.id, () => []).add(timer);
  }

  void _cancelTimers() {
    for (final list in _timers.values) {
      for (final t in list) {
        t.cancel();
      }
    }
    _timers.clear();
  }

  Future<void> close() async {
    _cancelTimers();
    for (final r in _runners.values) {
      r.cancelAll();
    }
    await _subscription.cancel();
    while (_pending.isNotEmpty) {
      await Future.wait(List.of(_pending));
    }
  }
}

const _weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

/// The next local time at `HH:MM` after [now], on one of [days] when given.
/// Built from local calendar fields, so a DST change moves it with the wall
/// clock: 07:00 stays 07:00, and it fires once.
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
