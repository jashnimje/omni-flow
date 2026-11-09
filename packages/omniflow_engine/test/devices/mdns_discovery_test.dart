import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import 'fake_mdns.dart';

void main() {
  test('resolves PTR to SRV, TXT and A for each instance once', () async {
    final fake = FakeMdns(shellyRecords);
    final found = await MdnsDiscovery(client: () => fake)
        .browse('_shelly._tcp');
    found.sort((x, y) => x.host.compareTo(y.host));
    expect(found.map((s) => s.toJson()), [
      {
        'service': '_shelly._tcp',
        'instance': 'ShellyPlus1-A8032AB10002',
        'target': 'shellyplus1-a8032ab10002.local',
        'host': '10.0.0.42',
        'port': 8080,
        'txt': <String, String>{},
      },
      {
        'service': '_shelly._tcp',
        'instance': 'shellyplus1-a8032ab10001',
        'target': 'shellyplus1-a8032ab10001.local',
        'host': '192.168.1.41',
        'port': 80,
        'txt': {
          'gen': '2',
          'app': 'Plus1',
          'ver': '1.4.4',
          'id': 'shellyplus1-a8032ab10001',
        },
      },
    ]);
    expect(fake.started, isTrue);
    expect(fake.stopped, isTrue);
    expect(
      fake.queries.where((q) => q.startsWith('SRV')),
      hasLength(2),
      reason: 'the repeated PTR is resolved only once',
    );
  });

  test('drops instances without SRV, without IPv4, or off the LAN', () async {
    const noSrv = 'lost._hue._tcp.local';
    const v6Only = 'v6._hue._tcp.local';
    const public = 'far._hue._tcp.local';
    const good = 'Philips Hue - 1A2B3C._hue._tcp.local.';
    final fake = FakeMdns([
      ptr('_hue._tcp', noSrv),
      ptr('_hue._tcp', v6Only),
      ptr('_hue._tcp', public),
      ptr('_hue._tcp', good),
      srv(v6Only, 'v6.local', 443),
      a('v6.local', 'fe80::1'),
      srv(public, 'far.local', 443),
      a('far.local', '8.8.8.8'),
      srv(good.substring(0, good.length - 1), 'hue-bridge.local.', 443),
      txt(good.substring(0, good.length - 1), [
        'bridgeid=001788fffe1a2b3c',
        'modelid=BSB002',
      ]),
      a('hue-bridge.local', '192.168.1.2'),
    ]);
    final found = await MdnsDiscovery(client: () => fake).browse('_hue._tcp');
    final hue = found.single;
    expect(hue.instance, 'Philips Hue - 1A2B3C');
    expect(hue.target, 'hue-bridge.local');
    expect(hue.host, '192.168.1.2');
    expect(hue.txt['bridgeid'], '001788fffe1a2b3c');
  });

  test('a board with no TXT record still resolves', () async {
    const board = 'desk-node._omniflow._udp.local';
    final fake = FakeMdns([
      ptr('_omniflow._udp', board),
      srv(board, 'desk-node.local', 38950),
      a('desk-node.local', '192.168.1.77'),
    ]);
    final found = await MdnsDiscovery(client: () => fake)
        .browse('_omniflow._udp');
    expect(found.single.instance, 'desk-node');
    expect(found.single.port, 38950);
    expect(found.single.txt, isEmpty);
  });

  test('the instance cap bounds the work one browse does', () async {
    final records = <ResourceRecord>[
      for (var i = 0; i < 10; i++) ...[
        ptr('_home-assistant._tcp', 'ha$i._home-assistant._tcp.local'),
        srv('ha$i._home-assistant._tcp.local', 'ha$i.local', 8123),
        a('ha$i.local', '192.168.1.${10 + i}'),
      ],
    ];
    final fake = FakeMdns(records);
    final found = await MdnsDiscovery(
      client: () => fake,
      maxInstances: 3,
    ).browse('_home-assistant._tcp');
    expect(found, hasLength(3));
  });

  test('a service name that is not a DNS-SD type is refused', () async {
    var made = 0;
    final discovery = MdnsDiscovery(
      client: () {
        made++;
        return FakeMdns(const []);
      },
    );
    for (final bad in [
      'shelly',
      '_shelly._tcp.local',
      '_shelly._sctp',
      '_a-name-far-too-long._tcp',
      '_x._tcp\nevil',
    ]) {
      await expectLater(
        discovery.browse(bad),
        throwsA(isA<ArgumentError>()),
        reason: bad,
      );
    }
    expect(made, 0);
  });

  test('the client is stopped even when a lookup fails', () async {
    final fake = FakeMdns(const [], failLookups: true);
    await expectLater(
      MdnsDiscovery(client: () => fake).browse('_shelly._tcp'),
      throwsA(isA<SocketException>()),
    );
    expect(fake.stopped, isTrue);
  });

  test('TXT keys are lower-cased and the first of a repeat wins', () {
    expect(parseTxt('A=1\nflag\na=2\n=x\nurl=http://h/?q=1\n\n'), {
      'a': '1',
      'flag': '',
      'url': 'http://h/?q=1',
    });
  });

  test('the known service types are valid DNS-SD types', () {
    for (final service in knownMdnsServices) {
      expect(mdnsServicePattern.hasMatch(service), isTrue, reason: service);
    }
  });

  test(
    'DeviceDiscovery maps an mdns spec to devices with idTxt as the stable id',
    () async {
      final udp = await UdpTransport.bind();
      addTearDown(udp.close);
      final manifest = DriverManifest.parse({
        'schemaVersion': 1,
        'id': 'shelly_mdns_fixture',
        'name': 'Shelly found over mDNS',
        'category': 'power',
        'transport': {'type': 'http', 'port': 80},
        'discovery': [
          {'method': 'mdns', 'service': '_shelly._tcp', 'idTxt': 'id'},
        ],
        'capabilities': [
          {
            'id': 'power',
            'type': 'toggle',
            'label': 'Power',
            'command': {
              'path': '/rpc/Switch.Set',
              'query': {'id': 0, 'on': '{{value}}'},
            },
          },
        ],
      });
      final discovery = DeviceDiscovery(
        udp: UdpDiscovery(udp, targets: () async => const []),
        mdns: MdnsDiscovery(client: () => FakeMdns(shellyRecords)),
      );
      final found = await discovery.discover(
        manifest,
        window: const Duration(milliseconds: 100),
      );
      final byHost = {for (final d in found) d.host: d.toJson()};
      expect(byHost['192.168.1.41'], {
        'host': '192.168.1.41',
        'stableId': 'shellyplus1-a8032ab10001',
        'port': 80,
        'name': 'shellyplus1-a8032ab10001',
        'method': 'mdns',
        'reply': isA<Map<String, Object?>>(),
      });
      expect(byHost['10.0.0.42']!.containsKey('stableId'), isFalse);
      expect(
        await discovery.locator(manifest, 'SHELLYPLUS1-A8032AB10001'),
        '192.168.1.41',
      );
    },
  );
}
