import 'dart:async';

import '../template/template_renderer.dart';
import 'conditions.dart';
import 'flow.dart';
import 'node_types.dart';
import 'transformers.dart';

/// Time for the executor, so tests and dry runs control it.
abstract interface class FlowClock {
  DateTime now();

  /// Completes after [duration], or early with [RunCancelled] when [token] is cancelled.
  Future<void> sleep(Duration duration, CancelToken token);
}

class SystemFlowClock implements FlowClock {
  const SystemFlowClock();

  @override
  DateTime now() => DateTime.now();

  /// A cancelled sleep cancels its timer, so a cancelled long delay does not
  /// keep the process alive.
  @override
  Future<void> sleep(Duration duration, CancelToken token) {
    if (token.isCancelled) return Future.error(RunCancelled());
    final done = Completer<void>();
    final timer = Timer(duration, () {
      if (!done.isCompleted) done.complete();
    });
    token.whenCancelled.then((_) {
      timer.cancel();
      if (!done.isCompleted) done.completeError(RunCancelled());
    });
    return done.future;
  }
}

/// A dry run's clock: fixed time, and every wait finishes at once.
class InstantFlowClock implements FlowClock {
  InstantFlowClock(this._at);

  final DateTime _at;

  @override
  DateTime now() => _at;

  @override
  Future<void> sleep(Duration duration, CancelToken token) async {
    if (token.isCancelled) throw RunCancelled();
  }
}

class RunCancelled implements Exception {}

/// The msg key carrying the flows a `run_flow` chain has passed through.
const callStackKey = '_callStack';

class CancelToken {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw RunCancelled();
  }
}

/// What actions do outside the executor. The engine supplies the real ones.
abstract interface class FlowEffects {
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params,
  );

  /// Sets a toggle capability to the opposite of the device's current state.
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId,
  );
  Future<void> runFlow(String flowId, Map<String, Object?> msg);
  void announce(Map<String, Object?> payload);
  Future<void> setGlobal(String name, Object? value);
  Map<String, Object?> get globals;
  Map<String, Map<String, Object?>> get deviceStates;

  /// Events the `wait_for_event` node listens to.
  Stream<Map<String, Object?>> get events;
}

class NodeTrace {
  NodeTrace(this.nodeId, this.type, this.startedAt, this.input);

  final String nodeId;
  final String type;
  final DateTime startedAt;
  final Map<String, Object?> input;
  String? port;
  Map<String, Object?>? output;
  String? error;
  Duration? duration;

  Map<String, Object?> toJson() => {
    'node': nodeId,
    'type': type,
    'at': startedAt.toIso8601String(),
    if (duration != null) 'ms': duration!.inMilliseconds,
    if (port != null) 'port': port,
    if (error != null) 'error': error,
    'input': input,
    if (output != null) 'output': output,
  };
}

enum RunOutcome { completed, failed, cancelled, dropped }

class RunTrace {
  RunTrace(
    this.runId,
    this.flowId,
    this.trigger,
    this.startedAt, {
    this.dryRun = false,
  });

  final String runId;
  final String flowId;
  final String trigger;
  final DateTime startedAt;
  final bool dryRun;
  final nodes = <NodeTrace>[];
  RunOutcome outcome = RunOutcome.completed;

  /// Why a run was dropped (running, cooldown, queue_full) or what failed.
  String? reason;
  DateTime? finishedAt;

  Map<String, Object?> toJson() => {
    'run': runId,
    'flow': flowId,
    'trigger': trigger,
    'dryRun': dryRun,
    'outcome': outcome.name,
    if (reason != null) 'reason': reason,
    'startedAt': startedAt.toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
    'nodes': nodes.map((n) => n.toJson()).toList(),
  };
}

class _Run {
  _Run(this.trace, this.dryRun);

  final RunTrace trace;
  final bool dryRun;
  final token = CancelToken();
  final flowVars = <String, Object?>{};
  bool reachedAction = false;
}

