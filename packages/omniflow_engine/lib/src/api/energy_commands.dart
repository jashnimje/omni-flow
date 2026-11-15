import 'api_error.dart';
import 'away_lighting.dart' show dayKey;
import 'command_args.dart';
import 'engine_core.dart';
import 'smart_lights.dart';
import '../devices/device_service.dart';
import '../storage/database.dart';

/// What a plug reports about power: watts now, and its own energy counter
/// in kWh when it keeps one.
typedef EnergyReading = ({double? watts, double? counterKwh});

double? _number(Object? v) => v is num ? v.toDouble() : null;

/// The power reading in a device's [state], by its driver, or null when
/// the driver reports none.
///
/// - Shelly Plus and Pro (Gen2): `apower` in W and `aenergy.total` in Wh,
///   from `Switch.GetStatus`.
/// - Shelly Gen1: `meters[0]`, read into the state as `power` in W and
///   `total` in watt-minutes.
/// - Tuya plugs: DP 19 is power in tenths of a watt (tinytuya lists it as
///   0 to 50000 W, and Tuya's standard plug scale is one decimal). DP 17
///   is energy added since the plug's last report, not a running total, so
///   Tuya plugs are integrated from power.
EnergyReading? energyReading(String driverId, Map<String, Object?> state) {
  switch (driverId) {
    case 'shelly_plus_switch':
      final energy = state['aenergy'];
      final total = energy is Map ? _number(energy['total']) : null;
      final watts = _number(state['apower']);
      if (watts == null && total == null) return null;
      return (watts: watts, counterKwh: total == null ? null : total / 1000);
    case 'shelly_gen1_relay':
      final watts = _number(state['power']);
      final total = _number(state['total']);
      if (watts == null && total == null) return null;
      return (watts: watts, counterKwh: total == null ? null : total / 60000);
    case 'tuya_plug':
      final deci = _number(state['19']);
      return deci == null ? null : (watts: deci / 10, counterKwh: null);
  }
  return null;
}

/// Readings further apart than this are not joined: the plug was away.
const energyGap = Duration(minutes: 15);

/// A counter jump above this is a replaced or reset plug, not real use.
const _counterJumpKwh = 50.0;

/// How many days of totals are kept.
const energyKeepDays = 35;

typedef _Last = ({DateTime at, double? watts, double? counterKwh});

/// Adds up kWh per device per local day from successive readings. A plug's
/// own counter is preferred, and power is integrated (the mean of two
/// readings over the time between them) where there is none.
class EnergyMeter {
  /// kWh by device, then by `YYYY-MM-DD`.
  final days = <String, Map<String, double>>{};
  final _last = <String, _Last>{};

  void _add(String device, DateTime day, double kwh) {
    if (kwh <= 0) return;
    final key = dayKey(day);
    final perDay = days[device] ??= {};
    perDay[key] = (perDay[key] ?? 0) + kwh;
  }

  /// Takes [reading] of [device] at [at].
  void add(String device, DateTime at, EnergyReading reading) {
    final local = at.toLocal();
    final before = _last[device];
    _last[device] = (
      at: local,
      watts: reading.watts,
      counterKwh: reading.counterKwh ?? before?.counterKwh,
    );
    if (before == null) return;
    final gap = local.difference(before.at);
    if (gap <= Duration.zero) return;
    final counter = reading.counterKwh;
    final previous = before.counterKwh;
    if (counter != null && previous != null) {
      final delta = counter - previous;
      if (delta >= 0 && delta < _counterJumpKwh) {
        _add(device, local, delta);
        return;
      }
    }
    final watts = reading.watts;
    if (watts == null || gap > energyGap) return;
    final mean = ((before.watts ?? watts) + watts) / 2;
    // A span across midnight is shared between the two days.
    final midnight = DateTime(local.year, local.month, local.day);
    if (before.at.isBefore(midnight)) {
      _add(
        device,
        before.at,
        mean * _hours(midnight.difference(before.at)) / 1000,
      );
      _add(device, local, mean * _hours(local.difference(midnight)) / 1000);
    } else {
      _add(device, local, mean * _hours(gap) / 1000);
    }
  }

  static double _hours(Duration d) => d.inMicroseconds / 3.6e9;

  double on(String device, DateTime day) => days[device]?[dayKey(day)] ?? 0;

  void prune(DateTime now) {
    final keep = DateTime(now.year, now.month, now.day - energyKeepDays);
    for (final perDay in days.values) {
      perDay.removeWhere(
        (k, _) => (DateTime.tryParse(k) ?? now).isBefore(keep),
      );
    }
  }

  Map<String, Object?> toJson() => {
    'days': days,
    'last': {
      for (final e in _last.entries)
        e.key: {
          'at': e.value.at.toUtc().toIso8601String(),
          'watts': ?e.value.watts,
          'counterKwh': ?e.value.counterKwh,
        },
    },
  };

