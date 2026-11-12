import 'dart:async';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

class _Host implements FlowHost {
  _Host({this.ran = false});

  final bool ran;
  final traces = <Map<String, Object?>>[];
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<bool> ranAt(String flowId, String scheduled) async =>
      ran || marked.contains('$flowId@$scheduled');

  final marked = <String>{};

  @override
  Future<void> markScheduled(String flowId, String scheduled) async =>
      marked.add('$flowId@$scheduled');

  @override
  Future<void> saveTrace(Map<String, Object?> trace) async => traces.add(trace);

  @override
  Future<void> saveGlobal(String name, Object? value) async {}

  @override
  void emit(Map<String, Object?> event) {}

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

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

FlowSpec _daily(String at) => FlowSpec.parse({
  'schemaVersion': 1,
  'id': 'night',
  'name': 'Night',
  'nodes': [
    {
      'id': 'when',
      'type': 'time_of_day',
      'config': {'at': at},
    },
    {
      'id': 'say',
      'type': 'notify',
      'config': {'title': 'Good night'},
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

Future<List<Map<String, Object?>>> _startAt(
  DateTime now, {
  bool ran = false,
  Set<String> marked = const {},
}) async {
  final host = _Host(ran: ran)..marked.addAll(marked);
  final engine = FlowEngine(host, clock: InstantFlowClock(now))
    ..load([_daily('01:00')])
    ..startTimers();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await engine.close();
  return host.traces;
}

void main() {
  test('a daily time missed during a restart runs once on start', () async {
    final traces = await _startAt(DateTime(2026, 11, 10, 1, 5));
    expect(traces, hasLength(1));
    expect(
      ((traces.single['nodes'] as List).first as Map)['input'],
      containsPair('caughtUp', true),
    );
  });

  test('a time that already ran, or is long past, is not run again', () async {
    expect(await _startAt(DateTime(2026, 11, 10, 1, 5), ran: true), isEmpty);
    expect(await _startAt(DateTime(2026, 11, 10, 1, 30)), isEmpty);
    expect(await _startAt(DateTime(2026, 11, 10, 0, 59)), isEmpty);
  });

  test('a run cut off by the restart is not started again', () async {
    final at = DateTime(2026, 11, 10, 1).toIso8601String();
    expect(
      await _startAt(DateTime(2026, 11, 10, 1, 5), marked: {'night@$at'}),
      isEmpty,
    );
  });

  test('the previous time of day respects the days', () {
    expect(
      previousTimeOfDay(DateTime(2026, 11, 10, 1, 5), '01:00'),
      DateTime(2026, 11, 10, 1, 0),
    );
    expect(
      previousTimeOfDay(
        DateTime(2026, 11, 10, 1, 5),
        '01:00',
        days: const ['sun'],
      ),
      DateTime(2026, 11, 8, 1, 0),
    );
  });
}
