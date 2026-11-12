import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/service/engine_host.dart';
import 'package:omniflow_app/service/engine_link.dart';
import 'package:omniflow_app/service/engine_owner.dart';
import 'package:omniflow_app/service/foreground_runtime.dart';
import 'package:omniflow_app/service/multicast_lock.dart';
import 'package:omniflow_app/service/phone_inputs.dart';
import 'package:omniflow_app/service/service_engine_client.dart';
import 'package:omniflow_app/startup.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

import 'fake_engine.dart';
import 'loopback_link.dart';

/// The service as connectToService sees it, over a loopback link.
class _FakeControl implements ServiceControl {
  _FakeControl(this.link, {this.running = false, this.hubError});

  final LoopbackLink link;
  final String? hubError;
  bool running;
  var starts = 0;
  var restarts = 0;

  /// What a start or restart does to the service: by default it attaches a
  /// fresh fake engine and starts answering.
  late void Function() onStart = () {
    link.serviceDeaf = false;
    link.host.attach(FakeEngine(), hubError: hubError);
  };

  @override
  Future<bool> get isRunning async => running;

  @override
  Future<void> start() async {
    starts++;
    running = true;
    onStart();
  }

  @override
  Future<void> restart() async {
    restarts++;
    onStart();
  }
}

Map<String, Object?> errorOf(Map<String, Object?> result) =>
    Map<String, Object?>.from(result['error'] as Map);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the link to the service', () {
    test('calls reach the real engine in the service and come back', () async {
      final home = await Directory.systemTemp.createTemp('omni_service');
      addTearDown(() => home.delete(recursive: true));
      final engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
      );
      addTearDown(engine.close);
      final link = LoopbackLink();
      link.host.attach(InProcessEngineClient(engine));
      final client = ServiceEngineClient(link.uiEnd());
      addTearDown(client.close);

      expect(await client.connect(), isNull);
      final added = await client.call('device.add', {
        'id': 'desk_lamp',
        'name': 'Desk lamp',
        'driver': 'philips_wiz_udp',
        'host': '127.0.0.1',
      });
      expect(added['ok'], isTrue, reason: '$added');
      final listed = await client.call('device.list');
      expect(
        [for (final d in listed['devices'] as List) (d as Map)['id']],
        ['desk_lamp'],
      );
      final unknown = await client.call('no.such.command');
      expect(unknown['ok'], isFalse);
    });

    test('hellos lost before the handler is set are said again', () async {
      final link = LoopbackLink()..serviceDeaf = true;
      link.host.attach(FakeEngine(), hubError: 'port 38951 is in use');
      final client = ServiceEngineClient(link.uiEnd());
      addTearDown(client.close);
      Timer(const Duration(milliseconds: 200), () => link.serviceDeaf = false);
      expect(
        await client.connect(retry: const Duration(milliseconds: 20)),
        'port 38951 is in use',
      );
    });

    test(
      'a hello and a call made while the engine opens wait for it',
      () async {
        final link = LoopbackLink();
        final client = ServiceEngineClient(link.uiEnd());
        addTearDown(client.close);
        final connected = client.connect();
        final listed = client.call('device.list');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        link.host.attach(FakeEngine(), hubError: 'port 38900 is in use');
        expect(await connected, 'port 38900 is in use');
        final devices = (await listed)['devices'] as List;
        expect((devices.single as Map)['id'], 'desk_lamp');
      },
    );

    test('an engine that did not open fails connect and every call', () async {
      final link = LoopbackLink();
      link.host.fail('omniflow.sqlite is locked');
      final client = ServiceEngineClient(link.uiEnd());
      addTearDown(client.close);
      await expectLater(
        client.connect(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'omniflow.sqlite is locked',
          ),
        ),
      );
      final result = await client.call('device.list');
      expect(errorOf(result)['type'], 'unavailable');
      expect('${errorOf(result)['message']}', contains('is locked'));
    });

    test('each UI gets only the replies to its own calls', () async {
      final engine = FakeEngine();
      engine.answerers['echo'] = (args) => {'ok': true, 'n': args['n']};
      final link = LoopbackLink();
      link.host.attach(engine);
      final old = ServiceEngineClient(link.uiEnd());
      final reopened = ServiceEngineClient(link.uiEnd());
      addTearDown(old.close);
      addTearDown(reopened.close);
      expect(old.session, isNot(reopened.session));
      final results = await Future.wait([
        old.call('echo', {'n': 1}),
        reopened.call('echo', {'n': 2}),
      ]);
      expect([for (final r in results) r['n']], [1, 2]);
    });

    test('engine events reach the UI', () async {
      final engine = FakeEngine();
      final link = LoopbackLink();
      link.host.attach(engine);
      final client = ServiceEngineClient(link.uiEnd());
      addTearDown(client.close);
      final event = client.events.first;
      engine.eventsOut.add({
        'event': 'device.stateChanged',
        'device': {
          'id': 'desk_lamp',
          'state': {'state': true},
        },
      });
      expect(await event, {
        'event': 'device.stateChanged',
        'device': {
          'id': 'desk_lamp',
          'state': {'state': true},
        },
      });
    });

    test('a stop tells the UI and answers what was waiting', () async {
      final engine = FakeEngine()..delay = const Duration(seconds: 5);
      final link = LoopbackLink();
      link.host.attach(engine);
      final client = ServiceEngineClient(link.uiEnd());
      await client.connect();
      final stopped = client.events.firstWhere(
        (e) => e['event'] == serviceStoppedEvent,
      );
      final waiting = client.call('device.list');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await link.host.stop('Stopped from the notification');
      expect(await stopped, {
        'event': serviceStoppedEvent,
        'reason': 'Stopped from the notification',
      });
      expect(errorOf(await waiting)['type'], 'unavailable');
      final later = await client.call('device.list');
      expect(errorOf(later)['message'], 'Stopped from the notification');
    });

    test('a result that is not JSON comes back as an internal error', () async {
      final engine = FakeEngine();
      engine.answers['engine.status'] = {'ok': true, 'at': DateTime(2026)};
      final link = LoopbackLink();
      link.host.attach(engine);
      final client = ServiceEngineClient(link.uiEnd());
      addTearDown(client.close);
      final result = await client.call('engine.status');
      expect(errorOf(result)['type'], 'internal');
    });

    test('a call the service never answers times out as unavailable', () async {
      final link = LoopbackLink()..serviceDeaf = true;
      final client = ServiceEngineClient(
        link.uiEnd(),
        callTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(client.close);
      final result = await client.call('device.list');
      expect(errorOf(result)['type'], 'unavailable');
    });

    test('a TV file transfer gets the longer transfer timeout', () async {
      final engine = FakeEngine()..delay = const Duration(milliseconds: 150);
      final link = LoopbackLink();
      link.host.attach(engine);
      final client = ServiceEngineClient(
        link.uiEnd(),
        callTimeout: const Duration(milliseconds: 50),
        transferTimeout: const Duration(seconds: 5),
      );
      addTearDown(client.close);
      final upload = await client.call('tv.files.upload', {'id': 'tv'});
      expect(upload['ok'], isTrue, reason: '$upload');
      final state = await client.call('tv.state', {'id': 'tv'});
      expect(errorOf(state)['type'], 'unavailable');
    });

    test('garbage on the link is ignored', () async {
      final link = LoopbackLink();
      link.host.attach(FakeEngine());
      await link.host.receive('not json');
      await link.host.receive(42);
      await link.host.receive(LinkMessage.encode({'t': 'call', 'id': 1}));
      final client = ServiceEngineClient(link.uiEnd());
      addTearDown(client.close);
      expect(await client.connect(), isNull);
    });
  });

  group('connectToService', () {
    test('starts a service that is not running and connects', () async {
      final link = LoopbackLink();
      final control = _FakeControl(link, hubError: 'no Wi-Fi');
      final started = await connectToService(
        control: control,
        link: link.uiEnd,
      );
      addTearDown((started.client as ServiceEngineClient).close);
      expect(control.starts, 1);
      expect(control.restarts, 0);
      expect(started.hubError, 'no Wi-Fi');
      expect((await started.client.call('device.list'))['ok'], isTrue);
    });

    test('a running service that answers is used as it is', () async {
      final link = LoopbackLink();
      link.host.attach(FakeEngine());
      final control = _FakeControl(link, running: true);
      final started = await connectToService(
        control: control,
        link: link.uiEnd,
      );
      addTearDown((started.client as ServiceEngineClient).close);
      expect(control.starts + control.restarts, 0);
    });

    test('a running service that does not answer is restarted', () async {
      final link = LoopbackLink()..serviceDeaf = true;
      final control = _FakeControl(link, running: true);
      final started = await connectToService(
        control: control,
        link: link.uiEnd,
        runningTimeout: const Duration(milliseconds: 100),
      );
      addTearDown((started.client as ServiceEngineClient).close);
      expect(control.restarts, 1);
      expect((await started.client.call('device.list'))['ok'], isTrue);
    });

    for (final afterReady in [false, true]) {
      test('the replaced task stopping ${afterReady ? 'after' : 'before'} '
          'the new one answers leaves the new client open', () async {
        final link = LoopbackLink()..serviceDeaf = true;
        final control = _FakeControl(link, running: true);
        late EngineHost old;
        control.onStart = () {
          old = link.replaceHost();
          final fresh = link.host;
          link.serviceDeaf = false;
          if (!afterReady) {
            Timer(
              const Duration(milliseconds: 10),
              () => old.stop('OmniFlow was stopped'),
            );
          }
          Timer(
            const Duration(milliseconds: 40),
            () => fresh.attach(FakeEngine()),
          );
        };
        final started = await connectToService(
          control: control,
          link: link.uiEnd,
          timeout: const Duration(seconds: 2),
          runningTimeout: const Duration(milliseconds: 100),
        );
        final client = started.client as ServiceEngineClient;
        addTearDown(client.close);
        final events = <Map<String, Object?>>[];
        client.events.listen(events.add);
        if (afterReady) await old.stop('OmniFlow was stopped');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(control.restarts, 1);
        expect(events, isEmpty);
        expect((await client.call('device.list'))['ok'], isTrue);

        await link.host.stop('Stopped from the notification');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(events.single['reason'], 'Stopped from the notification');
      });
    }

    test('a service that never answers fails the start', () async {
      final link = LoopbackLink()..serviceDeaf = true;
      final control = _FakeControl(link)..onStart = () {};
      await expectLater(
        connectToService(
          control: control,
          link: link.uiEnd,
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('the service task', () {
    const channel = MethodChannel(MulticastLock.channelName);
    late List<String> lockCalls;

    setUp(() {
      lockCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            lockCalls.add(call.method);
            return call.method == 'acquire';
          });
    });

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    /// A handler wired to a UI client the way the plugin's data channel
    /// wires them.
    ({OmniTaskHandler handler, ServiceEngineClient client, List<int> stops})
    wire(Future<Started> Function() open) {
      final toUi = StreamController<String>.broadcast();
      final stops = <int>[];
      late OmniTaskHandler handler;
      handler = OmniTaskHandler(
        open: open,
        send: toUi.add,
        stopService: () async {
          stops.add(1);
          await handler.onDestroy(DateTime.now(), false);
          return null;
        },
      );
      final client = ServiceEngineClient(
        _CallbackLink(handler.onReceiveData, toUi.stream),
      );
      return (handler: handler, client: client, stops: stops);
    }

    test('holds the multicast lock while the engine runs, and the Stop '
        'button closes the engine and releases it', () async {
      final home = await Directory.systemTemp.createTemp('omni_task');
      addTearDown(() => home.delete(recursive: true));
      final engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
      );
      final engineDone = Completer<void>();
      engine.events.listen(null, onDone: engineDone.complete);
      final w = wire(
        () async => (client: InProcessEngineClient(engine), hubError: null),
      );
      await w.handler.onStart(DateTime.now(), TaskStarter.developer);
      expect(lockCalls, ['acquire']);
      expect(await w.client.connect(), isNull);
      expect((await w.client.call('device.list'))['ok'], isTrue);

      final stopped = w.client.events.firstWhere(
        (e) => e['event'] == serviceStoppedEvent,
      );
      w.handler.onNotificationButtonPressed('open');
      expect(w.stops, isEmpty);
      w.handler.onNotificationButtonPressed(stopButtonId);
      expect((await stopped)['reason'], 'Stopped from the notification');
      await engineDone.future.timeout(const Duration(seconds: 5));
      expect(w.stops, [1]);
      expect(lockCalls, ['acquire', 'release']);
    });

    test('a restarted task opens only once the old engine is closed', () async {
      final order = <String>[];
      final closing = Completer<void>();
      final old = OmniTaskHandler(
        open: () async =>
            (client: FakeEngine() as EngineClient, hubError: null),
        send: (_) {},
        stopService: () async => null,
        owner: EngineOwner(name: 'test.restart'),
        inputs: (_) => _SlowStopInputs(closing.future, order),
      );
      await old.onStart(DateTime.now(), TaskStarter.developer);
      final replacement = OmniTaskHandler(
        open: () async {
          order.add('new open');
          return (client: FakeEngine() as EngineClient, hubError: null);
        },
        send: (_) {},
        stopService: () async => null,
        owner: EngineOwner(name: 'test.restart'),
      );
      // The plugin does not wait for onDestroy before the new onStart.
      final destroyed = old.onDestroy(DateTime.now(), false);
      final started = replacement.onStart(DateTime.now(), TaskStarter.system);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(order, isEmpty);
      closing.complete();
      await destroyed;
      await started;
      expect(order, ['old closed', 'new open']);
      await replacement.onDestroy(DateTime.now(), false);
    });

    test('an old task that never answers holds off the new one only for '
        'a while', () async {
      // A port with no owner left behind, as a killed isolate leaves it.
      final dead = ReceivePort();
      IsolateNameServer.registerPortWithName(dead.sendPort, 'test.dead');
      addTearDown(dead.close);
      final opened = Completer<void>();
      final h = OmniTaskHandler(
        open: () async {
          opened.complete();
          return (client: FakeEngine() as EngineClient, hubError: null);
        },
        send: (_) {},
        stopService: () async => null,
        owner: EngineOwner(
          name: 'test.dead',
          wait: const Duration(milliseconds: 50),
        ),
      );
      await h.onStart(DateTime.now(), TaskStarter.system);
      expect(opened.isCompleted, isTrue);
      await h.onDestroy(DateTime.now(), false);
    });

    test('an engine that fails to open is reported to the UI', () async {
      final w = wire(() async => throw StateError('disk full'));
      await w.handler.onStart(DateTime.now(), TaskStarter.system);
      await expectLater(w.client.connect(), throwsA(isA<StateError>()));
      await w.client.close();
    });

    test('the lock reads as not held without the native side', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await MulticastLock().acquire(), isFalse);
    });
  });

  testWidgets('a stopped service says so, and Start connects again', (
    tester,
  ) async {
    var attempts = 0;
    final engine = FakeEngine();
    await tester.pumpWidget(
      Launcher(
        start: () async {
          attempts++;
          return (client: engine as EngineClient, hubError: null);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Desk lamp'), findsOneWidget);
    engine.eventsOut.add({
      'event': serviceStoppedEvent,
      'reason': 'Stopped from the notification',
    });
    await tester.pumpAndSettle();
    expect(find.text('OmniFlow is stopped'), findsOneWidget);
    expect(
      find.textContaining('Stopped from the notification'),
      findsOneWidget,
    );
    expect(find.text('Desk lamp'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('service-start')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Desk lamp'), findsOneWidget);
  });

  for (final byUser in [false, true]) {
    testWidgets(
      byUser
          ? 'after the user stops it, the app waits for Start'
          : 'a service Android stopped and started again is reconnected',
      (tester) async {
        var attempts = 0;
        var running = false;
        final engine = FakeEngine();
        await tester.pumpWidget(
          Launcher(
            start: () async {
              attempts++;
              return (client: engine as EngineClient, hubError: null);
            },
            serviceRunning: () async => running,
          ),
        );
        await tester.pumpAndSettle();
        engine.eventsOut.add({
          'event': serviceStoppedEvent,
          'reason': byUser
              ? stoppedFromNotification
              : 'Android stopped the service',
        });
        await tester.pumpAndSettle();
        expect(find.text('OmniFlow is stopped'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        expect(attempts, 1, reason: 'not back yet');
        running = true;
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(attempts, byUser ? 1 : 2);
        expect(find.text('Desk lamp'), byUser ? findsNothing : findsOneWidget);
      },
    );
  }
}

class _CallbackLink implements EngineLink {
  _CallbackLink(this._deliver, this.incoming);

  final void Function(Object data) _deliver;

  @override
  final Stream<String> incoming;

  @override
  void send(String message) => Future.microtask(() => _deliver(message));

  @override
  Future<void> close() async {}
}

/// Phone inputs whose stop waits for [until], standing in for an engine
/// that takes a while to close.
class _SlowStopInputs implements PhoneInputs {
  _SlowStopInputs(this.until, this.order);

  final Future<void> until;
  final List<String> order;

  @override
  void start() {}

  @override
  Future<void> stop() async {
    await until;
    order.add('old closed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
