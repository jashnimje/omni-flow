import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

void main() {
  late Directory home;
  late OmniEngine engine;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_asif');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
  });

  tearDown(() async {
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command -> $result');
    return result;
  }

  test('Try as if: a check on the trigger\'s own state sees the made-up '
      'value, as the real run does', () async {
    await ok('phone.battery', {'level': 50, 'charging': false});
    final trigger = {
      'on': 'phone.battery',
      'crosses': {'below': 20},
    };
    await ok('automation.save', {
      'form': 'rule',
      'trusted': true,
      'spec': {
        'name': 'Low',
        'when': [trigger],
        'onlyIf': [
          {'state': 'phone.battery', 'op': '<', 'value': 20},
        ],
        'then': [
          {
            'notify': {'title': 'low'},
          },
        ],
      },
    });
    final dry = await ok('automation.dry_run', {
      'id': 'low',
      'trigger': ruleTriggerNodeId(0),
      'msg': asIfMessage(trigger),
    });
    final run = dry['run'] as Map;
    final ports = [
      for (final n in (run['nodes'] as List).cast<Map>()) n['port'],
    ];
    expect(ports, isNot(contains('false')), reason: '$run');
    expect(ports, contains('true'), reason: '$run');

    final real = await ok('automation.dry_run', {
      'id': 'low',
      'trigger': ruleTriggerNodeId(0),
      'msg': {'thing': 'phone', 'key': 'battery', 'value': 19},
    });
    expect(
      [
        for (final n in ((real['run'] as Map)['nodes'] as List).cast<Map>())
          n['port'],
      ],
      contains('false'),
      reason: 'a message that is not made up reads the real state',
    );
  });
}
