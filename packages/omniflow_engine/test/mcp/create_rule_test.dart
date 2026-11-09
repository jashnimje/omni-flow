import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../api/automation_harness.dart';

Map<String, Object?> body(CallToolResult r) =>
    jsonDecode((r.content.single as TextContent).text) as Map<String, Object?>;

void main() {
  late Directory home;
  late AutomationHarness h;
  late McpClient client;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_mcp_rule');
    h = await AutomationHarness.open(home);
    final toServer = StreamController<List<int>>();
    final toClient = StreamController<List<int>>();
    await createOmniMcpServerFor(
      h,
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
    await h.shutdown();
    await home.delete(recursive: true);
  });

  Future<CallToolResult> createRule(Map<String, Object?> rule) =>
      client.callTool(
        CallToolRequest(name: 'create_rule', arguments: {'rule': rule}),
      );

  test('an agent rule is saved as a rule, and reopens as one', () async {
    final result = await createRule({
      'name': 'Door light',
      'when': ['nfc:front_door'],
      'then': ['lamp.power=true'],
    });
    expect(result.isError, isFalse, reason: '${body(result)}');
    expect(body(result), containsPair('approved', true));
    final got = await h.handle('automation.get', {'id': 'door_light'});
    expect(got['source'], 'rule');
    expect((got['spec'] as Map)['when'], [
      {'on': 'front_door.scanned', 'event': true},
    ]);
  });

  test('an agent rule that runs host commands waits for approval', () async {
    final result = await createRule({
      'name': 'Wake',
      'when': ['home:entered'],
      'then': ['mac_mini.display_wake'],
    });
    expect((body(result)['highRisk'], body(result)['approved']), (true, false));
    expect(h.core.flows.loadedFlows, isNot(contains('wake')));
  });

  test('an agent cannot quietly replace a rule the user saved', () async {
    final rule = {
      'name': 'Evening',
      'when': ['time:18:00'],
      'then': ['lamp.power=true'],
    };
    await h.handle('automation.save', {
      'form': 'rule',
      'spec': rule,
      'trusted': true,
    });
    final result = await createRule({
      ...rule,
      'then': ['lamp.power=false'],
    });
    expect(result.isError, isTrue);
    expect((body(result)['error'] as Map)['type'], 'exists');
    final got = await h.handle('automation.get', {'id': 'evening'});
    expect(got['approved'], isTrue);
    expect(
      ((got['spec'] as Map)['then'] as List).single,
      containsPair('params', {'value': true}),
      reason: 'the user\'s rule is left as it was',
    );
  });

  test('issues come back at rule paths', () async {
    final result = await createRule({
      'name': 'Bad',
      'when': ['garage.door'],
      'then': ['lamp.power=true'],
    });
    expect(result.isError, isTrue);
    final error = body(result)['error'] as Map;
    expect((error['issues'] as List).single, {
      'path': 'when[0].on',
      'message': 'no thing garage',
    });
  });
}
