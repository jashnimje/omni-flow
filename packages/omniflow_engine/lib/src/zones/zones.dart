import '../dag/canonical.dart';
import '../manifest/validation.dart';

enum ZoneTransition { entered, exited }

class ZoneChange {
  const ZoneChange(this.zoneId, this.transition, this.at);

  final String zoneId;
  final ZoneTransition transition;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'zone': zoneId,
    'transition': transition.name,
    'at': at.toIso8601String(),
  };
}

/// Tunables for one beacon. Defaults are the design's starting values; each
/// zone is tuned from a recorded RSSI trace of the real place.
class BleSettings {
  const BleSettings({
    required this.matchName,
    this.enterDbm = -62,
    this.exitDbm = -74,
    this.enterDwell = const Duration(seconds: 2),
    this.exitDwell = const Duration(seconds: 8),
    this.silence = const Duration(seconds: 5),
    this.processNoisePerSecond = 0.65,
    this.measurementNoise = 3.5,
    this.absentDbm = -100,
  });

  /// The beacon's advertised name (MACs are never used).
  final String matchName;
  final double enterDbm;
  final double exitDbm;
  final Duration enterDwell;
  final Duration exitDwell;
  final Duration silence;
  final double processNoisePerSecond;
  final double measurementNoise;
  final double absentDbm;
}

/// One beacon: Kalman filter with Q scaled by elapsed time, an absent reading
/// injected when the beacon goes silent, and enter and exit thresholds with
/// dwell times.
class BleTracker {
  BleTracker(this.settings);

  final BleSettings settings;
  double? _estimate;
  double _p = 1;
  DateTime? _lastUpdate;
  DateTime? _lastHeard;
  bool _present = false;
  DateTime? _candidateSince;

  bool get isPresent => _present;
  double? get estimate => _estimate;

  /// Starts present, as last known before a restart: heard at [at] at the
  /// enter level, so the silence tick still exits if it stays quiet.
  void assumePresent(DateTime at) {
    _present = true;
    _estimate = settings.enterDbm;
    _p = 1;
    _lastHeard = at;
    _lastUpdate = at;
    _candidateSince = null;
  }

  /// A real reading from the beacon.
  ZoneTransition? reading(double rssi, DateTime at) {
    _lastHeard = at;
    return _update(rssi, at);
  }

  /// Call about once a second. Feeds an absent reading when the beacon has
  /// not been heard for the silence window, so an exit can happen.
  ZoneTransition? tick(DateTime at) {
    final heard = _lastHeard;
    if (heard == null || at.difference(heard) < settings.silence) return null;
    return _update(settings.absentDbm, at);
  }

  ZoneTransition? _update(double z, DateTime at) {
    final last = _lastUpdate;
    if (_estimate == null || last == null) {
      _estimate = z;
      _p = 1;
    } else {
      final dt = at.difference(last).inMicroseconds / 1e6;
      final prior =
          _p + settings.processNoisePerSecond * (dt <= 0 ? 0.001 : dt);
      final gain = prior / (prior + settings.measurementNoise);
      _estimate = _estimate! + gain * (z - _estimate!);
      _p = (1 - gain) * prior;
    }
    _lastUpdate = at;
    final x = _estimate!;
    if (!_present) {
      if (x >= settings.enterDbm) {
        _candidateSince ??= at;
        if (at.difference(_candidateSince!) >= settings.enterDwell) {
          _present = true;
          _candidateSince = null;
          return ZoneTransition.entered;
        }
      } else {
        _candidateSince = null;
      }
    } else {
      if (x <= settings.exitDbm) {
        _candidateSince ??= at;
        if (at.difference(_candidateSince!) >= settings.exitDwell) {
          _present = false;
          _candidateSince = null;
          return ZoneTransition.exited;
        }
      } else {
        _candidateSince = null;
      }
    }
    return null;
  }
}

class WifiSettings {
  const WifiSettings({
    this.ssids = const {},
    this.bssids = const {},
    this.required = false,
    this.awayAfter = defaultAwayAfter,
  });

  /// How long the phone may be off the network before it counts as gone:
  /// a router restart, a weak spot in the house or Android dozing the radio
  /// is not leaving.
  static const defaultAwayAfter = Duration(minutes: 2);

  final Set<String> ssids;
  final Set<String> bssids;
  final Duration awayAfter;

  /// A required Wi-Fi input must hold for the zone to count as entered.
  final bool required;

  bool matches(String? ssid, String? bssid) =>
      (ssid != null && ssids.contains(ssid)) ||
      (bssid != null && bssids.contains(bssid.toLowerCase()));
}