/// Runs one flow. Trigger nodes are fired by the flow engine; everything
/// downstream happens here.
class FlowRunner {
  FlowRunner(
    this.flow,
    this._effects, {
    this._clock = const SystemFlowClock(),
    this.onTrace,
    this.maxConcurrent = 10,
    this.maxQueued = 10,
  }) {
    for (final n in flow.nodes) {
      final type = builtInNodeTypes[n.type];
      if (type == null) throw ArgumentError('unknown node type ${n.type}');
      _types[n.id] = type;
    }
  }

  final FlowSpec flow;
  final FlowEffects _effects;
  final FlowClock _clock;
  final void Function(RunTrace trace)? onTrace;
  final int maxConcurrent;
  final int maxQueued;
  final _types = <String, NodeType>{};
  final _active = <_Run>[];
  Future<void> _queueTail = Future.value();
  int _queued = 0;
  DateTime? _cooldownArmedAt;
  final _gatePasses = <String, DateTime>{};
  final _debounceTokens = <String, Object>{};
  var _runCounter = 0;

  /// Bumped by [cancelAll], so a queued run enqueued before it never starts.
  var _generation = 0;

  int get activeRuns => _active.length;

  bool _inCooldown(FlowClock clock) {
    final cooldown = flow.cooldownSeconds;
    return cooldown > 0 &&
        _cooldownArmedAt != null &&
        clock.now().difference(_cooldownArmedAt!) < Duration(seconds: cooldown);
  }

  /// Fires [triggerNodeId] with [msg]. Returns the finished trace. A dry run
  /// stubs every effect and ignores run mode and cooldown.
  Future<RunTrace> fire(
    String triggerNodeId,
    Map<String, Object?> msg, {
    bool dryRun = false,
    FlowClock? clock,
  }) {
    final runClock = clock ?? _clock;
    final now = runClock.now();
    // The time prefix keeps ids unique across runners of the same flow.
    final trace = RunTrace(
      '${flow.id}-${DateTime.now().microsecondsSinceEpoch}-${++_runCounter}',
      flow.id,
      triggerNodeId,
      now,
      dryRun: dryRun,
    );
    if (dryRun) {
      return _execute(_Run(trace, true), triggerNodeId, msg, runClock);
    }

    if (_inCooldown(runClock)) return Future.value(_drop(trace, 'cooldown'));
    switch (flow.mode) {
      case RunMode.single:
        if (_active.isNotEmpty) return Future.value(_drop(trace, 'running'));
      case RunMode.restart:
        for (final r in List.of(_active)) {
          r.token.cancel();
        }
      case RunMode.parallel:
        if (_active.length >= maxConcurrent) {
          return Future.value(_drop(trace, 'too_many_runs'));
        }
      case RunMode.queued:
        if (_queued >= maxQueued) {
          return Future.value(_drop(trace, 'queue_full'));
        }
        _queued++;
        final generation = _generation;
        final previous = _queueTail;
        final done = previous.then<RunTrace>((_) {
          _queued--;
          if (generation != _generation) return _drop(trace, 'cancelled');
          // An earlier queued run may have armed the cooldown meanwhile.
          if (_inCooldown(runClock)) return _drop(trace, 'cooldown');
          return _execute(_Run(trace, false), triggerNodeId, msg, runClock);
        });
        _queueTail = done.then((_) {}, onError: (_) {});
        return done;
    }
    return _execute(_Run(trace, false), triggerNodeId, msg, runClock);
  }

  /// Cancels every running run (the flow was disabled or removed).
  void cancelAll() {
    _generation++;
    for (final r in _active) {
      r.token.cancel();
    }
  }

  RunTrace _drop(RunTrace trace, String reason) {
    trace
      ..outcome = RunOutcome.dropped
      ..reason = reason
      ..finishedAt = trace.startedAt;
    onTrace?.call(trace);
    return trace;
  }

