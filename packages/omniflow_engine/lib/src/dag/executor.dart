import 'dart:async';
import 'dart:convert';

import '../template/template_renderer.dart';
import 'asks.dart';
import 'canonical.dart';
import 'conditions.dart';
import 'data_steps.dart';
import 'error_text.dart';
import 'expression.dart';
import 'flow.dart';
import 'flow_engine.dart' show payloadMatches, stateTriggerFires;
import 'node_types.dart';
import 'transformers.dart';
import 'web_request.dart';

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
  /// Runs a capability for the flow [flowId].
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    String? flowId,
  });

  /// Sets a toggle capability to the opposite of the device's current state.
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId, {
    String? flowId,
  });
  Future<void> runFlow(String flowId, Map<String, Object?> msg);
  void announce(Map<String, Object?> payload);
  Future<void> setGlobal(String name, Object? value);
  Map<String, Object?> get globals;
  Map<String, Map<String, Object?>> get deviceStates;

  /// Events the `wait_for_event` node listens to.
  Stream<Map<String, Object?>> get events;

  /// The stored state of [deviceId], read after a step drives it, or null.
  Future<Map<String, Object?>?> stateOf(String deviceId);

  /// The ids of the devices in the room named [room] (or with that id), in
  /// the user's order. Throws when there is no such room.
  Future<List<String>> roomDevices(String room);
}

class NodeTrace {
  NodeTrace(this.nodeId, this.type, this.startedAt, this.input, {this.label});

  final String nodeId;
  final String type;

  /// The step's words when it ran, so a past run reads right after the
  /// automation is edited.
  final String? label;
  final DateTime startedAt;
  final Map<String, Object?> input;
  String? port;
  Map<String, Object?>? output;
  String? error;
  Duration? duration;

  Map<String, Object?> toJson() => {
    'node': nodeId,
    'type': type,
    'label': ?label,
    'at': startedAt.toIso8601String(),
    if (duration != null) 'ms': duration!.inMilliseconds,
    if (port != null) 'port': port,
    if (error != null) 'error': error,
    'input': _traced(input),
    if (output != null) 'output': _traced(output!),
  };
}

/// [msg] as a trace keeps it: a web reply's body stays with the run that
/// reads it, so the run log holds only its status and size. A phone
/// notification's title and text stay with the run too, and so does what
/// a step announced from them.
Map<String, Object?> _traced(Map<String, Object?> msg) {
  var out = msg;
  final response = msg['response'];
  if (response is Map && response.containsKey('body')) {
    out = {
      ...out,
      'response': {
        for (final e in response.entries)
          if (e.key != 'body') e.key: e.value,
      },
    };
  }
  if (isNotificationMsg(msg)) {
    out = {
      ...out,
      'payload': ?_withoutPrivate(out['payload']),
      'event': ?_withoutPrivate(out['event']),
      if (out['announced'] is Map)
        'announced': {'type': (out['announced'] as Map)['type']},
    };
  }
  return out;
}

/// The phone event whose payload carries a notification's words.
const notificationEvent = 'notification';

/// The payload keys of a notification that never leave its run.
const _privateKeys = {'title', 'text'};

/// Whether [msg] came from a notification arriving, as a trigger or what a
/// wait matched.
bool isNotificationMsg(Map<String, Object?> msg) =>
    msg['key'] == notificationEvent ||
    (msg['event'] is Map && (msg['event'] as Map)['key'] == notificationEvent);

