import 'api_error.dart';
import 'away_lighting.dart' show dayKey;
import 'command_args.dart';
import 'engine_core.dart';
import 'houses.dart' show firstHouseId;
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

/// Power readings further apart than this count only this long after the
/// first, at its power: what the plug did after that is not known.
const energyGap = Duration(hours: 1);

/// The most power a plug's counter can add, in kW. A counter that grew
/// faster over a gap is a replaced or reset plug, not real use.
const _maxKw = 25.0;

/// The smallest counter jump always taken, so readings close together are
/// not refused for rounding.
const _minJumpKwh = 1.0;

/// How many days of totals are kept.
const energyKeepDays = 35;

typedef _Last = ({DateTime at, double? watts, double? counterKwh});

/// Adds up kWh per device per local day from successive readings. A plug's
/// own counter is preferred, and power is integrated (the mean of two
/// readings over the time between them) where there is none. A gap that
/// crosses midnight is shared between the days it covers, a counter jump
/// faster than any plug draws is refused, and a power gap longer than
/// [energyGap] counts only [energyGap].
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
      final limit = _maxKw * _hours(gap);
      if (delta >= 0 && delta <= (limit < _minJumpKwh ? _minJumpKwh : limit)) {
        _spread(device, before.at, local, delta);
        return;
      }
    }
    final watts = reading.watts;
    if (watts == null) return;
    if (gap <= energyGap) {
      final mean = ((before.watts ?? watts) + watts) / 2;
      _spread(device, before.at, local, mean * _hours(gap) / 1000);
    } else if (before.watts case final w?) {
      _spread(
        device,
        before.at,
        before.at.add(energyGap),
        w * _hours(energyGap) / 1000,
      );
    }
  }

  /// Shares [kwh] used from [from] to [to] between the local days the span
  /// covers, by the time spent in each.
  void _spread(String device, DateTime from, DateTime to, double kwh) {
    final total = to.difference(from);
    if (total <= Duration.zero) return _add(device, to, kwh);
    var start = from;
    while (start.isBefore(to)) {
      final next = DateTime(start.year, start.month, start.day + 1);
      final end = next.isBefore(to) ? next : to;
      _add(
        device,
        start,
        kwh * end.difference(start).inMicroseconds / total.inMicroseconds,
      );
      start = end;
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

  /// The first house's price, kept where it was before houses.
  double? perKwh;
  String currency = '';

  /// Each other house's price, by house id.
  final prices = <String, ({double? perKwh, String currency})>{};
  var _dirty = false;

  Map<String, CommandHandler> get commands => {
    'energy.summary': summary,
    'energy.price': (args) async => _price(_core.houses.target(args)),
    'energy.price.set': setPrice,
  };

  ({double? perKwh, String currency}) _priceOf(String house) =>
      house == firstHouseId
      ? (perKwh: perKwh, currency: currency)
      : prices[house] ?? (perKwh: null, currency: '');

  Future<void> load() async {
    final json = await _store.read();
    meter.load(json);
    final price = json['price'];
    if (price is Map) {
      perKwh = _number(price['perKwh']);
      currency = price['currency'] is String ? price['currency'] as String : '';
    }
    final others = json['prices'];
    if (others is Map) {
      for (final e in others.entries) {
        final p = e.value;
        if (p is! Map) continue;
        prices['${e.key}'] = (
          perKwh: _number(p['perKwh']),
          currency: p['currency'] is String ? p['currency'] as String : '',
        );
      }
    }
  }

  Future<void> flush() async {
    if (!_dirty) return;
    _dirty = false;
    meter.prune(DateTime.now());
    await _store.write({
      ...meter.toJson(),
      'price': {'perKwh': ?perKwh, 'currency': currency},
      if (prices.isNotEmpty)
        'prices': {
          for (final e in prices.entries)
            e.key: {'perKwh': ?e.value.perKwh, 'currency': e.value.currency},
        },
    });
  }

  /// Saves the totals after a device's were dropped.
  Future<void> forgetSaved() async {
    _dirty = true;
    await flush();
  }

  /// Every device state change: a plug's power reading is counted.
  void observe(DeviceStateChanged e, DateTime now) {
    final reading = energyReading(e.device.driverId, e.device.state);
    if (reading == null) return;
    meter.add(e.device.id, now, reading);
    _dirty = true;
  }

  Map<String, Object?> _price(String house) {
    final p = _priceOf(house);
    return {'perKwh': p.perKwh, 'currency': p.currency};
  }

  /// `{perKwh, currency?, house?}`: the price of one kWh in the house, and
  /// the money symbol shown with it. A null price takes it away.
  Future<Map<String, Object?>> setPrice(Map<String, Object?> args) async {
    final price = args['perKwh'];
    if (price != null && (price is! num || price < 0 || price > 1000)) {
      throw ApiError('invalid', 'perKwh must be a number from 0 to 1000');
    }
    final symbol = optStringArg(args, 'currency');
    if (symbol != null && symbol.trim().length > 5) {
      throw ApiError('invalid', 'currency must be a short symbol, such as \$');
    }
    final house = _core.houses.target(args);
    final value = (price as num?)?.toDouble();
    if (house == firstHouseId) {
      perKwh = value;
      if (symbol != null) currency = symbol.trim();
    } else {
      prices[house] = (
        perKwh: value,
        currency: symbol?.trim() ?? _priceOf(house).currency,
      );
    }
    _dirty = true;
    await flush();
    return _price(house);
  }

  /// `{days?, house?}` (1 to 31, default 7): per plug, watts now, today's
  /// kWh, the last [days] days' kWh (a week by default), and the totals,
  /// with cost where a price is set. Given a house, its plugs at its price.
  Future<Map<String, Object?>> summary(Map<String, Object?> args) async {
    final house = _core.houses.resolve(args['house']);
    final price = _priceOf(house ?? _core.houses.defaultId).perKwh;
    double? cost(double kwh) => price == null ? null : _round(kwh * price, 2);
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
      if (house != null && !_core.houses.thingIn(d.id, house)) continue;
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
        'todayCost': ?cost(kwhToday),
        'weekCost': ?cost(kwhWeek),
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
        'todayCost': ?cost(totalToday),
        'weekCost': ?cost(totalWeek),
      },
      'price': _price(house ?? _core.houses.defaultId),
    };
  }
}
