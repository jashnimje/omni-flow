import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import '../../manifest/driver_manifest.dart' show mdnsServicePattern;
import '../../transports/udp_transport.dart';

export '../../manifest/driver_manifest.dart' show mdnsServicePattern;

/// The discovery method a driver manifest names for DNS-SD over mDNS. Its
/// `service` field is the service type and `idTxt`, when present, names
/// the TXT key that carries a stable id.
const mdnsMethod = 'mdns';

/// Service types OmniFlow browses for: its own boards, Shelly, Hue bridges
/// and Home Assistant.
const knownMdnsServices = [
  '_omniflow._udp',
  '_shelly._tcp',
  '_hue._tcp',
  '_home-assistant._tcp',
];

/// One resolved service instance.
class MdnsService {
  const MdnsService({
    required this.service,
    required this.instance,
    required this.target,
    required this.host,
    required this.port,
    required this.txt,
  });

  /// The service type browsed, for example `_shelly._tcp`.
  final String service;

  /// The instance label, for example `shellyplus1-a8032ab12345`.
  final String instance;

  /// The SRV target host name, for example `shellyplus1-a8032ab12345.local`.
  final String target;

  /// The IPv4 address the target resolved to.
  final String host;
  final int port;

  /// TXT entries with lower-case keys. A key without `=` maps to `''`.
  final Map<String, String> txt;

  Map<String, Object?> toJson() => {
    'service': service,
    'instance': instance,
    'target': target,
    'host': host,
    'port': port,
    'txt': txt,
  };
}

/// Makes the client for one browse. Tests pass a fake [MDnsClient], or a
/// real one built with a `rawDatagramSocketFactory`.
typedef MdnsClientFactory = MDnsClient Function();

/// Browses DNS-SD services over mDNS and resolves each instance from its
/// PTR record to SRV and TXT, then the SRV target to an A record.
///
/// The client, and its UDP 5353 socket, lives only for one [browse] call.
/// mDNS replies carry no sender the client exposes, so an address outside
/// the local network is refused at the A record instead.
/// An mDNS client whose sockets never ask for SO_REUSEPORT where the
/// platform has none (Android): binding then fails and nothing is found.
MDnsClient platformMdnsClient() => MDnsClient(
  rawDatagramSocketFactory:
      (
        host,
        int port, {
        bool reuseAddress = true,
        bool reusePort = false,
        int ttl = 1,
      }) => RawDatagramSocket.bind(
        host,
        port,
        reuseAddress: reuseAddress,
        reusePort: reusePort && !Platform.isAndroid,
        ttl: ttl,
      ),
);

class MdnsDiscovery {
  MdnsDiscovery({
    this._client = platformMdnsClient,
    this._acceptAddress = isLocalNetworkAddress,
    this.resolveTimeout = const Duration(milliseconds: 1500),
    this.maxInstances = 64,
  });

  final MdnsClientFactory _client;
  final bool Function(InternetAddress address) _acceptAddress;

  /// How long each SRV, TXT and A lookup may take after its PTR arrives.
  final Duration resolveTimeout;

  /// A cap on instances resolved per browse, so a noisy network cannot
  /// make one browse do unbounded work.
  final int maxInstances;

  /// The instances of [service] that answer within [window] and resolve.
  /// Instances that do not resolve to a local IPv4 address are left out.
  Future<List<MdnsService>> browse(
    String service, {
    Duration window = const Duration(seconds: 3),
  }) async {
    if (!mdnsServicePattern.hasMatch(service)) {
      throw ArgumentError.value(
        service,
        'service',
        'must look like _name._tcp or _name._udp',
      );
    }
    final domain = '$service.local';
    final client = _client();
    await client.start();
    try {
      final seen = <String>{};
      final pending = <Future<MdnsService?>>[];
      await for (final ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(domain),
        timeout: window,
      )) {
        final name = _trimDot(ptr.domainName);
        if (!seen.add(name.toLowerCase())) continue;
        if (seen.length > maxInstances) break;
        pending.add(_resolve(client, service, domain, name));
      }
      final resolved = await Future.wait(pending);
      return [for (final s in resolved) ?s];
    } finally {
      client.stop();
    }
  }

  Future<MdnsService?> _resolve(
    MDnsClient client,
    String service,
    String domain,
    String name,
  ) async {
    final srvLookup = _first(
      client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(name),
        timeout: resolveTimeout,
      ),
    );
    final txtLookup = _first(
      client.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(name),
        timeout: resolveTimeout,
      ),
    );
    final srv = await srvLookup;
    final txt = await txtLookup;
    if (srv == null) return null;
    final target = _trimDot(srv.target);
    final address = await _first(
      client
          .lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(target),
            timeout: resolveTimeout,
          )
          .where(
            (a) =>
                a.address.type == InternetAddressType.IPv4 &&
                _acceptAddress(a.address),
          ),
    );
    if (address == null) return null;
    return MdnsService(
      service: service,
      instance: _instanceLabel(name, domain),
      target: target,
      host: address.address.address,
      port: srv.port,
      txt: txt == null ? const {} : parseTxt(txt.text),
    );
  }

  static Future<T?> _first<T>(Stream<T> records) async {
    await for (final record in records) {
      return record;
    }
    return null;
  }

  static String _trimDot(String name) =>
      name.endsWith('.') ? name.substring(0, name.length - 1) : name;

  static String _instanceLabel(String name, String domain) {
    final suffix = '.$domain';
    return name.toLowerCase().endsWith(suffix.toLowerCase())
        ? name.substring(0, name.length - suffix.length)
        : name;
  }
}

/// TXT strings as multicast_dns joins them (one per line) to a map. Keys
/// are case-insensitive, so they are lower-cased, and only the first of a
/// repeated key counts (RFC 6763 section 6.4).
Map<String, String> parseTxt(String text) {
  final entries = <String, String>{};
  for (final line in text.split('\n')) {
    if (line.isEmpty) continue;
    final equals = line.indexOf('=');
    final key = (equals < 0 ? line : line.substring(0, equals)).toLowerCase();
    if (key.isEmpty) continue;
    entries.putIfAbsent(
      key,
      () => equals < 0 ? '' : line.substring(equals + 1),
    );
  }
  return entries;
}
