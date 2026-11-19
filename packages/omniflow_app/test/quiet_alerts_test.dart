import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/house_calls.dart';
import 'package:omniflow_app/service/foreground_runtime.dart';
import 'package:omniflow_app/service/notifier.dart';
import 'package:omniflow_app/ui/app.dart' show toastsAnnouncement;
import 'package:omniflow_app/ui/settings/alerts_page.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

void main() {
  group('device alerts', () {
    test('not answering is off unless the engine says it is on', () {
      expect(HouseAlerts.fromJson(const {'battery': true}).offline, isFalse);
      expect(HouseAlerts.fromJson(const {'offline': true}).offline, isTrue);
      expect(HouseAlerts.fromJson(const {}).battery, isTrue);
    });

    test('a device that stopped or started answering is no toast, a '
        'notify step is', () {
      Map<String, Object?> announce([String? alert]) => {
        'event': 'flow.announce',
        'title': 'Bedroom Light is not answering',
        'alert': ?alert,
      };
      expect(toastsAnnouncement(announce('offline')), isFalse);
      expect(toastsAnnouncement(announce('online')), isFalse);
      expect(toastsAnnouncement(announce()), isTrue);
      expect(toastsAnnouncement(announce('battery')), isTrue);
      expect(toastsAnnouncement({'event': 'run.finished'}), isFalse);
    });

    testWidgets('while the app is open, a device not answering shows no '
        'toast', (tester) async {
      final engine = FakeEngine();
      await pumpApp(tester, engine);
      engine.eventsOut.add({
        'event': 'flow.announce',
        'type': 'notify',
        'title': 'Bedroom Light is not answering',
        'alert': 'offline',
        'thing': 'bulb',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SnackBar), findsNothing);
      engine.eventsOut.add({'event': 'flow.announce', 'title': 'Welcome home'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Welcome home'), findsOneWidget);
    });

    testWidgets('Alerts shows not answering off, and how to hide the '
        'running notice', (tester) async {
      final engine = FakeEngine()
        ..answers['alerts.get'] = {'ok': true, 'battery': true};
      await pumpPushed(tester, engine, const AlertsPage());
      final offline = tester.widget<Switch>(
        find.descendant(
          of: find.byKey(const ValueKey('alert-offline')),
          matching: find.byType(Switch),
        ),
      );
      expect(offline.value, isFalse);
      expect(find.text(runningNoticeHint), findsOneWidget);
      expect(runningNoticeHint, contains(serviceChannelName));
    });
  });

  test('a failed run names the device that did not answer, once', () async {
    final engine = FakeEngine()
      ..answers['automation.get'] = {'ok': true, 'name': 'Lights on'};
    final posted = <(String, String, String?)>[];
    final notifier = AutomationNotifier(
      engine,
      post:
          ({required channel, required id, required title, body, link}) async {
            posted.add((channel, title, body));
          },
    );
    await notifier.start();
    addTearDown(notifier.stop);
    final failed = {
      'event': 'run.finished',
      'flow': 'lights_on',
      'run': 'r1',
      'outcome': 'failed',
      'reason': 'Bedroom Light did not answer. Is it switched on?',
    };
    for (var i = 0; i < 3; i++) {
      engine.eventsOut.add(failed);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }
    expect(posted, [
      (
        'problems',
        'Lights on did not finish',
        'Bedroom Light did not answer. Is it switched on?',
      ),
    ]);
  });

  group('the running notice', () {
    test('is on its own quiet channel, named plainly', () {
      final o = serviceNotificationOptions;
      expect(o.channelId, serviceChannelId);
      expect(o.channelName, 'Running in the background');
      expect(o.channelImportance, NotificationChannelImportance.MIN);
      expect(o.priority, NotificationPriority.MIN);
      expect(
        (o.playSound, o.enableVibration, o.showBadge, o.showWhen),
        (false, false, false, false),
      );
      expect(serviceText.length, lessThan(30));
    });

    test('an update moves a running service to the same channel', () {
      final kotlin = File(
        'android/app/src/main/kotlin/com/jashnm/omniflow_app/'
        'OmniFlowApplication.kt',
      ).readAsStringSync();
      expect(kotlin, contains('"$serviceChannelId"'));
      expect(kotlin, contains('"$serviceChannelName"'));
      expect(kotlin, contains('IMPORTANCE_MIN'));
    });
  });
}
