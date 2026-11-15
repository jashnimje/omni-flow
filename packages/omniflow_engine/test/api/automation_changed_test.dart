import 'dart:async';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

void main() {
  late Directory home;
  late OmniEngine engine;
  late List<Map<String, Object?>> events;
  late StreamSubscription<Map<String, Object?>> sub;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_changed');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
    events = [];
    sub = engine.events.listen(events.add);
  });

  tearDown(() async {
    await sub.cancel();
    await engine.close();
    await home.delete(recursive: true);
  });

  List<Map<String, Object?>> changed() => [
    for (final e in events)
      if (e['event'] == OmniEngine.automationChangedEvent) e,
  ];

  Future<Map<String, Object?>> save() => engine.handle('automation.save', {
    'form': 'rule',
    'spec': {
      'id': 'hello',
      'name': 'Hello',
      'when': ['manual'],
      'then': ['notify:Hello'],
    },
    'trusted': true,
  });

  test('saving, turning off and removing an automation each say so', () async {
    expect((await save())['ok'], isTrue);
    expect(
      (await engine.handle('automation.enable', {
        'id': 'hello',
        'enabled': false,
      }))['ok'],
      isTrue,
    );
    expect(
      (await engine.handle('automation.remove', {'id': 'hello'}))['ok'],
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      [for (final e in changed()) e['command']],
      ['automation.save', 'automation.enable', 'automation.remove'],
    );
    expect(changed().every((e) => e['id'] == 'hello'), isTrue);
  });

  test('a read or a failed change says nothing', () async {
    await engine.handle('automation.list', const {});
    final bad = await engine.handle('automation.save', {
      'form': 'rule',
      'spec': {'name': 'Broken', 'then': <Object>[]},
    });
    expect(bad['ok'], isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(changed(), isEmpty);
  });
}
