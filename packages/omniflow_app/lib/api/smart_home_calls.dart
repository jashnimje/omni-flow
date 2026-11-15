import 'engine_calls.dart' show DeviceView, Json;

/// Every call the weather, follow-the-sun, away lighting and energy pages
/// make, with the fields read back from their results. When the engine's
/// shape changes, the change is made here and nowhere else.
abstract final class SmartHomeCalls {
  static const weatherDriver = 'weather';
  static const weatherAdd = 'weather.add';
  static const weatherRefresh = 'weather.refresh';
  static const sunlightGet = 'sunlight.get';
  static const sunlightSet = 'sunlight.set';
  static const sunlightApply = 'sunlight.apply';
  static const awaylightGet = 'awaylight.get';
  static const awaylightSet = 'awaylight.set';
  static const awaylightPreview = 'awaylight.preview';
  static const energySummary = 'energy.summary';
  static const energyPrice = 'energy.price';
  static const energyPriceSet = 'energy.price.set';

  /// The drivers whose plugs report power.
  static const energyDrivers = {
    'shelly_plus_switch',
    'shelly_gen1_relay',
    'tuya_plug',
  };

  static Json sunlightSetArgs(
    List<String> targets, {
    required bool enabled,
    SunCurveView? curve,
  }) => {'targets': targets, 'enabled': enabled, ...?curve?.toJson()};

  static Json awaylightSetArgs({List<String>? lights, bool? enabled}) => {
    'lights': ?lights,
    'enabled': ?enabled,
  };

  static Json priceArgs(double? perKwh, String currency) => {
    'perKwh': perKwh,
    'currency': currency,
  };
}

double? _double(Object? v) => v is num ? v.toDouble() : null;
int _int(Object? v, int fallback) => v is num ? v.round() : fallback;

/// Whether [d] is a light the home helpers can drive: a power switch and a
/// brightness or white temperature.
bool isSmartLight(DeviceView d) =>
    d.capabilities.any((c) => c['id'] == 'power' && c['type'] == 'toggle') &&
    d.capabilities.any(
      (c) =>
          c['id'] == 'brightness' ||
          c['id'] == 'dimmer' ||
          c['id'] == 'color_temp',
    );

/// The weather thing's state, in the words the page shows.
class WeatherView {
  const WeatherView(this.state);

  final Json state;

  double? get temperature => _double(state['temperature']);
  double? get feelsLike => _double(state['feels_like']);
  double? get humidity => _double(state['humidity']);
  double? get wind => _double(state['wind_speed']);
  double? get uv => _double(state['uv_index']);
  double? get rainMm => _double(state['rain_next_hour']);
  double? get rainChance => _double(state['rain_chance_next_hour']);
  double? get high => _double(state['high_today']);
  double? get low => _double(state['low_today']);
  bool get rainExpected => state['rain_expected'] == true;
  String? get condition => state['condition'] as String?;
  String? get problem => state['problem'] as String?;
  DateTime? get updated => DateTime.tryParse('${state['updated_at']}');

  static String degrees(double? v) => v == null ? '-' : '${v.round()}°';

  /// One line for a tile: "24° Partly cloudy, rain likely soon".
  String get line {
    if (temperature == null) return problem ?? 'Not read yet';
    return [
      '${degrees(temperature)} ${condition ?? ''}'.trim(),
      if (rainExpected) 'rain likely in the next hour',
    ].join(', ');
  }
}

/// A follow-the-sun range.
class SunCurveView {
  const SunCurveView({
    this.minK = 2200,
    this.maxK = 5000,
    this.minBrightness = 30,
    this.maxBrightness = 100,
  });

  factory SunCurveView.of(Object? json) {
    final j = json is Map ? json : const {};
    return SunCurveView(
      minK: _int(j['minK'], 2200),
      maxK: _int(j['maxK'], 5000),
      minBrightness: _int(j['minBrightness'], 30),
      maxBrightness: _int(j['maxBrightness'], 100),
    );
  }

  final int minK;
  final int maxK;
  final int minBrightness;
  final int maxBrightness;

  Json toJson() => {
    'minK': minK,
    'maxK': maxK,
    'minBrightness': minBrightness,
    'maxBrightness': maxBrightness,
  };

  SunCurveView copyWith({
    int? minK,
    int? maxK,
    int? minBrightness,
    int? maxBrightness,
  }) => SunCurveView(
    minK: minK ?? this.minK,
    maxK: maxK ?? this.maxK,
    minBrightness: minBrightness ?? this.minBrightness,
    maxBrightness: maxBrightness ?? this.maxBrightness,
  );
}

/// One point of today's curve.
typedef SunPoint = ({DateTime at, int kelvin, int brightness});

/// A light or room that follows the sun.
typedef SunTargetView = ({
  String id,
  String kind,
  String name,
  SunCurveView curve,
  List<String> lights,
});

/// A `sunlight.get` reply.
class SunlightView {
  const SunlightView({
    required this.targets,
    required this.paused,
    required this.curve,
    required this.preview,
    this.problem,
    this.nowKelvin,
    this.nowBrightness,
  });

