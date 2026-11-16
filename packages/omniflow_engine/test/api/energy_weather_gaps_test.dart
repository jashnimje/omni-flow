import 'package:omniflow_engine/src/api/energy_commands.dart';
import 'package:omniflow_engine/src/api/weather.dart';
import 'package:test/test.dart';

Map<String, double> _rounded(Map<String, double>? days) => {
  for (final e in (days ?? const <String, double>{}).entries)
    e.key: double.parse(e.value.toStringAsFixed(3)),
};

void main() {
  group('energy over gaps', () {
    test('a counter that grew over 57 hours with the engine closed is '
        'shared between the days it covers', () {
      final m = EnergyMeter()
        ..add('plug', DateTime(2026, 11, 10, 23), (
          watts: 1000,
          counterKwh: 100,
        ))
        ..add('plug', DateTime(2026, 11, 13, 8), (
          watts: 1000,
          counterKwh: 157,
        ));
      expect(_rounded(m.days['plug']), {
        '2026-11-10': 1.0,
        '2026-11-11': 24.0,
        '2026-11-12': 24.0,
        '2026-11-13': 8.0,
      });
    });

    test('an overnight gap splits at midnight', () {
      final m = EnergyMeter()
        ..add('plug', DateTime(2026, 11, 10, 22), (
          watts: 1000,
          counterKwh: 100,
        ))
        ..add('plug', DateTime(2026, 11, 11, 9), (
          watts: 1000,
          counterKwh: 111,
        ));
      expect(_rounded(m.days['plug']), {'2026-11-10': 2.0, '2026-11-11': 9.0});
    });

    test('a counter that jumps faster than any plug draws is a reset', () {
      final m = EnergyMeter()
        ..add('plug', DateTime(2026, 11, 10, 12), (watts: 100, counterKwh: 5))
        ..add('plug', DateTime(2026, 11, 10, 12, 10), (
          watts: 100,
          counterKwh: 900,
        ));
      expect(m.on('plug', DateTime(2026, 11, 10)), lessThan(0.1));
    });

    test('a plug read from power: a 20 minute poll gap counts, and a long '
        'gap counts only its first hour', () {
      final m = EnergyMeter()
        ..add('tuya', DateTime(2026, 11, 10, 12), (
          watts: 2000,
          counterKwh: null,
        ))
        ..add('tuya', DateTime(2026, 11, 10, 12, 20), (
          watts: 2000,
          counterKwh: null,
        ));
      expect(m.on('tuya', DateTime(2026, 11, 10)), closeTo(0.667, 0.001));
      m.add('tuya', DateTime(2026, 11, 10, 20, 20), (
        watts: 2000,
        counterKwh: null,
      ));
      expect(m.on('tuya', DateTime(2026, 11, 10)), closeTo(2.667, 0.001));
    });
  });

  group('stale weather', () {
    final at = DateTime.utc(2026, 11, 12, 9);
    test('fresh weather is not marked', () {
      expect(
        weatherStalePatch({
          'updated_at': at.toIso8601String(),
          'rain_expected': true,
        }, at.add(const Duration(hours: 2))),
        isNull,
      );
    });

    test('weather over 3 hours old is stale, says so, and expects no rain', () {
      final patch = weatherStalePatch({
        'updated_at': at.toIso8601String(),
        'rain_expected': true,
      }, at.add(const Duration(hours: 3, minutes: 1)));
      expect(patch, {
        'stale': true,
        'rain_expected': false,
        'problem': weatherStaleWords,
      });
      expect(weatherStaleWords, contains('more than 3 hours old'));
      expect(
        weatherStalePatch({
          'updated_at': at.toIso8601String(),
          'stale': true,
        }, at.add(const Duration(hours: 5))),
        isNull,
        reason: 'marked once',
      );
    });
  });
}