class ZoneSpec {
  const ZoneSpec({required this.id, required this.name, this.ble, this.wifi});

  final String id;
  final String name;
  final BleSettings? ble;
  final WifiSettings? wifi;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (ble != null)
      'ble': {
        'matchName': ble!.matchName,
        'enterDbm': ble!.enterDbm,
        'exitDbm': ble!.exitDbm,
        'enterDwellMs': ble!.enterDwell.inMilliseconds,
        'exitDwellMs': ble!.exitDwell.inMilliseconds,
        'silenceMs': ble!.silence.inMilliseconds,
      },
    if (wifi != null)
      'wifi': {
        'ssids': wifi!.ssids.toList(),
        'bssids': wifi!.bssids.toList(),
        'required': wifi!.required,
        if (wifi!.awayAfter != WifiSettings.defaultAwayAfter)
          'awayAfterMs': wifi!.awayAfter.inMilliseconds,
      },
  };

  /// A place may have no input yet ([requireInput] false), and then is
  /// never entered.
  static ZoneSpec parse(Object? json, {bool requireInput = true}) {
    final issues = IssueCollector();
    if (json is! Map) {
      throw ValidationException('zone', [
        const ValidationIssue(r'$', 'must be an object'),
      ]);
    }
    final map = Map<String, Object?>.from(json);
    final id = issues.requiredString(map, 'id', r'$');
    if (id != null && !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(id)) {
      issues.add(r'$.id', 'must be lower snake case');
    }
    final name = issues.optionalString(map, 'name', r'$');
    BleSettings? ble;
    final rawBle = issues.optionalMap(map, 'ble', r'$');
    if (rawBle != null) {
      final match = issues.requiredString(rawBle, 'matchName', r'$.ble');
      num n(String k, num d) {
        final v = rawBle[k];
        if (v == null) return d;
        if (v is! num) issues.add('\$.ble.$k', 'must be a number');
        return v is num ? v : d;
      }

      final enter = n('enterDbm', -62).toDouble();
      final exit = n('exitDbm', -74).toDouble();
      if (enter <= exit) {
        issues.add(
          r'$.ble',
          'enterDbm must be above exitDbm, so the zone does not flicker',
        );
      }
      if (match != null) {
        ble = BleSettings(
          matchName: match,
          enterDbm: enter,
          exitDbm: exit,
          enterDwell: Duration(milliseconds: n('enterDwellMs', 2000).toInt()),
          exitDwell: Duration(milliseconds: n('exitDwellMs', 8000).toInt()),
          silence: Duration(milliseconds: n('silenceMs', 5000).toInt()),
        );
      }
    }
    WifiSettings? wifi;
    final rawWifi = issues.optionalMap(map, 'wifi', r'$');
    if (rawWifi != null) {
      Set<String> strings(String k) {
        final v = rawWifi[k];
        if (v == null) return {};
        if (v is! List || v.any((e) => e is! String)) {
          issues.add('\$.wifi.$k', 'must be a list of strings');
          return {};
        }
        return v.cast<String>().toSet();
      }

      final away = rawWifi['awayAfterMs'];
      if (away != null && (away is! int || away < 0 || away > 3600000)) {
        issues.add(r'$.wifi.awayAfterMs', 'must be 0 to 3600000');
      }
      wifi = WifiSettings(
        ssids: strings('ssids'),
        bssids: strings('bssids').map((b) => b.toLowerCase()).toSet(),
        required: rawWifi['required'] == true,
        awayAfter: away is int && away >= 0 && away <= 3600000
            ? Duration(milliseconds: away)
            : WifiSettings.defaultAwayAfter,
      );
      if (wifi.ssids.isEmpty && wifi.bssids.isEmpty) {
        issues.add(r'$.wifi', 'needs ssids or bssids');
      }
    }
    if (requireInput && ble == null && wifi == null && rawBle == null) {
      issues.add(r'$', 'a zone needs a ble or wifi input');
    }
    if (issues.hasIssues || id == null) {
      throw ValidationException('zone ${id ?? ''}'.trim(), issues.issues);
    }
    return ZoneSpec(id: id, name: name ?? id, ble: ble, wifi: wifi);
  }
}

/// Every zone's state, fed by sensor readings. Returns the zone changes each
/// reading causes, which set each place's `inside` state.
///
/// A zone with a BLE input is entered when its beacon is present and, when
/// its Wi-Fi input is required, the Wi-Fi matches. A zone with only Wi-Fi is
/// entered while the Wi-Fi matches.
class ZoneTracker {
  ZoneTracker(Iterable<ZoneSpec> zones) {
    update(zones);
  }

