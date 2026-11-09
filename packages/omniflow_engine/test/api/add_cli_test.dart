import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/cli/add_cli.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import '../devices/tv/fake_tvs.dart';
import 'thing_add_harness.dart';

const haInstance = 'Home._home-assistant._tcp.local';

final records = <ResourceRecord>[
  ptr('_home-assistant._tcp', haInstance),
  srv(haInstance, 'homeassistant.local', 8123),
  txt(haInstance, ['uuid=ha0001']),
  a('homeassistant.local', '192.168.1.5'),
];

void main() {
  late AddHarness engine;

  setUp(() async {
    engine = await AddHarness.open(
      mdns: MdnsDiscovery(client: () => FakeMdns(records)),
    );
  });

  tearDown(() => engine.shutdown());

  /// Runs `omni add` against the harness, with [stdin] as its input.
  Future<(int, String)> omniAdd(List<String> args, {String stdin = ''}) async {
    final out = StringBuffer();
    final runner = CommandRunner<int>('omni', 'test')
      ..addCommand(
        AddCommand(
          connect: () async => engine,
          out: out,
          input: Stream.value(utf8.encode(stdin)),
        ),
      );
    final code = await runner.run(['add', ...args]);
    return (code ?? 0, out.toString());
  }

  const mdnsOnly = ['--method', 'mdns', '--window-ms', '200'];

  test('omni add lists what it found and what is added by address', () async {
    final (code, out) = await omniAdd(mdnsOnly);
    expect(code, 0, reason: out);
    expect(out, contains('Home Assistant'));
    expect(out, contains('  1. Home at 192.168.1.5:8123 via mdns'));
    expect(out, contains('Add by address with --driver and --host: '));
    expect(out, contains('lg_webos_tv'));
    expect(out, isNot(contains('phone,')));
    expect(await engine.handle('device.get', {'id': 'home'}), {
      'ok': false,
      'error': containsPair('type', 'not_found'),
    });
  });

  test('omni add --pick walks the secret and the settings from stdin, '
      'and never prints the secret', () async {
    final listing = (await omniAdd(mdnsOnly)).$2.split('\n');
    expect(listing[1], endsWith('(home_assistant_entity):'));
    expect(listing[2], '  1. Home at 192.168.1.5:8123 via mdns');

    final (code, out) = await omniAdd([
      ...mdnsOnly,
      '--pick',
      '1',
      '--id',
      'kitchen',
    ], stdin: 'fixture-token\nlight.kitchen\nlight\n');
    expect(code, 0, reason: out);
    expect(out, contains('Added kitchen'));
    expect(out, contains('Stored token'));
    expect(out, contains('Done. Home is ready'));
    expect(out, isNot(contains('fixture-token')));
    expect(
      await engine.secrets.read(deviceSecretKey('kitchen', 'token')),
      'fixture-token',
    );
    final device = (await engine.ok('device.get', {'id': 'kitchen'}))['device'];
    expect(((device as Map)['settings'] as Map)['entityId'], 'light.kitchen');
  });

  test('a secret is never taken from --set', () async {
    final (code, out) = await omniAdd([
      '--driver',
      'home_assistant_sensor',
      '--host',
      '192.168.1.5',
      '--id',
      'temp',
      '--set',
      'token=leak',
    ]);
    expect(code, 1);
    expect(out, contains('token is a secret'));
    expect(await engine.secrets.read(deviceSecretKey('temp', 'token')), isNull);
  });

  test('omni add stops when stdin ends, and --resume carries on', () async {
    final (code, out) = await omniAdd([
      '--driver',
      'home_assistant_sensor',
      '--host',
      '192.168.1.5',
      '--id',
      'temp',
      '--set',
      'entityId=sensor.temp',
    ]);
    expect(code, addIncompleteExitCode, reason: out);
    expect(out, contains('Continue with: omni add --resume temp'));

    final (resumed, more) = await omniAdd([
      '--resume',
      'temp',
      '--json',
    ], stdin: 'fixture-token\n');
    expect(resumed, 0, reason: more);
    expect(more, contains('Done. temp is ready'));
    expect(more, isNot(contains('fixture-token')));
    final replies = [
      for (final l in more.split('\n'))
        if (l.startsWith('{')) jsonDecode(l) as Map,
    ];
    expect(replies.last['next'], containsPair('step', 'done'));
  });

  test('omni add pairs a TV and finishes', () async {
    final tv = await FakeWebOsTv.start();
    addTearDown(tv.close);
    final args = [
      '--driver',
      'lg_webos_tv',
      '--host',
      '127.0.0.1',
      '--port',
      '${tv.port}',
      '--id',
      'lounge',
    ];
    final (stopped, first) = await omniAdd([...args, '--no-pair']);
    expect(stopped, addIncompleteExitCode);
    expect(first, contains('Pair: '));
    expect(first, contains('Allow'));

    final (code, out) = await omniAdd(['--resume', 'lounge']);
    expect(code, 0, reason: out);
    expect(out, contains('lounge is paired'));
    expect(out, contains('Done. lounge is ready'));
    expect(
      await engine.secrets.read(deviceSecretKey('lounge', 'clientKey')),
      isNotNull,
    );
  });

  test('omni add configures a board pin set given as JSON', () async {
    final (code, out) = await omniAdd([
      '--driver',
      'omniflow_board',
      '--host',
      '127.0.0.1',
      '--id',
      'desk',
      '--no-provision',
    ], stdin: '{"relay": {"pin": 4, "mode": "out"}}\n');
    expect(out, contains('Settings: Name the pins'));
    expect(code, 0, reason: out);
    final device = (await engine.ok('device.get', {'id': 'desk'}))['device'];
    expect(((device as Map)['settings'] as Map)['pins'], {
      'relay': {'pin': 4, 'mode': 'out'},
    });
  });

  test(
    '--set keeps a JSON object whole and a number-like UID as text',
    () async {
      final (code, out) = await omniAdd([
        '--driver',
        'omniflow_board',
        '--host',
        '127.0.0.1',
        '--id',
        'desk',
        '--no-provision',
        '--set',
        'pins={"relay":{"pin":4,"mode":"out"},"button":{"pin":5,"mode":"in"}}',
      ]);
      expect(code, 0, reason: out);
      final board = (await engine.ok('device.get', {'id': 'desk'}))['device'];
      expect(((board as Map)['settings'] as Map)['pins'], {
        'relay': {'pin': 4, 'mode': 'out'},
        'button': {'pin': 5, 'mode': 'in'},
      });

      final (tagCode, tagOut) = await omniAdd([
        '--driver',
        'nfc_tag',
        '--id',
        'card',
        '--set',
        'uid=12E45678',
      ]);
      expect(tagCode, 0, reason: tagOut);
      final tag = (await engine.ok('device.get', {'id': 'card'}))['device'];
      expect(((tag as Map)['settings'] as Map)['uid'], '12E45678');
    },
  );

  test('parseSettings keeps scalars as text and objects structured', () {
    expect(parseSettings(['id=0042', 'on=true', 'n=1,2']), {
      'id': '0042',
      'on': 'true',
      'n': '1,2',
    });
    expect(parseSettings(['l=[1,2]']), {
      'l': [1, 2],
    });
    expect(() => parseSettings(['x']), throwsA(isA<UsageException>()));
  });

  test('omni add refuses arguments that do not go together', () async {
    await expectLater(
      omniAdd(['--pick', '1', '--resume', 'x']),
      throwsA(isA<UsageException>()),
    );
    await expectLater(omniAdd(['extra']), throwsA(isA<UsageException>()));
    await expectLater(
      omniAdd([...mdnsOnly, '--pick', '9']),
      throwsA(isA<UsageException>()),
    );
  });
}
