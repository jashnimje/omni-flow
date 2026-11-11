@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

const _light = {
  'schemaVersion': 1,
  'id': 'test_light',
  'name': 'Test light',
  'category': 'light',
  'transport': {'type': 'virtual'},
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'command': {'set': 'power', 'value': '{{value}}'},
      'stateJsonPath': r'$.power',
    },
  ],
};

void main() {
  group('the policy', () {
    test('read opens reads only, and says how to allow setup', () {
      expect(agentRefusal('device.list', const {}, AgentAccess.read), isNull);
      expect(
        agentRefusal('room.save', const {}, AgentAccess.read),
        contains('Set up everything'),
      );
      expect(agentRefusal('room.save', const {}, AgentAccess.setup), isNull);
    });

    test('user-only commands are refused at every level', () {
      for (final command in agentUserOnly.keys) {
        expect(
          agentRefusal(command, const {}, AgentAccess.setup),
          contains('for the user only'),
          reason: command,
        );
      }
      expect(
        agentRefusal('made.up', const {}, AgentAccess.setup),
        contains('not open to agents'),
      );
    });

    test('a TV app may be opened and stopped, never removed', () {
      expect(
        agentRefusal('tv.app', const {'action': 'open'}, AgentAccess.setup),
        isNull,
      );
      for (final action in ['uninstall', 'clear_data', 'disable']) {
        expect(
          agentRefusal('tv.app', {'action': action}, AgentAccess.setup),
          contains('for the user only'),
        );
      }
    });

    test('the engine variables are not an agent\'s to set', () {
      expect(
        agentRefusal('var.set', const {'var': r'$_omni'}, AgentAccess.setup),
        isNotNull,
      );
      expect(
        agentRefusal('var.set', const {'var': r'$Mood'}, AgentAccess.setup),
        isNull,
      );
    });

    test('saves are untrusted and TV calls never pair', () {
      expect(
        agentArgs('automation.save', const {'trusted': true})['trusted'],
        isFalse,
      );
      expect(agentArgs('tv.state', const {'id': 'tv'})['allowPairing'], false);
      expect(agentArgs('room.save', const {'name': 'Den'}), {'name': 'Den'});
    });

    test('every open command is a real engine command', () async {
      final home = await Directory.systemTemp.createTemp('omni_agent_cmds');
      final engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
        mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
      );
      addTearDown(() async {
        await engine.close();
        await home.delete(recursive: true);
      });
      for (final command in {
        ...agentReadCommands,
        ...agentSetupCommands,
        ...agentUserOnly.keys,
      }) {
        final r = await engine.handle(command, const {});
        expect(
          (r['error'] as Map?)?['type'],
          isNot('unknown_command'),
          reason: command,
        );
      }
    });
  });

  group('the engine', () {
    late Directory home;
    late OmniEngine engine;

    Future<Map<String, Object?>> call(
      String command, [
      Map<String, Object?> args = const {},
    ]) => engine.handle('agent.call', {'command': command, 'args': args});

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_agent');
      engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
        mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
      );
      await engine.handle('driver.register', {'manifest': _light});
      await engine.handle('device.add', {
        'id': 'lamp',
        'name': 'Desk lamp',
        'driver': 'test_light',
      });
    });

    tearDown(() async {
      await engine.close();
      await home.delete(recursive: true);
    });

    test('starts at read, and the user setting setup lasts', () async {
      expect((await engine.handle('agent.access', {}))['access'], 'read');
      final refused = await call('room.save', {'name': 'Den'});
      expect((refused['error'] as Map)['type'], 'needs_user');

      await engine.handle('agent.access.set', {'access': 'setup'});
      expect(jsonDecode(File('${home.path}/agent.json').readAsStringSync()), {
        'access': 'setup',
      });
      final saved = await call('room.save', {'name': 'Den'});
      expect(saved['ok'], isTrue, reason: '$saved');
      expect((saved['room'] as Map)['name'], 'Den');
    });

    test('an agent cannot raise its own access', () async {
      final r = await call('agent.access.set', {'access': 'setup'});
      expect((r['error'] as Map)['type'], 'needs_user');
      expect((await engine.handle('agent.access', {}))['access'], 'read');
    });

    test('an agent rule saves untrusted, and a plain one goes live', () async {
      await engine.handle('agent.access.set', {'access': 'setup'});
      final saved = await call('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Lamp by hand',
          'when': ['manual'],
          'then': ['lamp.power=true'],
        },
      });
      expect(saved['ok'], isTrue, reason: '$saved');
      expect(saved['approved'], isTrue);
      final run = await call('automation.run', {'id': saved['id']});
      expect(run['ok'], isTrue, reason: '$run');
      final lamp = await engine.handle('device.get', {'id': 'lamp'});
      expect(((lamp['device'] as Map)['state'] as Map)['power'], isTrue);
    });

    test('describe gives the whole setup in one reply', () async {
      final d = await engine.handle('agent.describe', {});
      expect(d['ok'], isTrue);
      expect(
        d.keys,
        containsAll([
          'things',
          'rooms',
          'places',
          'automations',
          'templates',
          'drivers',
          'agentAccess',
        ]),
      );
      expect([
        for (final t in d['things'] as List) (t as Map)['id'],
      ], contains('lamp'));
    });
  });

  group('over adb', () {
    test('sends the request as base64 and reads the reply', () async {
      late List<String> sent;
      final phone = AdbPhoneConnection(
        adb: 'adb',
        serial: 'phone-1',
        run: (exe, args) async {
          sent = args;
          final reply = base64.encode(utf8.encode('{"ok":true,"rooms":[]}'));
          return ProcessResult(1, 0, 'Result: Bundle[{result=$reply}]\n', '');
        },
      );
      expect(await phone.handle('room.list', const {}), {
        'ok': true,
        'rooms': [],
      });
      expect(sent.take(7), [
        '-s',
        'phone-1',
        'shell',
        'content',
        'call',
        '--uri',
        phoneBridgeUri,
      ]);
      expect(jsonDecode(utf8.decode(base64.decode(sent.last))), {
        'command': 'room.list',
        'args': {},
      });
    });

    test('a phone that does not answer is unreachable, not a crash', () async {
      final phone = AdbPhoneConnection(
        adb: 'adb',
        run: (_, _) async =>
            ProcessResult(1, 1, '', 'adb: no devices/emulators found'),
      );
      final r = await phone.handle('room.list', const {});
      expect((r['error'] as Map)['type'], 'unreachable');
      expect((r['error'] as Map)['message'], contains('no devices'));
    });
  });
}
