import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:test/test.dart';

import '../devices/adb/fake_adbd.dart';
import '../devices/adb/fake_tv.dart';

void main() {
  late AdbHostKey key;
  late Directory home;
  late FakeAdbd adbd;
  late FakeTv tv;
  late OmniEngine engine;
  late McpClient client;

  setUpAll(() => key = AdbHostKey.generateSync());

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_tv_mcp');
    final secrets = InMemorySecretStore();
    await secrets.write(adbHostKeySecret, key.toPem());
    adbd = await FakeAdbd.start();
    tv = FakeTv(adbd);
    tv.apps['in.startv.hotstar'] = FakeApp('in.startv.hotstar');
    adbd.fs.writeFile('/sdcard/Download/a.txt', [1]);
    engine = await OmniEngine.open(home: home, secrets: secrets);
    await engine.handle('agent.access.set', {'access': 'setup'});
    await engine.handle('device.add', {
      'id': 'tv',
      'driver': 'android_tv_adb',
      'host': InternetAddress.loopbackIPv4.address,
      'port': adbd.port,
    });
    final toServer = StreamController<List<int>>();
    final toClient = StreamController<List<int>>();
    await createOmniMcpServer(
      engine,
    ).connect(IOStreamTransport(stream: toServer.stream, sink: toClient.sink));
    client = McpClient(
      const Implementation(name: 'test', version: '1'),
      options: const McpClientOptions(capabilities: ClientCapabilities()),
    );
    await client.connect(
      IOStreamTransport(stream: toClient.stream, sink: toServer.sink),
    );
  });

  tearDown(() async {
    await client.close();
    await engine.close();
    await adbd.close();
    await home.delete(recursive: true);
  });

  Future<(bool, Map<String, Object?>)> call(
    String name,
    Map<String, dynamic> args,
  ) async {
    final result = await client.callTool(
      CallToolRequest(name: name, arguments: args),
    );
    final text = (result.content.single as TextContent).text;
    return (result.isError != true, jsonDecode(text) as Map<String, Object?>);
  }

  Future<void> pairAsUser() async {
    final r = await engine.handle('tv.state', {'id': 'tv'});
    expect(r['ok'], isTrue, reason: '$r');
    adbd.commands.clear();
  }

  test('an agent cannot put the pairing prompt on the TV', () async {
    final (ok, body) = await call('tv_state', {'deviceId': 'tv'});
    expect(ok, isFalse);
    expect((body['error'] as Map)['type'], 'needs_user');
    expect((body['error'] as Map)['message'], contains('omni device pair tv'));
    expect(adbd.offeredKeys, isEmpty);
  });

  test('an agent reads state, keys, apps, settings and files', () async {
    await pairAsUser();
    for (final (name, args) in [
      ('tv_state', <String, dynamic>{}),
      ('tv_remote_keys', <String, dynamic>{}),
      ('tv_list_apps', {'filter': 'user'}),
      ('tv_app_info', {'package': 'in.startv.hotstar'}),
      ('tv_settings', {'view': 'catalog'}),
      ('tv_settings', {'view': 'list', 'namespace': 'global'}),
      (
        'tv_settings',
        {'view': 'get', 'namespace': 'global', 'key': 'bluetooth_on'},
      ),
      ('tv_files', {'path': '/sdcard/Download'}),
      ('tv_files', {'view': 'stat', 'path': '/sdcard/Download/a.txt'}),
      ('tv_system', <String, dynamic>{}),
      ('tv_processes', <String, dynamic>{}),
    ]) {
      final (ok, body) = await call(name, {'deviceId': 'tv', ...args});
      expect(ok, isTrue, reason: '$name $args: $body');
    }
    expect(
      adbd.commands.where(
        (c) =>
            RegExp(r'settings put|input |pm (clear|uninstall|disable)|rm ')
                .hasMatch(c),
      ),
      isEmpty,
    );
  });

  test('tv_change says which changes an agent sends at setup and which are '
      'the user\'s, and sends nothing', () async {
    await pairAsUser();
    for (final (change, command) in [
      ('remote', 'tv.key'),
      ('text', 'tv.text'),
      ('volume', 'tv.volume'),
      ('apps', 'tv.app'),
    ]) {
      final (ok, body) = await call('tv_change', {
        'deviceId': 'tv',
        'change': change,
      });
      expect(ok, isTrue, reason: change);
      expect(body['yours'], isTrue);
      expect(body['needs'], 'setup');
      expect(body['command'], command);
    }
    for (final change in ['install', 'settings', 'files', 'shell']) {
      final (ok, body) = await call('tv_change', {
        'deviceId': 'tv',
        'change': change,
      });
      expect(ok, isFalse);
      expect((body['error'] as Map)['type'], 'needs_user', reason: change);
      expect((body['error'] as Map)['message'], contains('omni tv tv'));
      expect((body['error'] as Map)['message'], contains('for the user only'));
    }
    expect(adbd.commands, isEmpty);
  });

  test('invoking a setting or app change answers needs_user, a volume step '
      'runs', () async {
    await pairAsUser();
    for (final (capability, params) in [
      (
        'set_setting',
        {'namespace': 'global', 'key': 'private_dns_mode', 'value': 'off'},
      ),
      ('manage_app', {'package': 'in.startv.hotstar', 'action': 'uninstall'}),
    ]) {
      final (ok, body) = await call('invoke_device_capability', {
        'deviceId': 'tv',
        'capabilityId': capability,
        'params': params,
      });
      expect(ok, isFalse, reason: capability);
      expect((body['error'] as Map)['type'], 'needs_user');
    }
    expect(adbd.commands, isEmpty);
    expect(tv.settings['global']!['private_dns_mode'], 'hostname');
    expect(tv.apps['in.startv.hotstar']!.installed, isTrue);

    final (ok, body) = await call('invoke_device_capability', {
      'deviceId': 'tv',
      'capabilityId': 'volume',
      'params': {'value': 20},
    });
    expect(ok, isTrue, reason: '$body');
    expect(tv.volume, 20);
  });

  test(
    'a rule an agent saves with a setting step waits for approval',
    () async {
      final (ok, body) = await call('create_rule', {
        'rule': {
          'name': 'Agent dns',
          'when': ['time:23:00'],
          'then': [
            {
              'do': 'tv.set_setting',
              'params': {
                'namespace': 'global',
                'key': 'private_dns_mode',
                'value': 'off',
              },
            },
          ],
        },
      });
      expect(ok, isTrue, reason: '$body');
      expect((body['highRisk'], body['approved']), (true, false));
      expect(engine.flows.loadedFlows, isEmpty);
    },
  );
}
