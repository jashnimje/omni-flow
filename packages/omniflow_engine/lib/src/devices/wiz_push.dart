import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../transports/packet_tap.dart';
import '../transports/udp_transport.dart';
import 'device.dart';
import 'device_service.dart';

/// A bulb that said hello with `firstBeat`.
class WizFirstBeat {
  const WizFirstBeat(this.host, this.mac);

  final String host;
  final String? mac;
}

/// Keeps WiZ bulbs pushing their state, the way pywizlight does: send
/// `registration` with this machine's IP and a made-up MAC to each bulb's port
/// 38899, renew it every 20 seconds, and listen on 38900 for `syncPilot` and
/// `firstBeat`. A `syncPilot` is routed to the device whose stable id is the
/// bulb's MAC, and only when it comes from that device's current address.
/// Pushes get no reply.
///
/// The manager keeps device ids, not devices: every renewal and push reads
/// the device from [DeviceService], so a bulb that moved is registered at its
/// new address and a removed one is dropped.
class WizPushManager {
  WizPushManager._(
    this._socket,
    this._devices,
    this._localAddressFor,
    this._renewEvery,
    this._bulbPort,
    this._acceptFrom,
  ) {
    _socket.incoming.listen(_onDatagram);
  }

  static Future<WizPushManager> start({
    required DeviceService devices,
    int listenPort = 38900,
    int bulbPort = 38899,
    Duration renewEvery = const Duration(seconds: 20),
    Future<String?> Function(String bulbHost)? localAddressFor,
    PacketTap? tap,
    bool Function(InternetAddress from) acceptFrom = isLocalNetworkAddress,
  }) async {
    final socket = await UdpTransport.bind(port: listenPort, tap: tap);
    return WizPushManager._(
      socket,
      devices,
      localAddressFor ?? lanAddressFor,
      renewEvery,
      bulbPort,
      acceptFrom,
    );
  }

  final UdpTransport _socket;
  final DeviceService _devices;
  final Future<String?> Function(String bulbHost) _localAddressFor;
  final Duration _renewEvery;
  final int _bulbPort;
  final bool Function(InternetAddress from) _acceptFrom;
  final _phoneMac = _randomMac();

  /// Device id by lower-case MAC.
  final _bulbs = <String, String>{};
  final _firstBeats = StreamController<WizFirstBeat>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  Timer? _timer;

  int get listenPort => _socket.localPort;

  Stream<WizFirstBeat> get firstBeats => _firstBeats.stream;

  /// Failures handling a push or a renewal. They never stop the manager.
  Stream<Object> get errors => _errors.stream;

  /// Registers with [bulbs] now and every renewal interval after that.
  Future<void> watch(Iterable<Device> bulbs) async {
    _bulbs.clear();
    for (final d in bulbs) {
      _track(d);
    }
    await _registerAll();
    _timer?.cancel();
    _timer = Timer.periodic(_renewEvery, (_) => _registerAll());
  }

  /// Starts registering with one more bulb, now and at every renewal.
  Future<void> add(Device bulb) async {
    if (!_track(bulb)) return;
    await _register(bulb.id);
  }

  /// Stops registering with [deviceId] and ignores its pushes.
  void remove(String deviceId) => _bulbs.removeWhere((_, id) => id == deviceId);

  bool _track(Device d) {
    final mac = d.stableId?.toLowerCase();
    if (mac == null) return false;
    remove(d.id);
    _bulbs[mac] = d.id;
    return true;
  }

  Future<void> _registerAll() async {
    for (final id in _bulbs.values.toList()) {
      await _register(id);
    }
  }

  Future<void> _register(String deviceId) async {
    try {
      final bulb = await _devices.device(deviceId);
      if (bulb == null || bulb.stableId == null) {
        remove(deviceId);
        return;
      }
      _track(bulb);
      final ip = await _localAddressFor(bulb.host);
      if (ip == null) return;
      try {
        _socket.send(
          InternetAddress(bulb.host),
          bulb.port ?? _bulbPort,
          registrationMessage(ip, _phoneMac),
        );
      } on SocketException {
        // Unreachable right now: the next renewal tries again.
      }
    } catch (e) {
      _report(e);
    }
  }

  Future<void> _onDatagram(UdpDatagram d) async {
    try {
      if (!_acceptFrom(d.address)) return;
      final text = d.text;
      if (text == 'test') return;
      final Object? json;
      try {
        json = jsonDecode(text);
      } on FormatException {
        return;
      }
      if (json is! Map) return;
      final message = Map<String, Object?>.from(json);
      final params = message['params'];
      final mac = params is Map
          ? params['mac']?.toString().toLowerCase()
          : null;
      switch (message['method']) {
        case 'syncPilot':
          final id = mac == null ? null : _bulbs[mac];
          if (id == null) return;
          final bulb = await _devices.device(id);
          if (bulb == null) {
            remove(id);
            return;
          }
          if (bulb.host != d.address.address) return;
          await _devices.applyPush(id, message);
        case 'firstBeat':
          if (!_firstBeats.isClosed) {
            _firstBeats.add(WizFirstBeat(d.address.address, mac));
          }
      }
    } catch (e) {
      _report(e);
    }
  }

  void _report(Object error) {
    if (!_errors.isClosed) _errors.add(error);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _socket.close();
    await _firstBeats.close();
    await _errors.close();
  }
}

/// The registration that asks a bulb to push to [phoneIp]:38900.
List<int> registrationMessage(String phoneIp, String phoneMac) => utf8.encode(
  jsonEncode({
    'method': 'registration',
    'params': {'phoneIp': phoneIp, 'register': true, 'phoneMac': phoneMac},
  }),
);

/// This machine's IPv4 address on the same /24 as [host], or the first LAN
/// address when none shares it. Loopback hosts get loopback.
Future<String?> lanAddressFor(String host) async {
  final target = InternetAddress.tryParse(host);
  if (target != null && target.isLoopback) {
    return InternetAddress.loopbackIPv4.address;
  }
  final candidates = [
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
      for (final a in i.addresses)
        if (!a.isLoopback && !a.isLinkLocal) a,
  ];
  if (target != null) {
    final net = directedBroadcast(target, 24);
    for (final a in candidates) {
      if (directedBroadcast(a, 24) == net) return a.address;
    }
  }
  return candidates.firstOrNull?.address;
}

String _randomMac() {
  final r = Random.secure();
  return List.generate(
    6,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
