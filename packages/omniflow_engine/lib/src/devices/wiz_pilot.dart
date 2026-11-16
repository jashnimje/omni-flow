import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/param_spec.dart';
import 'channels.dart';
import 'device.dart';
import 'http_channel.dart' show SecretRejectedException;

/// The secret setting holding a WiZ home's `udp_signing_key`.
const wizSigningKey = 'signingKey';

/// The device setting where what a bulb said about itself is kept.
const wizBulbSetting = 'bulb';

/// A WiZ home key: 16 bytes as 32 hex characters.
final wizKeyPattern = RegExp(r'^[0-9a-fA-F]{32}$');

/// Whether [manifest] speaks the WiZ pilot protocol (transport option
/// `"pilot": "wiz"`), whose writes the channel fits and signs.
bool isWizPilot(DriverManifest? manifest) =>
    manifest?.transport.options['pilot'] == 'wiz';

/// Whether [method] changes the bulb. Reads and the push registration are
/// sent unsigned.
bool isWizWrite(Object? method) =>
    method is String && !method.startsWith('get') && method != 'registration';

/// [value] as Python's `json.dumps(value, separators=(",", ":"))` writes
/// it, which is what a WiZ bulb hashes: compact, keys in insertion order,
/// anything outside ASCII escaped.
String wizJson(Object? value) => switch (value) {
  null => 'null',
  bool b => '$b',
  int i => '$i',
  double d when d.isFinite => d == d.roundToDouble() ? '${d.toInt()}.0' : '$d',
  num _ => throw ArgumentError('a WiZ message cannot carry $value'),
  String s => _pythonString(s),
  Map m =>
    '{${[for (final e in m.entries) '${_pythonString('${e.key}')}:${wizJson(e.value)}'].join(',')}}',
  List l => '[${l.map(wizJson).join(',')}]',
  _ => throw ArgumentError('a WiZ message cannot carry $value'),
};

String _pythonString(String s) {
  final out = StringBuffer('"');
  for (final unit in s.codeUnits) {
    switch (unit) {
      case 0x22:
        out.write(r'\"');
      case 0x5c:
        out.write(r'\\');
      case 0x0a:
        out.write(r'\n');
      case 0x0d:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      case 0x08:
        out.write(r'\b');
      case 0x0c:
        out.write(r'\f');
      default:
        if (unit < 0x20 || unit > 0x7f) {
          out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.writeCharCode(unit);
        }
    }
  }
  out.write('"');
  return out.toString();
}

Uint8List _hexBytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

/// base64(HMAC-SHA256(key, [wizJson] of [value])).
String wizHmac(String keyHex, Object? value) {
  final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(_hexBytes(keyHex)));
  return base64Encode(
    mac.process(Uint8List.fromList(utf8.encode(wizJson(value)))),
  );
}

/// [message] signed as firmware that answers `"env": "pro"` wants it, as
/// pywizlight's `sign_request` does: `sigTs` (unix seconds) added to the
/// params, the HMAC over the params, and `env` and `hmac` at the top.
Map<String, Object?> signWizRequest(
  Map<String, Object?> message,
  String keyHex, {
  required int timestamp,
}) {
  final params = {
    ...?(message['params'] as Map?)?.cast<String, Object?>(),
    'sigTs': timestamp,
  };
  return {
    'method': message['method'],
    'env': 'pro',
    'params': params,
    'hmac': wizHmac(keyHex, params),
  };
}

/// Whether a signed reply's `hmac` matches its result or error under
/// [keyHex]. Null when the reply carries no `hmac`.
bool? wizReplyVerified(Map<String, Object?> reply, String keyHex) {
  final hmac = reply['hmac'];
  if (hmac is! String) return null;
  final body = reply.containsKey('result') ? reply['result'] : reply['error'];
  return wizHmac(keyHex, body) == hmac;
}

/// What a bulb says it is, from `getSystemConfig` and `getModelConfig`.
class WizBulb {
  const WizBulb({this.module, this.kind, this.minK, this.maxK, this.minDim});

  /// The module name, `ESP25_SHRGB_01`.
  final String? module;

  /// `rgb` (colour, and white when it has a range), `white` (tunable
  /// white), `dimmable` (one white), `socket`, or null when unknown.
  final String? kind;
  final int? minK;
  final int? maxK;

  /// The lowest dimming it takes, 10 on most bulbs.
  final int? minDim;

  bool get hasWhiteRange => minK != null && maxK != null;

  /// Whether it can take a white temperature. Null when unknown.
  bool? get hasWhite => switch (kind) {
    'white' => true,
    'rgb' => hasWhiteRange,
    'dimmable' || 'socket' => false,
    _ => null,
  };

  /// Whether it can take a colour. Null when unknown.
  bool? get hasColour => switch (kind) {
    'rgb' => true,
    'white' || 'dimmable' || 'socket' => false,
    _ => null,
  };