  factory SunlightView.of(Json r) => SunlightView(
    targets: [
      for (final t in (r['targets'] as List? ?? const []))
        if (t is Map)
          (
            id: '${t['id']}',
            kind: '${t['kind']}',
            name: '${t['name'] ?? t['id']}',
            curve: SunCurveView.of(t),
            lights: [for (final l in (t['lights'] as List? ?? const [])) '$l'],
          ),
    ],
    paused: {
      for (final p in (r['paused'] as List? ?? const []))
        if (p is Map) '${p['id']}',
    },
    curve: SunCurveView.of(r['curve']),
    preview: [
      for (final p in (r['preview'] as List? ?? const []))
        if (p is Map && DateTime.tryParse('${p['at']}') != null)
          (
            at: DateTime.parse('${p['at']}'),
            kelvin: _int(p['kelvin'], 2200),
            brightness: _int(p['brightness'], 30),
          ),
    ],
    problem: r['problem'] as String?,
    nowKelvin: (r['now'] as Map?)?['kelvin'] as int?,
    nowBrightness: (r['now'] as Map?)?['brightness'] as int?,
  );

  final List<SunTargetView> targets;
  final Set<String> paused;
  final SunCurveView curve;
  final List<SunPoint> preview;
  final String? problem;
  final int? nowKelvin;
  final int? nowBrightness;

  /// Whether [id] follows the sun on its own (not through its room).
  bool follows(String id) => targets.any((t) => t.id == id);

  /// Whether [id] follows the sun, itself or through its room.
  bool followsLight(String id) => targets.any((t) => t.lights.contains(id));
}

/// One change away lighting plans.
typedef AwayActionView = ({String light, String name, DateTime at, bool on});

/// `awaylight.get` with `awaylight.preview`.
class AwayLightView {
  const AwayLightView({
    required this.enabled,
    required this.lights,
    required this.away,
    required this.running,
    required this.actions,
    this.reason,
  });

  factory AwayLightView.of(Json settings, Json preview) => AwayLightView(
    enabled: settings['enabled'] == true,
    lights: [for (final l in (settings['lights'] as List? ?? const [])) '$l'],
    away: settings['away'] == true,
    running: settings['running'] == true,
    reason: settings['reason'] as String?,
    actions: [
      for (final a in (preview['actions'] as List? ?? const []))
        if (a is Map && DateTime.tryParse('${a['at']}') != null)
          (
            light: '${a['light']}',
            name: '${a['name'] ?? a['light']}',
            at: DateTime.parse('${a['at']}'),
            on: a['on'] == true,
          ),
    ],
  );

  final bool enabled;
  final List<String> lights;
  final bool away;
  final bool running;
  final String? reason;
  final List<AwayActionView> actions;

  /// What away lighting is doing, in words.
  String get status {
    if (!enabled) return 'Off';
    if (lights.isEmpty) return 'Pick the lights to use';
    if (running) return 'Running now, because the home is empty';
    if (away) return 'Starts within a minute';
    return 'Starts when everyone is away, or in Vacation mode';
  }
}

/// One plug's day.
typedef EnergyDay = ({String date, double kwh});

/// One plug in `energy.summary`.
class EnergyRow {
  const EnergyRow({
    required this.id,
    required this.name,
    required this.todayKwh,
    required this.weekKwh,
    required this.days,
    this.watts,
    this.todayCost,
    this.weekCost,
  });

  factory EnergyRow.of(Map<Object?, Object?> j) => EnergyRow(
    id: '${j['id']}',
    name: '${j['name'] ?? j['id']}',
    watts: _double(j['watts']),
    todayKwh: _double(j['todayKwh']) ?? 0,
    weekKwh: _double(j['weekKwh']) ?? 0,
    todayCost: _double(j['todayCost']),
    weekCost: _double(j['weekCost']),
    days: [
      for (final d in (j['days'] as List? ?? const []))
        if (d is Map) (date: '${d['date']}', kwh: _double(d['kwh']) ?? 0),
    ],
  );

  final String id;
  final String name;
  final double? watts;
  final double todayKwh;
  final double weekKwh;
  final double? todayCost;
  final double? weekCost;
  final List<EnergyDay> days;
}

/// An `energy.summary` reply.
class EnergySummary {
  const EnergySummary({
    required this.devices,
    required this.todayKwh,
    required this.weekKwh,
    this.todayCost,
    this.weekCost,
    this.perKwh,
    this.currency = '',
  });

  factory EnergySummary.of(Json r) {
    final total = r['total'] is Map ? r['total'] as Map : const {};
    final price = r['price'] is Map ? r['price'] as Map : const {};
    return EnergySummary(
      devices: [
        for (final d in (r['devices'] as List? ?? const []))
          if (d is Map) EnergyRow.of(d),
      ],
      todayKwh: _double(total['todayKwh']) ?? 0,
      weekKwh: _double(total['weekKwh']) ?? 0,
      todayCost: _double(total['todayCost']),
      weekCost: _double(total['weekCost']),
      perKwh: _double(price['perKwh']),
      currency: price['currency'] is String ? price['currency'] as String : '',
    );
  }

  final List<EnergyRow> devices;
  final double todayKwh;
  final double weekKwh;
  final double? todayCost;
  final double? weekCost;
  final double? perKwh;
  final String currency;

  EnergyRow? device(String id) => devices.where((d) => d.id == id).firstOrNull;

  /// `0.42 kWh`, with two places under 10 and one above.
  static String kwh(double v) =>
      '${v < 10 ? v.toStringAsFixed(2) : v.toStringAsFixed(1)} kWh';

  /// The money with its symbol, or null with no price set.
  String? money(double? v) =>
      v == null ? null : '$currency${v.toStringAsFixed(2)}';

  /// "1.20 kWh today, ₹9.60".
  String todayLine() =>
      ['${kwh(todayKwh)} today', ?money(todayCost)].join(', ');
}
