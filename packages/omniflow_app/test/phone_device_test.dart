import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/devices/open_device.dart';
import 'package:omniflow_app/ui/tv/tv_page.dart';

import 'automations_fixtures.dart' show tapKey;
import 'fake_engine.dart';
import 'screen_harness.dart';
import 'tv_fixtures.dart';

const phoneId = 'pixel';

/// A 1x1 PNG, enough for Image.memory to draw a frame.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

Map<String, Object?> phoneDevice() => {
  'id': phoneId,
  'name': 'Pixel',
  'driver': 'android_phone_adb',
  'host': '192.168.1.77',
  'stableId': 'adb-FAKE-AbCdEf',
  'settings': const <String, Object?>{},
  'state': const {'power': 'on', 'screen': 'on', 'app': null, 'volume': 5},
  'capabilities': const [],
};

/// A FakeEngine with one other phone, answering the tv.* reads for it.
FakeEngine phoneEngine() {
  final engine = tvEngine()..devices = [phoneDevice(), FakeEngine.lamp()];
  engine.answers.addAll({
    'tv.state': {
      'ok': true,
      'kind': 'phone',
      'power': 'on',
      'screen': 'on',
      'reachable': true,
      'app': 'com.android.chrome',
      'volume': 5,
      'volumeMax': 15,
      'muted': false,
    },
    'tv.screenshot': {'ok': true, 'png': _png, 'width': 1080, 'height': 2400},
    'tv.input.tap': {'ok': true},
    'tv.record.status': {'ok': true, 'recording': false},
  });
  return engine;
}

Future<void> pumpPhone(
  WidgetTester tester,
  FakeEngine engine, {
  Size size = const Size(1236, 5400),
}) => pumpScreen(
  tester,
  engine,
  const DeviceRoute(id: phoneId),
  size: size,
  overrides: [
    phoneFilesProvider.overrideWithValue(FakePhoneFiles()),
    tvPollProvider.overrideWithValue(const Duration(hours: 1)),
  ],
);

Future<void> openMore(WidgetTester tester) async {
  await tapKey(tester, 'tv-tab-more');
}

void main() {
  testWidgets('a phone opens the Android device page on Screen, with Apps '
      'and Files as tabs', (tester) async {
    final engine = phoneEngine();
    await pumpPhone(tester, engine);
    expect(find.byType(TvPage), findsOneWidget);
    for (final t in ['screen', 'apps', 'files']) {
      expect(find.byKey(ValueKey('tv-tab-$t')), findsOneWidget, reason: t);
    }
    expect(find.byKey(const ValueKey('tv-tab-remote')), findsNothing);
    expect(find.byKey(const ValueKey('tv-screen')), findsOneWidget);
    expect(find.text('Screen on'), findsNothing, reason: 'an app is in front');
    expect(find.bySemanticsLabel('Lock the phone'), findsOneWidget);
    expect(find.textContaining('TV'), findsNothing);
  });

  testWidgets('Files on a phone says Phone, not TV', (tester) async {
    final engine = phoneEngine();
    await pumpPhone(tester, engine);
    await tapKey(tester, 'tv-tab-files');
    expect(argsOf(engine, 'tv.files.list'), isNotEmpty);
    expect(find.text('Phone'), findsWidgets);
    expect(find.text('TV'), findsNothing);
  });

  testWidgets('More holds System, Settings, Remote and Console', (
    tester,
  ) async {
    await pumpPhone(tester, phoneEngine());
    await openMore(tester);
    for (final t in ['system', 'settings', 'remote', 'console']) {
      expect(find.byKey(ValueKey('tv-more-$t')), findsOneWidget, reason: t);
    }
    expect(find.byKey(const ValueKey('tv-more-files')), findsNothing);
    expect(find.text('change settings on the phone'), findsOneWidget);
  });

  testWidgets('the phone remote sends Back, Home, Recents, lock and the '
      'notification shade', (tester) async {
    final engine = phoneEngine();
    await pumpPhone(tester, engine);
    await openMore(tester);
    await tapKey(tester, 'tv-more-remote');
    expect(find.byKey(const ValueKey('phone-remote')), findsOneWidget);
    for (final code in [4, 3, 187, 24, 25, 26, 223, 224]) {
      await tapKey(tester, 'key-$code');
    }
    expect(
      [for (final a in argsOf(engine, 'tv.key')) a['keycode'] ?? a['key']],
      [4, 'home', 187, 24, 25, 26, 223, 224],
    );
    await tapKey(tester, 'phone-notifications');
    await tapKey(tester, 'phone-shade-close');
    expect(
      [for (final a in argsOf(engine, 'tv.notifications')) a['action']],
      ['expand', 'collapse'],
    );
    expect(find.byKey(const ValueKey('key-243')), findsNothing, reason: 'HDMI');
  });

  testWidgets('the screen fits a portrait phone and a tap lands where it is '
      'on the phone', (tester) async {
    final engine = phoneEngine();
    await pumpPhone(tester, engine, size: const Size(1236, 2400));
    expect(find.byKey(const ValueKey('tv-screen-portrait')), findsOneWidget);
    final touch = find.byKey(const ValueKey('tv-screen-touch'));
    final box = tester.getRect(touch);
    expect(box.width / box.height, closeTo(1080 / 2400, 0.01));
    final page = tester.getSize(find.byType(TvPage));
    expect(box.height, lessThan(page.height * 0.7));
    await tester.tapAt(
      box.topLeft + Offset(box.width * 0.25, box.height * 0.8),
    );
    await tester.pumpAndSettle();
    final tap = argsOf(engine, 'tv.input.tap').single;
    expect(tap['x']! as double, closeTo(0.25, 0.01));
    expect(tap['y']! as double, closeTo(0.8, 0.01));
  });

  testWidgets('a phone that stopped answering says to turn Wireless '
      'debugging on again', (tester) async {
    final engine = phoneEngine();
    engine.answers['tv.state'] = {
      'ok': true,
      'kind': 'phone',
      'power': null,
      'screen': null,
      'reachable': false,
      'message': 'pixel did not answer.',
    };
    await pumpPhone(tester, engine);
    expect(find.byKey(const ValueKey('tv-offline')), findsOneWidget);
    expect(find.textContaining('Wireless debugging'), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-pair')), findsNothing);
  });

  testWidgets('a TV still opens on Remote with its own tabs', (tester) async {
    await pumpScreen(
      tester,
      tvEngine(),
      const DeviceRoute(id: tvId),
      overrides: [
        phoneFilesProvider.overrideWithValue(FakePhoneFiles()),
        tvPollProvider.overrideWithValue(const Duration(hours: 1)),
      ],
    );
    expect(find.byKey(const ValueKey('tv-tab-remote')), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-tab-files')), findsNothing);
    expect(find.byKey(const ValueKey('phone-remote')), findsNothing);
    expect(find.bySemanticsLabel('Put the TV to sleep'), findsOneWidget);
  });
}
