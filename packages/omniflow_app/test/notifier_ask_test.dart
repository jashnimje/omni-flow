import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/service/notifier.dart';

import 'service_fake_engine.dart';

void main() {
  late ServiceFakeEngine engine;
  late List<AskNotice> asked;
  late List<int> cancelled;
  late AutomationNotifier notifier;
  final now = DateTime.utc(2026, 11, 12, 9);

  AutomationNotifier make() => AutomationNotifier(
    engine,
    post: ({
      required channel,
      required id,
      required title,
      body,
      link,
    }) async {},
    postAsk: (ask) async => asked.add(ask),
    cancel: (id) async => cancelled.add(id),
    now: () => now,
  );

  setUp(() {
    engine = ServiceFakeEngine();
    asked = [];
    cancelled = [];
    notifier = make();
  });

  tearDown(() => notifier.stop());

  Future<void> send(Map<String, Object?> e) async {
    engine.eventsOut.add(e);
    await pumpEventQueue();
  }

  Map<String, Object?> request(
    String kind, {
    String askId = 'a1',
    List<String>? choices,
    Object? expiresAt,
    Object? fallback,
  }) => {
    'event': 'ask.request',
    'askId': askId,
    'flow': 'film night',
    'kind': kind,
    'title': 'Start film night?',
    'body': 'You arrived home',
    'choices': ?choices,
    'default': ?fallback,
    'expiresAt': ?expiresAt,
  };

  test('ask before running shows Run and Not now, closing at expiry', () async {
    await notifier.start();
    await send(
      request(
        'confirm',
        choices: ['Run', 'Not now'],
        expiresAt: now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      ),
    );
    expect(asked, hasLength(1));
    final ask = asked.single;
    expect(ask.askId, 'a1');
    expect(ask.title, 'Start film night?');
    expect(ask.body, 'You arrived home');
    expect(ask.actions, ['Run', 'Not now']);
    expect(ask.reply, isFalse);
    expect(ask.chooser, isEmpty);
    expect(ask.timeoutMs, 300000);
    expect(ask.link, 'omniflow://open/automation/film%20night');
    expect(ask.id, askNotificationId('a1'));
  });

  test('a confirm with no choices still offers Run and Not now', () async {
    await notifier.start();
    await send(request('confirm'));
    expect(asked.single.actions, ['Run', 'Not now']);
  });

  test('up to three choices are actions, more open a list', () async {
    await notifier.start();
    await send(
      request('choose', askId: 'few', choices: ['Netflix', 'YouTube', 'Prime']),
    );
    await send(
      request(
        'choose',
        askId: 'many',
        choices: ['Netflix', 'YouTube', 'Prime', 'Hotstar'],
      ),
    );
    expect(asked[0].actions, ['Netflix', 'YouTube', 'Prime']);
    expect(asked[0].chooser, isEmpty);
    expect(asked[1].actions, isEmpty);
    expect(asked[1].chooser, ['Netflix', 'YouTube', 'Prime', 'Hotstar']);
  });

  test('an input ask gets a reply box that names the default', () async {
    await notifier.start();
    await send(
      request('input', fallback: 'Hello', expiresAt: '2026-11-12T09:05:00Z'),
    );
    final ask = asked.single;
    expect(ask.reply, isTrue);
    expect(ask.actions, isEmpty);
    expect(ask.hint, 'Or leave it for Hello');
    expect(ask.timeoutMs, 300000);
  });

  test('an ask that cannot be answered is not posted', () async {
    await notifier.start();
    await send(request('choose'));
    await send(request('dance'));
    await send({'event': 'ask.request', 'kind': 'confirm', 'title': 'x'});
    expect(asked, isEmpty);
  });

  test('ask.closed takes the notification down', () async {
    await notifier.start();
    await send(request('confirm', askId: 'gone'));
    await send({'event': 'ask.closed', 'askId': 'gone', 'reason': 'timeout'});
    expect(cancelled, [askNotificationId('gone')]);
  });

  test('on start, asks missed earlier are posted once', () async {
    engine.answers['ask.pending'] = {
      'ok': true,
      'asks': [request('confirm', askId: 'missed')],
    };
    await notifier.start();
    expect(engine.argsOf('ask.pending'), hasLength(1));
    expect(asked.map((a) => a.askId), ['missed']);
    // The same ask arriving as an event is already on screen.
    await send(request('confirm', askId: 'missed'));
    expect(asked, hasLength(1));
  });

  test('an engine without ask.pending still starts', () async {
    engine.answers['ask.pending'] = {
      'ok': false,
      'error': {'type': 'unknown_command', 'message': 'no such command'},
    };
    await notifier.start();
    await send(request('confirm'));
    expect(asked, hasLength(1));
  });

  test('the notice carries what the platform needs', () {
    final json = const AskNotice(
      id: 7,
      askId: 'a',
      title: 'T',
      actions: ['Run'],
    ).toJson();
    expect(json, {
      'id': 7,
      'askId': 'a',
      'title': 'T',
      'actions': ['Run'],
      'reply': false,
      'chooser': <String>[],
    });
  });
}
