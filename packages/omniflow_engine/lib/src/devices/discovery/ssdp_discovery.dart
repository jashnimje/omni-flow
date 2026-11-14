import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../manifest/driver_manifest.dart' show ssdpTargetPattern;
import '../../transports/udp_transport.dart';

export '../../manifest/driver_manifest.dart' show ssdpTargetPattern;

/// The discovery method a driver manifest names for SSDP (UPnP). Its `st`
/// field is the search target (`roku:ecp`,
/// `urn:schemas-upnp-org:device:ZonePlayer:1`), and `idHeader` names the
/// reply header that carries a stable id (`usn`).
const ssdpMethod = 'ssdp';

/// The SSDP multicast group and port every UPnP device listens on.
final ssdpGroup = InternetAddress('239.255.255.250');
const ssdpPort = 1900;

/// One device that answered an M-SEARCH.
class SsdpReply {
  const SsdpReply({required this.host, required this.headers, this.port});

  /// The address the reply came from. Commands go there, never to the
  /// `LOCATION` host, which the device could set to anything.
  final String host;

  /// The port named in `LOCATION`, when it parses.
  final int? port;

  /// Reply headers with lower-case names.
  final Map<String, String> headers;

  /// The unique id inside a `USN` header (`uuid:roku:ecp:P0A070000007`
  /// gives `P0A070000007`, `uuid:RINCON_000E58A0123401400::urn:...` gives
  /// `RINCON_000E58A0123401400`), or the whole value of another header.
  String? stableId(String header) {
    final value = headers[header.toLowerCase()];
    if (value == null || value.isEmpty) return null;
    if (header.toLowerCase() != 'usn') return value;
    var id = value.split('::').first;
    if (id.toLowerCase().startsWith('uuid:')) id = id.substring(5);
    final roku = RegExp(r'^roku:ecp:(.+)$').firstMatch(id);
    return roku?.group(1) ?? id;
  }

  Map<String, Object?> toJson() => {
    'host': host,
    'port': ?port,
    'headers': headers,
  };
}

/// Sends an SSDP M-SEARCH for a search target and collects the answers.
///
/// Probes go to the SSDP multicast group unless [targets] names others (a
/// test passes loopback). Replies from outside the local network are
/// dropped, as every discovery here does, and so is a reply whose `ST` is
/// not the target asked for.
class SsdpDiscovery {
  SsdpDiscovery({
    this._targets,
    this.port = ssdpPort,
    bool Function(InternetAddress from)? acceptFrom,
  }) : _acceptFrom = acceptFrom ?? isLocalNetworkAddress;

  final Future<List<InternetAddress>> Function()? _targets;
  final int port;
  final bool Function(InternetAddress from) _acceptFrom;

  /// The M-SEARCH datagram for [st].
  static List<int> search(String st, {int mx = 1}) => ascii.encode(
    'M-SEARCH * HTTP/1.1\r\n'
    'HOST: 239.255.255.250:1900\r\n'
    'MAN: "ssdp:discover"\r\n'
    'MX: $mx\r\n'
    'ST: $st\r\n'
    '\r\n',
  );

  /// Parses an SSDP reply: an `HTTP/1.1 200 OK` status line and headers.
  /// Null for anything else, including another device's own M-SEARCH.
  static Map<String, String>? parse(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    if (lines.isEmpty ||
        !lines.first.toUpperCase().startsWith('HTTP/1.1 200')) {
      return null;
    }
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      headers.putIfAbsent(
        line.substring(0, colon).trim().toLowerCase(),
        () => line.substring(colon + 1).trim(),
      );
    }
    return headers;
  }

  /// Every device that answers [st] within [window], one per address.
  /// Throws [ArgumentError] for a search target outside
  /// [ssdpTargetPattern], and [SocketException] when no socket opens.
  Future<List<SsdpReply>> discover(
    String st, {
    Duration window = const Duration(seconds: 2),
  }) async {
    if (!ssdpTargetPattern.hasMatch(st)) {
      throw ArgumentError('"$st" is not an SSDP search target');
    }
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final found = <String, SsdpReply>{};
    final subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null || !_acceptFrom(datagram.address)) return;
        final headers = parse(utf8.decode(datagram.data, allowMalformed: true));
        if (headers == null) return;
        if ((headers['st'] ?? '').toLowerCase() != st.toLowerCase()) return;
        final location = Uri.tryParse(headers['location'] ?? '');
        found.putIfAbsent(
          datagram.address.address,
          () => SsdpReply(
            host: datagram.address.address,
            port: location != null && location.hasPort ? location.port : null,
            headers: headers,
          ),
        );
      },
      onError: (Object _) {
        // A send the OS could not route (no network, no broadcast route)
        // comes back here on some systems. It is not a reply: ignore it.
      },
    );
    try {
      final targets = await (_targets ?? () async => [ssdpGroup])();
      final probe = search(st);
      for (var round = 0; round < 2; round++) {
        for (final target in targets) {
          try {
            socket.send(probe, target, port);
          } on SocketException {
            // An interface that cannot reach the group: skip it.
          }
        }
        await Future<void>.delayed(window ~/ 2);
      }
    } finally {
      await subscription.cancel();
      socket.close();
    }
    return found.values.toList();
  }
}
