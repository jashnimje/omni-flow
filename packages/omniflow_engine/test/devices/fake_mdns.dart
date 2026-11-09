import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

/// Answers lookups from a fixed record set, with no sockets. Each lookup
/// stream ends once its matching records are sent, as the real client's
/// does when its timeout fires.
class FakeMdns implements MDnsClient {
  FakeMdns(this.records, {this.failLookups = false});

  final List<ResourceRecord> records;
  final bool failLookups;
  final queries = <String>[];
  var started = false;
  var stopped = false;

  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async {
    started = true;
  }

  @override
  void stop() => stopped = true;

  @override
  Future<Iterable<NetworkInterface>> allInterfacesFactory(
    InternetAddressType type,
  ) async => const [];

  @override
  Stream<T> lookup<T extends ResourceRecord>(
    ResourceRecordQuery query, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (!started) throw StateError('lookup before start');
    if (failLookups) throw const SocketException('network is down');
    queries.add(
      '${ResourceRecordType.toDebugString(query.resourceRecordType)} '
      '${query.fullyQualifiedName}',
    );
    final controller = StreamController<T>();
    Future<void>(() async {
      for (final r in records) {
        if (r.resourceRecordType == query.resourceRecordType &&
            r.name.toLowerCase() == query.fullyQualifiedName.toLowerCase()) {
          await Future<void>.delayed(Duration.zero);
          controller.add(r as T);
        }
      }
      await controller.close();
    });
    return controller.stream;
  }
}

const ttl = 0;

PtrResourceRecord ptr(String service, String instance) =>
    PtrResourceRecord('$service.local', ttl, domainName: instance);

SrvResourceRecord srv(String instance, String target, int port) =>
    SrvResourceRecord(
      instance,
      ttl,
      target: target,
      port: port,
      priority: 0,
      weight: 0,
    );

IPAddressResourceRecord a(String host, String address) =>
    IPAddressResourceRecord(host, ttl, address: InternetAddress(address));

TxtResourceRecord txt(String instance, List<String> entries) =>
    TxtResourceRecord(instance, ttl, text: '${entries.join('\n')}\n');

const shellyA = 'shellyplus1-a8032ab10001._shelly._tcp.local';
const shellyB = 'ShellyPlus1-A8032AB10002._shelly._tcp.local';

final shellyRecords = <ResourceRecord>[
  ptr('_shelly._tcp', shellyA),
  ptr('_shelly._tcp', shellyB),
  ptr('_shelly._tcp', shellyA.toUpperCase()),
  srv(shellyA, 'shellyplus1-a8032ab10001.local', 80),
  txt(shellyA, [
    'gen=2',
    'app=Plus1',
    'ver=1.4.4',
    'ID=shellyplus1-a8032ab10001',
  ]),
  a('shellyplus1-a8032ab10001.local', '192.168.1.41'),
  srv(shellyB, 'shellyplus1-a8032ab10002.local', 8080),
  a('shellyplus1-a8032ab10002.local', '10.0.0.42'),
];
