import 'dart:math';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

final t0 = DateTime(2026, 11, 6, 19);
DateTime s(num seconds) =>
    t0.add(Duration(milliseconds: (seconds * 1000).round()));

/// A recorded walk: approach for 10 s, sit for 60 s, then leave and go out of
/// range. Readings arrive about 4 times a second with +-12 dBm noise, as on a phone.
List<(DateTime, double)> walkToDeskAndLeave(int seed) {
  final rng = Random(seed);
  final out = <(DateTime, double)>[];
  for (var ms = 0; ms < 75000; ms += 250 + rng.nextInt(100)) {
    final sec = ms / 1000;
    final double mean;
    if (sec < 10) {
      mean = -90 + 3.2 * sec;
    } else if (sec < 70) {
      mean = -57;
    } else {
      mean = -57 - 8 * (sec - 70);
    }
    if (mean < -95) break;
    out.add((s(sec), mean + (rng.nextDouble() * 24 - 12)));
  }
  return out;
}

void main() {
  const desk = BleSettings(matchName: 'OMNI_PICO_DESK');

  group('BLE tracker', () {
    test(
      'a noisy walk to the desk and away gives exactly one enter and one exit',
      () {
        for (final seed in [1, 2, 3, 4, 5]) {
          final tracker = BleTracker(desk);
          final changes = <(ZoneTransition, double)>[];
          final trace = walkToDeskAndLeave(seed);
          var last = trace.first.$1;
          for (final (at, rssi) in trace) {
            final c = tracker.reading(rssi, at);
            if (c != null) {
              changes.add((c, at.difference(t0).inMilliseconds / 1000));
            }
            last = at;
          }
          for (var sec = 1; sec <= 60; sec++) {
            final at = last.add(Duration(seconds: sec));
            final c = tracker.tick(at);
            if (c != null) {
              changes.add((c, at.difference(t0).inMilliseconds / 1000));
            }
          }
          expect(changes.map((c) => c.$1), [
            ZoneTransition.entered,
            ZoneTransition.exited,
          ], reason: 'seed $seed: $changes');
          expect(
            changes.first.$2,
            inInclusiveRange(8, 17),
            reason: 'seed $seed enters late',
          );
          expect(
            changes.last.$2,
            greaterThan(70),
            reason: 'seed $seed exits while still at the desk',
          );
        }
      },
    );

    test('silence alone produces an exit (the defect the spec had)', () {
      final tracker = BleTracker(desk);
      for (var i = 0; i <= 12; i++) {
        tracker.reading(-55, s(i * 0.25));
      }
      expect(tracker.isPresent, isTrue);
      ZoneTransition? exit;
      for (var sec = 4; sec < 60 && exit == null; sec++) {
        exit = tracker.tick(s(sec));
      }
      expect(exit, ZoneTransition.exited);
    });

    test('hovering between the thresholds never flips the state', () {
      final tracker = BleTracker(desk);
      final rng = Random(9);
      final changes = <ZoneTransition>[];
      for (var i = 0; i < 2000; i++) {
        final c = tracker.reading(-68 + rng.nextDouble() * 6 - 3, s(i * 0.25));
        if (c != null) changes.add(c);
      }
      expect(changes, isEmpty);
    });

    test('Q scales with time, so sparse readings move the estimate more than dense ones', () {
      final dense = BleTracker(desk)..reading(-90, s(0));
      final sparse = BleTracker(desk)..reading(-90, s(0));
      dense.reading(-50, s(0.1));
      sparse.reading(-50, s(10));
      expect(sparse.estimate!, greaterThan(dense.estimate!));
    });
  });

  group('zone tracker', () {
    final deskZone = ZoneSpec.parse({
      'id': 'desk',
      'name': 'Desk',
      'ble': {'matchName': 'OMNI_PICO_DESK'},
      'wifi': {
        'ssids': ['HomeNet'],
        'awayAfterMs': 0,
        'required': true,
      },
    });
    final homeZone = ZoneSpec.parse({
      'id': 'home',
      'wifi': {
        'ssids': ['HomeNet'],
        'awayAfterMs': 0,
        'bssids': ['AA:BB:CC:00:11:22'],
      },
    });

    test('a short Wi-Fi drop is not leaving, a long one is', () {
      final z = ZoneTracker([
        ZoneSpec.parse({
          'id': 'home',
          'wifi': {
            'ssids': ['HomeNet'],
          },
        }),
      ]);
      expect(
        z.wifi('HomeNet', null, s(0)).single.transition,
        ZoneTransition.entered,
      );
      expect(z.wifi(null, null, s(10)), isEmpty, reason: 'the router restarts');
      expect(z.tick(s(100)), isEmpty);
      expect(z.wifi('HomeNet', null, s(110)), isEmpty, reason: 'back in time');
      expect(z.tick(s(300)), isEmpty);
      expect(z.wifi('Cafe', null, s(400)), isEmpty);
      expect(z.tick(s(519)), isEmpty);
      expect(z.tick(s(521)).single.transition, ZoneTransition.exited);
      expect(z.isInside('home'), isFalse);
    });

    test('a place removed during its away wait is forgotten', () {
      final home = ZoneSpec.parse({
        'id': 'home',
        'wifi': {
          'ssids': ['HomeNet'],
        },
      });
      final z = ZoneTracker([home]);
      z.wifi('HomeNet', null, s(0));
      z.wifi('Cafe', null, s(10));
      z.update(const []);
      expect(z.tick(s(500)), isEmpty);
    });

    test('the away wait is a place setting, and 0 leaves at once', () {
      expect(
        ZoneSpec.parse({
          'id': 'home',
          'wifi': {
            'ssids': ['HomeNet'],
            'awayAfterMs': 30000,
          },
        }).wifi!.awayAfter,
        const Duration(seconds: 30),
      );
      expect(
        () => ZoneSpec.parse({
          'id': 'home',
          'wifi': {
            'ssids': ['HomeNet'],
            'awayAfterMs': -1,
          },
        }),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a Wi-Fi zone follows the network', () {
      final z = ZoneTracker([homeZone]);
      expect(
        z.wifi('HomeNet', null, s(0)).single.transition,
        ZoneTransition.entered,
      );
      expect(z.wifi('HomeNet', null, s(1)), isEmpty);
      expect(
        z.wifi('Cafe', null, s(2)).single.transition,
        ZoneTransition.exited,
      );
      expect(
        z.wifi(null, 'aa:bb:cc:00:11:22', s(3)).single.transition,
        ZoneTransition.entered,
      );
    });

    test('a BLE zone with required Wi-Fi enters only on home Wi-Fi, and scans only there', () {
      final z = ZoneTracker([deskZone]);
      z.wifi('Cafe', null, s(0));
      expect(z.zonesNeedingBle, isEmpty);
      for (var i = 0; i < 20; i++) {
        z.bleReading('OMNI_PICO_DESK', -50, s(i * 0.25));
      }
      expect(z.isInside('desk'), isFalse);
      final changes = z.wifi('HomeNet', null, s(6));
      expect(z.zonesNeedingBle, {'desk'});
      expect(changes.single.transition, ZoneTransition.entered);
      expect(
        z.wifi('Cafe', null, s(7)).single.transition,
        ZoneTransition.exited,
      );
    });

    test('readings for another beacon are ignored', () {
      final z = ZoneTracker([deskZone])..wifi('HomeNet', null, s(0));
      for (var i = 0; i < 20; i++) {
        z.bleReading('SOMEONE_ELSE', -40, s(i * 0.25));
      }
      expect(z.isInside('desk'), isFalse);
    });

    test('zone specs are validated', () {
      expect(
        () => ZoneSpec.parse({'id': 'x'}),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => ZoneSpec.parse({
          'id': 'x',
          'ble': {'matchName': 'B', 'enterDbm': -80, 'exitDbm': -70},
        }),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => ZoneSpec.parse({'id': 'x', 'wifi': {}}),
        throwsA(isA<ValidationException>()),
      );
      expect(ZoneSpec.parse(deskZone.toJson()).toJson(), deskZone.toJson());
    });
  });
}
