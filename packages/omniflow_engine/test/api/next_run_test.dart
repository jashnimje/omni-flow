import 'dart:io';

import 'package:test/test.dart';

import 'automation_harness.dart';

/// automation.list says when a time-based automation runs next.
void main() {
  late Directory home;
  late AutomationHarness h;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_next_run');
    h = await AutomationHarness.open(home);
  });

  tearDown(() async {
    await h.shutdown();
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await h.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command: $result');
    return result;
  }

  Future<Map<String, Object?>> row(String id) async {
    final listed = await ok('automation.list', const {});
    return (listed['automations'] as List)
        .cast<Map<String, Object?>>()
        .firstWhere((a) => a['id'] == id);
  }

  Future<void> save(String name, List<Object> when) => ok('automation.save', {
    'form': 'rule',
    'spec': {
      'name': name,
      'when': when,
      'then': ['lamp.power=true'],
    },
    'trusted': true,
  });

  void expectNextAt(Object? next, int hour, int minute) {
    expect(next, isA<String>());
    final at = DateTime.parse(next! as String);
    final now = DateTime.now();
    expect(at.isAfter(now), isTrue, reason: '$at is after $now');
    expect(at.difference(now), lessThanOrEqualTo(const Duration(hours: 25)));
    expect((at.hour, at.minute), (hour, minute));
  }

  test('a daily time carries its next run, with and without timers', () async {
    await save('Evening', ['time:18:30']);
    expectNextAt((await row('evening'))['nextRun'], 18, 30);

    h.core.flows.startTimers();
    expectNextAt((await row('evening'))['nextRun'], 18, 30);
    h.core.flows.stopTimers();
  });

  test('the earliest of two times is the next run', () async {
    await save('Twice', ['time:06:00', 'time:06:01']);
    final next = DateTime.parse((await row('twice'))['nextRun']! as String);
    final now = DateTime.now();
    final six = DateTime(now.year, now.month, now.day, 6);
    final sixOne = six.add(const Duration(minutes: 1));
    // Between 06:00 and 06:01 the next run is 06:01 today.
    final expected = now.isBefore(six)
        ? six
        : now.isBefore(sixOne)
        ? sixOne
        : DateTime(now.year, now.month, now.day + 1, 6);
    expect(next, expected);
  });

  test('a manual or switched off automation has no next run', () async {
    await save('By hand', ['manual']);
    expect((await row('by_hand')).containsKey('nextRun'), isFalse);

    await save('Later', ['time:18:30']);
    await ok('automation.enable', {'id': 'later', 'enabled': false});
    expect((await row('later')).containsKey('nextRun'), isFalse);
  });
}