  void load(Map<String, Object?> json) {
    final saved = json['days'];
    if (saved is Map) {
      for (final e in saved.entries) {
        if (e.value is! Map) continue;
        days['${e.key}'] = {
          for (final d in (e.value as Map).entries)
            if (d.value is num) '${d.key}': (d.value as num).toDouble(),
        };
      }
    }
    final last = json['last'];
    if (last is Map) {
      for (final e in last.entries) {
        final v = e.value;
        final at = v is Map && v['at'] is String
            ? DateTime.tryParse(v['at'] as String)
            : null;
        if (at == null) continue;
        _last['${e.key}'] = (
          at: at.toLocal(),
          watts: _number((v as Map)['watts']),
          counterKwh: _number(v['counterKwh']),
        );
      }
    }
  }

  void forget(String device) {
    days.remove(device);
    _last.remove(device);
  }
}

double _round(double v, [int places = 3]) =>
    double.parse(v.toStringAsFixed(places));

/// `energy.summary`, `energy.price` and `energy.price.set`: today's and
/// this week's kWh per plug that reports power, and what it cost.
class EnergyCommands {
  EnergyCommands(this._core, this._store);

  final EngineCore _core;
  final JsonFileStore _store;
  final meter = EnergyMeter();
  double? perKwh;
  String currency = '';
  var _dirty = false;

  Map<String, CommandHandler> get commands => {
    'energy.summary': summary,
    'energy.price': (_) async => _price(),
    'energy.price.set': setPrice,
  };

  Future<void> load() async {
    final json = await _store.read();
    meter.load(json);
    final price = json['price'];
    if (price is Map) {
      perKwh = _number(price['perKwh']);
      currency = price['currency'] is String ? price['currency'] as String : '';
    }
  }

  Future<void> flush() async {
    if (!_dirty) return;
    _dirty = false;
    meter.prune(DateTime.now());
    await _store.write({
      ...meter.toJson(),
      'price': {'perKwh': ?perKwh, 'currency': currency},
    });
  }

  /// Every device state change: a plug's power reading is counted.
  void observe(DeviceStateChanged e, DateTime now) {
    final reading = energyReading(e.device.driverId, e.device.state);
    if (reading == null) return;
    meter.add(e.device.id, now, reading);
    _dirty = true;
  }

  Map<String, Object?> _price() => {'perKwh': perKwh, 'currency': currency};

  /// `{perKwh, currency?}`: the price of one kWh, and the money symbol
  /// shown with it. A null price takes it away.
  Future<Map<String, Object?>> setPrice(Map<String, Object?> args) async {
    final price = args['perKwh'];
    if (price != null && (price is! num || price < 0 || price > 1000)) {
      throw ApiError('invalid', 'perKwh must be a number from 0 to 1000');
    }
    final symbol = optStringArg(args, 'currency');
    if (symbol != null && symbol.trim().length > 5) {
      throw ApiError('invalid', 'currency must be a short symbol, such as \$');
    }
    perKwh = (price as num?)?.toDouble();
    if (symbol != null) currency = symbol.trim();
    _dirty = true;
    await flush();
    return _price();
  }

  double? _cost(double kwh) => perKwh == null ? null : _round(kwh * perKwh!, 2);

  /// `{days?}` (1 to 31, default 7): per plug, watts now, today's kWh, the
  /// last [days] days' kWh (a week by default), and the totals, with cost
  /// where a price is set.
  Future<Map<String, Object?>> summary(Map<String, Object?> args) async {
    final count = optIntArg(args, 'days') ?? 7;
    if (count < 1 || count > 31) {
      throw ApiError('invalid', 'days must be 1 to 31');
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dates = [
      for (var i = count - 1; i >= 0; i--)
        DateTime(today.year, today.month, today.day - i),
    ];
    final week = [
      for (var i = 6; i >= 0; i--)
        DateTime(today.year, today.month, today.day - i),
    ];
    var totalToday = 0.0;
    var totalWeek = 0.0;
    final rows = <Map<String, Object?>>[];
    for (final d in await DriftDeviceStore(_core.db).all()) {
      final reading = energyReading(d.driverId, d.state);
      if (reading == null && !meter.days.containsKey(d.id)) continue;
      final kwhToday = meter.on(d.id, today);
      final kwhWeek = week.fold(0.0, (s, day) => s + meter.on(d.id, day));
      totalToday += kwhToday;
      totalWeek += kwhWeek;
      rows.add({
        'id': d.id,
        'name': d.name,
        'room': ?(d.room == null ? null : _core.roomNames[d.room] ?? d.room),
        'watts': ?reading?.watts,
        'todayKwh': _round(kwhToday),
        'weekKwh': _round(kwhWeek),
        'todayCost': ?_cost(kwhToday),
        'weekCost': ?_cost(kwhWeek),
        'days': [
          for (final day in dates)
            {'date': dayKey(day), 'kwh': _round(meter.on(d.id, day))},
        ],
      });
    }
    rows.sort(
      (a, b) => (b['todayKwh'] as double).compareTo(a['todayKwh'] as double),
    );
    return {
      'devices': rows,
      'total': {
        'todayKwh': _round(totalToday),
        'weekKwh': _round(totalWeek),
        'todayCost': ?_cost(totalToday),
        'weekCost': ?_cost(totalWeek),
      },
      'price': _price(),
    };
  }
}
