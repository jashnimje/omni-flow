import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

/// A loopback Shelly Gen1 relay that records each turn it is told.
class FakeRelay {
  FakeRelay._(this._server) {
    _server.listen((req) async {
      final turn = req.uri.queryParameters['turn'];
      if (req.uri.path == '/relay/0' && turn != null) turns.add(turn);
      final on = turns.isNotEmpty && turns.last == 'on';
      req.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(
            req.uri.path == '/status'
                ? {
                    'relays': [
                      {'ison': on},
                    ],
                  }
                : {'ison': on},
          ),
        );
      await req.response.close();
    });
  }

  static Future<FakeRelay> start() async =>
      FakeRelay._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final turns = <String>[];

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}

void main() {
  late Directory home;
  late FakeRelay relay;
  late FakeRelay fan;

  Future<OmniEngine> open(Directory home, {PacketTap? tap}) => OmniEngine.open(
    home: home,
    secrets: InMemorySecretStore(),
    tap: tap,
    discoveryTargets: () async => const [],
    mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
  );

  Future<void> ok(
    OmniEngine engine,
    String command,
    Map<String, Object?> a,
  ) async {
    final result = await engine.handle(command, a);
    expect(result['ok'], isTrue, reason: '$command $result');
  }

  /// Two relays and a rule "when the relay turns on, turn the fan on",
  /// after [wait] when given.
  Future<void> seed({String? wait}) async {
    final engine = await open(home);
    try {
      for (final (id, device) in [('relay', relay), ('fan', fan)]) {
        await ok(engine, 'device.add', {
          'id': id,
          'name': id,
          'driver': 'shelly_gen1_relay',
          'host': '127.0.0.1',
          'port': device.port,
        });
      }
      await ok(engine, 'automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Fan follows relay',
          'when': [
            {
              'on': 'relay.power',
              'change': {'to': true},
            },
          ],
          'then': [?wait, 'fan.power=true'],
        },
      });
    } finally {
      await engine.close();
    }
  }

  Future<(int, Duration)> omni(List<String> args) async {
    final out = StringBuffer();
    final watch = Stopwatch()..start();
    final code = await OmniCommandRunner(
      out: out,
      input: const Stream.empty(),
      engineFactory: open,
      socketPath: '${home.path}/no-hub.sock',
    ).run(['--home', home.path, ...args]);
    return (code, watch.elapsed);
  }

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_one_shot');
    relay = await FakeRelay.start();
    fan = await FakeRelay.start();
  });

  tearDown(() async {
    await relay.close();
    await fan.close();
    await home.delete(recursive: true);
  });

  test(
    'a CLI change fires the rule it triggers before the engine closes',
    () async {
      await seed();
      final (code, _) = await omni([
        'device',
        'invoke',
        'relay',
        'power',
        'value=true',
      ]);
      expect(code, 0);
      expect(relay.turns, ['on']);
      expect(fan.turns, ['on']);
    },
  );

  test('a command that triggers nothing does not wait', () async {
    await seed();
    final (code, took) = await omni([
      'device',
      'invoke',
      'relay',
      'power',
      'value=false',
    ]);
    expect(code, 0);
    expect(fan.turns, isEmpty);
    expect(took, lessThan(const Duration(milliseconds: 1500)));
  });

  test('a rule still waiting after 2 s is cut off, not waited for', () async {
    await seed(wait: 'wait:10s');
    final (code, took) = await omni([
      'device',
      'invoke',
      'relay',
      'power',
      'value=true',
    ]);
    expect(code, 0);
    expect(fan.turns, isEmpty);
    expect(took, greaterThanOrEqualTo(const Duration(seconds: 2)));
    expect(took, lessThan(const Duration(seconds: 6)));
  });
}
