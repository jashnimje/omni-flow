import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

const HomeLocation _mumbai = (latitude: 19.076, longitude: 72.8777);
const HomeLocation _london = (latitude: 51.5074, longitude: -0.1278);
const HomeLocation _tromso = (latitude: 69.6496, longitude: 18.956);

Matcher _near(DateTime expected) => predicate<DateTime?>(
  (t) => t != null && t.difference(expected).inSeconds.abs() <= 120,
  'within 2 minutes of $expected',
);

void main() {
  group('sun times', () {
    test('match published sunrise and sunset within 2 minutes', () {
      // Published (timeanddate.com) for 21 June 2026: Mumbai 06:02 and 19:18
      // IST, London 04:43 and 21:21 BST, and 08:04 and 15:53 GMT in December.
      expect(
        sunEventUtc(2026, 6, 21, SunEvent.sunrise, 19.076, 72.8777),
        _near(DateTime.utc(2026, 6, 21, 0, 32)),
      );
      expect(
        sunEventUtc(2026, 6, 21, SunEvent.sunset, 19.076, 72.8777),
        _near(DateTime.utc(2026, 6, 21, 13, 48)),
      );
      expect(
        sunEventUtc(2026, 6, 21, SunEvent.sunrise, 51.5074, -0.1278),
        _near(DateTime.utc(2026, 6, 21, 3, 43)),
      );
      expect(
        sunEventUtc(2026, 6, 21, SunEvent.sunset, 51.5074, -0.1278),
        _near(DateTime.utc(2026, 6, 21, 20, 21)),
      );
      expect(
        sunEventUtc(2026, 12, 21, SunEvent.sunrise, 51.5074, -0.1278),
        _near(DateTime.utc(2026, 12, 21, 8, 4)),
      );
      expect(
        sunEventUtc(2026, 12, 21, SunEvent.sunset, 51.5074, -0.1278),
        _near(DateTime.utc(2026, 12, 21, 15, 53)),
      );
    });

    test('a polar day or night has no event', () {
      expect(
        sunEventUtc(2026, 12, 21, SunEvent.sunrise, 69.6496, 18.956),
        isNull,
      );
      expect(
        sunEventUtc(2026, 6, 21, SunEvent.sunset, 69.6496, 18.956),
        isNull,
      );
    });

    test('the local day picks the event that falls on it', () {
      // A UTC time reads its own calendar day, so the result does not depend
      // on the zone the tests run in.
      final day = DateTime.utc(2026, 6, 21, 12);
      expect(
        sunEventOn(day, SunEvent.sunrise, _mumbai),
        _near(DateTime.utc(2026, 6, 21, 0, 32)),
      );
    });
  });

  group('next and previous fire', () {
    test('an offset moves the event', () {
      final now = DateTime.utc(2026, 6, 21, 12);
      expect(
        nextSunTrigger(now, SunEvent.sunset, _london, offsetMinutes: -30),
        _near(DateTime.utc(2026, 6, 21, 19, 51)),
      );
      expect(
        nextSunTrigger(now, SunEvent.sunset, _london, offsetMinutes: 45),
        _near(DateTime.utc(2026, 6, 21, 21, 6)),
      );
    });

    test('after today\'s event the next is tomorrow, across midnight', () {
      final now = DateTime.utc(2026, 6, 21, 23, 30);
      final next = nextSunTrigger(now, SunEvent.sunrise, _london)!;
      expect(next.day, 22);
      expect(next, _near(DateTime.utc(2026, 6, 22, 3, 43)));
      // A late offset pushes the sunset past midnight: it fires at 00:21
      // on the 22nd for the 21st's sunset.
      final late = nextSunTrigger(
        now,
        SunEvent.sunset,
        _london,
        offsetMinutes: 240,
      )!;
      expect(late, _near(DateTime.utc(2026, 6, 22, 0, 21)));
    });

    test('days pick the day of the event', () {
      // 21 June 2026 is a Sunday.
      final now = DateTime.utc(2026, 6, 21, 12);
      final next = nextSunTrigger(
        now,
        SunEvent.sunset,
        _london,
        days: const ['tue'],
      )!;
      expect(next.weekday, DateTime.tuesday);
      expect(next.day, 23);
    });

    test('a polar night waits for the sun to come back', () {
      final now = DateTime.utc(2026, 12, 21, 12);
      final next = nextSunTrigger(now, SunEvent.sunrise, _tromso)!;
      expect(next.isAfter(DateTime.utc(2027, 1, 1)), isTrue);
      expect(next.isBefore(DateTime.utc(2027, 2, 1)), isTrue);
    });

    test('the previous fire is the last one at or before now', () {
      final now = DateTime.utc(2026, 6, 21, 20, 30);
      expect(
        previousSunTrigger(now, SunEvent.sunset, _london),
        _near(DateTime.utc(2026, 6, 21, 20, 21)),
      );
      expect(
        previousSunTrigger(now, SunEvent.sunset, _london, offsetMinutes: 20),
        _near(DateTime.utc(2026, 6, 20, 20, 41)),
      );
    });
  });
}
