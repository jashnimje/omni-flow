import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/src/devices/wiz_pilot.dart';
import 'package:omniflow_engine/src/transports/udp_transport.dart';

/// A WiZ bulb on loopback that refuses exactly what real bulbs refuse:
/// dimming outside its range or not whole, a white outside its own range or
/// on a colour-only bulb, a colour on a white bulb, an all-zero colour, an
/// unknown scene. With [key] set it is firmware 1.38 ("env": "pro"): every
/// write must be signed with that key and a fresh `sigTs`, or it answers
/// -32602 (unsigned) or -32605 (wrong signature).
class FakeWizBulb {
  FakeWizBulb._(
    this._udp, {
    required this.module,
    this.range,
    this.key,
    this.minDim = 10,
    required this.now,
    this.methodInErrors = true,
    this.mac = 'a8bb50aabbcc',
  });

  /// [module] picks the kind as real bulbs name it: `ESP01_SHRGB1C_31`
  /// (colour and white), `ESP56_SHTW3_01` (tunable white),
  /// `ESP06_SHDW9_01` (one white), `ESP25_SHRGB_01` with no [range]
  /// (colour only).
  static Future<FakeWizBulb> start({
    required String module,
    List<int>? range,
    String? key,
    int minDim = 10,
    DateTime Function()? now,
    bool methodInErrors = true,
    String mac = 'a8bb50aabbcc',
  }) async {
    final bulb = FakeWizBulb._(
      await UdpTransport.bind(),
      module: module,
      range: range,
      key: key,
      minDim: minDim,
      now: now ?? DateTime.now,
      methodInErrors: methodInErrors,
      mac: mac,
    );
    bulb._udp.incoming.listen(bulb._answer);
    return bulb;
  }

  final UdpTransport _udp;
  final String module;
  final List<int>? range;
  final String? key;
  final int minDim;
  final DateTime Function() now;

  /// Whether an error reply names the method, as most firmware does.
  final bool methodInErrors;

  /// What `getSystemConfig` says its MAC is.
  final String mac;

  /// Every request, as decoded JSON.
  final requests = <Map<String, Object?>>[];

  /// The pilot the bulb is in now.
  final pilot = <String, Object?>{'state': false, 'dimming': 100};

  int get port => _udp.localPort;
  String get host => InternetAddress.loopbackIPv4.address;

  bool get _rgb => module.split('_')[1].contains('RGB');
  bool get _white =>
      range != null && (_rgb || module.split('_')[1].contains('TW'));

  void close() => _udp.close();

  void _answer(UdpDatagram d) {
    final request = jsonDecode(d.text) as Map<String, Object?>;
    requests.add(request);
    final method = request['method'] as String;
    final params = Map<String, Object?>.from(
      request['params'] as Map? ?? const {},
    );
    void reply(Map<String, Object?> body) => _udp.send(
      d.address,
      d.port,
      utf8.encode(
        jsonEncode({
          if (body.containsKey('result') || methodInErrors) 'method': method,
          if (key != null) 'env': 'pro',
          ...body,
        }),
      ),
    );
    void refuse(int code, String message) => reply({
      'error': {'code': code, 'message': message},
    });

    switch (method) {
      case 'getPilot':
        return reply({'result': pilot});
      case 'getSystemConfig':
        return reply({
          'result': {
            'mac': mac,
            'moduleName': module,
            'fwVersion': key == null ? '1.25.0' : '1.38.0',
          },
        });
      case 'getModelConfig':
        return reply({
          'result': {
            if (range != null)
              'cctRange': [range![0], range![0], range![1], range![1]],
            'minDimLevel': minDim,
          },
        });
      case 'setPilot' || 'setState':
        if (key != null) {
          final hmac = request['hmac'];
          if (hmac == null) return refuse(-32602, 'Invalid params');
          final ts = params['sigTs'];
          final fresh =
              ts is int &&
              (now().millisecondsSinceEpoch ~/ 1000 - ts).abs() <= 45;
          if (hmac != wizHmac(key!, params) || !fresh) {
            return refuse(-32605, 'Security error');
          }
          params.remove('sigTs');
        }
        if (!_valid(method, params)) return refuse(-32602, 'Invalid params');
        // A bulb is in one of white, colour or a scene at a time, and
        // reports only that one's keys.
        const modes = [
          ['temp'],
          ['r', 'g', 'b', 'c', 'w'],
          ['sceneId', 'speed'],
        ];
        if (modes.any(
          (m) => m.any((k) => k != 'speed' && params.containsKey(k)),
        )) {
          for (final m in modes) {
            m.forEach(pilot.remove);
          }
          if (params.containsKey('r')) {
            pilot.addAll({'c': 0, 'w': 0});
          }
        }
        pilot.addAll(params);
        if (method == 'setPilot') pilot['state'] = params['state'] ?? true;
        return reply({
          'result': {'success': true},
        });
      default:
        return refuse(-32601, 'Method not found');
    }
  }

  bool _valid(String method, Map<String, Object?> p) {
    if (method == 'setState') {
      return p.keys.every((k) => k == 'state') && p['state'] is bool;
    }
    bool whole(Object? v) => v is int;
    for (final k in [
      'dimming',
      'temp',
      'r',
      'g',
      'b',
      'c',
      'w',
      'sceneId',
      'speed',
    ]) {
      if (p.containsKey(k) && !whole(p[k])) return false;
    }
    final dim = p['dimming'] as int?;
    if (dim != null && (dim < minDim || dim > 100)) return false;
    final temp = p['temp'] as int?;
    if (temp != null && (!_white || temp < range![0] || temp > range![1])) {
      return false;
    }
    final colour = ['r', 'g', 'b'].where(p.containsKey);
    if (colour.isNotEmpty) {
      if (!_rgb) return false;
      final values = [
        for (final k in ['r', 'g', 'b', 'c', 'w']) p[k] as int? ?? 0,
      ];
      if (values.any((v) => v < 0 || v > 255)) return false;
      if (values.every((v) => v == 0)) return false;
    }
    // What an ESP25_SHRGB_01 on firmware 1.38 takes: the scenes 1 to 36
    // and 40, the custom modes 256 to 265, and no Rhythm (1000).
    final scene = p['sceneId'] as int?;
    if (scene != null &&
        !((scene >= 1 && scene <= 36) ||
            scene == 40 ||
            (scene >= 256 && scene <= 265))) {
      return false;
    }
    final speed = p['speed'] as int?;
    if (speed != null && (speed < 10 || speed > 200)) return false;
    return true;
  }
}
