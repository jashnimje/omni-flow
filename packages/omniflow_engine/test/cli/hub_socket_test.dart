@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

String octal(int mode) => (mode & int.parse('777', radix: 8)).toRadixString(8);

Future<void> chmod(String mode, String path) async {
  final r = await Process.run('/bin/chmod', [mode, path]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
}

/// Leaves a socket file that nothing listens on, as a hub killed with
/// SIGKILL does. ServerSocket.close removes its own path, so the socket is
/// bound elsewhere and moved into place first.
Future<void> leaveStaleSocket(String path) async {
  final bound = '${File(path).parent.path}/bound.sock';
  final server = await ServerSocket.bind(
    InternetAddress(bound, type: InternetAddressType.unix),
    0,
  );
  File(bound).renameSync(path);
  await server.close();
  expect(
    FileSystemEntity.typeSync(path, followLinks: false),
    FileSystemEntityType.unixDomainSock,
  );
}

void main() {
  late Directory home;
  late InMemorySecretStore secrets;
  late OmniEngine engine;
  late PacketTap tap;
  LocalServer? server;

  String sock() => '${home.path}/omni.sock';

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_sock');
    secrets = InMemorySecretStore();
    tap = PacketTap();
    engine = await OmniEngine.open(home: home, secrets: secrets, tap: tap);
  });

  tearDown(() async {
    await server?.close();
    server = null;
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<LocalServer> serve() async =>
      server = await LocalServer.start(engine, home: home);

  /// The CLI as a user runs it, with an engine factory that fails the test
  /// if a command opens the engine instead of going through the hub.
  /// Runs [body] with the test's engine closed, so a hub or the CLI can
  /// take the database, and opens it again whatever happens.
  Future<void> withEngineClosed(Future<void> Function() body) async {
    await engine.close();
    try {
      await body();
    } finally {
      engine = await OmniEngine.open(home: home, secrets: secrets, tap: tap);
    }
  }

  Future<(int, String, String)> omni(
    List<String> args, {
    String stdin = '',
    bool hubOnly = true,
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runOmni(
      ['--home', home.path, ...args],
      runner: OmniCommandRunner(
        out: out,
        input: Stream.value(utf8.encode(stdin)),
        socketPath: sock(),
        engineFactory: (h, {tap}) => hubOnly
            ? throw StateError('opened the engine instead of the hub')
            : OmniEngine.open(home: h, secrets: secrets, tap: tap),
      ),
      err: err,
    );
    return (code, out.toString(), err.toString());
  }

  test('the socket is 0600 in a 0700 home, and gone after close', () async {
    await chmod('755', home.path);
    final s = await serve();
    expect(s.path, '${home.absolute.path}/omni.sock');
    expect(
      FileSystemEntity.typeSync(s.path),
      FileSystemEntityType.unixDomainSock,
    );
    expect(octal(FileStat.statSync(s.path).mode), '600');
    expect(octal(home.statSync().mode), '700');
    await s.close();
    expect(FileSystemEntity.typeSync(s.path), FileSystemEntityType.notFound);
  });

  test('a missing home is created at 0700', () async {
    final fresh = Directory('${home.path}/new_home');
    await preparePrivateHome(fresh);
    expect(octal(fresh.statSync().mode), '700');
  });

  test(
    'CLI commands go through the running hub, secrets from stdin included',
    () async {
      await serve();
      final bulb = await UdpTransport.bind();
      addTearDown(bulb.close);
      final sent = <Map>[];
      bulb.incoming.listen((d) {
        final m = jsonDecode(d.text) as Map;
        sent.add(m);
        bulb.send(
          d.address,
          d.port,
          utf8.encode(
            jsonEncode({
              'method': m['method'],
              'result': {'success': true},
            }),
          ),
        );
      });
      var (code, out, err) = await omni([
        'device',
        'add',
        'desk_lamp',
        '--driver',
        'philips_wiz_udp',
        '--host',
        '127.0.0.1',
        '--port',
        '${bulb.localPort}',
      ]);
      expect(code, 0, reason: '$out$err');
      expect(
        ((await engine.handle('device.get', {'id': 'desk_lamp'}))['device']
            as Map)['port'],
        bulb.localPort,
      );

      (code, out, err) = await omni([
        'device',
        'invoke',
        'desk_lamp',
        'brightness',
        'value=80',
      ]);
      expect(code, 0, reason: '$out$err');
      expect(sent.last['params'], containsPair('dimming', 80));

      (code, out, err) = await omni(['device', 'get', 'ghost']);
      expect(code, 1);
      expect(((jsonDecode(out) as Map)['error'] as Map)['type'], 'not_found');

      await engine.handle('device.add', {
        'id': 'plug',
        'driver': 'tuya_plug',
        'host': '127.0.0.1',
        'stableId': 'abc',
      });
      (code, out, err) = await omni([
        'secret',
        'set',
        'plug',
        'localKey',
      ], stdin: 'not-a-real-key\n');
      expect(code, 0, reason: '$out$err');
      expect(
        await secrets.read(deviceSecretKey('plug', 'localKey')),
        'not-a-real-key',
      );
      expect(out, isNot(contains('not-a-real-key')));

      (code, out, err) = await omni([
        'secret',
        'set-web',
        'ha_token',
      ], stdin: 'fixture-token\n');
      expect(code, 0, reason: '$out$err');
      expect(await secrets.read(webSecretKey('ha_token')), 'fixture-token');
      expect(out, isNot(contains('fixture-token')));
      final refused = await engine.handle('agent.call', {
        'command': 'web.secret.set',
        'args': {'name': 'ha_token', 'value': 'agent-value'},
      });
      expect((refused['error'] as Map)['type'], 'needs_user');
      expect(await secrets.read(webSecretKey('ha_token')), 'fixture-token');
    },
  );

  test('lookups inside CLI commands go through the hub too', () async {
    await serve();
    final saved = await engine.handle('flow.save', {
      'flow': {
        'schemaVersion': 1,
        'id': 'noop',
        'name': 'Noop',
        'nodes': [
          {'id': 'go', 'type': 'manual'},
          {
            'id': 'say',
            'type': 'notify',
            'config': {'title': 'hi'},
          },
        ],
        'edges': [
          {
            'id': 'a',
            'from': {'node': 'go', 'port': 'out'},
            'to': {'node': 'say', 'port': 'in'},
          },
        ],
      },
      'trusted': false,
    });
    expect(saved['ok'], isTrue, reason: '$saved');
    final (code, out, err) = await omni(['flow', 'approve', 'noop']);
    expect(code, 0, reason: '$out$err');
    expect(jsonDecode(out), containsPair('approved', true));
  });

  test(
    'omni hub serves the socket while it runs and removes it after',
    () => withEngineClosed(() async {
      final hubOut = StringBuffer();
      final hub =
          OmniCommandRunner(
            out: hubOut,
            input: const Stream.empty(),
            engineFactory: (h, {tap}) =>
                OmniEngine.open(home: h, secrets: secrets, tap: tap),
          ).run([
            '--home',
            home.path,
            'hub',
            '--seconds',
            // Long enough for both calls on a loaded machine: the whole
            // suite in parallel once took longer than 3 s to reach them.
            '15',
            '--wiz-port',
            '0',
            '--hello-port',
            '0',
          ]);
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (FileSystemEntity.typeSync(sock()) ==
          FileSystemEntityType.notFound) {
        if (DateTime.now().isAfter(deadline)) fail('no socket: $hubOut');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final (code, out, err) = await omni(['device', 'list']);
      expect(code, 0, reason: '$out$err');
      expect((jsonDecode(out) as Map)['devices'], isEmpty);
      final (statusCode, status, _) = await omni(['flow', 'list']);
      expect(statusCode, 0, reason: status);
      expect(await hub, 0);
      expect(FileSystemEntity.typeSync(sock()), FileSystemEntityType.notFound);
    }),
  );

  test('a stale socket file is replaced by the hub', () async {
    await leaveStaleSocket(sock());
    final s = await serve();
    final client = await LocalClient.connect(s.path);
    expect(client, isNotNull);
    expect((await client!.handle('engine.status', {}))['ok'], isTrue);
    await client.close();
  });

  test('with a stale socket and no hub, the CLI opens the engine', () async {
    await leaveStaleSocket(sock());
    await withEngineClosed(() async {
      final (code, out, err) = await omni(['device', 'list'], hubOnly: false);
      expect(code, 0, reason: '$out$err');
    });
  });

  test('a socket that still answers is another hub, and is refused', () async {
    await serve();
    final other = await Directory.systemTemp.createTemp('omni_sock2');
    addTearDown(() => other.delete(recursive: true));
    await expectLater(
      LocalServer.start(engine, home: other, path: sock()),
      throwsA(
        isA<LocalSocketException>().having((e) => e.exitCode, 'exitCode', 75),
      ),
    );
    final first = (await LocalClient.connect(sock()))!;
    addTearDown(first.close);
    expect((await first.handle('engine.status', {}))['ok'], isTrue);
  });

  test('a home other users can write is refused', () async {
    await chmod('775', home.path);
    await expectLater(
      serve(),
      throwsA(
        isA<LocalSocketException>().having(
          (e) => e.message,
          'message',
          contains('writable by other users'),
        ),
      ),
    );
    expect(FileSystemEntity.typeSync(sock()), FileSystemEntityType.notFound);

    var opened = false;
    final err = StringBuffer();
    final code = await runOmni(
      ['--home', home.path, 'hub', '--seconds', '0.1', '--wiz-port', '0'],
      runner: OmniCommandRunner(
        out: StringBuffer(),
        input: const Stream.empty(),
        engineFactory: (h, {tap}) {
          opened = true;
          return OmniEngine.open(home: h, secrets: secrets, tap: tap);
        },
      ),
      err: err,
    );
    expect(code, 77);
    expect(const LineSplitter().convert(err.toString()), hasLength(1));
    expect(err.toString(), contains('chmod 700'));
    expect(opened, isFalse);
    await chmod('700', home.path);
  });

  test('a client refuses a socket other users can open', () async {
    await serve();
    await chmod('666', sock());
    final (code, _, err) = await omni(['device', 'list']);
    expect(code, 77);
    expect(err, contains('open to other users'));
  });

  test('a client refuses a socket in a directory others can write', () async {
    await serve();
    await chmod('777', home.path);
    final (code, _, err) = await omni(['device', 'list']);
    await chmod('700', home.path);
    expect(code, 77);
    expect(err, contains('writable by other users'));
  });

  test('events stream to subscribers, packets only when asked', () async {
    await serve();
    final client = (await LocalClient.connect(sock()))!;
    addTearDown(client.close);
    final plain = <Map>[];
    final withPackets = <Map>[];
    final a = (await client.events()).listen(plain.add);
    final b = (await client.events(packets: true)).listen(withPackets.add);
    await engine.handle('device.add', {
      'id': 'desk_lamp',
      'driver': 'philips_wiz_udp',
      'host': '127.0.0.1',
    });
    await engine.devices.mergeState('desk_lamp', {'state': true});
    tap.record(
      CapturedPacket(
        transport: 'udp',
        direction: PacketDirection.outgoing,
        remote: '127.0.0.1:9',
        bytes: utf8.encode('{"method":"getPilot"}'),
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!withPackets.any((e) => e['event'] == 'packet.captured') ||
        !plain.any((e) => e['event'] == 'device.stateChanged')) {
      if (DateTime.now().isAfter(deadline)) fail('$plain $withPackets');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(plain.where((e) => e['event'] == 'packet.captured'), isEmpty);
    final changed = plain.firstWhere(
      (e) => e['event'] == 'device.stateChanged',
    );
    expect(((changed['device'] as Map)['state'] as Map)['state'], isTrue);
    await a.cancel();
    await b.cancel();
  });

  test('omni watch prints hub events and ends when the hub stops', () async {
    await serve();
    await engine.handle('device.add', {
      'id': 'desk_lamp',
      'driver': 'philips_wiz_udp',
      'host': '127.0.0.1',
    });
    final watch = omni(['watch', '--seconds', '30']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await engine.devices.mergeState('desk_lamp', {'state': true});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await server!.close();
    final (code, out, err) = await watch.timeout(const Duration(seconds: 10));
    expect(code, 0, reason: err);
    final events = const LineSplitter()
        .convert(out)
        .map((l) => (jsonDecode(l) as Map)['event'])
        .toList();
    expect(events.first, 'watch.started');
    expect(events, contains('device.stateChanged'));
  });

  test('a bad line gets an error and the connection keeps working', () async {
    await serve();
    final raw = await Socket.connect(
      InternetAddress(sock(), type: InternetAddressType.unix),
      0,
    );
    addTearDown(raw.destroy);
    final replies = raw
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((l) => jsonDecode(l) as Map)
        .asBroadcastStream();
    raw.write('not json\n');
    raw.write('{"id":2,"command":7}\n');
    raw.write('{"id":3,"command":"engine.status","args":{}}\n');
    raw.write('{"id":4,"subscribe":"everything"}\n');
    final got = await replies.take(4).toList();
    expect(got[0]['id'], isNull);
    expect((got[0]['result'] as Map)['ok'], isFalse);
    expect(((got[1]['result'] as Map)['error'] as Map)['type'], 'invalid');
    expect(got[2]['id'], 3);
    expect((got[2]['result'] as Map)['hubRunning'], isFalse);
    expect((got[3]['result'] as Map)['ok'], isFalse);
  });

  test(
    'a request over the hub limit fails at once instead of hanging',
    () async {
      await serve();
      final client = (await LocalClient.connect(sock()))!;
      addTearDown(client.close);
      final flow = {'name': 'x' * (8 << 20)};
      final result = await client
          .handle('flow.validate', {'flow': flow})
          .timeout(const Duration(seconds: 5));
      expect((result['error'] as Map)['type'], 'invalid');
      expect('${result['error']}', contains('over the omni hub limit'));
      final status = await client.handle('engine.status', {});
      expect(status['ok'], isTrue, reason: 'the connection still works');
    },
  );

  test(
    'a client of a hub that stops gets unavailable, not an exception',
    () async {
      await serve();
      final client = (await LocalClient.connect(sock()))!;
      await server!.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final result = await client.handle('engine.status', {});
      expect((result['error'] as Map)['type'], 'unavailable');
      await client.close();
      expect(await LocalClient.connect(sock()), isNull);
    },
  );

  test('a path too long for a Unix socket is refused before binding', () async {
    await expectLater(
      LocalServer.start(engine, home: home, path: '${home.path}/${'x' * 120}'),
      throwsA(
        isA<LocalSocketException>().having((e) => e.exitCode, 'exitCode', 73),
      ),
    );
  });
}