  bool get dims => kind != 'socket';

  /// What [system] and [model] (the `result` objects, either may be null)
  /// say. The kind comes from the module name as pywizlight reads it; the
  /// white range from `extRange`, `cctRange` or `whiteRange`, lowest to
  /// highest.
  factory WizBulb.from({Map? system, Map? model}) {
    final module = system?['moduleName'];
    String? kind;
    if (module is String && module.contains('_')) {
      final id = module.split('_')[1].toUpperCase();
      kind = id.contains('RGB')
          ? 'rgb'
          : id.contains('TW')
          ? 'white'
          : id.contains('SOCKET')
          ? 'socket'
          : 'dimmable';
    }
    List<int>? range;
    for (final list in [
      model?['extRange'],
      model?['cctRange'],
      system?['extRange'],
      system?['whiteRange'],
    ]) {
      if (list is List && list.isNotEmpty && list.every((v) => v is num)) {
        range = [for (final v in list) (v as num).round()];
        break;
      }
    }
    final minDim = model?['minDimLevel'];
    final noWhite = kind == 'dimmable' || kind == 'socket';
    return WizBulb(
      module: module is String ? module : null,
      kind: kind,
      minK: noWhite || range == null ? null : range.reduce(_min),
      maxK: noWhite || range == null ? null : range.reduce(_max),
      minDim: minDim is num && minDim >= 1 && minDim <= 100
          ? minDim.round()
          : null,
    );
  }

  static int _min(int a, int b) => a < b ? a : b;
  static int _max(int a, int b) => a > b ? a : b;

  /// The one a device's [wizBulbSetting] holds, or null.
  static WizBulb? of(Device device) {
    final raw = device.settings[wizBulbSetting];
    if (raw is! Map) return null;
    int? whole(Object? v) => v is num ? v.round() : null;
    return WizBulb(
      module: raw['module'] is String ? raw['module'] as String : null,
      kind: raw['kind'] is String ? raw['kind'] as String : null,
      minK: whole(raw['minK']),
      maxK: whole(raw['maxK']),
      minDim: whole(raw['minDim']),
    );
  }

  Map<String, Object?> toJson() => {
    'module': ?module,
    'kind': ?kind,
    'minK': ?minK,
    'maxK': ?maxK,
    'minDim': ?minDim,
  };

  /// The white range in words, "2700 to 6500 K".
  String? get rangeWords => hasWhiteRange ? '$minK to $maxK K' : null;
}

/// [base] narrowed to what [device] said it is: no colour on a white
/// bulb, no white on a colour-only one, only power on a socket, and the
/// bulb's own white range and lowest dimming on the sliders.
DriverManifest wizManifestFor(DriverManifest base, Device device) {
  final bulb = WizBulb.of(device);
  if (bulb == null) return base;
  bool keep(CapabilitySpec c) => switch (c.type) {
    CapabilityType.colorRgb => bulb.hasColour != false,
    CapabilityType.colorTemp => bulb.hasWhite != false,
    CapabilityType.level => bulb.dims,
    _ => true,
  };
  final narrowed = [
    for (final c in base.capabilities)
      if (keep(c))
        switch (c.type) {
          CapabilityType.colorTemp when bulb.hasWhiteRange => _withValueRange(
            c,
            bulb.minK!,
            bulb.maxK!,
          ),
          CapabilityType.level when bulb.minDim != null => _withValueRange(
            c,
            bulb.minDim!,
            c.params['value']?.max ?? 100,
          ),
          _ => c,
        },
  ];
  return base.withCapabilities(narrowed, keep: (_) => false);
}

CapabilitySpec _withValueRange(CapabilitySpec c, num min, num max) {
  final v = c.params['value'];
  if (v == null) return c;
  return CapabilitySpec(
    id: c.id,
    type: c.type,
    label: c.label,
    params: {
      ...c.params,
      'value': ParamSpec(
        type: v.type,
        min: min,
        max: max,
        unit: v.unit,
        optional: v.optional,
        values: v.values,
        pattern: v.pattern,
        integer: v.integer,
        clamp: v.clamp,
      ),
    },
    command: c.command,
    stateJsonPath: c.stateJsonPath,
    onOff: c.onOff,
    alsoOff: c.alsoOff,
    values: c.values,
    derive: c.derive,
    highRisk: c.highRisk,
    zeroTurnsOff: c.zeroTurnsOff,
  );
}

/// The WiZ scenes: 1 to 32, and 1000 for rhythm.
bool _isScene(int id) => (id >= 1 && id <= 32) || id == 1000;