  Future<RunTrace> _execute(
    _Run run,
    String triggerNodeId,
    Map<String, Object?> msg,
    FlowClock clock,
  ) async {
    _active.add(run);
    try {
      final trigger = flow.node(triggerNodeId);
      if (trigger == null ||
          _types[triggerNodeId]?.category != NodeCategory.trigger) {
        throw ArgumentError('$triggerNodeId is not a trigger of ${flow.id}');
      }
      final triggerTrace = NodeTrace(trigger.id, trigger.type, clock.now(), msg)
        ..port = 'out'
        ..duration = Duration.zero;
      run.trace.nodes.add(triggerTrace);
      await _follow(run, trigger.id, 'out', msg, clock);
      if (run.trace.nodes.any((n) => n.error != null) &&
          run.trace.outcome == RunOutcome.completed) {
        run.trace
          ..outcome = RunOutcome.failed
          ..reason = run.trace.nodes.firstWhere((n) => n.error != null).error;
      }
    } on RunCancelled {
      run.trace.outcome = RunOutcome.cancelled;
    } finally {
      _active.remove(run);
      run.trace.finishedAt = clock.now();
      onTrace?.call(run.trace);
    }
    return run.trace;
  }

  Future<void> _follow(
    _Run run,
    String nodeId,
    String port,
    Map<String, Object?> msg,
    FlowClock clock,
  ) async {
    final targets = flow
        .edgesFrom(nodeId, port)
        .map((e) => flow.node(e.to.node)!)
        .toList();
    await Future.wait([for (final t in targets) _runNode(run, t, msg, clock)]);
  }

  Future<void> _runNode(
    _Run run,
    NodeSpec node,
    Map<String, Object?> msg,
    FlowClock clock,
  ) async {
    run.token.check();
    final type = _types[node.id]!;
    final trace = NodeTrace(node.id, node.type, clock.now(), msg);
    run.trace.nodes.add(trace);
    final watch = Stopwatch()..start();
    String? port;
    var out = msg;
    try {
      switch (type.category) {
        case NodeCategory.trigger:
          throw StateError('a trigger cannot be a target');
        case NodeCategory.condition:
          final ctx = _context(run, msg, clock);
          port = evaluateRule({...node.config, 'type': node.type}, ctx)
              ? 'true'
              : 'false';
        case NodeCategory.gate:
          port = await _gate(run, node, clock);
        case NodeCategory.transformer:
          out = applyTransformer(
            node.type,
            node.config,
            msg,
            context: _context(run, msg, clock),
          );
          port = 'out';
        case NodeCategory.flowControl:
          (port, out) = await _flowControl(run, node, msg, clock);
        case NodeCategory.action:
          if (!run.dryRun && !run.reachedAction) {
            run.reachedAction = true;
            if (flow.cooldownSeconds > 0) _cooldownArmedAt = clock.now();
          }
          try {
            out = await _action(run, node, msg, clock);
            port = 'out';
          } on RunCancelled {
            rethrow;
          } catch (e) {
            port = 'error';
            out = {...msg, 'error': _message(e)};
            if (flow.edgesFrom(node.id, 'error').isEmpty) {
              trace.error = _message(e);
            }
          }
      }
    } on RunCancelled {
      trace.error = 'cancelled';
      rethrow;
    } catch (e) {
      trace.error = _message(e);
      return;
    } finally {
      trace.duration = watch.elapsed;
      trace.port = port;
      trace.output = port == null ? null : out;
    }
    if (port != null) await _follow(run, node.id, port, out, clock);
  }

  Future<String?> _gate(_Run run, NodeSpec node, FlowClock clock) async {
    switch (node.type) {
      case 'cooldown':
        final last = _gatePasses[node.id];
        final now = clock.now();
        if (last != null &&
            now.difference(last) <
                Duration(seconds: node.config['seconds'] as int)) {
          return null;
        }
        if (!run.dryRun) _gatePasses[node.id] = now;
        return 'out';
      case 'debounce':
        final mine = Object();
        _debounceTokens[node.id] = mine;
        await clock.sleep(
          Duration(milliseconds: node.config['ms'] as int),
          run.token,
        );
        return identical(_debounceTokens[node.id], mine) ? 'out' : null;
    }
    throw ArgumentError('${node.type} is not a gate');
  }

