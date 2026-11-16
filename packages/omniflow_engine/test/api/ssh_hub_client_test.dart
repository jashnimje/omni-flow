@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

/// A [HubChannel] that runs `omni hub attach` in this process, with its
/// stdin and stdout as streams, the way sshd would run it.
class AttachChannel implements HubChannel {
  AttachChannel._(this._toHub, this._fromHub, this.finished);

  static Future<AttachChannel> open(String socketPath) async {
    final toHub = StreamController<List<int>>();
    final fromHub = StreamController<List<int>>();
    final sink = _ByteSink(fromHub);
    final finished = runOmni(
      ['hub', 'attach'],
      runner: OmniCommandRunner(
        out: sink,
        input: toHub.stream,
        socketPath: socketPath,
        engineFactory: (h, {tap}) => throw StateError('opened the engine'),
      ),
    ).whenComplete(fromHub.close);
    return AttachChannel._(toHub, fromHub, finished);
  }

  final StreamController<List<int>> _toHub;
  final StreamController<List<int>> _fromHub;
  final Future<int> finished;

  @override
  Stream<List<int>> get input => _fromHub.stream;

  @override
  String get errors => '';

  @override
  void add(List<int> bytes) => _toHub.add(bytes);

  @override
  Future<void> close() => _toHub.close();
}

class _ByteSink implements StringSink {
  _ByteSink(this._out);

  final StreamController<List<int>> _out;

