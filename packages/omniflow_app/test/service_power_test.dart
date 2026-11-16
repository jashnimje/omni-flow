import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/service/foreground_runtime.dart';
import 'package:omniflow_app/service/multicast_lock.dart';
import 'package:omniflow_app/service/notifier.dart';
import 'package:omniflow_app/service/phone_actions.dart';
import 'package:omniflow_app/service/phone_inputs.dart';
import 'package:omniflow_app/service/service_power.dart';
import 'package:omniflow_app/service/usb_links.dart';

import 'service_fake_engine.dart';

/// The service keeps automations running for months: it holds the CPU and
/// the Wi-Fi locks only when needed, wakes for time triggers with exact
/// alarms, retries a start that failed, and says when nothing runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 13, 9);

  group('the power plan', () {
    test('holds nothing and sets no alarm with nothing to do', () {
      final p = planPower(now: now, runs: 0, exact: true);
      expect(p.cpu, isFalse);
      expect(p.wifi, isFalse);
      expect(p.multicast, isFalse);
      expect(p.wakeAt, isNull);
    });

    test('lets the CPU sleep until an exact alarm before a far time', () {
      final due = now.add(const Duration(hours: 5));
      final p = planPower(now: now, runs: 0, exact: true, nextDue: due);
      expect(p.cpu, isFalse);
      expect(p.wakeAt, due.subtract(wakeLead));
      expect(p.recheckAt, due.subtract(stayAwakeBefore));
    });

    test('stays awake, for a bounded time, close to a time trigger', () {
      final due = now.add(const Duration(minutes: 3));
      final p = planPower(now: now, runs: 0, exact: true, nextDue: due);
      expect(p.cpu, isTrue);
      expect(p.cpuFor, const Duration(minutes: 3) + wakeLead);
      expect(p.wakeAt, isNull);
      expect(p.recheckAt, due.add(const Duration(seconds: 5)));
    });

    test('without exact alarms, an armed time trigger keeps the CPU awake', () {
      final due = now.add(const Duration(hours: 5));
      final p = planPower(now: now, runs: 0, exact: false, nextDue: due);
      expect(p.cpu, isTrue);
      expect(p.cpuFor, holdTurn);
      expect(p.recheckAt, now.add(holdTurn - const Duration(minutes: 5)));
    });

    test('a run holds the CPU, Wi-Fi and multicast; a board multicast', () {
      final run = planPower(now: now, runs: 1, exact: true);
      expect((run.cpu, run.wifi, run.multicast), (true, true, true));
      expect(run.cpuFor, longestRun);
      final board = planPower(now: now, runs: 0, exact: true, boards: true);
      expect((board.cpu, board.wifi, board.multicast), (false, false, true));
    });

    test('a short window holds the CPU until it ends', () {
      final p = planPower(
        now: now,
        runs: 0,
        exact: true,
        awakeUntil: now.add(const Duration(seconds: 30)),
      );
      expect(p.cpu, isTrue);
      expect(p.cpuFor, const Duration(seconds: 30));
    });
  });

  group('the service power', () {
    late _Hands hands;
    late StreamController<Map<String, Object?>> events;
    late List<String> explained;
    var retimed = 0;
    DateTime? due;

    ServicePower make() => ServicePower(
      hands: hands,
      events: events.stream,
      nextDue: () => due,
      retime: () => retimed++,
      explain: (title, body, open) async => explained.add(open),
      now: () => now,
    );

    setUp(() {
      hands = _Hands();
      events = StreamController.broadcast();
      explained = [];
      retimed = 0;
      due = null;
    });

    test('holds the locks from a run starting until it finishes', () async {
      final power = make();
      await power.start();
      expect(hands.cpu.last, isFalse);
      events.add({'event': 'run.node', 'run': 'r1', 'status': 'done'});
      await pumpEventQueue();
      expect(hands.cpu.last, isTrue);
      expect(hands.wifi.last, isTrue);
      events.add({'event': 'run.finished', 'run': 'r1'});
      await pumpEventQueue();
      expect(hands.cpu.last, isFalse);
      expect(hands.wifi.last, isFalse);
      await power.stop();
      expect(hands.wakes.last, isNull);
    });

    test('sets the alarm for the next time, and the alarm retimes the '
        'engine and keeps it awake a moment', () async {
      due = now.add(const Duration(hours: 2));
      final power = make();
      await power.start();
      expect(hands.wakes.last, due!.subtract(wakeLead));
      expect(power.held!.cpu, isFalse);
      hands.signal('wake');
      await pumpEventQueue();
      expect(retimed, 1);
      expect(hands.cpu.last, isTrue);
      hands.signal('clock');
      await pumpEventQueue();
      expect(retimed, 2);
      await power.stop();
    });

    test('says once why time triggers keep the phone awake without exact '
        'alarms', () async {
      hands.exact = false;
      due = now.add(const Duration(hours: 2));
      final power = make();
      await power.start();
      expect(power.held!.cpu, isTrue);
      await power.plan();
      expect(explained, ['alarms']);
      await power.stop();
    });

    test('a Wi-Fi change opens a short awake window', () async {
      final power = make();
      await power.start();
      power.wifiChanged();
      await pumpEventQueue();
      expect(power.held!.cpu, isTrue);
      expect(power.held!.multicast, isTrue);
      await power.stop();
    });
  });

  group('the service task', () {
    test('Stop asks first; Keep running goes back, Stop stops and says '
        'how to start again', () async {
      final notice = _Notice();
      final stops = <int>[];
      final handler = OmniTaskHandler(
        open: () async =>
            (client: ServiceFakeEngine() as EngineClient, hubError: null),
        send: (_) {},
        stopService: () async => stops.add(1),
        notice: notice,
        lock: _quietLock(),
      );
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      expect(notice.titles.last, serviceTitle);
      expect(notice.reasons, isEmpty);

      handler.onNotificationButtonPressed(stopButtonId);
      await pumpEventQueue();
      expect(stops, isEmpty);
      expect(notice.titles.last, stopConfirmTitle);
      expect(notice.buttons.last.map((b) => b.id), [
        stopConfirmId,
        keepRunningId,
      ]);

      handler.onNotificationButtonPressed(keepRunningId);
      await pumpEventQueue();
      expect(notice.titles.last, serviceTitle);

      handler.onNotificationButtonPressed(stopButtonId);
      handler.onNotificationButtonPressed(stopConfirmId);
      await pumpEventQueue();
      expect(stops, [1]);
      expect(notice.reasons.single, contains('Tap Start'));
      await handler.onDestroy(DateTime.now(), false);
    });

    test('an engine that fails to open says why and is tried again until '
        'it opens', () async {
      final notice = _Notice();
      var tries = 0;
      final engine = ServiceFakeEngine();
      final handler = OmniTaskHandler(
        open: () async {
          if (++tries < 3) throw StateError('the database is locked');
          return (client: engine as EngineClient, hubError: null);
        },
        send: (_) {},
        stopService: () async => null,
        notice: notice,
        lock: _quietLock(),
        retryDelays: const [Duration(milliseconds: 5)],
      );
      await handler.onStart(DateTime.now(), TaskStarter.system);
      expect(notice.titles.last, notArmedTitle);
      expect(notice.reasons.single, contains('the database is locked'));
      expect(handler.trouble, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tries, 3);
      expect(handler.trouble, isNull);
      expect(notice.titles.last, serviceTitle);
      expect(notice.cleared, 1);
      await handler.onDestroy(DateTime.now(), false);
    });

    test('a hub that did not start is started again', () async {
      final notice = _Notice();
      final engine = ServiceFakeEngine()
        ..answers['hub.start'] = {
          'ok': false,
          'error': {'type': 'unavailable', 'message': 'port 38900 is busy'},
        };
      final handler = OmniTaskHandler(
        open: () async =>
            (client: engine as EngineClient, hubError: 'port 38900 is busy'),
        send: (_) {},
        stopService: () async => null,
        notice: notice,
        lock: _quietLock(),
        retryDelays: const [Duration(milliseconds: 5)],
      );
      await handler.onStart(DateTime.now(), TaskStarter.system);
      expect(notice.titles.last, notArmedTitle);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(engine.argsOf('hub.start'), isNotEmpty);
      expect(engine.argsOf('hub.start').first, hubStartArgs);
      engine.answers['hub.start'] = {'ok': true};
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(handler.trouble, isNull);
      expect(notice.titles.last, serviceTitle);
      await handler.onDestroy(DateTime.now(), false);
    });
  });

  group('notifications', () {
    late ServiceFakeEngine engine;
    late List<(String, int, String, String?)> posted;
    late AutomationNotifier notifier;

    setUp(() {
      engine = ServiceFakeEngine();
      posted = [];
      notifier = AutomationNotifier(
        engine,
        post: ({
          required channel,
          required id,
          required title,
          body,
          link,
        }) async => posted.add((channel, id, title, body)),
        now: () => DateTime(2026, 11, 13, 9),
      )..start();
    });

    tearDown(() => notifier.stop());

    test('device alerts post on their own channel, keep the engine\'s '
        'words, and back online replaces offline', () async {
      engine.eventsOut.add({
        'event': 'flow.announce',
        'title': 'Desk lamp is offline',
        'body': 'Not heard from for 5 days',
        'alert': 'offline',
        'thing': 'lamp',
      });
      await pumpEventQueue();
      engine.eventsOut.add({
        'event': 'flow.announce',
        'title': 'Desk lamp is back online',
        'body': 'It answers again',
        'alert': 'online',
        'thing': 'lamp',
      });
      await pumpEventQueue();
      expect(posted.first.$1, alertsChannel);
      expect(posted.first.$4, 'Not heard from for 5 days');
      expect(engine.calls.where((c) => c.$1 == 'device.get'), isEmpty);
      expect(posted.last.$2, posted.first.$2);
    });

    test('a notice with no automation keeps one id per title', () async {
      for (var i = 0; i < 3; i++) {
        engine.eventsOut.add({'event': 'flow.announce', 'title': 'Hello'});
        await pumpEventQueue();
      }
      expect({for (final p in posted) p.$2}, hasLength(1));
    });

    test('an ask with no text says what it waits for', () async {
      final asked = <AskNotice>[];
      engine.answers['automation.get'] = {'ok': true, 'name': 'Night lights'};
      final n = AutomationNotifier(
        engine,
        post: ({
          required channel,
          required id,
          required title,
          body,
          link,
        }) async {},
        postAsk: (a) async => asked.add(a),
      )..start();
      engine.eventsOut.add({
        'event': 'ask.request',
        'askId': 'a1',
        'kind': 'confirm',
        'title': 'Run Night lights?',
        'flow': 'night',
      });
      await pumpEventQueue();
      expect(
        asked.single.body,
        'Tap Run to let Night lights go ahead, or Not now to skip it',
      );
      expect(asked.single.group, 'ask/a1');
      await n.stop();
    });
  });

  group('phone inputs', () {
    test('location off with a Wi-Fi place is told once, and again only '
        'after it was back on', () async {
      final engine = ServiceFakeEngine()
        ..answers['device.list'] = {
          'ok': true,
          'devices': [
            {
              'id': 'home',
              'driver': 'place',
              'settings': {
                'wifi': {
                  'ssids': ['Home'],
                },
              },
            },
          ],
        };
      final readings = StreamController<Object?>.broadcast();
      final told = <String?>[];
      final inputs = PhoneInputs(
        engine,
        readings: readings.stream,
        post: ({
          required channel,
          required id,
          required title,
          body,
          link,
          open,
        }) async => told.add(open),
      )..start();
      readings.add({'kind': 'location', 'on': false});
      await pumpEventQueue();
      readings.add({'kind': 'wifi', 'connected': true, 'locationOn': false});
      await pumpEventQueue();
      expect(told, ['location']);
      expect(inputs.locationOn, isFalse);
      expect(engine.argsOf('phone.wifi'), isEmpty);
      readings.add({'kind': 'location', 'on': true});
      readings.add({'kind': 'location', 'on': false});
      await pumpEventQueue();
      expect(told, ['location', 'location']);
      await inputs.stop();
    });

    test('a Wi-Fi change is passed to the service', () async {
      final readings = StreamController<Object?>.broadcast();
      var changes = 0;
      final inputs = PhoneInputs(ServiceFakeEngine(), readings: readings.stream)
        ..onWifiChanged = () => changes++;
      inputs.start();
      readings.add({'kind': 'wifi', 'connected': true, 'ssid': 'Home'});
      readings.add({'kind': 'wifi', 'connected': true, 'ssid': 'Home'});
      readings.add({'kind': 'wifi', 'connected': false});
      await pumpEventQueue();
      expect(changes, 2);
      await inputs.stop();
    });
  });

  group('calendar', () {
    test(
      'says when the next report is due, and reads again on a change',
      () async {
        final at = DateTime.now().add(const Duration(hours: 1));
        final hands = _CalendarHands([
          {
            'words': 'gym',
            'title': 'Gym',
            'begin': at.millisecondsSinceEpoch,
            'end': at.add(const Duration(hours: 1)).millisecondsSinceEpoch,
          },
        ]);
        final engine = ServiceFakeEngine()
          ..answers[PhoneActionRunner.ready] = {
            'ok': true,
            'phone': 'phone',
            'watch': {
              'calendarWords': ['gym'],
            },
          };
        var timed = 0;
        final runner = PhoneActionRunner(engine, hands: hands)
          ..onCalendarTimed = () => timed++;
        runner.start();
        await pumpEventQueue();
        expect(
          runner.nextCalendarDue,
          DateTime.fromMillisecondsSinceEpoch(at.millisecondsSinceEpoch),
        );
        expect(timed, 1);
        runner.calendarChanged();
        await pumpEventQueue();
        expect(hands.reads, 2);
        await runner.stop();
        expect(runner.nextCalendarDue, isNull);
      },
    );
  });

  group('USB boards', () {
    const methods = MethodChannel('omniflow/usb');
    const events = 'omniflow/usb_data';
    late List<String> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (call) async {
            calls.add(call.method);
            return call.method == 'permission' ? true : null;
          });
    });

    tearDown(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockStreamHandler(const EventChannel(events), null);
    });

    test('a board that comes back on the same name is opened again', () async {
      final sink = StreamController<Object?>.broadcast();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
            const EventChannel(events),
            MockStreamHandler.inline(
              onListen: (_, out) => sink.stream.listen(out.success),
            ),
          );
      final links = UsbLinks();
      final link = await links.open('usb:1a86:7523', 115200);
      await pumpEventQueue();
      sink.add({'event': 'detached', 'path': 'usb:1a86:7523'});
      await pumpEventQueue();
      await expectLater(link.write([1]), throwsA(isA<Exception>()));
      sink.add({'event': 'attached', 'path': 'usb:1a86:7523'});
      await pumpEventQueue();
      expect(calls.where((c) => c == 'open'), hasLength(2));
      await link.write([1]);
      expect(calls.last, 'write');
      await links.close();
    });
  });
}

