@TestOn('mac-os')
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../../tool/hub/embed_templates.dart' show generateHubTemplates;
import '../devices/fake_mdns.dart';

String octal(int mode) => (mode & int.parse('777', radix: 8)).toRadixString(8);

/// Records what would have run, so no test reaches launchctl.
class FakeRunner {
  final calls = <List<String>>[];
  var failWith = <String, int>{};

  Future<ProcessResult> call(String exe, List<String> args) async {
    calls.add([exe, ...args]);
    if (exe == '/usr/bin/id') return ProcessResult(0, 0, '501\n', '');
    final code = failWith[args.isEmpty ? exe : args.first] ?? 0;
    return ProcessResult(0, code, '', code == 0 ? '' : 'refused');
  }
}

/// Makes an OpenSSH public key with ssh-keygen, which only writes files.
Future<String> keygen(Directory dir, String name, String type) async {
  final path = '${dir.path}/$name';
  final r = await Process.run('/usr/bin/ssh-keygen', [
    '-q',
    '-t',
    type,
    if (type == 'rsa') ...['-b', '2048'],
    '-N',
    '',
    '-C',
    'test@$name',
    '-f',
    path,
  ]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return path;
}

/// `ssh-keygen -l` of [path]: `<bits> SHA256:... comment (TYPE)`.
Future<List<String>> keygenFingerprint(String path) async {
  final r = await Process.run('/usr/bin/ssh-keygen', ['-l', '-f', path]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return '${r.stdout}'.trim().split(' ');
}

void main() {
  late Directory tmp;
  late Directory home;
  late Directory userHome;
  late FakeRunner runner;
  late InMemorySecretStore secrets;

  String sock() => '${home.path}/omni.sock';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('omni_hub_cli');
    home = Directory('${tmp.path}/h')..createSync();
    userHome = Directory('${tmp.path}/u')..createSync();
    runner = FakeRunner();
    secrets = InMemorySecretStore();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  HubEnvironment env({List<String>? hostKeys}) => HubEnvironment(
    userHome: userHome.path,
    hostKeyFiles: hostKeys ?? const [],
    run: runner.call,
    secrets: secrets,
    now: () => DateTime(2026, 11, 12, 3, 30),
  );

  Future<OmniEngine> openEngine() => OmniEngine.open(
    home: home,
    secrets: secrets,
    mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
  );

  Future<(int, String, String)> omni(
    List<String> args, {
    Stream<List<int>>? input,
    HubEnvironment? hub,
    bool withHome = false,
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runOmni(
      [
        if (withHome) ...['--home', home.path],
        ...args,
      ],
      runner: OmniCommandRunner(
        out: out,
        input: input ?? const Stream.empty(),
        socketPath: sock(),
        hubEnvironment: hub ?? env(),
        engineFactory: (h, {tap}) =>
            OmniEngine.open(home: home, secrets: secrets, tap: tap),
      ),
      err: err,
    );
    return (code, out.toString(), err.toString());
  }

  Map<String, Object?> json(String out) =>
      Map<String, Object?>.from(jsonDecode(out) as Map);

  test('the embedded templates match tool/hub', () {
    expect(
      File('lib/src/cli/hub_templates.g.dart').readAsStringSync(),
      generateHubTemplates(Directory('tool/hub')),
      reason: 'run dart run tool/hub/embed_templates.dart',
    );
  });

  group('omni hub attach', () {
    late OmniEngine engine;
    late LocalServer server;

    setUp(() async {
      engine = await openEngine();
      server = await LocalServer.start(engine, home: home);
    });

    tearDown(() async {
      await server.close();
      await engine.close();
    });

    test('copies lines both ways and names itself with hello', () async {
      final input = StreamController<List<int>>();
      final out = StringBuffer();
      final runnerDone = runOmni(
        ['hub', 'attach'],
        runner: OmniCommandRunner(
          out: out,
          input: input.stream,
          socketPath: sock(),
          hubEnvironment: env(),
          engineFactory: (h, {tap}) => throw StateError('opened the engine'),
        ),
      );
      input.add(
        utf8.encode(
          '${jsonEncode({
            'id': 1,
            'command': 'hello',
            'args': {'client': 'omniflow-app', 'phone': 'phone'},
          })}\n',
        ),
      );
      // A line split across two writes still goes as one line.
      final status = jsonEncode({'id': 2, 'command': 'engine.status'});
      input.add(utf8.encode(status.substring(0, 10)));
      input.add(utf8.encode('${status.substring(10)}\n'));
      input.add(
        utf8.encode('${jsonEncode({'id': 3, 'command': 'hub.clients'})}\n'),
      );
      await input.close();
      expect(await runnerDone, 0);
      final replies = [
        for (final l in const LineSplitter().convert(out.toString()))
          jsonDecode(l) as Map,
      ];
      expect(replies.map((r) => r['id']), [1, 2, 3]);
      expect(replies[0]['result'], containsPair('ok', true));
      expect((replies[1]['result'] as Map)['version'], isA<String>());
      final clients = (replies[2]['result'] as Map)['clients'] as List;
      expect(clients, [
        allOf(
          containsPair('client', 'omniflow-app'),
          containsPair('phone', 'phone'),
        ),
      ]);
      expect(engine.hubClients.list(), isEmpty, reason: 'gone once closed');
    });

    test('a line over 8 MiB is dropped and the next one answered', () async {
      final input = StreamController<List<int>>();
      final out = StringBuffer();
      final done = runOmni(
        ['hub', 'attach'],
        runner: OmniCommandRunner(
          out: out,
          input: input.stream,
          socketPath: sock(),
          hubEnvironment: env(),
        ),
      );
      final big = List<int>.filled(1 << 20, 0x61);
      for (var i = 0; i < 9; i++) {
        input.add(big);
      }
      input.add([0x0A]);
      input.add(
        utf8.encode('${jsonEncode({'id': 7, 'command': 'engine.status'})}\n'),
      );
      await input.close();
      expect(await done, 0);
      final lines = const LineSplitter().convert(out.toString());
      expect(lines, hasLength(2));
      final dropped = jsonDecode(lines.first) as Map;
      expect(dropped['id'], isNull);
      expect('${dropped['result']}', contains('over 8388608 bytes'));
      expect((jsonDecode(lines.last) as Map)['id'], 7);
    });

    test('a bad hello is refused and the connection stays', () async {
      final client = (await LocalClient.connect(sock()))!;
      final bad = await client.handle('hello', {'client': ''});
      expect(bad['ok'], isFalse);
      expect((bad['error'] as Map)['type'], 'invalid');
      final good = await client.handle('hello', {'client': 'omni'});
      expect(good, containsPair('version', isA<String>()));
      await client.close();
    });

    test('omni hub status reads the running hub', () async {
      final watcher = (await LocalClient.connect(sock()))!;
      await watcher.handle('hello', {'client': 'omniflow-app', 'phone': 'p1'});
      final (code, out, err) = await omni(['hub', 'status']);
      expect(code, 0, reason: err);
      final status = json(out);
      expect(status['version'], isA<String>());
      expect(status['uptimeSeconds'], isA<int>());
      expect(status['loadIssues'], isA<List<Object?>>());
      expect(status['lastRun'], isNull);
      expect(status['clients'] as List, contains(containsPair('phone', 'p1')));
      await watcher.close();
    });
  });

  test('attach and status refuse when no hub runs, in one line', () async {
    for (final verb in ['attach', 'status', 'clients']) {
      final (code, out, err) = await omni(['hub', verb]);
      expect(code, 69, reason: verb);
      expect(out, isEmpty);
      expect(err.trim(), 'omni: no omni hub is running');
    }
  });

  group('omni hub install', () {
    test('--dry-run prints the files and writes nothing', () async {
      final (code, out, err) = await omni(['hub', 'install', '--dry-run']);
      expect(code, 0, reason: err);
      final agents = '${userHome.path}/Library/LaunchAgents';
      expect(
        out,
        contains('Would write $agents/com.jashnm.omniflow.hub.plist'),
      );
      expect(
        out,
        contains('Would write $agents/com.jashnm.omniflow.backup.plist'),
      );
      expect(out, contains('<key>RunAtLoad</key>\n  <true/>'));
      expect(out, contains('<key>KeepAlive</key>\n  <true/>'));
      expect(
        out,
        contains(
          '    <string>${userHome.path}/.local/bin/omni</string>\n'
          '    <string>hub</string>\n'
          '    <string>--quiet</string>',
        ),
      );
      expect(out, contains('${userHome.path}/Library/Logs/OmniFlow/hub.log'));
      expect(out, contains('<string>backup</string>'));
      expect(out, contains('${userHome.path}/OmniFlow/backups'));
      expect(out, contains('launchctl bootstrap gui/<uid>'));
      expect(out, contains('/etc/ssh/sshd_config.d/omniflow.conf'));
      expect(out, contains('PasswordAuthentication no'));
      expect(out, contains('KbdInteractiveAuthentication no'));
      expect(Directory('${userHome.path}/Library').existsSync(), isFalse);
      expect(runner.calls, isEmpty);
    });

    test('writes valid plists and loads them with launchctl', () async {
      final bin = File('${userHome.path}/.local/bin/omni')
        ..createSync(recursive: true);
      final (code, out, err) = await omni([
        '--home',
        home.path,
        'hub',
        'install',
      ]);
      expect(code, 0, reason: err);
      final agents = '${userHome.path}/Library/LaunchAgents';
      final hubPlist = '$agents/com.jashnm.omniflow.hub.plist';
      final backupPlist = '$agents/com.jashnm.omniflow.backup.plist';
      for (final p in [hubPlist, backupPlist]) {
        // plutil only reads the file.
        final lint = await Process.run('/usr/bin/plutil', ['-lint', p]);
        expect(lint.exitCode, 0, reason: '${lint.stdout}');
      }
      final args = await Process.run('/usr/bin/plutil', [
        '-extract',
        'ProgramArguments',
        'json',
        '-o',
        '-',
        hubPlist,
      ]);
      expect(jsonDecode('${args.stdout}'), [
        bin.path,
        '--home',
        home.absolute.path,
        'hub',
        '--quiet',
      ]);
      expect(
        Directory('${userHome.path}/Library/Logs/OmniFlow').existsSync(),
        isTrue,
      );
      expect(runner.calls, [
        ['/usr/bin/id', '-u'],
        ['/bin/launchctl', 'bootout', 'gui/501/com.jashnm.omniflow.hub'],
        ['/bin/launchctl', 'bootstrap', 'gui/501', hubPlist],
        ['/bin/launchctl', 'bootout', 'gui/501/com.jashnm.omniflow.backup'],
        ['/bin/launchctl', 'bootstrap', 'gui/501', backupPlist],
      ]);
      expect(out, contains('PasswordAuthentication no'));
    });

    test('refuses when the binary is missing or the path is odd', () async {
      final (code, _, err) = await omni(['hub', 'install']);
      expect(code, 64);
      expect(err, contains('there is no omni at'));
      final (odd, _, oddErr) = await omni([
        'hub',
        'install',
        '--dry-run',
        '--binary',
        '/tmp/a b/omni',
      ]);
      expect(odd, 64);
      expect(oddErr, contains('--binary must be an absolute path'));
      expect(runner.calls, isEmpty);
    });
  });

  group('phones in authorized_keys', () {
    late String key;
    late String otherKey;

    setUp(() async {
      key = (await File(
        '${await keygen(tmp, 'phone_key', 'ed25519')}.pub',
      ).readAsString()).trim();
      otherKey = (await File(
        '${await keygen(tmp, 'other_key', 'ecdsa')}.pub',
      ).readAsString()).trim();
    });

    File authorizedKeys() => File('${userHome.path}/.ssh/authorized_keys');

    test('allow writes one restricted line, 0600 in a 0700 .ssh', () async {
      final (code, out, err) = await omni([
        'hub',
        'allow',
        'jade_pixel',
        key,
        '--from',
        '192.168.1.0/24,100.64.0.0/10',
      ]);
      expect(code, 0, reason: err);
      expect(json(out), containsPair('changed', true));
      final parts = key.split(' ');
      expect(
        authorizedKeys().readAsStringSync(),
        'restrict,from="192.168.1.0/24,100.64.0.0/10",'
        'command="${userHome.path}/.local/bin/omni hub attach" '
        '${parts[0]} ${parts[1]} omniflow-jade_pixel\n',
      );
      expect(octal(authorizedKeys().statSync().mode), '600');
      expect(octal(Directory('${userHome.path}/.ssh').statSync().mode), '700');
      final fingerprint = await keygenFingerprint('${tmp.path}/phone_key.pub');
      expect(json(out)['fingerprint'], fingerprint[1]);

      final (again, againOut, _) = await omni([
        'hub',
        'allow',
        'jade_pixel',
        key,
        '--from',
        '192.168.1.0/24,100.64.0.0/10',
      ]);
      expect(again, 0);
      expect(json(againOut), containsPair('changed', false));
      expect(
        const LineSplitter().convert(authorizedKeys().readAsStringSync()),
        hasLength(1),
      );
    });

    test('the attach command carries --home when the hub uses one', () async {
      final (code, _, err) = await omni([
        '--home',
        home.path,
        'hub',
        'allow',
        'p',
        key,
      ]);
      expect(code, 0, reason: err);
      expect(
        authorizedKeys().readAsStringSync(),
        contains(
          'command="${userHome.path}/.local/bin/omni --home '
          '${home.absolute.path} hub attach"',
        ),
      );
    });

    test('revoke removes only that line, and phones lists them', () async {
      Directory('${userHome.path}/.ssh').createSync();
      authorizedKeys().writeAsStringSync('ssh-ed25519 AAAAmine me@laptop\n');
      expect((await omni(['hub', 'allow', 'one', key])).$1, 0);
      expect((await omni(['hub', 'allow', 'two', otherKey])).$1, 0);
      final (_, listed, _) = await omni(['hub', 'phones']);
      final phones = json(listed)['phones'] as List;
      expect(phones.map((p) => (p as Map)['name']), ['one', 'two']);
      expect((phones.last as Map)['type'], 'ecdsa-sha2-nistp256');

      final (code, out, _) = await omni(['hub', 'revoke', 'one']);
      expect(code, 0);
      expect(json(out), containsPair('removed', true));
      final lines = const LineSplitter().convert(
        authorizedKeys().readAsStringSync(),
      );
      expect(lines, hasLength(2));
      expect(lines.first, 'ssh-ed25519 AAAAmine me@laptop');
      expect(lines.last, endsWith('omniflow-two'));
      final (missing, _, _) = await omni(['hub', 'revoke', 'one']);
      expect(missing, 1);
    });

    test('one name per key and one key per name', () async {
      expect((await omni(['hub', 'allow', 'one', key])).$1, 0);
      final (sameName, out, _) = await omni(['hub', 'allow', 'one', otherKey]);
      expect(sameName, 1);
      expect('${json(out)['error']}', contains('revoke one first'));
      final (sameKey, out2, _) = await omni(['hub', 'allow', 'two', key]);
      expect(sameKey, 1);
      expect('${json(out2)['error']}', contains('already allowed as one'));
    });

    test('a bad name, key or range is refused', () async {
      final rsa = (await File(
        '${await keygen(tmp, 'rsa_key', 'rsa')}.pub',
      ).readAsString()).trim();
      for (final (args, why) in [
        (['bad name', key], 'NAME is 1 to 32'),
        (['Pixel', key], 'NAME is 1 to 32'),
        (['a' * 33, key], 'NAME is 1 to 32'),
        (['x;rm', key], 'NAME is 1 to 32'),
        (['p', 'command="sh" $key'], 'with no options'),
        (['p', 'restrict $key'], 'with no options'),
        (['p', '$key\nssh-ed25519 AAAA'], 'one line'),
        (['p', rsa], 'starting ssh-ed25519 or ecdsa-sha2-nistp256'),
        (['p', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5'], 'wrong length'),
        (['p', 'ssh-ed25519 !!!'], 'not valid base64'),
        (['p', key, '--from', '10.0.0.0/40'], '--from is addresses'),
        (['p', key, '--from', '"x"'], '--from is addresses'),
      ]) {
        final (code, _, err) = await omni(['hub', 'allow', ...args]);
        expect(code, 64, reason: '$args');
        expect(err, contains(why), reason: '$args');
      }
      expect(authorizedKeys().existsSync(), isFalse);
    });

    test('allow makes the phone thing, with its person', () async {
      Future<Map<String, Object?>?> thing(String id) async {
        final engine = await openEngine();
        try {
          final r = await engine.handle('device.get', {'id': id});
          return r['ok'] == true
              ? Map<String, Object?>.from(r['device'] as Map)
              : null;
        } finally {
          await engine.close();
        }
      }

      final (missing, missingOut, _) = await omni([
        'hub',
        'allow',
        'asha_phone',
        key,
        '--person',
        'asha',
      ]);
      expect(missing, 1);
      expect(
        '${json(missingOut)['error']}',
        contains('there is no person asha on the hub'),
      );
      expect(authorizedKeys().existsSync(), isFalse);
      expect(await thing('asha_phone'), isNull);

      final engine = await openEngine();
      await engine.handle('device.add', {'id': 'asha', 'driver': 'person'});
      await engine.handle('device.add', {'id': 'lamp', 'driver': 'person'});
      await engine.close();

      final (code, out, err) = await omni([
        'hub',
        'allow',
        'asha_phone',
        key,
        '--person',
        'asha',
      ]);
      expect(code, 0, reason: err);
      expect(json(out)['phone'], {
        'id': 'asha_phone',
        'created': true,
        'person': 'asha',
      });
      final phone = (await thing('asha_phone'))!;
      expect(phone['driver'], 'phone');
      expect((phone['settings'] as Map)['person'], 'asha');

      final (again, againOut, _) = await omni([
        'hub',
        'allow',
        'asha_phone',
        key,
        '--person',
        'asha',
      ]);
      expect(again, 0);
      expect(json(againOut), containsPair('changed', false));
      expect(json(againOut)['phone'], containsPair('created', false));

      // Readings that name the phone are taken now.
      final reading = await openEngine();
      final battery = await reading.handle('phone.battery', {
        'level': 70,
        'phone': 'asha_phone',
      });
      expect(battery['ok'], isTrue, reason: '$battery');
      await reading.close();

      final (taken, takenOut, _) = await omni([
        'hub',
        'allow',
        'lamp',
        otherKey,
      ]);
      expect(taken, 1);
      expect('${json(takenOut)['error']}', contains('not a phone'));
      expect(
        const LineSplitter().convert(authorizedKeys().readAsStringSync()),
        hasLength(1),
      );

      final (revoked, revokedOut, _) = await omni([
        'hub',
        'revoke',
        'asha_phone',
      ]);
      expect(revoked, 0);
      expect('${json(revokedOut)['note']}', contains('stays on the hub'));
      expect(await thing('asha_phone'), isNotNull);
    });

    test('a .ssh others can write is refused', () async {
      final dir = Directory('${userHome.path}/.ssh')..createSync();
      await Process.run('/bin/chmod', ['777', dir.path]);
      final (code, _, err) = await omni(['hub', 'allow', 'p', key]);
      expect(code, 77);
      expect(err, contains('writable by other users'));
    });
  });

  test('fingerprint prints each host key as ssh-keygen -l does', () async {
    final keys = [
      for (final (name, type) in [
        ('ssh_host_ed25519_key', 'ed25519'),
        ('ssh_host_ecdsa_key', 'ecdsa'),
        ('ssh_host_rsa_key', 'rsa'),
      ])
        '${await keygen(tmp, name, type)}.pub',
    ];
    final (code, out, err) = await omni([
      'hub',
      'fingerprint',
    ], hub: env(hostKeys: keys));
    expect(code, 0, reason: err);
    final listed = json(out)['keys'] as List;
    expect(listed, hasLength(3));
    for (final (i, path) in keys.indexed) {
      final want = await keygenFingerprint(path);
      final got = listed[i] as Map;
      expect(got['bits'], int.parse(want[0]), reason: path);
      expect(got['fingerprint'], want[1], reason: path);
      expect(got['file'], path);
    }
    final (none, _, _) = await omni(['hub', 'fingerprint']);
    expect(none, 1);
  });

  test('update swaps the binary in place and restarts the hub', () async {
    final installed = File('${userHome.path}/.local/bin/omni')
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    final fresh = File('${tmp.path}/omni-new')..writeAsStringSync('new');
    final (code, out, err) = await omni(['hub', 'update', fresh.path]);
    expect(code, 0, reason: err);
    expect(json(out), containsPair('restarted', true));
    expect(installed.readAsStringSync(), 'new');
    expect(octal(installed.statSync().mode), '755');
    expect(
      userHome.listSync(recursive: true).where((f) => f.path.contains('.new-')),
      isEmpty,
    );
    expect(runner.calls.last, [
      '/bin/launchctl',
      'kickstart',
      '-k',
      'gui/501/com.jashnm.omniflow.hub',
    ]);

    runner.failWith = {'kickstart': 3};
    final (failed, failedOut, _) = await omni(['hub', 'update', fresh.path]);
    expect(failed, 1);
    expect('${json(failedOut)['error']}', contains('Run omni hub install'));
    final (missing, _, _) = await omni(['hub', 'update', '${tmp.path}/nope']);
    expect(missing, 66);
  });

  test('backup writes a dated export and keeps the newest', () async {
    final dir = Directory('${tmp.path}/backups')..createSync();
    for (var d = 1; d <= 4; d++) {
      File('${dir.path}/omniflow-2026-11-0$d.json').writeAsStringSync('{}');
    }
    File('${dir.path}/notes.txt').writeAsStringSync('mine');
    final (code, out, err) = await omni([
      'hub',
      'backup',
      '--dir',
      dir.path,
      '--keep',
      '3',
    ]);
    expect(code, 0, reason: err);
    final written = File('${dir.path}/omniflow-2026-11-12.json');
    expect(json(out)['out'], written.path);
    expect(jsonDecode(written.readAsStringSync()), isA<Map<String, Object?>>());
    final left = dir.listSync().map((f) => f.uri.pathSegments.last).toSet();
    expect(left, {
      'omniflow-2026-11-12.json',
      'omniflow-2026-11-04.json',
      'omniflow-2026-11-03.json',
      'notes.txt',
    });
  });

  test('omni hub on its own still runs the hub', () async {
    final (code, out, err) = await omni([
      'hub',
      '--seconds',
      '0.2',
      '--wiz-port',
      '0',
      '--hello-port',
      '0',
      '--quiet',
    ], withHome: true);
    expect(code, 0, reason: err);
    final lines = const LineSplitter().convert(out);
    expect(lines, hasLength(1), reason: '--quiet prints only the start');
    expect(json(lines.single), containsPair('event', 'hub.started'));
    final (bad, _, badErr) = await omni(['hub', 'nope']);
    expect(bad, 64);
    expect(badErr, contains('Could not find a subcommand named "nope"'));
  });

  test('hub.discover lists Macs offering Remote Login', () async {
    const instance = 'Mac mini._ssh._tcp.local';
    final engine = await OmniEngine.open(
      home: home,
      secrets: secrets,
      mdns: MdnsDiscovery(
        client: () => FakeMdns([
          ptr('_ssh._tcp', instance),
          srv(instance, 'mac-mini.local', 22),
          a('mac-mini.local', '192.168.1.30'),
        ]),
      ),
    );
    try {
      final r = await engine.handle('hub.discover', {'windowMs': 300});
      expect(r['ok'], isTrue, reason: '$r');
      expect(r['hosts'], [
        {'name': 'Mac mini', 'host': '192.168.1.30', 'port': 22},
      ]);
      final bad = await engine.handle('hub.discover', {'windowMs': 1});
      expect((bad['error'] as Map)['type'], 'invalid');
      expect(agentReadCommands, containsAll(['hub.discover', 'hub.clients']));
    } finally {
      await engine.close();
    }
  });
}