  @override
  void write(Object? object) => _out.add(utf8.encode('$object'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');
}

void main() {
  late Directory home;
  late InMemorySecretStore secrets;
  late OmniEngine engine;
  LocalServer? server;

  String sock() => '${home.path}/omni.sock';

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_ssh_hub');
    secrets = InMemorySecretStore();
    engine = await OmniEngine.open(
      home: home,
      secrets: secrets,
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
    server = await LocalServer.start(engine, home: home);
  });

  tearDown(() async {
    await server?.close();
    server = null;
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<HubChannel> socketChannel() async =>
      SocketHubChannel((await LocalClient.openSocket(sock()))!);

  group('the newline JSON over a channel', () {
    test('commands, the hello and events go through attach', () async {
      final channels = <AttachChannel>[];
      final hub = await HubConnection.connect(() async {
        final c = await AttachChannel.open(sock());
        channels.add(c);
        return c;
      }, hello: const {'client': 'omniflow-app', 'phone': 'phone'});
      expect(hub.hubVersion, isA<String>());
      final events = await hub.events();
      final seen = <Map<String, Object?>>[];
      final sub = events.listen(seen.add);
      final set = await hub.handle('var.set', {
        'name': 'Mood',
        'value': 'calm',
      });
      expect(set['ok'], isTrue, reason: '$set');
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!seen.any((e) => e['event'] == 'variable.changed') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(seen.map((e) => e['event']), contains('variable.changed'));
      final clients = engine.hubClients.list();
      expect(clients, hasLength(2));
      expect(
        clients.every((c) => c['client'] == 'omniflow-app'),
        isTrue,
        reason: '$clients',
      );
      expect(clients.where((c) => c['events'] == true), hasLength(1));
      await sub.cancel();
      await hub.close();
      for (final c in channels) {
        expect(await c.finished, 0);
      }
    });

    test('a lost channel answers unavailable, then reconnects', () async {
      var opened = 0;
      final hub = await HubConnection.connect(() async {
        opened++;
        return socketChannel();
      });
      expect((await hub.handle('device.list', {}))['ok'], isTrue);
      await server!.close();
      server = null;
      final lost = await hub.handle('device.list', {});
      expect((lost['error'] as Map)['type'], 'unavailable');
      server = await LocalServer.start(engine, home: home);
      final back = await hub.handle('device.list', {});
      expect(back['ok'], isTrue, reason: '$back');
      expect(opened, greaterThanOrEqualTo(2));
      await hub.close();
      final closed = await hub.handle('device.list', {});
      expect((closed['error'] as Map)['type'], 'unavailable');
    });

    test('an event stream says when it is lost and restored', () async {
      final hub = await HubConnection.connect(
        socketChannel,
        retryDelays: const [Duration(milliseconds: 50)],
      );
      final seen = <Map<String, Object?>>[];
      final sub = (await hub.events()).listen(seen.add);
      await server!.close();
      server = null;
      Future<void> waitFor(String state) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!seen.any((e) => e['state'] == state)) {
          if (DateTime.now().isAfter(deadline)) fail('no $state in $seen');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      await waitFor('lost');
      server = await LocalServer.start(engine, home: home);
      await waitFor('restored');
      seen.clear();
      await engine.handle('var.set', {'name': 'Mood', 'value': 'back'});
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!seen.any((e) => e['event'] == 'variable.changed') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(seen.map((e) => e['event']), contains('variable.changed'));
      await sub.cancel();
      await hub.close();
    });

    test('another major or minor version is refused with both', () async {
      for (final (local, says) in [
        ('9.1.0', 'Update the hub'),
        ('0.0.1', 'Update the app'),
      ]) {
        await expectLater(
          HubConnection.connect(socketChannel, localVersion: local),
          throwsA(
            isA<HubLinkException>()
                .having((e) => e.type, 'type', 'version_mismatch')
                .having((e) => e.message, 'message', contains(says))
                .having(
                  (e) => e.details,
                  'details',
                  allOf(
                    containsPair('localVersion', local),
                    containsPair('hubVersion', isA<String>()),
                  ),
                ),
          ),
        );
      }
      expect(() => checkHubVersion('0.4.9', '0.4.0'), returnsNormally);
      expect(
        () => checkHubVersion(null, '0.4.0'),
        throwsA(isA<HubLinkException>()),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (engine.hubClients.list().isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(engine.hubClients.list(), isEmpty, reason: 'refused ones close');
    });
  });

  test('a hub target is user@host[:port]', () {
    expect(
      '${SshHubTarget.parse('jade@mac-mini.local')}',
      'jade@mac-mini.local',
    );
    final t = SshHubTarget.parse('jade@100.64.1.2:2222');
    expect((t.user, t.host, t.port), ('jade', '100.64.1.2', 2222));
    expect(SshHubTarget.parse('jade@[fd00::1]:22').host, 'fd00::1');
    for (final bad in [
      'mac-mini',
      '@host',
      'jade@',
      'jade@host:0',
      'jade@host:x',
      'ja sh@host',
      'jade@ho st',
      'jade@[nope]',
    ]) {
      expect(() => SshHubTarget.parse(bad), throwsFormatException, reason: bad);
    }
  });

  group('over a loopback OpenSSH sshd', () {
    // A real sshd on 127.0.0.1 only, run as this user with a temp config,
    // so the forced command, restrict and key pinning are OpenSSH's own.
    final sshd = File('/usr/sbin/sshd');

    late Directory dir;
    late Process daemon;
    late int port;
    late String user;
    late String clientKey;
    late String hostFingerprint;
    late Directory kernelDir;
    late String kernel;

    // The forced command runs this checkout's omni, compiled once.
    setUpAll(() async {
      kernelDir = await Directory.systemTemp.createTemp('omni_kernel');
      kernel = '${kernelDir.path}/omni.dill';
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        'bin/omni.dart',
        '-o',
        kernel,
      ]);
      expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
    });

    tearDownAll(() => kernelDir.delete(recursive: true));

    Future<String> keygen(String name) async {
      final path = '${dir.path}/$name';
      final r = await Process.run('/usr/bin/ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        '-N',
        '',
        '-f',
        path,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return path;
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('omni_sshd');
      user = Platform.environment['USER'] ?? 'nobody';
      final hostKey = await keygen('host_key');
      final listed = await Process.run('/usr/bin/ssh-keygen', [
        '-l',
        '-f',
        '$hostKey.pub',
      ]);
      hostFingerprint = '${listed.stdout}'.split(' ')[1];
      clientKey = await keygen('client_key');
      final wrapper = File('${dir.path}/omni')
        ..writeAsStringSync(
          '#!/bin/sh\nexec "${Platform.resolvedExecutable}" "$kernel" "\$@"\n',
        );
      await Process.run('/bin/chmod', ['755', wrapper.path]);
      final userHome = Directory('${dir.path}/u')..createSync();
      final allow = await runOmni(
        [
          '--home',
          home.path,
          'hub',
          'allow',
          'test_phone',
          File('$clientKey.pub').readAsStringSync().trim(),
          '--from',
          '127.0.0.1',
          '--binary',
          wrapper.path,
        ],
        runner: OmniCommandRunner(
          out: StringBuffer(),
          hubEnvironment: HubEnvironment(userHome: userHome.path),
        ),
      );
      expect(allow, 0);
      final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = free.port;
      await free.close();
      final config = File('${dir.path}/sshd_config')
        ..writeAsStringSync(
          [
            'Port $port',
            'ListenAddress 127.0.0.1',
            'HostKey $hostKey',
            'AuthorizedKeysFile ${userHome.path}/.ssh/authorized_keys',
            'PidFile ${dir.path}/sshd.pid',
            'UsePAM no',
            'StrictModes no',
            'PasswordAuthentication no',
            'KbdInteractiveAuthentication no',
            'PerSourcePenalties no',
            '',
          ].join('\n'),
        );
      daemon = await Process.start(sshd.path, ['-D', '-e', '-f', config.path]);
      final ready = Completer<void>();
      final log = StringBuffer();
      daemon.stderr.transform(utf8.decoder).listen((text) {
        log.write(text);
        if (text.contains('Server listening') && !ready.isCompleted) {
          ready.complete();
        }
      });
      daemon.stdout.drain<void>().ignore();
      await ready.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('sshd did not start: $log'),
      );
    });

    tearDown(() async {
      daemon.kill();
      await daemon.exitCode;
      await dir.delete(recursive: true);
    });

    SshHubTarget target() => SshHubTarget(user, '127.0.0.1', port);

    test('drives the hub through the forced omni hub attach', () async {
      final hub = await connectSshHub(
        target: target(),
        privateKeyPem: File(clientKey).readAsStringSync(),
        secrets: secrets,
        hello: const {'client': 'test', 'phone': 'phone'},
      );
      expect(
        await secrets.read('ssh/hostkey/127.0.0.1:$port'),
        'ssh-ed25519 $hostFingerprint',
      );
      final added = await hub.handle('device.add', {
        'id': 'jade',
        'driver': 'person',
      });
      expect(added['ok'], isTrue, reason: '$added');
      expect(
        engine.hubClients.list(),
        contains(containsPair('client', 'test')),
      );
      await hub.close();
      final phone = await engine.handle('device.get', {'id': 'test_phone'});
      expect(
        (phone['device'] as Map)['driver'],
        'phone',
        reason: 'allow made it',
      );

      // The key cannot run anything else: asking for another command still
      // gets omni hub attach.
      final forced = await openSshHubChannel(
        target: target(),
        privateKeyPem: File(clientKey).readAsStringSync(),
        secrets: secrets,
        command: 'echo not the hub',
      );
      final reply = forced.input
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      forced.add(
        utf8.encode('${jsonEncode({'id': 5, 'command': 'device.list'})}\n'),
      );
      final line =
          jsonDecode(await reply.timeout(const Duration(seconds: 20))) as Map;
      expect(line['id'], 5);
      expect((line['result'] as Map)['ok'], isTrue);
      await forced.close();
    });

    test('omni --hub runs a CLI command on the hub', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runOmni(
        [
          '--hub',
          '$user@127.0.0.1:$port',
          '--hub-key',
          clientKey,
          'device',
          'add',
          'asha',
          '--driver',
          'person',
        ],
        runner: OmniCommandRunner(
          out: out,
          socketPath: '${dir.path}/no.sock',
          hubEnvironment: HubEnvironment(secrets: secrets),
          engineFactory: (h, {tap}) => throw StateError('opened the engine'),
        ),
        err: err,
      );
      expect(code, 0, reason: '$out $err');
      final got = await engine.handle('device.get', {'id': 'asha'});
      expect(got['ok'], isTrue);
    });

    test('a changed host key fails with host_key and both keys', () async {
      await secrets.write(
        'ssh/hostkey/127.0.0.1:$port',
        'ssh-ed25519 SHA256:somethingelse',
      );
      await expectLater(
        connectSshHub(
          target: target(),
          privateKeyPem: File(clientKey).readAsStringSync(),
          secrets: secrets,
        ),
        throwsA(
          isA<HubLinkException>()
              .having((e) => e.type, 'type', 'host_key')
              .having(
                (e) => e.details,
                'details',
                containsPair('offered', 'ssh-ed25519 $hostFingerprint'),
              ),
        ),
      );
    });

    test('a phone key over sshd cannot run anything on the Mac', () async {
      final hub = await connectSshHub(
        target: target(),
        privateKeyPem: File(clientKey).readAsStringSync(),
        secrets: secrets,
        hello: const {'client': 'test', 'phone': 'someone_else'},
      );
      expect(hub.hubPhone, 'test_phone');
      final marker = File('${dir.path}/ran.txt');
      final register = await hub.handle('driver.register', {
        'manifest': {
          'schemaVersion': 1,
          'id': 'probe_host',
          'name': 'Probe',
          'category': 'computer',
          'transport': {'type': 'exec'},
          'capabilities': [
            {
              'id': 'run',
              'type': 'action',
              'label': 'Run',
              'command': ['/bin/sh', '-c', 'echo ran > ${marker.path}'],
            },
          ],
        },
      });
      expect((register['error'] as Map)['type'], 'not_allowed');
      final local = await hub.handle('device.add', {
        'id': 'probe',
        'driver': 'person',
        'host': 'local',
      });
      expect((local['error'] as Map)['type'], 'not_allowed');
      expect(marker.existsSync(), isFalse);
      expect(
        engine.hubClients.list(),
        contains(
          allOf(
            containsPair('phone', 'test_phone'),
            containsPair('session', 'phone'),
          ),
        ),
      );
      await hub.close();
    });

    test('the matched host key is required, and nothing is pinned', () async {
      final hub = await connectSshHub(
        target: target(),
        privateKeyPem: File(clientKey).readAsStringSync(),
        secrets: secrets,
        expectedHostKey: 'ssh-ed25519 $hostFingerprint',
      );
      await hub.close();
      expect(await secrets.read('ssh/hostkey/127.0.0.1:$port'), isNull);
      await expectLater(
        connectSshHub(
          target: target(),
          privateKeyPem: File(clientKey).readAsStringSync(),
          secrets: secrets,
          expectedHostKey: 'ssh-ed25519 SHA256:notthisone',
        ),
        throwsA(
          isA<HubLinkException>()
              .having((e) => e.type, 'type', 'host_key')
              .having(
                (e) => e.details,
                'details',
                containsPair('offered', 'ssh-ed25519 $hostFingerprint'),
              ),
        ),
      );
      expect(await secrets.read('ssh/hostkey/127.0.0.1:$port'), isNull);
    });

    test('a pin that cannot be read stops instead of trusting', () async {
      await expectLater(
        connectSshHub(
          target: target(),
          privateKeyPem: File(clientKey).readAsStringSync(),
          secrets: _BrokenSecrets(),
        ),
        throwsA(
          isA<HubLinkException>()
              .having((e) => e.type, 'type', 'host_key')
              .having((e) => e.message, 'message', contains('cannot read')),
        ),
      );
    });

    test('a key that was not allowed is refused', () async {
      final stranger = await keygen('stranger');
      await expectLater(
        connectSshHub(
          target: target(),
          privateKeyPem: File(stranger).readAsStringSync(),
          secrets: secrets,
        ),
        throwsA(
          isA<HubLinkException>()
              .having((e) => e.type, 'type', 'unavailable')
              .having(
                (e) => e.message,
                'message',
                contains('refused this key'),
              ),
        ),
      );
    });

    test('with no hub running the forced command says so', () async {
      await server!.close();
      server = null;
      await expectLater(
        connectSshHub(
          target: target(),
          privateKeyPem: File(clientKey).readAsStringSync(),
          secrets: secrets,
        ),
        throwsA(
          isA<HubLinkException>().having(
            (e) => e.message,
            'message',
            contains('no omni hub is running'),
          ),
        ),
      );
    });
  }, skip: _sshdSkip());
}

/// A keystore that fails every read, as Android's can after a restore.
class _BrokenSecrets implements SecretStore {
  final written = <String, String>{};

  @override
  Future<String?> read(String key) async =>
      throw const FileSystemException('the keystore is locked');

  @override
  Future<void> write(String key, String value) async => written[key] = value;

  @override
  Future<void> delete(String key) async => written.remove(key);
}

String? _sshdSkip() {
  if (!Platform.isMacOS) return 'the loopback sshd test runs on macOS';
  if (!File('/usr/sbin/sshd').existsSync() ||
      !File('/usr/bin/ssh-keygen').existsSync()) {
    return 'no OpenSSH here';
  }
  return null;
}