MulticastLock _quietLock() => MulticastLock(const MethodChannel('test/none'));

class _Hands implements PowerHands {
  final cpu = <bool>[];
  final wifi = <bool>[];
  final multicast = <bool>[];
  final wakes = <DateTime?>[];
  var exact = true;
  final _signals = StreamController<String>.broadcast();

  void signal(String s) => _signals.add(s);

  @override
  Future<void> holdCpu(bool hold, {Duration? atMost}) async => cpu.add(hold);

  @override
  Future<void> holdWifi(bool hold) async => wifi.add(hold);

  @override
  Future<void> holdMulticast(bool hold) async => multicast.add(hold);

  @override
  Future<bool> wakeAt(DateTime? at) async {
    wakes.add(at);
    return exact;
  }

  @override
  Future<bool> exactAlarms() async => exact;

  @override
  Stream<String> get signals => _signals.stream;
}

class _Notice implements ServiceNotice {
  final titles = <String>[];
  final buttons = <List<NotificationButton>>[];
  final reasons = <String>[];
  var cleared = 0;

  @override
  Future<void> show(
    String title,
    String text,
    List<NotificationButton> buttons,
  ) async {
    titles.add(title);
    this.buttons.add(buttons);
  }

  @override
  Future<void> notRunning(String reason) async => reasons.add(reason);

  @override
  Future<void> running() async => cleared++;
}

class _CalendarHands implements PhoneHands {
  _CalendarHands(this.events);

  final List<Map<String, Object?>> events;
  var reads = 0;

  @override
  Future<Map<String, Object?>> run(
    String action,
    Map<String, Object?> params,
  ) async => const {'ok': true};

  @override
  Future<void> watch(Map<String, Object?> watch) async {}

  @override
  Future<List<Map<String, Object?>>> calendar(List<String> words) async {
    reads++;
    return events;
  }
}
