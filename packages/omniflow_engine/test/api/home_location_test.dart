@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

void main() {
  late Directory home;
  late OmniEngine engine;

  Future<OmniEngine> open() => OmniEngine.open(
    home: home,
    secrets: InMemorySecretStore(),
    mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
  );

  Map<String, Object?> rule(Object trigger) => {
    'form': 'rule',
    'trusted': true,
    'spec': {
      'name': 'Evening',
      'when': [trigger],
      'then': [
        {
          'notify': {'title': 'Evening'},
        },
      ],
    },
  };

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_home_location');
    engine = await open();
  });

  tearDown(() async {
    await engine.close();
    await home.delete(recursive: true);
  });

  test('a sun rule needs home set first, then saves', () async {
    final refused = await engine.handle(
      'automation.save',
      rule({'sun': 'sunset', 'offset': -30}),
    );
    final error = refused['error'] as Map;
    expect(error['type'], 'invalid');
    final issue = (error['issues'] as List).single as Map;
    expect(issue['path'], 'when[0]');
    expect(issue['message'], startsWith('Set where home is first'));

    final set = await engine.handle('home.location.set', {
      'latitude': 51.5074,
      'longitude': -0.1278,
    });
    expect(set['ok'], isTrue, reason: '$set');
    expect((set['today'] as Map).keys, containsAll(['sunrise', 'sunset']));

    final saved = await engine.handle(
      'automation.save',
      rule({'sun': 'sunset', 'offset': -30}),
    );
    expect(saved['ok'], isTrue, reason: '$saved');
    final flow = (await engine.handle('flow.get', {'id': saved['id']}))['flow'];
    final trigger = ((flow as Map)['nodes'] as List).first as Map;
    expect(trigger['type'], 'sun');
    expect(trigger['config'], {'event': 'sunset', 'offsetMinutes': -30});
    expect(trigger['label'], '30 min before sunset');
  });

  test('the location lasts across a restart', () async {
    await engine.handle('home.location.set', {
      'latitude': 19.076,
      'longitude': 72.8777,
    });
    await engine.close();
    engine = await open();
    expect((await engine.handle('home.location', {}))['location'], {
      'latitude': 19.076,
      'longitude': 72.8777,
    });
    expect(engine.flows.homeLocation, (latitude: 19.076, longitude: 72.8777));
  });

  test('a bad location or sun trigger is a plain error', () async {
    final far = await engine.handle('home.location.set', {
      'latitude': 95,
      'longitude': 0,
    });
    expect((far['error'] as Map)['message'], contains('latitude'));
    await engine.handle('home.location.set', {'latitude': 0, 'longitude': 0});
    final bad = await engine.handle(
      'automation.save',
      rule({'sun': 'noon', 'offset': 1000}),
    );
    final paths = [
      for (final i in (bad['error'] as Map)['issues'] as List)
        (i as Map)['path'],
    ];
    expect(paths, containsAll(['when[0].sun', 'when[0].offset']));
  });

  test('shorthand writes a sun trigger', () {
    expect(expandTrigger('sunset-30m', const RuleContext()), {
      'sun': 'sunset',
      'offset': -30,
    });
    expect(expandTrigger('sunrise+1h@mon,fri', const RuleContext()), {
      'sun': 'sunrise',
      'offset': 60,
      'days': ['mon', 'fri'],
    });
    expect(expandTrigger('sunrise', const RuleContext()), {'sun': 'sunrise'});
  });
}
