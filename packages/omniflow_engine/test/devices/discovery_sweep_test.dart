import 'dart:convert';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/discovery/board_hellos.dart';
import 'package:omniflow_engine/src/devices/discovery/thing_finder.dart';
import 'package:omniflow_engine/src/manifest/built_in_drivers.g.dart';
import 'package:test/test.dart';

import 'fake_mdns.dart';

const hueInstance = 'Philips Hue - 0A0B0C._hue._tcp.local';
const haInstance = 'Home._home-assistant._tcp.local';
const boardInstance = 'hall-board._omniflow._udp.local';

final mdnsRecords = <ResourceRecord>[
  ptr('_hue._tcp', hueInstance),
  srv(hueInstance, 'ecb5fa0a0b0c.local', 443),
  txt(hueInstance, ['bridgeid=ecb5fafffe0a0b0c']),
  a('ecb5fa0a0b0c.local', '192.168.1.20'),
  ptr('_home-assistant._tcp', haInstance),
  srv(haInstance, 'homeassistant.local', 8123),
  txt(haInstance, ['uuid=ha0001']),
  a('homeassistant.local', '192.168.1.5'),
  ptr('_omniflow._udp', boardInstance),
  srv(boardInstance, 'hall-board.local', 38950),
  a('hall-board.local', '192.168.1.60'),
];

/// A loopback lamp answering the WiZ registration probe with its MAC.
Future<UdpTransport> fakeLamp(String mac) async {
  final lamp = await UdpTransport.bind();
  lamp.incoming.listen((d) {
    lamp.send(
      d.address,
      d.port,
      utf8.encode(
        jsonEncode({
          'method': 'registration',
          'result': {'mac': mac},
        }),
      ),
    );
  });
  return lamp;
}

/// The built-in WiZ driver as `test_wiz`, probing [port] on loopback.
DriverManifest wizOnPort(int port) {
  final json = jsonDecode(
    builtInDriverSources['philips_wiz_udp.omni_driver.json']!,
  ) as Map<String, Object?>;
  json['id'] = 'test_wiz';
  ((json['discovery'] as List).single as Map)['port'] = port;
  return DriverManifest.parse(json);
}

/// Binds each Tuya broadcast port as a loopback socket on a free port.
class LoopbackTuyaPorts {
  final ports = <int>[];
  var fail = false;

  Future<RawDatagramSocket> call(int port) async {
    if (fail) throw const SocketException('address in use');
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    ports.add(socket.port);
    return socket;
  }
}

