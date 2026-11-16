@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/hub_phone_session.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

/// `omni hub attach [args]` run in this process, as sshd runs the forced
/// command of a phone's key, with its stdin and stdout as a channel.
class AttachChannel implements HubChannel {
  AttachChannel._(this._toHub, this._fromHub, this.finished);

  static Future<AttachChannel> open(
    String socketPath,
    List<String> args,
  ) async {
    final toHub = StreamController<List<int>>();
    final fromHub = StreamController<List<int>>();
    final finished = runOmni(
      ['hub', 'attach', ...args],
      runner: OmniCommandRunner(
        out: _ByteSink(fromHub),
        input: toHub.stream,
        socketPath: socketPath,
        hubEnvironment: HubEnvironment(environment: const {}),
        engineFactory: (h, {tap}) => throw StateError('opened the engine'),
      ),
      err: StringBuffer(),
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

/// A channel whose far end answers with [respond]: each request line in,
/// the reply lines out, or none to stay silent.
class ScriptedChannel implements HubChannel {
  ScriptedChannel(this.respond);

  final List<Map<String, Object?>> Function(Map<String, Object?> request)
  respond;
  final _out = StreamController<List<int>>();
  var closed = false;

  @override
  Stream<List<int>> get input => _out.stream;

  @override
  String get errors => '';

  @override
  void add(List<int> bytes) {
    if (closed) throw StateError('closed');
    for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
      for (final reply in respond(jsonDecode(line) as Map<String, Object?>)) {
        scheduleMicrotask(() {
          if (!closed) _out.add(utf8.encode('${jsonEncode(reply)}\n'));
        });
      }
    }
  }

  void hangUp() {
    closed = true;
    _out.close();
  }

  @override
  Future<void> close() async {
    if (closed) return;
    hangUp();
  }
}

/// Answers hello as a hub of this version would.
List<Map<String, Object?>> helloOnly(Map<String, Object?> r) =>
    r['command'] == helloCommand
    ? [
        {
          'id': r['id'],
          'result': {'ok': true, 'version': omniflowEngineVersion},
        },
      ]
    : const [];

const _execDriver = {
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
      'command': ['/bin/sh', '-c', 'echo ran > "\$OMNI_MARKER"'],
    },
  ],
};

