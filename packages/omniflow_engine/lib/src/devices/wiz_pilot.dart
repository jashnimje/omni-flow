import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/param_spec.dart';
import 'channels.dart';
import 'device.dart';
import 'http_channel.dart' show SecretRejectedException;
import 'wiz_scenes.dart';

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
/// bulb, no white on a colour-only one, only power on a socket, the scenes
/// its kind plays, no white channels on a bulb without white, and the
/// bulb's own white range and lowest dimming on the sliders.
DriverManifest wizManifestFor(DriverManifest base, Device device) {
  final bulb = WizBulb.of(device);
  if (bulb == null) return base;
  final scenes = [for (final s in wizScenesFor(bulb.kind)) s.slug];
  bool keep(CapabilitySpec c) => switch (c.type) {
    CapabilityType.colorRgb => bulb.hasColour != false,
    CapabilityType.colorTemp => bulb.hasWhite != false,
    CapabilityType.level => bulb.dims,
    _ when isWizSceneCapability(c) => bulb.dims && scenes.isNotEmpty,
    _ => true,
  };
  CapabilitySpec narrow(CapabilitySpec c) {
    final params = {...c.params};
    void fit(String key, num? min, num? max) {
      final p = params[key];
      if (p != null) params[key] = p.copyWith(min: min, max: max);
    }

    if (bulb.minDim != null) {
      fit(
        c.type == CapabilityType.level ? 'value' : 'brightness',
        bulb.minDim,
        null,
      );
    }
    if (c.type == CapabilityType.colorTemp && bulb.hasWhiteRange) {
      fit('value', bulb.minK, bulb.maxK);
    }
    if (c.type == CapabilityType.colorRgb && bulb.hasWhite == false) {
      params
        ..remove('c')
        ..remove('w');
    }
    if (isWizSceneCapability(c)) {
      params['scene'] = params['scene']!.copyWith(
        values: [
          for (final v in params['scene']!.values)
            if (scenes.contains(v)) v,
        ],
      );
    }
    return c.withParams(params);
  }

  return base.withCapabilities([
    for (final c in base.capabilities)
      if (keep(c)) narrow(c),
  ], keep: (_) => false);
}

/// Whether [c] sets a WiZ scene: its `scene` param is the scene list.
bool isWizSceneCapability(CapabilitySpec c) =>
    c.params['scene']?.type == ParamType.enumeration &&
    c.params['scene']!.values.isNotEmpty;

/// The scene [value] names, fitted for [bulb]: its id, or a plain refusal.
int _sceneId(Object? value, WizBulb? bulb, String name) {
  final scene = wizSceneOf(value);
  final id = value is num ? value.round() : scene?.id;
  if (id == wizRhythmId) {
    throw CommandFailedException(
      'Rhythm follows the sound the WiZ app hears, so it only runs from '
      'that app. $name refuses it over the network',
    );
  }
  if (scene == null) {
    // The custom modes a user made in the WiZ app, 256 to 265.
    if (id != null && id >= 256 && id <= 265) return id;
    throw CommandFailedException(
      '$name has no scene $value. Pick one of '
      '${wizScenesFor(bulb?.kind).map((s) => s.slug).join(', ')}',
    );
  }
  if (!scene.playsOn(bulb?.kind)) {
    final what = bulb?.kind == 'white'
        ? 'a tunable white bulb'
        : 'a white bulb';
    throw CommandFailedException(
      '$name is $what and does not play ${scene.name}',
    );
  }
  return scene.id;
}

/// [payload] made into one a WiZ bulb takes: whole numbers only, dimming
/// inside the bulb's range, white inside its own range, colour channels 0
/// to 255, a scene by its id with a speed only when it moves, and a zero
/// brightness or an all-zero colour sent as power off. Throws a
/// [CommandFailedException] in plain words for what the bulb cannot do at
/// all (a colour on a white bulb, a scene its kind does not play).
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
    // A colour step that leaves the white channels at 0 is sent as before.
    if (hasRgb && p['c'] == 0 && p['w'] == 0) {
      p
        ..remove('c')
        ..remove('w');
    }
  }
  if (p.containsKey('sceneId')) {
    final id = _sceneId(p['sceneId'], bulb, name);
    p['sceneId'] = id;
    if (wizSceneById(id)?.dynamic == false) p.remove('speed');
  }
  if (p['speed'] case final num v) p['speed'] = fit(v, 10, 200);
  return {...payload, 'params': p};
}

/// [state] after [sent] (a fitted `setPilot` or `setState`) was taken: its
/// values in, and the keys of the modes it left (white, colour, scene) out,
/// as the bulb's next report would have it.
Map<String, Object?> wizStateAfter(
  Map<String, Object?> state,
  Map<String, Object?> sent,
) {
  final p = sent['params'];
  if (p is! Map) return state;
  final params = Map<String, Object?>.from(p)..remove('sigTs');
  final out = {...state};
  const modes = [
    ['temp'],
    ['r', 'g', 'b', 'c', 'w'],
    ['sceneId', 'speed'],
  ];
  if (sent['method'] == 'setPilot') {
    final entered = modes
        .where((m) => m.any((k) => k != 'speed' && params.containsKey(k)))
        .firstOrNull;
    if (entered != null) {
      for (final m in modes) {
        m.forEach(out.remove);
      }
      if (identical(entered, modes[1])) {
        for (final k in entered) {
          out[k] = 0;
        }
      }
      // A bulb in a scene reports sceneId 0 once it leaves it.
      if (!identical(entered, modes[2])) out['sceneId'] = 0;
    }
    out['state'] = params['state'] ?? true;
  } else if (sent['method'] == 'setState' && params['state'] is bool) {
    out['state'] = params['state'];
  }
  for (final e in params.entries) {
    if (e.key != 'state') out[e.key] = e.value;
  }
  return out;
}

String _sentWords(Map<String, Object?> payload) {
  final p = payload['params'];
  if (p is! Map) return '${payload['method']}';
  final parts = [
    if (p['state'] == false) 'off',
    if (p['dimming'] case final v?) 'brightness $v %',
    if (p['temp'] case final v?) 'white $v K',
    if (p['r'] is num) 'colour ${p['r']}, ${p['g']}, ${p['b']}',
    if (p['sceneId'] case final v?) 'scene ${wizSceneById(v)?.name ?? v}',
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
