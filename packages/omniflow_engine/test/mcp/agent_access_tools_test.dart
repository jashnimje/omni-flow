import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/dag/people_triggers.dart';
import 'package:omniflow_engine/src/dag/templates.dart' show ruleTemplates;
import 'package:test/test.dart';

Map<String, Object?> _body(CallToolResult r) =>
    jsonDecode((r.content.single as TextContent).text) as Map<String, Object?>;

/// The MCP tools under the agent's access level: every read goes through
/// agent.call, and the descriptions say what the policy and the rule model
/// say.
void main() {
  late Directory home;
  late OmniEngine engine;
  late McpClient client;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_mcp_access');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      tap: PacketTap(),
    );
    await engine.handle('device.add', {
      'id': 'tv',
      'driver': 'android_tv_adb',
      'host': '192.0.2.1',
    });
    await engine.handle('phone.wifi', {
      'ssid': 'ClinicGuest',
      'bssid': '01:02:03:04:05:06',
    });
    final toServer = StreamController<List<int>>();
    final toClient = StreamController<List<int>>();
    final mcp = createOmniMcpServer(engine);
    await mcp.connect(
      IOStreamTransport(stream: toServer.stream, sink: toClient.sink),
    );
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
    await home.delete(recursive: true);
  });

  Future<(bool, Map<String, Object?>)> call(
    String tool,
    Map<String, Object?> args,
  ) async {
    final r = await client.callTool(
      CallToolRequest(name: tool, arguments: args),
    );
    return (r.isError != true, _body(r));
  }

  test('read tools apply the read level', () async {
    for (final (tool, args) in [
      ('device_history', {'deviceId': 'phone'}),
      ('discover_devices_and_capabilities', <String, Object?>{}),
      ('describe_omniflow', <String, Object?>{}),
    ]) {
      final (ok, body) = await call(tool, args);
      expect(ok, isTrue, reason: '$tool $body');
      expect(jsonEncode(body), isNot(contains('ClinicGuest')), reason: tool);
      expect(jsonEncode(body), isNot(contains('01:02:03')), reason: tool);
    }
    final (infoOk, info) = await call('tv_app_info', {
      'deviceId': 'tv',
      'package': 'com.example',
    });
    expect(infoOk, isFalse);
    expect((info['error'] as Map)['message'], contains('sets the home up'));
    final (sniffOk, sniff) = await call('sniff_live_packets', {'seconds': 1});
    expect(sniffOk, isFalse);
    expect((sniff['error'] as Map)['type'], 'needs_user');
  });

  test('at setup the readings come back and packets can be watched', () async {
    await engine.handle('agent.access.set', {'access': 'setup'});
    final (ok, body) = await call('device_history', {'deviceId': 'phone'});
    expect(ok, isTrue);
    expect(jsonEncode(body), contains('ClinicGuest'));
    final (sniffOk, _) = await call('sniff_live_packets', {'seconds': 1});
    expect(sniffOk, isTrue);
  });

  test('the descriptions follow the policy and the rule model', () async {
    final tools = {
      for (final t in (await client.listTools()).tools) t.name: t.description,
    };
    final rule = tools['create_rule']!;
    for (final kind in [
      ...RuleKeys.triggers,
      ...RuleKeys.conditions,
      ...RuleKeys.steps,
      ...peopleTriggerKinds,
      ...peopleConditionKinds,
      ...RuleKeys.engineEvents,
    ]) {
      expect(rule, contains(kind), reason: kind);
    }
    expect(rule, contains('phone.show_message'));
    expect(rule, contains('is refused'));
    final templates = tools['list_rule_templates']!;
    for (final t in ruleTemplates) {
      expect(templates, contains(t.name));
    }
    final tvChange = tools['tv_change']!;
    expect(tvChange, contains('tv.text'));
    expect(tvChange, contains('android_phone_adb'));
    expect(tvChange, isNot(contains('Changing an Android TV is the user')));
    expect(tools['find_things'], contains('setup'));
    expect(tools['find_things'], isNot(contains('omni add')));
  });
}