void main() {
  final builtIns = DriverRegistry.withBuiltIns();
  DriverManifest driver(String id) => builtIns[id]!;
  late UdpTransport udp;

  setUp(() async => udp = await UdpTransport.bind());
  tearDown(() => udp.close());

  ThingFinder finder({
    List<ResourceRecord>? records,
    LoopbackTuyaPorts? tuya,
    SerialProbe? serial,
    RecentHellos? hellos,
  }) => ThingFinder(
    discovery: DeviceDiscovery(
      udp: UdpDiscovery(
        udp,
        targets: () async => [InternetAddress.loopbackIPv4],
      ),
      tuya: TuyaDiscovery(
        bind: (tuya ?? LoopbackTuyaPorts()).call,
        acceptFrom: (_) => true,
      ),
      mdns: MdnsDiscovery(client: () => FakeMdns(records ?? const [])),
      tuyaMinimumWindow: const Duration(milliseconds: 300),
    ),
    serial: serial ?? (_, _) async => const [],
    hellos: hellos,
  );

  Map<String, Object?> groupOf(FoundThings found, String driverId) =>
      found.groups.firstWhere((g) => g['driver'] == driverId);

  List<Map<String, Object?>> candidates(FoundThings found, String driverId) => [
    for (final c in groupOf(found, driverId)['candidates'] as List)
      c as Map<String, Object?>,
  ];

  const window = Duration(milliseconds: 200);

  test('udp_broadcast finds a lamp by its probe reply', () async {
    final lamp = await fakeLamp('a8bb50aabbcc');
    addTearDown(lamp.close);
    final found = await finder().find(
      [wizOnPort(lamp.localPort)],
      devices: const [],
      window: window,
    );
    final lamp1 = candidates(found, 'test_wiz').single;
    expect(lamp1['method'], 'udp_broadcast');
    expect(lamp1['host'], '127.0.0.1');
    expect(lamp1['stableId'], 'a8bb50aabbcc');
    expect(lamp1['id'], 'test_wiz_aabbcc');
    expect(lamp1['name'], 'Philips WiZ Light (local UDP) aabbcc');
    expect(lamp1['add'], {
      'driver': 'test_wiz',
      'host': '127.0.0.1',
      'stableId': 'a8bb50aabbcc',
      'id': 'test_wiz_aabbcc',
      'name': 'Philips WiZ Light (local UDP) aabbcc',
    });
  });

  test('one mdns browse serves every driver of a service, and a Hue keeps its '
      'own port', () async {
    final mdns = <FakeMdns>[];
    final found =
        await ThingFinder(
          discovery: DeviceDiscovery(
            udp: UdpDiscovery(udp, targets: () async => const []),
            mdns: MdnsDiscovery(
              client: () {
                final client = FakeMdns(mdnsRecords);
                mdns.add(client);
                return client;
              },
            ),
          ),
          serial: (_, _) async => const [],
        ).find(
          [
            driver('philips_hue_light'),
            driver('home_assistant_entity'),
            driver('home_assistant_sensor'),
          ],
          devices: const [],
          window: window,
          methods: {'mdns'},
        );
    final browses = [
      for (final m in mdns)
        for (final q in m.queries)
          if (q.startsWith('PTR')) q,
    ];
    expect(
      browses,
      unorderedEquals([
        'PTR (Domain Name Pointer) _hue._tcp.local',
        'PTR (Domain Name Pointer) _home-assistant._tcp.local',
      ]),
    );
    final hue = candidates(found, 'philips_hue_light').single;
    expect(hue['stableId'], 'ecb5fafffe0a0b0c');
    expect(hue['port'], 443);
    expect((hue['add'] as Map).containsKey('port'), isFalse);
    expect(hue['id'], 'philips_hue_0a0b0c');
    expect(hue['name'], 'Philips Hue - 0A0B0C');
    final entity = candidates(found, 'home_assistant_entity').single;
    final sensor = candidates(found, 'home_assistant_sensor').single;
    expect(entity['stableId'], 'ha0001');
    expect(sensor['host'], '192.168.1.5');
    expect(
      {entity['id'], sensor['id']},
      hasLength(2),
      reason: 'ids are unique across the result',
    );
    expect(found.methods, ['mdns']);
  });

  test('tuya_broadcast finds a plug by the gwId it announces', () async {
    final ports = LoopbackTuyaPorts();
    final sender = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(sender.close);
    final finding = finder(tuya: ports).find(
      [driver('tuya_plug')],
      devices: const [],
      window: window,
      methods: {'tuya_broadcast'},
    );
    for (var i = 0; i < 50 && ports.ports.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    sender.send(
      encodeTuyaBroadcast({
        'gwId': 'fixturegwid0001',
        'ip': '127.0.0.1',
        'version': '3.3',
      }),
      InternetAddress.loopbackIPv4,
      ports.ports.first,
    );
    final found = await finding;
    final plug = candidates(found, 'tuya_plug').single;
    expect(plug['method'], 'tuya_broadcast');
    expect(plug['stableId'], 'fixturegwid0001');
    expect(plug['host'], '127.0.0.1');
  });

  test('a method that cannot listen is reported and the rest go on', () async {
    final ports = LoopbackTuyaPorts()..fail = true;
    final found = await finder(tuya: ports, records: mdnsRecords).find(
      [driver('tuya_plug'), driver('philips_hue_light')],
      devices: const [],
      window: window,
    );
    expect(found.failures.single, contains('Tuya'));
    expect(candidates(found, 'philips_hue_light'), hasLength(1));
    expect(found.groups.map((g) => g['driver']), ['philips_hue_light']);
  });

  test('serial asks the board drivers and names a find by its node', () async {
    final asked = <String>[];
    final found =
        await finder(
          serial: (d, w) async {
            asked.add('${d.id} ${w.inMilliseconds}');
            return [
              {
                'host': '/dev/cu.usbserial-0001',
                'stableId': 'desk-board',
                'reply': {'event': 'describe', 'node': 'desk-board'},
              },
            ];
          },
        ).find(
          [driver('omniflow_board'), driver('philips_wiz_udp')],
          devices: const [],
          window: window,
          methods: {'serial'},
        );
    expect(asked, ['omniflow_board 3000']);
    final board = candidates(found, 'omniflow_board').single;
    expect(board['method'], 'serial');
    expect(board['host'], '/dev/cu.usbserial-0001');
    expect(board['id'], 'desk_board');
  });

  test(
    'a board heard by mdns and by hello is one find, and on USB another',
    () async {
      final hellos = RecentHellos()
        ..observe({
          'event': 'board.found',
          'node': 'hall-board',
          'board': 'esp32',
          'host': '192.168.1.60',
          'add': {
            'id': 'hall_board',
            'name': 'hall-board',
            'driver': 'omniflow_board',
            'host': '192.168.1.60',
            'stableId': 'hall-board',
          },
        });
      final found =
          await finder(
            records: mdnsRecords,
            hellos: hellos,
            serial: (_, _) async => [
              {'host': '/dev/cu.usbmodem1', 'stableId': 'hall-board'},
            ],
          ).find(
            [driver('omniflow_board')],
            devices: const [],
            window: window,
            methods: {'mdns', 'hello', 'serial'},
          );
      final boards = candidates(found, 'omniflow_board');
      expect(boards, hasLength(2));
      expect(boards.first['methods'], ['mdns', 'hello']);
      expect(boards.first['host'], '192.168.1.60');
      expect(boards.first['id'], 'hall_board');
      expect(boards.last['method'], 'serial');
      expect(boards.last['id'], 'hall_board_2');
    },
  );

  test('a find that is a device already is marked knownAs', () async {
    final found = await finder(records: mdnsRecords).find(
      [driver('philips_hue_light')],
      devices: const [
        Device(
          id: 'philips_hue_0a0b0c',
          name: 'Taken id',
          driverId: 'philips_wiz_udp',
          host: '10.0.0.9',
        ),
        Device(
          id: 'hall_light',
          name: 'Hall',
          driverId: 'philips_hue_light',
          host: '192.168.1.20',
          stableId: 'ECB5FAFFFE0A0B0C',
        ),
      ],
      window: window,
      methods: {'mdns'},
    );
    final hue = candidates(found, 'philips_hue_light').single;
    expect(hue['knownAs'], 'hall_light');
    expect(hue['id'], 'philips_hue_0a0b0c_2');
  });

  group('RecentHellos', () {
    Map<String, Object?> found(String node) => {
      'event': 'board.found',
      'node': node,
      'add': {
        'driver': 'omniflow_board',
        'host': '192.168.1.7',
        'stableId': node,
        'name': node,
      },
    };

    test('keeps hellos for the ttl, newest last, up to the cap', () {
      var now = DateTime(2026, 11, 7, 12);
      final hellos = RecentHellos(
        ttl: const Duration(minutes: 3),
        cap: 2,
        clock: () => now,
      );
      hellos
        ..observe(found('a'))
        ..observe({'event': 'device.stateChanged'})
        ..observe(found('b'))
        ..observe(found('c'));
      expect(hellos.recent.map((r) => r.$2.stableId), ['b', 'c']);
      now = now.add(const Duration(minutes: 2));
      hellos.observe(found('b'));
      now = now.add(const Duration(minutes: 2));
      expect(hellos.recent.map((r) => r.$2.stableId), ['b']);
      expect(hellos.recent.single.$1, 'omniflow_board');
      expect(hellos.recent.single.$2.method, helloMethod);
    });

    test('ignores a found event without an address', () {
      final hellos = RecentHellos()
        ..observe({
          'event': 'board.found',
          'add': {'driver': 'omniflow_board'},
        });
      expect(hellos.recent, isEmpty);
    });
  });

  test('suggestThingId makes lower snake case ids that do not clash', () {
    expect(suggestThingId('Philips Hue - 0A0B0C', {}), 'philips_hue_0a0b0c');
    expect(suggestThingId('hall-board', {'hall_board'}), 'hall_board_2');
    expect(
      suggestThingId('hall-board', {'hall_board', 'hall_board_2'}),
      'hall_board_3',
    );
    expect(suggestThingId('42 Lamp', {}), 'thing_42_lamp');
    expect(suggestThingId('***', {}), 'thing');
    expect(suggestThingId('a' * 60, {}), hasLength(40));
  });
}
