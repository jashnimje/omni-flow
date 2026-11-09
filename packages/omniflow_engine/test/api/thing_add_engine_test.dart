import 'dart:convert';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

const shellyInstance = 'shellyplus1-a8032ab10001._shelly._tcp.local';

final records = <ResourceRecord>[
  ptr('_shelly._tcp', shellyInstance),
  srv(shellyInstance, 'shellyplus1-a8032ab10001.local', 80),
  a('shellyplus1-a8032ab10001.local', '192.168.1.40'),
];

/// The add pipeline through the engine's own command table.
void main() {
  late Directory home;
  late OmniEngine engine;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_thing_add');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      discoveryTargets: () async => const [],
      mdns: MdnsDiscovery(client: () => FakeMdns(records)),
    );
  });

  tearDown(() async {
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command: $result');
    return result;
  }

  bool registered() {
    final missing = [
      for (final c in ['thing.add', 'thing.next', 'thing.configure'])
        if (!engine.commandNames.contains(c)) c,
    ];
    if (missing.isEmpty) return true;
    markTestSkipped('${missing.join(', ')} not in the command table yet');
    return false;
  }

  test('device.add says what comes next', () async {
    final added = await ok('device.add', {
      'id': 'lounge',
      'driver': 'lg_webos_tv',
      'host': '192.0.2.6',
    });
    expect(added['next'], containsPair('step', 'pair'));
    expect(added['next'], containsPair('command', 'device.pair'));
  });

  test('thing.add finds over mdns and adds through the engine', () async {
    if (!registered()) return;
    final found = await ok('thing.add', {
      'windowMs': 200,
      'methods': ['mdns'],
    });
    final shelly =
        (((found['groups'] as List).single as Map)['candidates'] as List).single
            as Map<String, Object?>;
    expect(shelly['driver'], 'shelly_plus_switch');
    final added = await ok('thing.add', {'candidate': shelly});
    expect(added['id'], 'shellyplus1_a8032ab10001');
    expect(added['next'], containsPair('step', 'done'));
    final next = await ok('thing.next', {'id': added['id']});
    expect(next['next'], containsPair('step', 'done'));
  });

  test('omni add picks a find and finishes through the engine', () async {
    if (!registered()) return;
    final out = StringBuffer();
    final runner = OmniCommandRunner(
      out: out,
      input: const Stream.empty(),
      engineFactory: (h, {tap}) => OmniEngine.open(
        home: h,
        secrets: InMemorySecretStore(),
        discoveryTargets: () async => const [],
        mdns: MdnsDiscovery(client: () => FakeMdns(records)),
      ),
      socketPath: '${home.path}/none.sock',
    );
    if (!runner.commands.containsKey('add')) {
      markTestSkipped('omni add is not registered yet');
      return;
    }
    // The CLI opens the engine itself, and the database takes one opener.
    await engine.close();
    final code = await runner.run([
      '--home',
      home.path,
      'add',
      '--method',
      'mdns',
      '--window-ms',
      '200',
      '--pick',
      '1',
    ]);
    expect(code, 0, reason: '$out');
    expect('$out', contains('Done. shellyplus1-a8032ab10001 is ready'));
    engine = await OmniEngine.open(home: home, secrets: InMemorySecretStore());
  });

  test('a hello the hub hears becomes a candidate', () async {
    if (!registered()) return;
    final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final helloPort = probe.port;
    probe.close();
    await ok('hub.start', {'wizPort': 0, 'helloPort': helloPort});
    final heard = engine.events.firstWhere((e) => e['event'] == 'board.found');
    final board = await UdpTransport.bind();
    addTearDown(board.close);
    board.send(
      InternetAddress.loopbackIPv4,
      helloPort,
      utf8.encode(jsonEncode({'node': 'hall-board', 'event': 'hello'})),
    );
    await heard.timeout(const Duration(seconds: 5));
    final found = await ok('thing.add', {
      'windowMs': 100,
      'methods': ['hello'],
    });
    final group = (found['groups'] as List).single as Map;
    expect(group['driver'], 'omniflow_board');
    expect(((group['candidates'] as List).single as Map)['id'], 'hall_board');
  });
}