Object? _withoutPrivate(Object? value) {
  if (value is! Map) return value;
  return {
    for (final e in value.entries)
      if (!_privateKeys.contains(e.key))
        e.key: e.key == 'payload' ? _withoutPrivate(e.value) : e.value,
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
    this.web = const IoWebRequester(),
    this.webSecret,
    this.asks,
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

  /// Sends web request steps.
  final WebRequester web;

  /// Reads the secrets a web request's `{"secret": "name"}` headers name.
  final WebSecretReader? webSecret;

  /// Asks the person for ask steps. Without one an ask step fails.
  final AskBroker? asks;
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
      final triggerTrace =
          NodeTrace(
              trigger.id,
              trigger.type,
              clock.now(),
              msg,
              label: _ownLabel(trigger),
            )
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
    final trace = NodeTrace(
      node.id,
      node.type,
      clock.now(),
      msg,
      label: _ownLabel(node),
    );
    run.trace.nodes.add(trace);
    final watch = Stopwatch()..start();
    String? port;
    // A failed step of a flow that carries on after errors records the
    // failure and goes on through `out`.
    String? follow;
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
          if (!run.dryRun &&
              !run.reachedAction &&
              !_valueSteps.contains(node.type)) {
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
              if (flow.continueOnError) follow = 'out';
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
    final next = follow ?? port;
    if (next != null) await _follow(run, node.id, next, out, clock);
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
        final event = await _waitForEvent(
          run,
          clock,
          Duration(milliseconds: node.config['timeoutMs'] as int),
          (e) => e['event'] == name ? e : null,
        );
        return event == null
            ? ('timeout', msg)
            : ('event', {...msg, 'event': event});
      case 'wait_until':
        final c = node.config;
        final thing = c['thing'] as String;
        final key = c['key'] as String?;
        // A rule's steps after a waitFor hang off `matched`, so a dry run
        // that timed out would never preview them.
        if (run.dryRun) {
          return (
            'matched',
            {
              ...msg,
              'event': {'thing': thing, 'key': ?key},
            },
          );
        }
        // The flow engine updates deviceStates before this listener sees
        // the event, so the value before it is tracked here.
        var before = Map<String, Object?>.of(
          _effects.deviceStates[thing] ?? const {},
        );
        Map<String, Object?>? matched(Map<String, Object?> e) {
          if (c['event'] == true) {
            if (e['event'] != 'thing.event' ||
                e['thing'] != thing ||
                e['key'] != key) {
              return null;
            }
            final payload = e['payload'] is Map
                ? Map<String, Object?>.from(e['payload'] as Map)
                : const <String, Object?>{};
            return payloadMatches(c['match'], payload)
                ? {'thing': thing, 'key': key, 'payload': payload}
                : null;
          }
          if (e['event'] != 'device.stateChanged') return null;
          final device = e['device'];
          if (device is! Map || device['id'] != thing) return null;
          final state = Map<String, Object?>.from(device['state'] as Map);
          final previous = before;
          before = state;
          final fires = key == null
              ? canonicalJson(previous) != canonicalJson(state)
              : stateTriggerFires(c, previous[key], state[key]);
          return fires
              ? {
                  'thing': thing,
                  if (key != null) ...{
                    'key': key,
                    'value': state[key],
                    'previous': previous[key],
                  },
                }
              : null;
        }

        final got = await _waitForEvent(
          run,
          clock,
          Duration(milliseconds: c['timeoutMs'] as int),
          matched,
        );
        return got == null
            ? ('timeout', msg)
            : ('matched', {...msg, 'event': got});
      case 'parallel':
        await _follow(run, node.id, 'branch', msg, clock);
        return ('done', msg);
      case 'repeat':
        // Up to maxIterations times, stopping before a pass once `until`
        // holds, with `everyMs` between passes.
        final times = node.config['maxIterations'] as int;
        final until = node.config['until'];
        final every = node.config['everyMs'] as int? ?? 0;
        for (var i = 0; i < times; i++) {
          run.token.check();
          if (i > 0 && every > 0) {
            await clock.sleep(Duration(milliseconds: every), run.token);
          }
          if (until is Map &&
              evaluateRule(
                Map<String, Object?>.from(until),
                _context(run, msg, clock),
              )) {
            break;
          }
          await _follow(run, node.id, 'body', {...msg, 'iteration': i}, clock);
        }
        return ('done', msg);
      case 'for_each':
        final items = await _items(run, node.config, msg);
        final max = node.config['maxIterations'] as int;
        final name = _varName(node.config['as'], 'item');
        for (var i = 0; i < items.length && i < max; i++) {
          run.token.check();
          run.flowVars[name] = items[i];
          await _follow(run, node.id, 'body', {...msg, 'index': i}, clock);
        }
        return ('done', msg);
    }
    throw ArgumentError('${node.type} is not a flow-control node');
  }

  /// The first engine event [match] turns into a result, or null when
  /// [timeout] passes first.
  Future<Map<String, Object?>?> _waitForEvent(
    _Run run,
    FlowClock clock,
    Duration timeout,
    Map<String, Object?>? Function(Map<String, Object?> event) match,
  ) async {
    // Whichever loses, the event subscription and the timer both end.
    final got = Completer<Map<String, Object?>?>();
    final waiting = CancelToken();
    run.token.whenCancelled.then((_) => waiting.cancel());
    final subscription = _effects.events.listen((e) {
      if (got.isCompleted) return;
      final result = match(e);
      if (result != null) got.complete(result);
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
      return await got.future;
    } finally {
      waiting.cancel();
      await subscription.cancel();
    }
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
        final deviceId = _deviceOf(c['deviceId'], context);
        final stateVar = _varName(c['as'], 'state');
        if (run.dryRun) {
          run.flowVars[stateVar] = _effects.deviceStates[deviceId];
          return {
            ...msg,
            'result': {
              'dryRun': true,
              'deviceId': deviceId,
              'capabilityId': c['capabilityId'],
              'params': params,
            },
          };
        }
        final reply = await _effects.invokeDevice(
          deviceId,
          c['capabilityId'] as String,
          params,
          flowId: flow.id,
        );
        run.flowVars[stateVar] = await _effects.stateOf(deviceId);
        return {...msg, 'result': reply};
      case 'device_toggle':
        final toggleId = _deviceOf(c['deviceId'], context);
        if (run.dryRun) {
          return {
            ...msg,
            'result': {
              'dryRun': true,
              'deviceId': toggleId,
              'capabilityId': c['capabilityId'],
              'toggle': true,
            },
          };
        }
        final toggled = await _effects.toggleDevice(
          toggleId,
          c['capabilityId'] as String,
          flowId: flow.id,
        );
        return {...msg, 'result': toggled};
      case 'set_variable':
        final name = c['name'] as String;
        final value = renderer.render(c['value'], context);
        if (name.startsWith('%')) {
          run.flowVars[name.substring(1)] = value;
        } else if (isNotificationMsg(msg)) {
          // A global is stored, backed up and read by agents, and could
          // keep the notification's words.
          throw StateError(
            'a run started by a notification cannot set the variable '
            '${name.substring(1)}: use a %run variable',
          );
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
      case 'http_request':
        final method = '${c['method'] ?? 'GET'}';
        final url = Uri.parse('${renderer.render(c['url'], context)}');
        if (url.scheme != 'http' && url.scheme != 'https') {
          throw StateError('$url is not an http or https address');
        }
        final secretHeaders = {
          for (final e in (c['headers'] as Map? ?? const {}).entries)
            '${e.key}': ?webSecretRef(e.value),
        };
        final headers = {
          for (final e in (c['headers'] as Map? ?? const {}).entries)
            if (!secretHeaders.containsKey('${e.key}'))
              '${e.key}': '${renderer.render(e.value, context)}',
        };
        final raw = renderer.render(c['body'], context);
        final body = raw == null || raw is String
            ? raw as String?
            : jsonEncode(raw);
        if (raw != null && raw is! String) {
          headers.putIfAbsent('content-type', () => 'application/json');
        }
        final replyVar = _varName(c['as'], 'reply');
        if (run.dryRun) {
          run.flowVars[replyVar] = {'status': 0, 'body': null};
          return {
            ...msg,
            'result': {
              'dryRun': true,
              'method': method,
              'url': webShownAddress('$url'),
            },
          };
        }
        for (final MapEntry(key: header, value: name)
            in secretHeaders.entries) {
          final value = await webSecret?.call(name);
          if (value == null) {
            throw StateError(
              'no web secret $name is stored for the $header header: set it '
              'with omni secret set-web $name',
            );
          }
          headers[header] = value;
        }
        final reply = await web.send(method, url, headers: headers, body: body);
        // A refusal is a failed step, so a try's otherwise takes over.
        if (reply.status >= 400) {
          throw StateError('${url.host} answered ${reply.status}');
        }
        run.flowVars[replyVar] = {
          'status': reply.status,
          'body': _jsonOrText(reply.body),
        };
        // Later steps read the body, and the trace leaves it out.
        return {
          ...msg,
          'response': {
            'status': reply.status,
            'bytes': reply.bytes,
            'body': reply.body,
          },
        };
      case 'notify' || 'speak':
        final payload = Map<String, Object?>.from(
          renderer.render({...c, 'type': node.type}, context) as Map,
        );
        if (!run.dryRun) _effects.announce({...payload, 'flow': flow.id});
        return {...msg, 'announced': payload};
      case 'ask':
        run.flowVars[_varName(c['as'], 'answer')] = await _ask(
          run,
          c,
          context,
          clock,
        );
        return msg;
      case 'get_value':
        final from = renderer.render(c['from'], context);
        final path = c['path'] as String?;
        final (found, value) = valueAt(from, path);
        if (!found && !run.dryRun) {
          throw StateError('the value has nothing at $path');
        }
        run.flowVars[_varName(c['as'], 'value')] = value;
        return msg;
      case 'format_text':
        final text = c['value'] is String
            ? renderer.renderText(c['value'] as String, context)
            : _text(renderer.render(c['value'], context));
        run.flowVars[_varName(c['as'], 'text')] = applyTextOp(text, c['op']);
        return msg;
      case 'calculate':
        run.flowVars[_varName(c['as'], 'result')] = _calculate(
          run,
          '${c['expr']}',
          context,
          msg,
        );
        return msg;
      case 'format_date':
        final at = clock.now().add(
          Duration(minutes: (c['offsetMinutes'] as int?) ?? 0),
        );
        run.flowVars[_varName(c['as'], 'date')] = formatDate(
          at,
          (c['format'] as String?) ?? 'HH:mm',
        );
        return msg;
    }
    throw ArgumentError('${node.type} is not an action');
  }

  /// The answer to an ask step: the person's, its default on a timeout, or
  /// in a dry run the default or first choice. With no answer and no
  /// default the step fails, so a try's otherwise runs.
  Future<String> _ask(
    _Run run,
    Map<String, Object?> c,
    TemplateContext context,
    FlowClock clock,
  ) async {
    const renderer = TemplateRenderer();
    final choices = c['choices'] == null
        ? null
        : [
            for (final choice in c['choices'] as List)
              renderer.renderText('$choice', context),
          ];
    final fallback = c['default'] == null
        ? null
        : renderer.renderText('${c['default']}', context);
    if (run.dryRun) return fallback ?? choices?.firstOrNull ?? '';
    final asks = this.asks;
    if (asks == null) throw StateError('nothing here can ask you');
    final answer = await asks.ask(
      flow: flow.id,
      kind: choices != null && choices.isNotEmpty
          ? AskKind.choose
          : AskKind.input,
      title: renderer.renderText('${c['title']}', context),
      body: c['body'] == null
          ? null
          : renderer.renderText('${c['body']}', context),
      choices: choices,
      fallback: fallback,
      timeout: Duration(
        milliseconds: (c['timeoutMs'] as int?) ?? askDefaultTimeoutMs,
      ),
      token: run.token,
      clock: clock,
    );
    if (answer != null) return answer;
    if (fallback != null) return fallback;
    throw StateError('no answer came in time');
  }

  /// [expr] with its `{{...}}` filled in, worked out. Names in it read
  /// run variables (`%count`), globals (`$Level`) and the message (`msg.x`).
  num _calculate(
    _Run run,
    String expr,
    TemplateContext context,
    Map<String, Object?> msg,
  ) {
    final filled = const TemplateRenderer().renderText(expr, context);
    num? resolve(String name) {
      final Object? v;
      if (name.startsWith('%')) {
        v = valueAt(run.flowVars, name.substring(1)).$2;
      } else if (name.startsWith(r'$')) {
        v = valueAt(_effects.globals, name.substring(1)).$2;
      } else if (name.startsWith('msg.')) {
        v = valueAt(msg, name.substring(4)).$2;
      } else {
        v = null;
      }
      return v is num ? v : (v is String ? num.tryParse(v) : null);
    }

    try {
      return evaluateExpression(filled, resolve);
    } on ExpressionException catch (e) {
      if (run.dryRun) return 0;
      throw StateError('$filled cannot be worked out: ${e.message}');
    }
  }

  /// The items a forEach goes through: a room's devices, or a list.
  Future<List<Object?>> _items(
    _Run run,
    Map<String, Object?> c,
    Map<String, Object?> msg,
  ) async {
    final source = c['in'];
    if (source is String && source.startsWith('room:')) {
      return _effects.roomDevices(source.substring(5).trim());
    }
    final value = const TemplateRenderer().render(
      source,
      TemplateContext(
        msg: msg,
        globals: _effects.globals,
        flowVars: run.flowVars,
      ),
    );
    final list = _jsonOrText(value);
    if (list is List) return list;
    if (run.dryRun) return const [];
    throw StateError('there is no list to go through, only ${_text(list)}');
  }

  static String _varName(Object? as, String fallback) =>
      as is String && as.startsWith('%') ? as.substring(1) : fallback;

  /// A device a step names, or the one a run variable holds.
  static String _deviceOf(Object? id, TemplateContext context) {
    final text = '$id';
    if (!runDevicePattern.hasMatch(text)) return text;
    final value = const TemplateRenderer().render(text, context);
    if (value is! String || value.isEmpty) {
      throw StateError('$text is not a device');
    }
    return value;
  }

  static Object? _jsonOrText(Object? body) {
    if (body is! String) return body;
    final t = body.trimLeft();
    if (!t.startsWith('{') && !t.startsWith('[')) return body;
    try {
      return jsonDecode(body);
    } on FormatException {
      return body;
    }
  }

  static String _text(Object? value) => switch (value) {
    String s => s,
    null => '',
    num() || bool() => '$value',
    _ => jsonEncode(value),
  };

  EvalContext _context(_Run run, Map<String, Object?> msg, FlowClock clock) =>
      EvalContext(
        now: clock.now(),
        globals: _effects.globals,
        flowVars: run.flowVars,
        msg: msg,
        deviceStates: _effects.deviceStates,
      );

  static String _message(Object e) =>
      withoutTypeName(e is ArgumentError ? '${e.message}' : '$e');
}

/// Steps that only ask or work out a value, which do not start a cooldown.
const _valueSteps = {
  'ask',
  'get_value',
  'format_text',
  'calculate',
  'format_date',
};

/// A node's label when the flow gave it one: without, it is the node id.
String? _ownLabel(NodeSpec node) => node.label == node.id ? null : node.label;