/// [payload] made into one a WiZ bulb takes: whole numbers only, dimming
/// inside the bulb's range, white inside its own range, colour channels 0
/// to 255, and a zero brightness or an all-zero colour sent as power off.
/// Throws a [CommandFailedException] in plain words for what the bulb
/// cannot do at all (a colour on a white bulb).
Map<String, Object?> fitWizPilot(
  Map<String, Object?> payload,
  WizBulb? bulb,
  String name,
) {
  if (payload['method'] != 'setPilot' || payload['params'] is! Map) {
    return payload;
  }
  final off = {
    ...payload,
    'method': 'setState',
    'params': {'state': false},
  };
  final p = Map<String, Object?>.from(payload['params'] as Map);
  int fit(num v, int min, int max) => v.round().clamp(min, max);
  final dimming = p['dimming'];
  if (dimming is num) {
    if (!dimming.isFinite || dimming <= 0) return off;
    p['dimming'] = fit(dimming, bulb?.minDim ?? 10, 100);
  }
  final hasRgb = ['r', 'g', 'b'].any((k) => p[k] is num);
  if (p['temp'] is num) {
    if (bulb?.hasWhite == false) {
      throw CommandFailedException(
        bulb?.kind == 'rgb'
            ? '$name has no white setting, only colours'
            : '$name has no white temperature setting',
      );
    }
    if (hasRgb) {
      p.remove('temp');
    } else {
      p['temp'] = fit(
        p['temp'] as num,
        bulb?.minK ?? 1000,
        bulb?.maxK ?? 10000,
      );
    }
  }
  if (hasRgb || p['c'] is num || p['w'] is num) {
    if (hasRgb && bulb?.hasColour == false) {
      throw CommandFailedException('$name is a white bulb and has no colours');
    }
    for (final k in ['r', 'g', 'b', 'c', 'w']) {
      if (p[k] case final num v) p[k] = v.isFinite ? fit(v, 0, 255) : 0;
    }
    final lit = ['r', 'g', 'b', 'c', 'w'].any((k) => (p[k] as num? ?? 0) > 0);
    if (!lit) return off;
  }
  if (p['sceneId'] case final num v) {
    final id = v.round();
    if (!_isScene(id)) {
      throw CommandFailedException(
        '$name has no scene $v. WiZ scenes are 1 to 32, and 1000 for rhythm',
      );
    }
    p['sceneId'] = id;
  }
  if (p['speed'] case final num v) p['speed'] = fit(v, 10, 200);
  return {...payload, 'params': p};
}

String _sentWords(Map<String, Object?> payload) {
  final p = payload['params'];
  if (p is! Map) return '${payload['method']}';
  final parts = [
    if (p['state'] == false) 'off',
    if (p['dimming'] case final v?) 'brightness $v %',
    if (p['temp'] case final v?) 'white $v K',
    if (p['r'] is num) 'colour ${p['r']}, ${p['g']}, ${p['b']}',
    if (p['sceneId'] case final v?) 'scene $v',
  ];
  return parts.isEmpty ? '${payload['method']}' : parts.join(', ');
}

/// A bulb's `error` reply to [sent], as an exception in plain words.
/// [signed] says whether [sent] carried a signature.
CommandFailedException wizErrorOf(
  Object? error,
  Map<String, Object?> sent,
  WizBulb? bulb,
  String name, {
  required bool signed,
  required bool pro,
}) {
  final code = error is Map ? error['code'] : null;
  final message = error is Map ? '${error['message'] ?? ''}' : '$error';
  final write = isWizWrite(sent['method']);
  if (code == -32605) {
    return SecretRejectedException(
      'The WiZ home key for $name is wrong. Export your home for local '
      'integration in the WiZ app again and paste its udp_signing_key',
      secretKey: wizSigningKey,
    );
  }
  if (code == -32602 && write && !signed && pro) {
    return SecretNeededException(
      "$name's firmware needs your WiZ home key. Export your home for "
      'local integration in the WiZ app and paste its udp_signing_key',
      secretKey: wizSigningKey,
    );
  }
  if (code == -32602) {
    final p = sent['params'];
    final temp = p is Map ? p['temp'] : null;
    if (temp is num && bulb?.rangeWords != null) {
      if (temp < bulb!.minK! || temp > bulb.maxK!) {
        return CommandFailedException(
          'The bulb does not do $temp K, its range is ${bulb.rangeWords}',
        );
      }
    }
    final range = bulb?.rangeWords;
    return CommandFailedException(
      '$name did not take ${_sentWords(sent)}. WiZ bulbs take brightness '
      '10 to 100 % and white within their own range'
      '${range == null ? '' : ', this one $range'}',
    );
  }
  if (code == -32601) {
    return CommandFailedException(
      '$name does not know ${sent['method']}. Its firmware may be older '
      'than this needs',
    );
  }
  return CommandFailedException(
    '$name replied with an error${code == null ? '' : ' $code'}'
    '${message.isEmpty ? '' : ': $message'}',
  );
}