  /// Makes [zones] the tracked set. A zone whose spec is unchanged keeps
  /// whether it is inside and its beacon filter, so saving another zone
  /// does not re-enter it. New and edited zones start outside.
  void update(Iterable<ZoneSpec> zones) {
    final next = {for (final z in zones) z.id: z};
    for (final id in _zones.keys.toList()) {
      final spec = next[id];
      if (spec != null &&
          canonicalJson(spec.toJson()) == canonicalJson(_zones[id]!.toJson())) {
        continue;
      }
      _zones.remove(id);
      _ble.remove(id);
      _inside.remove(id);
    }
    for (final z in next.values) {
      if (_zones.containsKey(z.id)) continue;
      _zones[z.id] = z;
      if (z.ble != null) _ble[z.id] = BleTracker(z.ble!);
      _inside[z.id] = false;
    }
  }

  final _zones = <String, ZoneSpec>{};
  final _ble = <String, BleTracker>{};
  final _inside = <String, bool>{};
  bool _wifiKnown = false;
  String? _ssid;
  String? _bssid;

  bool isInside(String zoneId) => _inside[zoneId] ?? false;

  /// Puts back whether each tracked zone was [inside] before a restart, so
  /// the first reading after it is not an arrival. A beacon zone counts as
  /// heard now, and exits as usual if it stays quiet.
  void restore(Map<String, bool> inside, DateTime at) {
    for (final MapEntry(key: id, value: was) in inside.entries) {
      if (!was || !_zones.containsKey(id)) continue;
      _inside[id] = true;
      _ble[id]?.assumePresent(at);
    }
  }

  Map<String, bool> get states => Map.unmodifiable(_inside);

  /// Zones that need BLE scanning right now: a BLE input, and any required
  /// Wi-Fi holds. This is what the app uses to scan only when it matters.
  Set<String> get zonesNeedingBle => {
    for (final z in _zones.values)
      if (z.ble != null &&
          (z.wifi?.required != true || z.wifi!.matches(_ssid, _bssid)))
        z.id,
  };

  List<ZoneChange> bleReading(String name, double rssi, DateTime at) => [
    for (final e in _ble.entries)
      if (e.value.settings.matchName == name)
        ...?_apply(e.key, e.value.reading(rssi, at), at),
  ];

  /// Call about once a second: beacons that went quiet, and Wi-Fi places
  /// whose away wait has run out.
  List<ZoneChange> tick(DateTime at) => [
    for (final e in _ble.entries) ...?_apply(e.key, e.value.tick(at), at),
    for (final id in _wifiLostAt.keys.toList())
      if (!_ble.containsKey(id)) ...?_apply(id, null, at),
  ];

  /// When each place's Wi-Fi stopped matching, while it still counts as
  /// inside.
  final _wifiLostAt = <String, DateTime>{};

  bool _wifiHolds(ZoneSpec zone, DateTime at) {
    final wifi = zone.wifi!;
    if (_wifiKnown && wifi.matches(_ssid, _bssid)) {
      _wifiLostAt.remove(zone.id);
      return true;
    }
    if (_inside[zone.id] != true || wifi.awayAfter == Duration.zero) {
      _wifiLostAt.remove(zone.id);
      return false;
    }
    final lost = _wifiLostAt.putIfAbsent(zone.id, () => at);
    if (at.difference(lost) < wifi.awayAfter) return true;
    _wifiLostAt.remove(zone.id);
    return false;
  }

  List<ZoneChange> wifi(String? ssid, String? bssid, DateTime at) {
    _ssid = ssid;
    _bssid = bssid;
    _wifiKnown = true;
    return [for (final z in _zones.values) ...?_apply(z.id, null, at)];
  }

  List<ZoneChange>? _apply(
    String zoneId,
    ZoneTransition? bleChange,
    DateTime at,
  ) {
    final zone = _zones[zoneId]!;
    final wifiOk = zone.wifi == null || _wifiHolds(zone, at);
    final bool nowInside;
    if (zone.ble == null && zone.wifi == null) {
      nowInside = false;
    } else if (zone.ble != null) {
      final blePresent = _ble[zoneId]!.isPresent;
      nowInside = blePresent && (zone.wifi?.required != true || wifiOk);
    } else {
      nowInside = wifiOk;
    }
    if (nowInside == _inside[zoneId]) return null;
    _inside[zoneId] = nowInside;
    return [
      ZoneChange(
        zoneId,
        nowInside ? ZoneTransition.entered : ZoneTransition.exited,
        at,
      ),
    ];
  }
}
