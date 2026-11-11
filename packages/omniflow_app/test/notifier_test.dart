import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/service/notifier.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;
  late List<(String, String, String?)> posted;
  late AutomationNotifier notifier;

  setUp(() {
    engine = FakeEngine();
    engine.answers['automation.get'] = {'ok': true, 'name': 'Home, film time'};
    posted = [];
    notifier = AutomationNotifier(
      engine,
      post: ({required channel, required id, required title, body}) async =>
          posted.add((channel, title, body)),
    )..start();
  });

  tearDown(() => notifier.stop());

  Future<void> send(Map<String, Object?> e) async {
    engine.eventsOut.add(e);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('a notify step becomes a notification', () async {
    await send({
      'event': 'flow.announce',
      'title': 'Welcome home',
      'body': 'Hi',
    });
    expect(posted, [('automations', 'Welcome home', 'Hi')]);
  });

  test('a failed run is posted once, in plain words, until it works', () async {
    final failed = {
      'event': 'run.finished',
      'flow': 'home_film_time',
      'outcome': 'failed',
      'reason': 'TimeoutException: no answer from 192.168.1.111:5555',
    };
    await send(failed);
    await send(failed);
    expect(posted, [
      (
        'problems',
        'Home, film time did not finish',
        'No answer from 192.168.1.111:5555.',
      ),
    ]);
    await send({
      'event': 'run.finished',
      'flow': 'home_film_time',
      'outcome': 'completed',
    });
    await send(failed);
    expect(posted, hasLength(2));
  });
}
