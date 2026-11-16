import 'dart:async';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// A phone that slept, or whose clock or time zone moved, wakes the engine
/// with an exact alarm for [FlowEngine.nextTimeDue] and calls
/// [FlowEngine.retime]: a timer counts only time the CPU is awake.
void main() {
  test('nothing is due before the timers start, then the daily time is', () {
    final clock = _SettableClock(DateTime(2026, 11, 10, 0, 30));
    final engine = FlowEngine(_Host(), clock: clock)..load([_daily('01:00')]);
    expect(engine.nextTimeDue, isNull);
    engine.startTimers();
    expect(engine.nextTimeDue, DateTime(2026, 11, 10, 1));
    addTearDown(engine.close);
  });

  test('a daily time passed while asleep runs once on retime', () async {
    final clock = _SettableClock(DateTime(2026, 11, 10, 0, 30));
    final host = _Host();
    final engine = FlowEngine(host, clock: clock)
      ..load([_daily('01:00')])
      ..startTimers();
    // The CPU slept through 01:00: the timer has not gone off yet.
    clock.at = DateTime(2026, 11, 10, 1, 0, 2);
    engine.retime();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.traces, hasLength(1));
    expect(engine.nextTimeDue, DateTime(2026, 11, 11, 1));
    // A second alarm for the same time does not run it again.
    engine.retime();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.traces, hasLength(1));
    await engine.close();
  });

  test('a clock put hours forward runs nothing it skipped over', () async {
    final clock = _SettableClock(DateTime(2026, 11, 10, 0, 30));
    final host = _Host();
    final engine = FlowEngine(host, clock: clock)
      ..load([_daily('01:00')])
      ..startTimers();
    clock.at = DateTime(2026, 11, 10, 7);
    engine.retime();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.traces, isEmpty);
    expect(engine.nextTimeDue, DateTime(2026, 11, 11, 1));
    await engine.close();
  });

  test('a time zone change moves the next time and runs nothing', () async {
    final clock = _SettableClock(DateTime(2026, 11, 10, 0, 30));
    final host = _Host();
    final engine = FlowEngine(host, clock: clock)
      ..load([_daily('01:00')])
      ..startTimers();
    // The local clock now reads an earlier hour: 01:00 is further away.
    clock.at = DateTime(2026, 11, 9, 21, 30);
    engine.retime();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.traces, isEmpty);
    expect(engine.nextTimeDue, DateTime(2026, 11, 10, 1));
    await engine.close();
  });

  test(
    'an interval is due one period on, and runs once when overdue',
    () async {
      final clock = _SettableClock(DateTime(2026, 11, 10, 9));
      final host = _Host();
      final engine = FlowEngine(host, clock: clock)
        ..load([_every(600)])
        ..startTimers();
      expect(engine.nextTimeDue, DateTime(2026, 11, 10, 9, 10));
      clock.at = DateTime(2026, 11, 10, 9, 12);
      engine.retime();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.traces, hasLength(1));
      expect(engine.nextTimeDue, DateTime(2026, 11, 10, 9, 22));
      await engine.close();
    },
  );

  test('retime does nothing while the timers are stopped', () async {
    final clock = _SettableClock(DateTime(2026, 11, 10, 0, 30));
    final host = _Host();
    final engine = FlowEngine(host, clock: clock)
      ..load([_daily('01:00')])
      ..startTimers()
      ..stopTimers();
    clock.at = DateTime(2026, 11, 10, 1, 0, 2);
    engine.retime();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.traces, isEmpty);
    expect(engine.nextTimeDue, isNull);
    await engine.close();
  });
}

FlowSpec _flow(String id, Map<String, Object?> trigger) => FlowSpec.parse({
  'schemaVersion': 1,
  'id': id,
  'name': id,
  'nodes': [
    {'id': 'when', ...trigger},
    {
      'id': 'say',
      'type': 'notify',
      'config': {'title': 'Hello'},
    },
  ],
  'edges': [
    {
      'id': 'e1',
      'from': {'node': 'when', 'port': 'out'},
      'to': {'node': 'say', 'port': 'in'},
    },
  ],
});

FlowSpec _daily(String at) => _flow('night', {
  'type': 'time_of_day',
  'config': {'at': at},
});

FlowSpec _every(int seconds) => _flow('often', {
  'type': 'interval',
  'config': {'seconds': seconds},
});

class _SettableClock implements FlowClock {
  _SettableClock(this.at);

  DateTime at;

  @override
  DateTime now() => at;

  @override
  Future<void> sleep(Duration duration, CancelToken token) async {
    if (token.isCancelled) throw RunCancelled();
  }
}

class _Host implements FlowHost {
  final traces = <Map<String, Object?>>[];
  final marked = <String>{};
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<bool> ranAt(String flowId, String scheduled) async =>
      marked.contains('$flowId@$scheduled');

  @override
  Future<void> markScheduled(String flowId, String scheduled) async =>
      marked.add('$flowId@$scheduled');

  @override
  Future<void> saveTrace(Map<String, Object?> trace) async => traces.add(trace);

  @override
  Future<void> saveGlobal(String name, Object? value) async {}

  @override
  Future<String?> webSecret(String name) async => null;

  @override
  void emit(Map<String, Object?> event) {}

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<Map<String, Object?>?> deviceState(String deviceId) async => null;

  @override
  Future<List<String>> roomDevices(String room) async => const [];

  @override
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    String? flowId,
  }) async => null;

  @override
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId, {
    String? flowId,
  }) async => null;
}
