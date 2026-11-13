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

  test('a clock set back before the time does not fire it early', () async {
    final clock = _SettableClock(DateTime(2026, 11, 10, 0, 59, 59, 800));
    final host = _Host();
    final engine = FlowEngine(host, clock: clock)
      ..load([_daily('01:00')])
      ..startTimers();
    clock.at = DateTime(2026, 11, 10, 0, 30);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(host.traces, isEmpty);
    expect(host.marked, isEmpty);
    await engine.close();
  });

  test('a daily time on time runs once', () async {
    final clock = _SettableClock(DateTime(2026, 11, 10, 0, 59, 59, 800));
    final host = _Host();
    final engine = FlowEngine(host, clock: clock)
      ..load([_daily('01:00')])
      ..startTimers();
    clock.at = DateTime(2026, 11, 10, 1, 0, 0, 1);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await engine.close();
    expect(host.traces, hasLength(1));
    expect(host.marked, {
      'night@${DateTime(2026, 11, 10, 1).toIso8601String()}',
    });
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

  group('a sun trigger', () {
    const HomeLocation london = (latitude: 51.5074, longitude: -0.1278);
    final sunset = sunEventUtc(2026, 6, 21, SunEvent.sunset, 51.5074, -0.1278)!;

    FlowSpec sunFlow() => FlowSpec.parse({
      'schemaVersion': 1,
      'id': 'dusk',
      'name': 'Dusk',
      'nodes': [
        {
          'id': 'when',
          'type': 'sun',
          'config': {'event': 'sunset'},
        },
        {
          'id': 'say',
          'type': 'notify',
          'config': {'title': 'Dusk'},
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

    Future<List<Map<String, Object?>>> startAt(
      DateTime now, {
      HomeLocation? home = london,
      bool ran = false,
    }) async {
      final host = _Host(ran: ran);
      final engine = FlowEngine(host, clock: InstantFlowClock(now))
        ..homeLocation = home
        ..load([sunFlow()])
        ..startTimers();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.close();
      return host.traces;
    }

    test('missed during a restart runs once, like a daily time', () async {
      final traces = await startAt(sunset.add(const Duration(minutes: 5)));
      expect(traces, hasLength(1));
      final input = ((traces.single['nodes'] as List).first as Map)['input'];
      expect(input, containsPair('caughtUp', true));
      expect(input, containsPair('scheduled', sunset.toIso8601String()));
    });

    test('long past, already run, or with no home, is not run', () async {
      expect(await startAt(sunset.add(const Duration(minutes: 30))), isEmpty);
      expect(
        await startAt(sunset.add(const Duration(minutes: 5)), ran: true),
        isEmpty,
      );
      expect(
        await startAt(sunset.add(const Duration(minutes: 5)), home: null),
        isEmpty,
      );
    });
  });
}

/// A wall clock the test moves, as a user or summer time would.
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
