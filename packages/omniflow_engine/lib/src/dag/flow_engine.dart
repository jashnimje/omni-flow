import 'dart:async';

import 'aligned_times.dart';
import 'as_if.dart' show asIfClock, asIfEffects;
import 'asks.dart';
import 'canonical.dart';
import 'conditions.dart';
import 'executor.dart';
import 'flow.dart';
import 'hold_triggers.dart';
import 'node_types.dart';
import 'people_triggers.dart';
import 'skips.dart';
import 'sun.dart';
import 'web_request.dart';

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

  /// The web secret [name] a web request header names, null when none is
  /// stored.
  Future<String?> webSecret(String name);

  /// The stored state of [deviceId], or null when there is no such device.
  Future<Map<String, Object?>?> deviceState(String deviceId);

  /// The ids of the devices in the room named [room], or with that id, in
  /// the user's order. Throws when there is no such room.
  Future<List<String>> roomDevices(String room);
  void emit(Map<String, Object?> event);
  Stream<Map<String, Object?>> get events;
}

/// Runs enabled flows: turns engine events and timers into trigger firings,
/// and gives each FlowRunner its effects.
class FlowEngine implements FlowEffects, PeopleSource {
  FlowEngine(
    this._host, {
    this._clock = const SystemFlowClock(),
    Map<String, Object?> globals = const {},
    this._web = const IoWebRequester(),
  }) {
    _openedAt = _clock.now();
    this.globals.addAll(globals);
    asks = AskBroker(_host.emit);
    _subscription = _host.events.listen(_onEvent);
  }

  /// The questions runs and ask-first automations are waiting on.
  late final AskBroker asks;

  final FlowHost _host;
  final FlowClock _clock;
  final WebRequester _web;
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

  /// The triggers that fired without a run, per automation.
  final skips = SkipLog();

  /// Held state triggers counting down, by `flow/node`.
  final _holds = <String, Timer>{};

  /// When each held countdown ends by the wall clock, and what it does then.
  final _holdDue = <String, ({DateTime at, void Function() go})>{};

  /// When each time trigger's timer is due by the wall clock, and what it
  /// does then. A [Timer] counts time the CPU is awake, so a phone that
  /// slept wakes the engine with an alarm and calls [retime].
  final _due = <Timer, ({DateTime at, void Function() go})>{};

  /// The person things, from the host and from the person states seen.
  Set<String>? _people;

  @override
  Set<String>? get people => _people;

  /// Stored automations that do not run (off, waiting for approval), whose
  /// triggers only record a skip. Empty on a host that does not say.
  final _idle = <String, (FlowSpec, String)>{};

  /// Whether `engine_started` triggers have fired: once per engine.
  var _engineStarted = false;

