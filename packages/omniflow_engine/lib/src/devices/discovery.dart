import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_path/json_path.dart';

import '../api/api_error.dart';
import '../manifest/driver_manifest.dart';
import '../transports/udp_transport.dart';
import 'device_service.dart';
import 'discovery/mdns_discovery.dart';
import 'discovery/tuya_broadcast.dart';

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.host,
    required this.reply,
    this.stableId,
    this.port,
    this.name,
    this.method,
  });

  final String host;
  final String? stableId;
  final Map<String, Object?> reply;

  /// The service port, when discovery reports one (mDNS SRV).
  final int? port;

  /// A name the device announced (an mDNS instance name).
  final String? name;

  /// The manifest discovery method that found it.
  final String? method;

  Map<String, Object?> toJson() => {
    'host': host,
    if (stableId != null) 'stableId': stableId,
    if (port != null) 'port': port,
    if (name != null) 'name': name,
    if (method != null) 'method': method,
    'reply': reply,
  };
}

/// What [DeviceDiscovery.discoverAll] found, by driver id, and the methods
/// that could not open their sockets.
class DiscoverySweep {
  const DiscoverySweep(this.found, this.failures, this.runs);

  final Map<String, List<DiscoveredDevice>> found;
  final List<String> failures;

  /// How many listens ran. When every one failed nothing could be heard.
  final int runs;
}

/// Runs every network discovery method a driver declares and merges the
/// results: `udp_broadcast`, `tuya_broadcast` and `mdns`. Serial discovery
/// stays with the serial channel, which owns the ports.
class DeviceDiscovery {
  DeviceDiscovery({
    required this.udp,
    TuyaDiscovery? tuya,
    MdnsDiscovery? mdns,
    this.tuyaMinimumWindow = const Duration(seconds: 6),
    this.tuyaLocateWindow = const Duration(seconds: 8),
  }) : tuya = tuya ?? TuyaDiscovery(),
       mdns = mdns ?? MdnsDiscovery();

  final UdpDiscovery udp;
  final TuyaDiscovery tuya;
  final MdnsDiscovery mdns;

  /// Tuya devices announce on a timer of several seconds rather than in
  /// answer to a probe, so a short window often hears nothing.
  final Duration tuyaMinimumWindow;

  /// How long healing listens for a moved Tuya device. It returns as soon
  /// as the device is heard.
  final Duration tuyaLocateWindow;

  /// [portOverride] applies to `udp_broadcast` only. A spec's `windowMs`
  /// lengthens [window] for that method.
  Future<List<DiscoveredDevice>> discover(
    DriverManifest driver, {
    Duration window = const Duration(seconds: 2),
    int? portOverride,
  }) async {
    final sweep = await discoverAll(
      [driver],
      window: window,
      portOverride: portOverride,
    );
    if (sweep.runs > 0 && sweep.failures.length == sweep.runs) {
      throw ApiError('unavailable', sweep.failures.join('. '));
    }
    return sweep.found[driver.id] ?? const [];
  }

  /// Runs the network discovery of every driver in [drivers] at once, each
  /// listen shared by the drivers that need it: one Tuya listen and one
  /// browse per mDNS service, however many drivers declare them. [methods]
  /// limits which methods run (all when null). A method that cannot open
  /// its socket is reported in [DiscoverySweep.failures] and the rest go on.
  Future<DiscoverySweep> discoverAll(
    List<DriverManifest> drivers, {
    Duration window = const Duration(seconds: 2),
    Set<String>? methods,
    int? portOverride,
  }) async {
    bool wanted(String method) => methods == null || methods.contains(method);
    // Each run yields (driver id, device) pairs, merged in the order the
    // runs were started so the result does not depend on which answers first.
    final runs = <Future<List<(String, DiscoveredDevice)>>>[];
    final failures = <String>[];
    void run(String method, Future<List<(String, DiscoveredDevice)>> work) =>
        runs.add(
          work.catchError((Object e) {
            failures.add(_cannotListen(method, e as SocketException));
            return const <(String, DiscoveredDevice)>[];
          }, test: (e) => e is SocketException),
        );

    for (final driver in drivers) {
      final spec = _spec(driver, 'udp_broadcast');
      if (spec == null || !wanted(spec.method)) continue;
      run(
        spec.method,
        udp
            .discover(
              driver,
              window: _longer(window, spec.config['windowMs']),
              portOverride: portOverride,
            )
            .then(
              (hits) => [
                for (final f in hits)
                  (
                    driver.id,
                    DiscoveredDevice(
                      host: f.host,
                      stableId: f.stableId,
                      reply: f.reply,
                      method: spec.method,
                    ),
                  ),
              ],
            ),
      );
    }

    final tuyaDrivers = [
      for (final d in drivers)
        if (_spec(d, tuyaBroadcastMethod) case final spec?) (d, spec),
    ];
    if (tuyaDrivers.isNotEmpty && wanted(tuyaBroadcastMethod)) {
      var tuyaWindow = tuyaMinimumWindow;
      for (final (_, spec) in tuyaDrivers) {
        tuyaWindow = _atLeast(
          tuyaWindow,
          _longer(window, spec.config['windowMs']),
        );
      }
      run(
        tuyaBroadcastMethod,
        tuya
            .discover(window: tuyaWindow)
            .then(
              (sightings) => [
                for (final (driver, _) in tuyaDrivers)
                  for (final s in sightings) (driver.id, _fromTuya(s)),
              ],
            ),
      );
    }

    final byService = <String, List<(DriverManifest, DiscoverySpec)>>{};
    for (final driver in drivers) {
      for (final spec in driver.discovery) {
        final service = spec.config['service'];
        if (spec.method != mdnsMethod || service is! String) continue;
        (byService[service] ??= []).add((driver, spec));
      }
    }
    if (wanted(mdnsMethod)) {
      for (final MapEntry(key: service, value: users) in byService.entries) {
        var serviceWindow = window;
        for (final (_, spec) in users) {
          serviceWindow = _longer(serviceWindow, spec.config['windowMs']);
        }
        run(
          mdnsMethod,
          mdns
              .browse(service, window: serviceWindow)
              .then(
                (instances) => [
                  for (final (driver, spec) in users)
                    for (final s in instances)
                      (
                        driver.id,
                        _fromMdns(
                          s,
                          spec.config['idTxt'] as String?,
                          spec.config['idInstance'] == true,
                        ),
                      ),
                ],
              ),
        );
      }
    }

    final found = <String, List<DiscoveredDevice>>{
      for (final d in drivers) d.id: [],
    };
    for (final results in await Future.wait(runs)) {
      for (final (driverId, device) in results) {
        found[driverId]!.add(device);
      }
    }
    return DiscoverySweep(
      {for (final MapEntry(:key, :value) in found.entries) key: _merged(value)},
      failures,
      runs.length,
    );
  }

