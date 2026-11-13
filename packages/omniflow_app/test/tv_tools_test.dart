import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'automations_fixtures.dart' show tapKey;
import 'tv_fixtures.dart';

/// A 1x1 PNG, enough for Image.memory to draw a frame.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

void main() {
  testWidgets('Screen shows the TV, sends a tap where it lands, and records', (
    tester,
  ) async {
    final engine = tvEngine()
      ..answers.addAll({
        'tv.screenshot': {
          'ok': true,
          'png': _png,
          'width': 1920,
          'height': 1080,
        },
        'tv.input.tap': {'ok': true},
        'tv.record.status': {'ok': true, 'recording': false},
        'tv.record.start': {
          'ok': true,
          'file': '/sdcard/Movies/OmniFlow/rec-1.mp4',
          'seconds': 60,
        },
        'tv.record.stop': {
          'ok': true,
          'file': '/sdcard/Movies/OmniFlow/rec-1.mp4',
          'bytes': 1000,
        },
      });
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Screen');
    expect(find.byKey(const ValueKey('tv-screen-touch')), findsOneWidget);
    final box = tester.getRect(find.byKey(const ValueKey('tv-screen-touch')));
    await tester.tapAt(box.center);
    await tester.pumpAndSettle();
    final tap = argsOf(engine, 'tv.input.tap').single;
    expect((tap['x']! as double), closeTo(0.5, 0.02));
    expect((tap['y']! as double), closeTo(0.5, 0.02));

    await tapKey(tester, 'tv-record-start');
    expect(argsOf(engine, 'tv.record.start').single['seconds'], 60);
    expect(find.byKey(const ValueKey('tv-record-stop')), findsOneWidget);
    await tapKey(tester, 'tv-record-stop');
    expect(find.byKey(const ValueKey('tv-record-download')), findsOneWidget);
  });

  testWidgets('System shows the TV working, stops an app, and asks before a '
      'restart', (tester) async {
    final engine = tvEngine()
      ..answers.addAll({
        'tv.system': {
          'ok': true,
          'cpu': {'percent': 42},
          'memory': {'totalKb': 2000000, 'availableKb': 500000},
          'storage': [
            {'mount': '/data', 'sizeKb': 8000000, 'usedKb': 6000000},
          ],
          'network': {'rxBytes': 1000, 'txBytes': 10},
          'uptimeSeconds': 7300,
          'temperatureC': 51.5,
        },
        'tv.processes': {
          'ok': true,
          'apps': [
            {
              'package': 'com.netflix.ninja',
              'pid': 4321,
              'memoryKb': 300000,
              'foreground': true,
            },
          ],
        },
        'tv.power': {'ok': true},
      });
    await pumpTv(tester, engine);
    await openTvTab(tester, 'System');
    expect(find.text('42%'), findsOneWidget);
    expect(find.textContaining('of 1.9 GB'), findsOneWidget);
    expect(
      find.text('51 °C').evaluate().length +
          find.text('52 °C').evaluate().length,
      1,
    );
    await tapKey(tester, 'tv-process-stop-com.netflix.ninja');
    expect(argsOf(engine, 'tv.app').last, containsPair('action', 'stop'));
    await tester.ensureVisible(find.byKey(const ValueKey('tv-reboot')));
    await tapKey(tester, 'tv-reboot');
    expect(find.text('Restart the TV?'), findsOneWidget);
    expect(argsOf(engine, 'tv.power'), isEmpty);
    await tapKey(tester, 'confirm');
    expect(argsOf(engine, 'tv.power').single['action'], 'reboot');
  });

  testWidgets('Gamepad sends A as the controller key', (tester) async {
    final engine = tvEngine();
    await pumpTv(tester, engine);
    await tester.tap(find.text('Gamepad'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'key-96');
    final sent = argsOf(engine, 'tv.key').last;
    expect(sent['keycode'] ?? sent['key'], anyOf(96, 'button_a'));
  });

  testWidgets('Mouse clicks where the pointer is, and a drag moves it', (
    tester,
  ) async {
    final engine = tvEngine()
      ..answers.addAll({
        'tv.screenshot': {
          'ok': true,
          'png': _png,
          'width': 1920,
          'height': 1080,
        },
        'tv.input.tap': {'ok': true},
      });
    await pumpTv(tester, engine);
    await tester.tap(find.text('Mouse'));
    await tester.pumpAndSettle();
    // Its picture refreshes on its own, so it never raises the TV's prompt.
    expect(argsOf(engine, 'tv.screenshot').first['allowPairing'], false);
    await tapKey(tester, 'tv-mouse-click');
    var tap = argsOf(engine, 'tv.input.tap').last;
    expect((tap['x']! as double, tap['y']! as double), (0.5, 0.5));
    final pad = find.byKey(const ValueKey('tv-mouse-pad'));
    await tester.drag(pad, const Offset(100, 0));
    await tester.pumpAndSettle();
    await tapKey(tester, 'tv-mouse-click');
    tap = argsOf(engine, 'tv.input.tap').last;
    expect(tap['x']! as double, greaterThan(0.5));
    // Up and down moves the pointer too: the page does not take the drag.
    await tester.drag(pad, const Offset(0, 120));
    await tester.pumpAndSettle();
    await tapKey(tester, 'tv-mouse-click');
    tap = argsOf(engine, 'tv.input.tap').last;
    expect(tap['y']! as double, greaterThan(0.5));
    // A quick, still touch on the pad is a click.
    final clicks = argsOf(engine, 'tv.input.tap').length;
    await tester.tap(pad);
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.input.tap').length, clicks + 1);
    await tester.pump(const Duration(seconds: 2));
  });
}
