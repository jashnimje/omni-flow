import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/ui/fun/home_stats.dart';
import 'package:omniflow_app/ui/fun/home_today_card.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

/// The today card reads what the real engine's `home.stats` says.
void main() {
  test('an automation run on a real engine reads as the card line', () async {
    final home = await Directory.systemTemp.createTemp('omni_fun');
    final engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
    );
    addTearDown(() async {
      await engine.close();
      await home.delete(recursive: true);
    });
    final client = InProcessEngineClient(engine);
    final saved = await client.call('automation.save', {
      'form': 'rule',
      'trusted': true,
      'spec': {
        'name': 'Hello',
        'when': ['manual'],
        'then': [
          {
            'notify': {'title': 'Hi'},
          },
          {
            'notify': {'title': 'Again'},
          },
        ],
      },
    });
    expect(saved['ok'], isTrue, reason: '$saved');
    await client.call('automation.run', {'id': saved['id']});

    final stats = await loadHomeStats(client);
    expect(stats, isNotNull);
    expect(todayLine(stats!), (
      title: '1 automation ran',
      detail: 'Saved you 1 tap',
    ));
    expect(stats.days, hasLength(7));
    expect(stats.newlyEarned, ['first_automation']);
    expect(stats.achievement('first_automation')?.earned, isTrue);
    expect(stats.achievement('runs_10')?.how, isNotEmpty);
  });
}