  static DiscoverySpec? _spec(DriverManifest driver, String method) =>
      driver.discovery.where((d) => d.method == method).firstOrNull;

  /// One device per stable id, or per address when it has none.
  static List<DiscoveredDevice> _merged(List<DiscoveredDevice> found) {
    final merged = <String, DiscoveredDevice>{};
    for (final d in found) {
      merged[(d.stableId ?? 'host:${d.host}').toLowerCase()] ??= d;
    }
    return merged.values.toList();
  }

  static String _cannotListen(String method, SocketException e) =>
      method == tuyaBroadcastMethod
      ? 'cannot listen on UDP ${tuyaBroadcastPorts.join(' or ')} for Tuya '
            'announcements (${e.message}). Another program holds the ports'
      : '$method discovery cannot open its socket (${e.message})';

  /// A [DeviceLocator] for address healing. A Tuya driver listens until the
  /// device with that `gwId` is heard; other methods discover and match the
  /// stable id.
  DeviceLocator get locator => (driver, stableId) async {
    final methods = {for (final d in driver.discovery) d.method};
    if (methods.contains(tuyaBroadcastMethod)) {
      final host = await tuya.locate(stableId, window: tuyaLocateWindow);
      if (host != null) return host;
    }
    if (!methods.contains('udp_broadcast') && !methods.contains(mdnsMethod)) {
      return null;
    }
    final hits = await discover(driver);
    return hits
        .where((h) => h.stableId?.toLowerCase() == stableId.toLowerCase())
        .firstOrNull
        ?.host;
  };

  static DiscoveredDevice _fromTuya(TuyaSighting s) => DiscoveredDevice(
    host: s.host,
    stableId: s.broadcast.gwId,
    reply: s.broadcast.json,
    method: tuyaBroadcastMethod,
  );

  /// The stable id is the TXT value [idTxt] names, or the instance label
  /// when [idInstance] (a board registers under its node name, a Shelly
  /// under its device id).
  static DiscoveredDevice _fromMdns(
    MdnsService s,
    String? idTxt,
    bool idInstance,
  ) => DiscoveredDevice(
    host: s.host,
    port: s.port,
    name: s.instance,
    stableId: idInstance
        ? s.instance
        : idTxt == null
        ? null
        : s.txt[idTxt.toLowerCase()],
    reply: s.toJson(),
    method: mdnsMethod,
  );

  static Duration _longer(Duration window, Object? windowMs) => windowMs is int
      ? _atLeast(window, Duration(milliseconds: windowMs))
      : window;

  static Duration _atLeast(Duration a, Duration b) => a > b ? a : b;
}

/// Finds devices by broadcasting a driver's `udp_broadcast` probe and
/// collecting the replies that match its `matchJsonPath`.
class UdpDiscovery {
  UdpDiscovery(
    this._udp, {
    this._targets,
    this._acceptFrom = isLocalNetworkAddress,
  });

  final UdpTransport _udp;

  /// Where probes go. Defaults to [broadcastTargets].
  final Future<List<InternetAddress>> Function()? _targets;

  /// Which senders a reply is taken from. A reply becomes a device address
  /// (and, through healing, where commands go), so only the local network.
  final bool Function(InternetAddress from) _acceptFrom;

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
      if (d.port != port || !_acceptFrom(d.address)) return;
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