void main() {
  late Directory home;
  late OmniEngine engine;
  late LocalServer server;

  String sock() => '${home.path}/omni.sock';

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_phone_session');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
    for (final (id, driver, settings) in [
      ('asha', 'person', const <String, Object?>{}),
      ('ravi', 'person', const <String, Object?>{}),
      ('asha_phone', 'phone', const {'person': 'asha'}),
      ('ravi_phone', 'phone', const {'person': 'ravi'}),
    ]) {
      final added = await engine.handle('device.add', {
        'id': id,
        'driver': driver,
        'settings': settings,
      });
      expect(added['ok'], isTrue, reason: '$added');
    }
    server = await LocalServer.start(engine, home: home);
  });

  tearDown(() async {
    await server.close();
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<HubConnection> phone(String name) => HubConnection.connect(
    () => AttachChannel.open(sock(), ['--phone', name]),
    hello: const {'client': 'omniflow-app', 'phone': 'someone_else'},
  );

  Map<String, Object?> errorOf(Map<String, Object?> r) =>
      Map<String, Object?>.from(r['error'] as Map);

  test('the phone socket sits beside omni.sock at 0600', () {
    final mode = File(server.phonePath).statSync().mode;
    expect(server.phonePath, '${home.absolute.path}/omni-phone.sock');
    expect(mode & int.parse('077', radix: 8), 0);
  });

  test('the socket_exec probe fails through a phone session and still works '
      'from the Mac', () async {
    final marker = File('${home.path}/ran.txt');
    final hub = await phone('asha_phone');
    final register = await hub.handle('driver.register', {
      'manifest': _execDriver,
    });
    expect(errorOf(register)['type'], 'not_allowed');
    expect('${errorOf(register)['message']}', contains('on the Mac'));

    // The Mac registers it, and the phone still cannot add, change or
    // key a thing that runs programs, nor put any thing on the Mac.
    expect(
      (await engine.handle('driver.register', {'manifest': _execDriver}))['ok'],
      isTrue,
    );
    for (final (command, args) in [
      ('device.add', {'id': 'probe', 'driver': 'probe_host', 'host': 'local'}),
      (
        'device.add',
        {'id': 'probe', 'driver': 'probe_host', 'host': '192.168.1.9'},
      ),
      (
        'thing.add',
        {
          'candidate': {
            'add': {'driver': 'probe_host', 'host': 'local'},
          },
        },
      ),
      ('device.add', {'id': 'p2', 'driver': 'person', 'host': 'local'}),
      ('driver.approve', {'id': 'probe_host'}),
      ('config.import', {'backup': <String, Object?>{}}),
      ('tv.shell', {'id': 'x', 'command': 'id'}),
      ('android.shell', {'id': 'x', 'command': 'id'}),
      ('tv.files.download', {'id': 'x', 'path': '/', 'to': '/tmp'}),
      ('board.flash', {'id': 'x'}),
      ('hub.stop', <String, Object?>{}),
      ('agent.access.set', {'access': 'setup'}),
      ('agent.call', {'command': 'driver.register'}),
      ('device.hostkey', {'id': 'probe'}),
    ]) {
      final r = await hub.handle(command, args);
      expect(errorOf(r)['type'], 'not_allowed', reason: '$command $r');
    }
    expect(marker.existsSync(), isFalse);

    final added = await engine.handle('device.add', {
      'id': 'mac',
      'driver': 'probe_host',
      'host': 'local',
    });
    expect(added['ok'], isTrue);
    for (final (command, args) in [
      (
        'thing.configure',
        {
          'id': 'mac',
          'settings': {'username': 'root'},
        },
      ),
      ('secret.set', {'deviceId': 'mac', 'key': 'sshPrivateKey', 'value': 'k'}),
    ]) {
      final r = await hub.handle(command, args);
      expect(errorOf(r)['type'], 'not_allowed', reason: '$command $r');
    }
    await hub.close();

    // The Mac's own socket keeps full access.
    final mac = (await LocalClient.connect(sock()))!;
    final markerDriver = {
      ..._execDriver,
      'id': 'probe_mac',
      'capabilities': [
        {
          'id': 'run',
          'type': 'action',
          'label': 'Run',
          'command': ['/bin/sh', '-c', 'echo ran > ${marker.path}'],
        },
      ],
    };
    expect(
      (await mac.handle('driver.register', {'manifest': markerDriver}))['ok'],
      isTrue,
    );
    expect(
      (await mac.handle('device.add', {
        'id': 'probe',
        'driver': 'probe_mac',
        'host': 'local',
      }))['ok'],
      isTrue,
    );
    final ran = await mac.handle('device.invoke', {
      'id': 'probe',
      'capability': 'run',
    });
    expect(ran['ok'], isTrue, reason: '$ran');
    expect(marker.readAsStringSync().trim(), 'ran');
    await mac.close();
  });

  test('a phone can still do what the app does', () async {
    final hub = await phone('asha_phone');
    for (final (command, args) in [
      ('device.list', <String, Object?>{}),
      ('automation.list', <String, Object?>{}),
      ('scene.list', <String, Object?>{}),
      ('ask.pending', <String, Object?>{}),
      ('var.set', {'name': 'Mood', 'value': 'calm'}),
      ('device.add', {'id': 'kitchen', 'driver': 'person'}),
      ('phone.ready', <String, Object?>{}),
      ('phone.wifi', {'ssid': 'Home', 'bssid': 'aa:bb:cc:dd:ee:ff'}),
    ]) {
      final r = await hub.handle(command, args);
      expect(r['ok'], isTrue, reason: '$command $r');
    }
    await hub.close();
  });

  test('the phone comes from the key, never from the client', () async {
    final hub = await phone('asha_phone');
    expect(hub.hubPhone, 'asha_phone');
    expect(hub.hubPerson, 'asha');
    expect(
      engine.hubClients.list(),
      contains(
        allOf(
          containsPair('phone', 'asha_phone'),
          containsPair('session', 'phone'),
        ),
      ),
      reason: 'hello.phone someone_else is ignored',
    );
    final other = await hub.handle('phone.wifi', {
      'phone': 'ravi_phone',
      'ssid': 'Away',
      'bssid': '11:22:33:44:55:66',
    });
    expect(errorOf(other)['type'], 'not_allowed');
    final away = await hub.handle('presence.set', {
      'home': false,
      'person': 'ravi',
    });
    expect(errorOf(away)['type'], 'not_allowed');

    final own = await hub.handle('phone.wifi', {
      'ssid': 'Home',
      'bssid': 'aa:bb:cc:dd:ee:ff',
    });
    expect(own['ok'], isTrue, reason: '$own');
    final got = await engine.handle('device.get', {'id': 'asha_phone'});
    expect(((got['device'] as Map)['state'] as Map)['wifi_ssid'], 'Home');
    final ravi = await engine.handle('device.get', {'id': 'ravi_phone'});
    expect(((ravi['device'] as Map)['state'] as Map)['wifi_ssid'], isNull);
    await hub.close();
  });

  test('a phone the hub does not know is turned away', () async {
    await expectLater(
      phone('nobody_phone'),
      throwsA(
        isA<HubLinkException>()
            .having((e) => e.type, 'type', 'not_allowed')
            .having((e) => e.message, 'message', contains('omni hub allow')),
      ),
    );
    // Something that is not attach, writing its own first line, gets the
    // same answer.
    final raw = await Socket.connect(
      InternetAddress(server.phonePath, type: InternetAddressType.unix),
      0,
    );
    raw.add(
      utf8.encode('${jsonEncode({'id': 1, 'command': 'driver.register'})}\n'),
    );
    final reply = await raw
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    expect(reply, contains('not_allowed'));
    raw.destroy();
  });

  test('a phone gets its own events and the home-wide ones only', () async {
    final hub = await phone('asha_phone');
    final seen = <Map<String, Object?>>[];
    final sub = (await hub.events(packets: true)).listen(seen.add);
    await engine.handle('phone.wifi', {
      'phone': 'ravi_phone',
      'ssid': 'Office',
      'bssid': '11:22:33:44:55:66',
    });
    await engine.handle('phone.wifi', {
      'phone': 'asha_phone',
      'ssid': 'Home',
      'bssid': 'aa:bb:cc:dd:ee:ff',
    });
    await engine.handle('var.set', {'name': 'Mood', 'value': 'calm'});
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!seen.any((e) => e['event'] == 'variable.changed') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(seen.map((e) => e['event']), contains('variable.changed'));
    expect(
      seen.where((e) => e['event'] == 'wifi.changed').map((e) => e['phone']),
      ['asha_phone'],
    );
    expect('$seen', isNot(contains('Office')));
    expect('$seen', isNot(contains('ravi_phone')));
    await sub.cancel();
    await hub.close();
  });

  test('a phone reaches what the app needs, and not the Mac', () {
    for (final command in [
      'automation.removed',
      'automation.unremove',
      'backup.auto.get',
      'backup.auto.set',
      'automation.approve',
      'ask.answer',
      'device.pair',
      'device.remove',
      'scene.run',
      'tv.key',
      'tv.input.tap',
      'android.input.tap',
      'phone.wifi',
      'nfc.scanned',
    ]) {
      expect(phoneCommandRefusal(command), isNull, reason: command);
    }
    for (final command in [
      'driver.register',
      'driver.approve',
      'config.import',
      'tv.shell',
      'android.shell',
      'tv.files.upload',
      'android.files.download',
      'board.flash',
      'hub.stop',
      'agent.call',
      'no.such.command',
    ]) {
      expect(phoneCommandRefusal(command), isNotNull, reason: command);
    }
    final known = engine.commandNames.toSet();
    final stale = [
      for (final c in phoneSessionNamedCommands)
        if (!known.contains(c)) c,
    ];
    expect(stale, isEmpty, reason: 'named for phones but not in the engine');
  });

  group('PhoneGate', () {
    PhoneGate gate({List<Map<String, Object?>> asks = const []}) => PhoneGate(
      const PhoneSession('asha_phone', person: 'asha'),
      (command, args) async => switch (command) {
        'ask.pending' => {'ok': true, 'asks': asks},
        _ => {'ok': true},
      },
    );

    test('answers only asks for its person or for anyone', () async {
      final g = gate(
        asks: [
          {'askId': 'a1', 'person': 'ravi'},
          {'askId': 'a2', 'person': 'asha'},
          {'askId': 'a3'},
        ],
      );
      expect(
        (await g.admit('ask.answer', {'askId': 'a1', 'answer': 'Run'})).refusal,
        contains('for ravi'),
      );
      expect(
        (await g.admit('ask.answer', {'askId': 'a2', 'answer': 'Run'})).refusal,
        isNull,
      );
      expect(
        (await g.admit('ask.answer', {'askId': 'a3', 'answer': 'Run'})).refusal,
        isNull,
      );
    });

    test('action replies and readings carry the session phone', () async {
      final done = await gate().admit('phone.actionDone', {
        'requestId': 'r',
        'ok': true,
      });
      expect(done.args['phone'], 'asha_phone');
      final reading = await gate().admit('phone.battery', {'level': 50});
      expect(reading.args['phone'], 'asha_phone');
      final spoofed = await gate().admit('phone.actionDone', {
        'requestId': 'r',
        'ok': true,
        'phone': 'ravi_phone',
      });
      expect(spoofed.refusal, contains('speaks only for itself'));
      final presence = await gate().admit('presence.set', {'home': true});
      expect(presence.args['person'], 'asha');
    });
  });

  test('a phone action reply for another phone is refused', () async {
    final hub = await phone('asha_phone');
    final engineReady = await engine.handle('phone.ready', {
      'phone': 'ravi_phone',
    });
    expect(engineReady['ok'], isTrue);
    final requests = <Map<String, Object?>>[];
    final watch = engine.events
        .where((e) => e['event'] == 'phone.action')
        .listen(requests.add);
    final asked = engine.handle('device.invoke', {
      'id': 'ravi_phone',
      'capability': 'ringer',
      'params': {'mode': 'silent'},
    });
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (requests.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(requests, isNotEmpty);
    final reply = await hub.handle('phone.actionDone', {
      'requestId': requests.first['requestId'],
      'ok': true,
    });
    expect(reply['ok'], isFalse, reason: '$reply');
    final ravi = await engine.handle('phone.actionDone', {
      'requestId': requests.first['requestId'],
      'ok': true,
      'phone': 'ravi_phone',
    });
    expect(ravi['ok'], isTrue);
    expect((await asked)['ok'], isTrue);
    await watch.cancel();
    await hub.close();
  });

  group('PhoneEventFilter', () {
    final filter = PhoneEventFilter(
      const PhoneSession('asha_phone', person: 'asha'),
      {'asha_phone', 'ravi_phone'}.contains,
    );

    test('keeps another person and phone out', () {
      for (final (event, allowed) in [
        ({'event': 'ask.request', 'askId': 'a1', 'person': 'ravi'}, false),
        ({'event': 'ask.closed', 'askId': 'a1'}, false),
        ({'event': 'ask.request', 'askId': 'a2', 'person': 'asha'}, true),
        ({'event': 'ask.closed', 'askId': 'a2'}, true),
        ({'event': 'ask.request', 'askId': 'a3'}, true),
        ({'event': 'flow.announce', 'type': 'notify', 'to': 'ravi'}, false),
        ({'event': 'flow.announce', 'type': 'notify', 'to': 'asha'}, true),
        ({'event': 'flow.announce', 'type': 'notify'}, true),
        ({'event': 'phone.action', 'phone': 'ravi_phone'}, false),
        ({'event': 'phone.action', 'phone': 'asha_phone'}, true),
        (
          {
            'event': 'thing.event',
            'thing': 'ravi_phone',
            'key': 'notification',
            'payload': {'text': 'code 1234'},
          },
          false,
        ),
        ({'event': 'thing.event', 'thing': 'asha_phone', 'key': 'x'}, true),
        ({'event': 'thing.event', 'thing': 'doorbell', 'key': 'press'}, true),
        (
          {
            'event': 'device.stateChanged',
            'device': {'id': 'ravi_phone', 'driver': 'phone'},
          },
          false,
        ),
        (
          {
            'event': 'device.stateChanged',
            'device': {'id': 'lamp', 'driver': 'wiz'},
          },
          true,
        ),
        ({'event': 'packet.captured', 'text': 'x'}, false),
        ({'event': 'automation.changed', 'id': 'r1'}, true),
        ({'event': 'run.finished', 'flow': 'r1'}, true),
      ]) {
        expect(filter.allows(event), allowed, reason: '$event');
      }
    });
  });

  test('a phone may add a USB board but no other path on the Mac', () {
    expect(phoneAddRefusal('omniflow', '/dev/cu.usbserial-1'), isNull);
    expect(phoneAddRefusal('omniflow', '192.168.1.20'), isNull);
    expect(phoneAddRefusal('serial', '/dev/ttyUSB0'), isNull);
    expect(phoneAddRefusal('serial', '/Users/me/.ssh/id_ed25519'), isNotNull);
    expect(phoneAddRefusal('serial', 'notes.txt'), isNotNull);
    expect(phoneAddRefusal('omniflow', '/etc/passwd'), isNotNull);
    expect(phoneAddRefusal('http', '/etc/passwd'), isNotNull);
    expect(phoneAddRefusal('udp', 'LocalHost'), isNotNull);
    expect(phoneAddRefusal('exec', '10.0.0.2'), isNotNull);
    expect(phoneAddRefusal('udp', '10.0.0.2'), isNull);
  });

  group('the hub client stays responsive', () {
    test('a refused subscription surfaces as unavailable', () async {
      final hub = await HubConnection.connect(
        () async => ScriptedChannel(
          (r) => r['subscribe'] == 'events'
              ? [
                  {
                    'id': 1,
                    'result': {'ok': false},
                  },
                ]
              : helloOnly(r),
        ),
      );
      await expectLater(
        hub.events().timeout(const Duration(seconds: 5)),
        throwsA(
          isA<HubLinkException>().having((e) => e.type, 'type', 'unavailable'),
        ),
      );
      await hub.close().timeout(const Duration(seconds: 5));
    });

    test('a channel that closes before subscribing is unavailable', () async {
      var first = true;
      final hub = await HubConnection.connect(() async {
        final c = ScriptedChannel(helloOnly);
        if (!first) scheduleMicrotask(c.hangUp);
        first = false;
        return c;
      });
      await expectLater(
        hub.events().timeout(const Duration(seconds: 5)),
        throwsA(isA<HubLinkException>()),
      );
      await hub.close().timeout(const Duration(seconds: 5));
    });

    test('a command the hub never answers times out', () async {
      final hub = await HubConnection.connect(
        () async => ScriptedChannel(helloOnly),
        deadline: (_, _) => const Duration(milliseconds: 100),
      );
      final r = await hub.handle('device.list', const {});
      expect(errorOf(r)['type'], 'timeout');
      await hub.close();
    });

    test('a link that stops answering pings is dropped and reopened', () async {
      final channels = <ScriptedChannel>[];
      var answering = true;
      final hub = await HubConnection.connect(
        () async {
          final c = ScriptedChannel(
            (r) => r['command'] == helloCommand
                ? helloOnly(r)
                : answering
                ? [
                    {
                      'id': r['id'],
                      'result': {'ok': true},
                    },
                  ]
                : const [],
          );
          channels.add(c);
          return c;
        },
        keepAlive: const Duration(milliseconds: 50),
        pingTimeout: const Duration(milliseconds: 100),
      );
      answering = false;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!channels.first.closed && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(channels.first.closed, isTrue, reason: 'the silent link drops');
      answering = true;
      expect((await hub.handle('device.list', const {}))['ok'], isTrue);
      expect(channels, hasLength(2));
      await hub.close();
      expect(channels.every((c) => c.closed), isTrue);
    });

    test('closing while a channel opens leaks nothing', () async {
      final opened = <ScriptedChannel>[];
      final gate = Completer<void>();
      final hub = await HubConnection.connect(() async {
        if (opened.isNotEmpty) await gate.future;
        final c = ScriptedChannel(
          (r) => r['subscribe'] == 'events'
              ? [
                  {
                    'id': 1,
                    'result': {'ok': true},
                  },
                ]
              : helloOnly(r),
        );
        opened.add(c);
        return c;
      });
      final stream = hub.events();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final closing = hub.close();
      gate.complete();
      await closing;
      await expectLater(stream, throwsA(isA<HubLinkException>()));
      expect(opened, hasLength(2));
      expect(opened.every((c) => c.closed), isTrue);
    });
  });
}