  RulesHost? get _rulesHost {
    final host = _host;
    return host is RulesHost ? host as RulesHost : null;
  }

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
      _cancelHolds(id);
    }
    final failures = <String, String>{};
    for (final f in wanted.values) {
      if (_runners.containsKey(f.id)) continue;
      try {
        final runner = FlowRunner(
          f,
          this,
          clock: _clock,
          onTrace: _onTrace,
          web: _web,
          webSecret: _host.webSecret,
          asks: asks,
          onNode: _onNode,
        );
        _runners[f.id] = runner;
        if (_timersOn) _startTimers(runner);
      } catch (e) {
        _runners.remove(f.id);
        _cancelTimers(f.id);
        failures[f.id] = e is ArgumentError ? '${e.message}' : '$e';
      }
    }
    _track(_refreshFromHost());
    return failures;
  }

  /// Reads the people and the automations that do not run from a host
  /// that tells them.
  Future<void> _refreshFromHost() async {
    final rules = _rulesHost;
    if (rules == null) return;
    try {
      _people = await rules.people();
      final idle = await rules.idleFlows();
      _idle
        ..clear()
        ..addAll({
          for (final (f, why) in idle)
            if (!_runners.containsKey(f.id)) f.id: (f, why),
        });
    } catch (_) {
      // The engine is closing, or a stored row is damaged: the people and
      // the skips of idle automations wait for the next load.
    }
  }

  HomeLocation? _home;

  /// Where home is, for sun triggers. Null until the user sets it, and a
  /// sun trigger then never fires.
  HomeLocation? get homeLocation => _home;

  /// Moves home, and reschedules every running sun trigger to it.
  set homeLocation(HomeLocation? home) {
    _home = home;
    rescheduleSun();
  }

  /// Where each house is that keeps its own location, by house id. A null
  /// entry is a house with no location yet, whose sun triggers wait.
  final houseLocations = <String, HomeLocation?>{};

  /// Each flow's house, by flow id, for the location its sun triggers use.
  final flowHouses = <String, String>{};

  /// Where the flow [flowId] runs its sun triggers: its house's location
  /// when that house keeps one, else [homeLocation].
  HomeLocation? locationOf(String flowId) {
    final house = flowHouses[flowId];
    return house != null && houseLocations.containsKey(house)
        ? houseLocations[house]
        : _home;
  }

  /// Arms every running sun trigger again, after a location moved.
  void rescheduleSun() {
    if (!_timersOn) return;
    for (final r in _runners.values) {
      if (r.flow.nodes.any((n) => n.type == 'sun')) _startTimers(r);
    }
  }

  /// Starts time_of_day, sun and interval triggers (the hub calls this),
  /// resumes held state triggers, and the first time, fires the
  /// `engine_started` triggers: once the engine runs automations on its
  /// own, not for each one-shot CLI command that opens it.
  void startTimers() {
    if (_timersOn) return;
    _timersOn = true;
    for (final r in _runners.values) {
      _startTimers(r);
    }
    if (_engineStarted) return;
    _engineStarted = true;
    for (final (r, n) in _triggers('engine_started').toList()) {
      _fire(r, n, {});
    }
  }

  /// Stops time_of_day and interval triggers until [startTimers] again.
  void stopTimers() {
    _timersOn = false;
    _cancelTimers();
  }

  /// The earliest wall-clock time a time trigger, interval or held
  /// countdown is due, or null when none is armed. A phone sets an exact
  /// alarm for it instead of keeping the CPU awake all day.
  DateTime? get nextTimeDue {
    DateTime? next;
    void consider(DateTime at) {
      if (next == null || at.isBefore(next!)) next = at;
    }

    for (final d in _due.values) {
      consider(d.at);
    }
    for (final e in _holdDue.entries) {
      if (_holds.containsKey(e.key)) consider(e.value.at);
    }
    return next;
  }

  /// When a time, sun or interval trigger of [flowId] fires next, or null
  /// when the automation is not running or has none. With timers armed it
  /// is the earliest armed time. Without them (the CLI, a test) a daily
  /// or clock-aligned trigger is worked out from now, and a plain interval
  /// has no fixed next time.
  DateTime? nextRunOf(String flowId) {
    final runner = _runners[flowId];
    if (runner == null) return null;
    DateTime? next;
    void consider(DateTime? at) {
      if (at != null && (next == null || at.isBefore(next!))) next = at;
    }

    if (_timersOn) {
      for (final t in _timers[flowId] ?? const <Timer>[]) {
        consider(_due[t]?.at);
      }
      return next;
    }
    final now = _clock.now();
    for (final n in runner.flow.nodes) {
      if (n.type == 'time_of_day' || n.type == 'sun') {
        consider(_dailyTime(n, now, flowId: flowId));
      } else if (n.type == 'interval' &&
          (n.config['offsetSeconds'] != null || n.config['between'] != null)) {
        try {
          consider(
            nextAlignedTime(
              now,
              seconds: n.config['seconds'] as int,
              offsetSeconds: n.config['offsetSeconds'] as int? ?? 0,
              between: (n.config['between'] as List?)?.cast<String>(),
            ),
          );
        } on StateError {
          continue;
        }
      }
    }
    return next;
  }

  /// Arms every time trigger again from the wall clock: after the phone
  /// slept (its timers lag by the time asleep), or the clock or the time
  /// zone changed. Anything whose time passed within [catchUpWindow] runs
  /// now, once (a daily trigger is skipped when it already ran for that
  /// time). One further back, as after the clock was put hours forward, is
  /// left to its next time, as a restart leaves it.
  void retime() {
    if (!_timersOn) return;
    final now = _clock.now();
    final overdue = [
      for (final e in _due.entries)
        if (!e.value.at.isAfter(now)) e,
    ];
    for (final e in overdue) {
      _due.remove(e.key);
      e.key.cancel();
      if (now.difference(e.value.at) <= catchUpWindow) e.value.go();
    }
    for (final key in _holds.keys.toList()) {
      final due = _holdDue[key];
      if (due == null) continue;
      _holds.remove(key)!.cancel();
      if (!due.at.isAfter(now)) {
        due.go();
      } else {
        _holds[key] = Timer(due.at.difference(now), due.go);
      }
    }
    for (final r in _runners.values.toList()) {
      _startTimers(r);
    }
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

  /// A dry run of an enabled or disabled flow. Started from a made-up
  /// "as if" change, its checks see the made-up value.
  Future<RunTrace> dryRun(
    FlowSpec flow,
    String triggerId,
    Map<String, Object?> msg,
    DateTime at,
  ) => FlowRunner(
    flow,
    asIfEffects(this, msg),
    clock: InstantFlowClock(asIfClock(msg, at)),
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
  Future<Map<String, Object?>?> stateOf(String deviceId) =>
      _host.deviceState(deviceId);

  @override
  Future<List<String>> roomDevices(String room) => _host.roomDevices(room);

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
    final full = {
      'trigger': n.type,
      'at': _clock.now().toIso8601String(),
      ...msg,
    };
    _track(r.flow.askFirst ? _askFirst(r, n, full) : r.fire(n.id, full));
  }

  /// Asks the person before a trigger starts [r]'s run, and runs it only on
  /// Run. While one ask is open for the automation, a second trigger is
  /// dropped rather than asking again: the open ask stands for both.
  Future<void> _askFirst(
    FlowRunner r,
    NodeSpec n,
    Map<String, Object?> msg,
  ) async {
    final flow = r.flow;
    if (asks.confirming(flow.id)) {
      _dropRun(flow.id, n.id, 'it is already asking you');
      return;
    }
    final String? answer;
    try {
      answer = await asks.ask(
        flow: flow.id,
        kind: AskKind.confirm,
        title: 'Run ${flow.name}?',
        timeout: const Duration(milliseconds: askDefaultTimeoutMs),
        token: _closing,
        clock: _clock,
        trigger: msg['thing'],
      );
    } on RunCancelled {
      return;
    }
    if (answer != askRun) {
      _dropRun(
        flow.id,
        n.id,
        answer == null ? 'not answered' : 'you chose not now',
      );
      return;
    }
    // The automation may have changed or been turned off while it asked.
    if (!identical(_runners[flow.id], r)) {
      _dropRun(flow.id, n.id, 'it changed while it was asking');
      return;
    }
    await r.fire(n.id, msg);
  }

  /// Cancelled when the engine closes, which ends every open ask.
  final _closing = CancelToken();

  void _dropRun(String flowId, String trigger, String reason) {
    final now = _clock.now();
    _onTrace(
      RunTrace(
          '$flowId-${DateTime.now().microsecondsSinceEpoch}-ask',
          flowId,
          trigger,
          now,
        )
        ..outcome = RunOutcome.dropped
        ..reason = reason
        ..finishedAt = now,
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
          final msg = _stateMsg(id, key, before, state);
          if (key != null && holdOf(c) != null) {
            _onHeld(r, n, state[key], before[key], msg);
            continue;
          }
          if (_stateFires(c, before, state)) _fire(r, n, msg);
        }
        for (final (f, why, n) in _idleTriggers('on')) {
          final c = n.config;
          if (c['thing'] != id || c['event'] == true || holdOf(c) != null) {
            continue;
          }
          if (_stateFires(c, before, state)) _skipIdle(f, n, why);
        }
        if (device['driver'] == personDriver) _onPerson(id, before, state);
      case 'thing.event':
        final payload = e['payload'] is Map
            ? Map<String, Object?>.from(e['payload'] as Map)
            : const <String, Object?>{};
        for (final (r, n) in _triggers('on')) {
          if (!_eventFires(n.config, e, payload)) continue;
          _fire(r, n, {
            'payload': payload,
            'thing': e['thing'],
            'deviceId': e['thing'],
            'device': e['thing'],
            'key': e['key'],
          });
        }
        for (final (f, why, n) in _idleTriggers('on')) {
          if (_eventFires(n.config, e, payload)) _skipIdle(f, n, why);
        }
    }
  }

  static Map<String, Object?> _stateMsg(
    String id,
    String? key,
    Map<String, Object?> before,
    Map<String, Object?> state,
  ) => {
    'payload': state,
    'thing': id,
    'deviceId': id,
    'device': id,
    if (key != null) ...{
      'key': key,
      'value': state[key],
      'previous': before[key],
    },
  };

  /// Whether the state `on` trigger [c] fires for [before] becoming
  /// [state]: its key changed as it asks, or with no key, anything changed.
  static bool _stateFires(
    Map<String, Object?> c,
    Map<String, Object?> before,
    Map<String, Object?> state,
  ) {
    final key = c['key'] as String?;
    // Heartbeats and polls save the device with nothing changed.
    if (key == null) return canonicalJson(before) != canonicalJson(state);
    return stateTriggerFires(c, before[key], state[key]);
  }

  static bool _eventFires(
    Map<String, Object?> c,
    Map<String, Object?> e,
    Map<String, Object?> payload,
  ) =>
      c['event'] == true &&
      c['thing'] == e['thing'] &&
      c['key'] == e['key'] &&
      payloadMatches(c['match'], payload);

  // Held state triggers -------------------------------------------------------

  static String _holdKey(FlowRunner r, NodeSpec n) => '${r.flow.id}/${n.id}';

  /// A held trigger [n] seeing its key go from [previous] to [value]: the
  /// state it waits for starts the countdown, anything else stops it.
  void _onHeld(
    FlowRunner r,
    NodeSpec n,
    Object? value,
    Object? previous,
    Map<String, Object?> msg,
  ) {
    final key = _holdKey(r, n);
    if (holdsNow(n.config, value) != true) {
      _holds.remove(key)?.cancel();
      return;
    }
    // Still holding (a heartbeat), or it already held before this change.
    if (_holds.containsKey(key) ||
        !stateTriggerFires(n.config, previous, value)) {
      return;
    }
    _startHold(r, n, holdOf(n.config)!, msg);
  }

  /// Fires [n] after [wait] if its state still holds then.
  void _startHold(
    FlowRunner r,
    NodeSpec n,
    Duration wait,
    Map<String, Object?> msg,
  ) {
    final key = _holdKey(r, n);
    _holds.remove(key)?.cancel();
    void go() {
      _holds.remove(key);
      _holdDue.remove(key);
      if (!identical(_runners[r.flow.id], r)) return;
      final c = n.config;
      final now = deviceStates[c['thing']]?[c['key']];
      if (holdsNow(c, now) != true) return;
      _fire(r, n, {...msg, 'value': now, 'heldMs': holdOf(c)!.inMilliseconds});
    }

    _holds[key] = Timer(wait, go);
    _holdDue[key] = (at: _clock.now().add(wait), go: go);
  }

  /// After a restart or a reload, carries on each held trigger of [r]
  /// whose state holds now: the countdown goes on from when the state
  /// last changed, in the device history. When that is not known, or its
  /// time already passed while the engine was down (it ran then, or the
  /// moment is gone), it waits for the next change, so it never runs twice.
  void _resumeHolds(FlowRunner r) {
    final rules = _rulesHost;
    if (rules == null) return;
    for (final n in r.flow.nodes) {
      final c = n.config;
      final hold = holdOf(c);
      final thing = c['thing'];
      final key = c['key'];
      if (n.type != 'on' ||
          hold == null ||
          thing is! String ||
          key is! String) {
        continue;
      }
      if (_holds.containsKey(_holdKey(r, n)) ||
          holdsNow(c, deviceStates[thing]?[key]) != true) {
        continue;
      }
      _track(() async {
        final DateTime? since;
        try {
          since = heldSince(c, await rules.stateHistory(thing, key));
        } catch (_) {
          return;
        }
        if (since == null ||
            _holds.containsKey(_holdKey(r, n)) ||
            !identical(_runners[r.flow.id], r)) {
          return;
        }
        final left = hold - _clock.now().difference(since);
        if (left <= Duration.zero) return;
        final state = deviceStates[thing] ?? const {};
        _startHold(r, n, left, {
          ..._stateMsg(thing, key, const {}, state),
          'previous': null,
          'resumed': true,
        });
      }());
    }
  }

  void _cancelHolds([String? flowId]) {
    for (final key in _holds.keys.toList()) {
      if (flowId == null || key.startsWith('$flowId/')) {
        _holds.remove(key)!.cancel();
      }
    }
  }

  // People triggers -----------------------------------------------------------

  /// A person's state changed: the first of the household to get home or
  /// the last to leave fires the people triggers that wait for it.
  void _onPerson(
    String id,
    Map<String, Object?> before,
    Map<String, Object?> state,
  ) {
    _people?.add(id);
    final kind = peopleTriggerFor(
      before['home'],
      state['home'],
      othersHome(deviceStates, _people, id),
    );
    if (kind == null) return;
    for (final (r, n) in _triggers('people_change')) {
      if (n.config['when'] == kind) {
        _fire(r, n, {'person': id, 'thing': id, 'payload': state});
      }
    }
    for (final (f, why, n) in _idleTriggers('people_change')) {
      if (n.config['when'] == kind) _skipIdle(f, n, why);
    }
  }

  // Skips ---------------------------------------------------------------------

  Iterable<(FlowSpec, String, NodeSpec)> _idleTriggers(String type) sync* {
    for (final (f, why) in _idle.values) {
      for (final n in f.nodes) {
        if (n.type == type) yield (f, why, n);
      }
    }
  }

  void _skipIdle(FlowSpec f, NodeSpec n, String why) => skips.add(
    SkipEntry(
      at: _clock.now(),
      flowId: f.id,
      trigger: n.id,
      triggerLabel: n.label,
      kind: why,
    ),
  );

  /// Keeps a skip for a dropped run, or a run a condition stopped before it
  /// did anything.
  void _recordSkip(RunTrace trace) {
    if (trace.dryRun) return;
    final String kind;
    if (trace.outcome == RunOutcome.dropped) {
      kind = SkipKind.ofDropReason(trace.reason);
    } else if (trace.outcome == RunOutcome.completed &&
        trace.stoppedBy != null &&
        !trace.nodes.any(
          (n) => builtInNodeTypes[n.type]?.category == NodeCategory.action,
        )) {
      kind = SkipKind.condition;
    } else {
      return;
    }
    final flow = _runners[trace.flowId]?.flow;
    skips.add(
      SkipEntry(
        at: trace.startedAt,
        flowId: trace.flowId,
        trigger: trace.trigger,
        triggerLabel: flow?.node(trace.trigger)?.label,
        kind: kind,
        stop: kind == SkipKind.condition ? trace.stoppedBy : null,
      ),
    );
  }

  /// The rule path of a compiled node, where the API layer knows it.
  String? Function(String flowId, String nodeId)? nodePath;

  /// The most `run.node` events one run sends, so a long repeat does not
  /// flood the app. The run log still has every node.
  static const nodeEventsPerRun = 200;

  /// `run.node {run, flow, node, path?, status, port?, seen?}` as each node
  /// of a real run starts waiting or finishes. It carries ids, the port and
  /// what a condition saw, never a step's config or message.
  void _onNode(RunTrace run, NodeTrace node, String status) {
    if (run.dryRun || run.nodes.length > nodeEventsPerRun) return;
    _host.emit({
      'event': 'run.node',
      'run': run.runId,
      'flow': run.flowId,
      'node': node.nodeId,
      'path': ?nodePath?.call(run.flowId, node.nodeId),
      'status': status,
      if (status != 'waiting') 'port': ?node.port,
      if (node.hasSeen) 'seen': node.seen,
    });
  }

  void _onTrace(RunTrace trace) {
    _recordSkip(trace);
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
    final flow = _runners[trace.flowId]?.flow;
    if (trace.outcome == RunOutcome.completed &&
        !trace.dryRun &&
        flow != null &&
        flow.notifyOnRun) {
      announce({
        'type': 'notify',
        'title': '${flow.name} ran',
        'flow': flow.id,
      });
    }
  }

  void _startTimers(FlowRunner r) {
    _cancelTimers(r.flow.id);
    for (final n in r.flow.nodes) {
      if (n.type == 'interval' &&
          (n.config['offsetSeconds'] != null || n.config['between'] != null)) {
        _scheduleAligned(r, n);
      } else if (n.type == 'interval') {
        final every = Duration(seconds: n.config['seconds'] as int);
        void go() => _fire(r, n, {});
        final timer = Timer.periodic(every, (t) {
          _due[t] = (at: _clock.now().add(every), go: go);
          go();
        });
        _due[timer] = (at: _clock.now().add(every), go: go);
        _timers.putIfAbsent(r.flow.id, () => []).add(timer);
      } else if (n.type == 'time_of_day' || n.type == 'sun') {
        _scheduleDaily(r, n);
      }
    }
    _resumeHolds(r);
  }

  /// An interval lined up on the clock ("every hour at :05"): each pass is
  /// timed to the next wall-clock time, so it does not drift.
  void _scheduleAligned(FlowRunner r, NodeSpec n) {
    final DateTime next;
    try {
      next = nextAlignedTime(
        _clock.now(),
        seconds: n.config['seconds'] as int,
        offsetSeconds: n.config['offsetSeconds'] as int? ?? 0,
        between: (n.config['between'] as List?)?.cast<String>(),
      );
    } on StateError {
      return;
    }
    late final Timer timer;
    void go() {
      _due.remove(timer);
      // As for daily times: a wall clock put back sets it off early.
      if (_clock.now().isBefore(next)) {
        _scheduleAligned(r, n);
        return;
      }
      _fire(r, n, {'scheduled': next.toIso8601String()});
      _scheduleAligned(r, n);
    }

    timer = Timer(next.difference(_clock.now()), go);
    _due[timer] = (at: next, go: go);
    _timers.putIfAbsent(r.flow.id, () => []).add(timer);
  }

  /// When the daily trigger [n] fires next after [now], or with [previous]
  /// when it last fired at or before [now]. Null when it never does: a sun
  /// trigger with no home set, or a polar night or day.
  DateTime? _dailyTime(
    NodeSpec n,
    DateTime now, {
    bool previous = false,
    String? flowId,
  }) {
    final days = (n.config['days'] as List?)?.cast<String>();
    if (n.type == 'time_of_day') {
      final at = n.config['at'] as String;
      return previous
          ? previousTimeOfDay(now, at, days: days)
          : nextTimeOfDay(now, at, days: days);
    }
    final home = flowId == null ? _home : locationOf(flowId);
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
    final next = _dailyTime(n, _clock.now(), flowId: r.flow.id);
    if (next == null) return;
    late final Timer timer;
    void go() {
      _due.remove(timer);
      // A timer counts elapsed time, so when the wall clock went back (the
      // end of summer time, a clock fix) it goes off before its time, which
      // would run the trigger now and again when the time comes.
      if (_clock.now().isBefore(next)) {
        _scheduleDaily(r, n);
        return;
      }
      final scheduled = next.toIso8601String();
      _track(() async {
        if (await _host.ranAt(r.flow.id, scheduled)) return;
        await _host.markScheduled(r.flow.id, scheduled);
        _fire(r, n, {'scheduled': scheduled});
      }());
      _scheduleDaily(r, n);
    }

    timer = Timer(next.difference(_clock.now()), go);
    _due[timer] = (at: next, go: go);
    _timers.putIfAbsent(r.flow.id, () => []).add(timer);
  }

  /// Runs a daily trigger once whose time passed within [catchUpWindow]
  /// before the engine opened (a reboot, Android restarting the service)
  /// and that has no run for it yet.
  void _catchUp(FlowRunner r, NodeSpec n) {
    final key = '${r.flow.id}/${n.id}';
    final now = _clock.now();
    final last = _dailyTime(n, now, previous: true, flowId: r.flow.id);
    // A sun trigger with no home yet has nothing to catch up, and may once
    // home is set.
    if (last == null && n.type == 'sun' && locationOf(r.flow.id) == null) {
      return;
    }
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
        _due.remove(t);
      }
    }
  }

  /// Lets the events already sent reach the triggers, then waits while the
  /// runs they started (and the runs those start) are going, for up to
  /// [limit]. Returns whether everything finished in time.
  ///
  /// A one-shot CLI command calls this before closing an engine it opened,
  /// so `omni device invoke` fires the automations its change triggers. A
  /// run still waiting at [limit] is cancelled by [close] as before.
  Future<bool> settle({Duration limit = const Duration(seconds: 2)}) async {
    final deadline = DateTime.now().add(limit);
    // Events travel through broadcast streams, one microtask per hop. A
    // zero timer runs only once every queued microtask has.
    await Future<void>.delayed(Duration.zero);
    while (_pending.isNotEmpty) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return false;
      // A cancelled timer, not Future.delayed, so a CLI process is not kept
      // alive by a wait nobody needs any more.
      final timedOut = Completer<void>();
      final timer = Timer(left, timedOut.complete);
      try {
        await Future.any([
          Future.wait([
            for (final p in List.of(_pending)) p.catchError((Object _) {}),
          ]),
          timedOut.future,
        ]);
      } finally {
        timer.cancel();
      }
      await Future<void>.delayed(Duration.zero);
    }
    return true;
  }

  Future<void> close() async {
    _cancelTimers();
    _cancelHolds();
    _timersOn = false;
    for (final r in _runners.values) {
      r.cancelAll();
    }
    _closing.cancel();
    asks.cancelAll();
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