  Future<(String?, Map<String, Object?>)> _flowControl(
    _Run run,
    NodeSpec node,
    Map<String, Object?> msg,
    FlowClock clock,
  ) async {
    switch (node.type) {
      case 'delay':
        await clock.sleep(
          Duration(milliseconds: node.config['ms'] as int),
          run.token,
        );
        return ('out', msg);
      case 'wait_for_event':
        if (run.dryRun) return ('timeout', msg);
        final name = node.config['event'] as String;
        final timeout = Duration(milliseconds: node.config['timeoutMs'] as int);
        // Whichever loses, the event subscription and the timer both end.
        final got = Completer<Map<String, Object?>?>();
        final waiting = CancelToken();
        run.token.whenCancelled.then((_) => waiting.cancel());
        final subscription = _effects.events.listen((e) {
          if (e['event'] == name && !got.isCompleted) got.complete(e);
        });
        clock
            .sleep(timeout, waiting)
            .then(
              (_) {
                if (!got.isCompleted) got.complete(null);
              },
              onError: (Object e) {
                if (!got.isCompleted) got.completeError(e);
              },
            );
        try {
          final event = await got.future;
          return event == null
              ? ('timeout', msg)
              : ('event', {...msg, 'event': event});
        } finally {
          waiting.cancel();
          await subscription.cancel();
        }
      case 'repeat':
        final times = node.config['maxIterations'] as int;
        for (var i = 0; i < times; i++) {
          run.token.check();
          await _follow(run, node.id, 'body', {...msg, 'iteration': i}, clock);
        }
        return ('done', msg);
    }
    throw ArgumentError('${node.type} is not a flow-control node');
  }

  Future<Map<String, Object?>> _action(
    _Run run,
    NodeSpec node,
    Map<String, Object?> msg,
    FlowClock clock,
  ) async {
    const renderer = TemplateRenderer();
    final context = TemplateContext(
      msg: msg,
      globals: _effects.globals,
      flowVars: run.flowVars,
    );
    final c = node.config;
    switch (node.type) {
      case 'device_capability':
        final params = Map<String, Object?>.from(
          renderer.render(c['params'] ?? const {}, context) as Map,
        );
        if (run.dryRun) {
          return {
            ...msg,
            'result': {
              'dryRun': true,
              'deviceId': c['deviceId'],
              'capabilityId': c['capabilityId'],
              'params': params,
            },
          };
        }
        final reply = await _effects.invokeDevice(
          c['deviceId'] as String,
          c['capabilityId'] as String,
          params,
        );
        return {...msg, 'result': reply};
      case 'device_toggle':
        if (run.dryRun) {
          return {
            ...msg,
            'result': {
              'dryRun': true,
              'deviceId': c['deviceId'],
              'capabilityId': c['capabilityId'],
              'toggle': true,
            },
          };
        }
        final toggled = await _effects.toggleDevice(
          c['deviceId'] as String,
          c['capabilityId'] as String,
        );
        return {...msg, 'result': toggled};
      case 'set_variable':
        final name = c['name'] as String;
        final value = renderer.render(c['value'], context);
        if (name.startsWith('%')) {
          run.flowVars[name.substring(1)] = value;
        } else if (!run.dryRun) {
          await _effects.setGlobal(name.substring(1), value);
        }
        return msg;
      case 'run_flow':
        final target = c['flowId'] as String;
        // A queued flow that calls itself, directly or through others,
        // would wait on its own run forever.
        final callers = [...?(msg[callStackKey] as List?), flow.id];
        if (callers.contains(target)) {
          throw StateError(
            'run_flow cycle: ${[...callers, target].join(' -> ')}',
          );
        }
        if (!run.dryRun) {
          await _effects.runFlow(target, {...msg, callStackKey: callers});
        }
        return msg;
      case 'notify' || 'speak':
        final payload = Map<String, Object?>.from(
          renderer.render({...c, 'type': node.type}, context) as Map,
        );
        if (!run.dryRun) _effects.announce(payload);
        return {...msg, 'announced': payload};
    }
    throw ArgumentError('${node.type} is not an action');
  }

  EvalContext _context(_Run run, Map<String, Object?> msg, FlowClock clock) =>
      EvalContext(
        now: clock.now(),
        globals: _effects.globals,
        flowVars: run.flowVars,
        msg: msg,
        deviceStates: _effects.deviceStates,
      );

  static String _message(Object e) {
    final text = e.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}
