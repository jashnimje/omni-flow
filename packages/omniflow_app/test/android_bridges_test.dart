import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/service/foreground_runtime.dart';
import 'package:omniflow_app/service/installed_apps.dart';
import 'package:omniflow_app/service/notifier.dart';
import 'package:omniflow_app/service/service_engine_client.dart';

import 'fake_engine.dart';
import 'loopback_link.dart';
import 'service_fake_engine.dart';

/// A service that answers, and counts notification refreshes.
class _RefreshingControl implements ServiceControl, RefreshableService {
  _RefreshingControl(this.link, {this.running = false, this.fails = false});

  final LoopbackLink link;
  final bool fails;
  bool running;
  var refreshes = 0;

  @override
  Future<bool> get isRunning async => running;

  @override
  Future<void> start() async {
    running = true;
    link.host.attach(FakeEngine());
  }

  @override
  Future<void> restart() => start();

  @override
  Future<void> refreshNotification() async {
    refreshes++;
    if (fails) throw StateError('no service');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('asks as heads-up notifications', () {
    late ServiceFakeEngine engine;
    late List<MethodCall> calls;
    late AutomationNotifier notifier;

    setUp(() {
      engine = ServiceFakeEngine();
      calls = [];
      messenger.setMockMethodCallHandler(
        const MethodChannel(AutomationNotifier.channelName),
        (call) async {
          calls.add(call);
          return null;
        },
      );
      notifier = AutomationNotifier(engine);
    });

    tearDown(() async {
      await notifier.stop();
      messenger.setMockMethodCallHandler(
        const MethodChannel(AutomationNotifier.channelName),
        null,
      );
    });

    Future<void> ask(String askId) async {
      engine.eventsOut.add({
        'event': 'ask.request',
        'askId': askId,
        'kind': 'confirm',
        'title': 'Start $askId?',
      });
      await pumpEventQueue();
    }

    Map<String, Object?> argsOf(MethodCall call) =>
        Map<String, Object?>.from(call.arguments as Map);

    test('each ask is its own notification on the questions channel', () async {
      await notifier.start();
      await ask('a1');
      await ask('a2');
      final asks = calls.where((c) => c.method == 'ask').map(argsOf).toList();
      expect(asks, hasLength(2));
      expect(asks.map((a) => a['channel']), everyElement(askChannel));
      expect(asks.map((a) => a['id']).toSet(), hasLength(2));
      expect(asks.map((a) => a['group']).toSet(), {'ask/a1', 'ask/a2'});
      expect(asks.first['actions'], ['Run', 'Not now']);
    });

    test('a repeat of the same ask is not posted twice', () async {
      await notifier.start();
      await ask('a1');
      await ask('a1');
      expect(calls.where((c) => c.method == 'ask'), hasLength(1));
    });

    test('ask.closed takes that ask down and leaves the others', () async {
      await notifier.start();
      await ask('a1');
      await ask('a2');
      engine.eventsOut.add({'event': 'ask.closed', 'askId': 'a1'});
      await pumpEventQueue();
      final cancels = calls.where((c) => c.method == 'cancel').toList();
      expect(cancels, hasLength(1));
      expect(argsOf(cancels.single)['id'], askNotificationId('a1'));
    });
  });

  group('service notification refresh', () {
    test('a running service gets the current notification', () async {
      final link = LoopbackLink();
      link.host.attach(FakeEngine());
      final control = _RefreshingControl(link, running: true);
      final started = await connectToService(
        control: control,
        link: link.uiEnd,
      );
      addTearDown((started.client as ServiceEngineClient).close);
      expect(control.refreshes, 1);
    });

    test('a freshly started service is refreshed too', () async {
      final link = LoopbackLink();
      final control = _RefreshingControl(link);
      final started = await connectToService(
        control: control,
        link: link.uiEnd,
      );
      addTearDown((started.client as ServiceEngineClient).close);
      expect(control.refreshes, 1);
    });

    test('a refresh that fails does not stop the app connecting', () async {
      final link = LoopbackLink();
      link.host.attach(FakeEngine());
      final control = _RefreshingControl(link, running: true, fails: true);
      final started = await connectToService(
        control: control,
        link: link.uiEnd,
      );
      addTearDown((started.client as ServiceEngineClient).close);
      expect((await started.client.call('device.list'))['ok'], isTrue);
    });

    test('the refresh carries the icon, texts and Stop button', () {
      expect(serviceIcon.metaDataName, 'com.jashnm.omniflow_app.SERVICE_ICON');
      expect(serviceTitle, isNotEmpty);
      expect(serviceText, isNotEmpty);
      expect(serviceButtons.single.id, stopButtonId);
    });
  });

  group('installed apps', () {
    const channel = MethodChannel(InstalledApps.name);
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('reads package and label, skipping broken entries', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'installedApps');
        return [
          {'package': 'com.example.maps', 'label': 'Maps'},
          {'package': 'com.example.blank', 'label': ' '},
          {'package': '', 'label': 'No package'},
          {'label': 'Missing'},
        ];
      });
      final apps = await const InstalledApps().list();
      expect(apps, [
        (package: 'com.example.maps', label: 'Maps'),
        (package: 'com.example.blank', label: 'com.example.blank'),
      ]);
    });

    test('is empty off the phone', () async {
      expect(await const InstalledApps().list(), isEmpty);
    });

    test('is empty when Android does not answer', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unavailable');
      });
      expect(await const InstalledApps().list(), isEmpty);
    });
  });
}
