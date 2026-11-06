import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_path/json_path.dart';

import '../manifest/driver_manifest.dart';
import '../transports/udp_transport.dart';
import 'device_service.dart';

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.host,
    required this.reply,
    this.stableId,
  });

  final String host;
  final String? stableId;
  final Map<String, Object?> reply;

  Map<String, Object?> toJson() => {
    'host': host,
    if (stableId != null) 'stableId': stableId,
    'reply': reply,
  };
}

/// Finds devices by broadcasting a driver's `udp_broadcast` probe and
/// collecting the replies that match its `matchJsonPath`.
class UdpDiscovery {
  UdpDiscovery(this._udp, {this._targets});

  final UdpTransport _udp;

  /// Where probes go. Defaults to [broadcastTargets].
  final Future<List<InternetAddress>> Function()? _targets;

  Future<List<DiscoveredDevice>> discover(
    DriverManifest driver, {
    Duration window = const Duration(seconds: 2),
    int? portOverride,
  }) async {
    final spec = driver.discovery
        .where((d) => d.method == 'udp_broadcast')
        .firstOrNull;
    if (spec == null) return const [];
    final port =
        portOverride ?? (spec.config['port'] as int?) ?? driver.transport.port;
    if (port == null) return const [];
    final probe = utf8.encode(jsonEncode(spec.config['probe'] ?? const {}));
    final match = spec.config['matchJsonPath'] as String?;
    final idPath = spec.config['idJsonPath'] as String?;

    final found = <String, DiscoveredDevice>{};
    final subscription = _udp.incoming.listen((d) {
      if (d.port != port) return;
      final Object? json;
      try {
        json = jsonDecode(d.text);
      } on FormatException {
        return;
      }
      if (json is! Map) return;
      if (match != null && JsonPath(match).readValues(json).isEmpty) return;
      final id = idPath == null
          ? null
          : JsonPath(idPath).readValues(json).firstOrNull;
      found[d.address.address] = DiscoveredDevice(
        host: d.address.address,
        stableId: id?.toString(),
        reply: Map<String, Object?>.from(json),
      );
    });
    try {
      final targets = await (_targets ?? broadcastTargets)();
      for (var round = 0; round < 2; round++) {
        for (final target in targets) {
          try {
            _udp.send(target, port, probe);
          } on SocketException {
            // An interface without broadcast: skip it.
          }
        }
        await Future<void>.delayed(window ~/ 2);
      }
    } finally {
      await subscription.cancel();
    }
    return found.values.toList();
  }

  /// A [DeviceLocator] for address healing: discover again and pick the
  /// reply whose stable id matches.
  DeviceLocator get locator => (driver, stableId) async {
    final hits = await discover(driver);
    return hits
        .where((h) => h.stableId?.toLowerCase() == stableId.toLowerCase())
        .firstOrNull
        ?.host;
  };
}

/// The limited broadcast address plus a /24 directed broadcast for every
/// IPv4 interface. Dart does not expose interface netmasks, and home networks
/// are almost always /24, so the /24 address is the practical default.
Future<List<InternetAddress>> broadcastTargets() async {
  final targets = <String>{'255.255.255.255'};
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  )) {
    for (final address in interface.addresses) {
      if (address.isLoopback || address.isLinkLocal) continue;
      targets.add(directedBroadcast(address, 24).address);
    }
  }
  return [for (final t in targets) InternetAddress(t)];
}
