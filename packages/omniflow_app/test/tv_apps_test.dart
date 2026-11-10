import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_engine.dart';
import 'tv_fixtures.dart';

void main() {
  late FakeEngine engine;

  setUp(() => engine = tvEngine());

  Future<void> openApp(WidgetTester tester, String package) async {
    await tester.tap(find.byKey(ValueKey('app-$package')));
    await tester.pumpAndSettle();
  }

  Iterable<Map<String, Object?>> appCalls() => argsOf(engine, 'tv.app');

  Finder inList(String text) => find.descendant(
    of: find.byKey(const ValueKey('apps-list')),
    matching: find.text(text),
  );

  testWidgets('lists installed apps first, then by filter and search', (
    tester,
  ) async {
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Apps');
    expect(argsOf(engine, 'tv.apps').single, {'id': tvId, 'filter': 'user'});
    expect(inList('Netflix'), findsOneWidget);
    expect(inList('SonyLIV'), findsOneWidget);
    expect(inList('disabled'), findsOneWidget);
    expect(inList('running'), findsOneWidget);
    expect(inList('com.netflix.ninja · 9.1'), findsOneWidget);
    expect(find.text('Search 2 apps'), findsOneWidget);

    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.apps').last, {'id': tvId, 'filter': 'system'});
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.apps').last, {'id': tvId, 'filter': 'all'});

    await tester.enterText(find.byKey(const ValueKey('apps-search')), 'sony');
    await tester.pump();
    expect(inList('Netflix'), findsNothing);
    expect(inList('SonyLIV'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('apps-search')), 'ninja');
    await tester.pump();
    expect(inList('Netflix'), findsOneWidget);
  });

  testWidgets('an app without a label is named from its package, with a '
      'badge', (tester) async {
    engine.answers['tv.apps'] = {
      'ok': true,
      'apps': [
        {'package': 'com.example.player', 'versionName': '2.0'},
      ],
    };
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Apps');
    expect(inList('Example'), findsOneWidget);
    expect(inList('E'), findsOneWidget);
    expect(inList('com.example.player · 2.0'), findsOneWidget);
  });

  testWidgets('an empty filter says so', (tester) async {
    engine.answers['tv.apps'] = {'ok': true, 'apps': const []};
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Apps');
    expect(find.text('No apps here'), findsOneWidget);
  });

  testWidgets('the header names the focused app once apps are listed', (
    tester,
  ) async {
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Apps');
    engine.eventsOut.add({
      'event': 'device.stateChanged',
      'device': {
        'id': tvId,
        'state': {'app': 'com.netflix.ninja'},
      },
    });
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('tv-app'))).data,
      'Netflix',
    );
  });

  testWidgets('open, force stop and clear cache run without asking', (
    tester,
  ) async {
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Apps');
    for (final (key, action) in [
      ('open', 'open'),
      ('stop', 'stop'),
      ('clear-cache', 'clear_cache'),
    ]) {
      await openApp(tester, 'com.netflix.ninja');
      await tester.tap(find.byKey(ValueKey('app-$key')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('confirm')), findsNothing);
      expect(appCalls().last, {
        'id': tvId,
        'package': 'com.netflix.ninja',
        'action': action,
      });
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    }
  });

  for (final (key, action, title) in [
    ('clear-data', 'clear_data', 'Clear all data of Netflix?'),
    ('uninstall', 'uninstall', 'Uninstall Netflix?'),
    ('disable', 'disable', 'Disable Netflix?'),
  ]) {
    testWidgets('$action asks first, and Cancel sends nothing', (tester) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Apps');
      await openApp(tester, 'com.netflix.ninja');
      await tester.tap(find.byKey(ValueKey('app-$key')));
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(appCalls(), isEmpty);

      final listed = engine.callsOf('tv.apps').length;
      await tester.tap(find.byKey(ValueKey('app-$key')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm')));
      await tester.pumpAndSettle();
      expect(appCalls().single, {
        'id': tvId,
        'package': 'com.netflix.ninja',
        'action': action,
      });
      expect(engine.callsOf('tv.apps').length, listed + 1);
    });
  }

  testWidgets('a disabled app offers Enable, which needs no confirm', (
    tester,
  ) async {
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Apps');
    await openApp(tester, 'com.sonyliv');
    expect(find.byKey(const ValueKey('app-disable')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('app-enable')));
    await tester.pumpAndSettle();
    expect(appCalls().single['action'], 'enable');
  });

  testWidgets('App info shows what the TV reports', (tester) async {
    engine.answers['tv.app'] = {
      'ok': true,
      'id': tvId,
      'app': {'firstInstallTime': '2025-01-02', 'targetSdk': 34},
    };
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Apps');
    await openApp(tester, 'com.netflix.ninja');
    await tester.tap(find.byKey(const ValueKey('app-info')));
    await tester.pumpAndSettle();
    expect(find.textContaining('targetSdk: 34'), findsOneWidget);
    expect(find.textContaining('id: $tvId'), findsNothing);
  });

  testWidgets('Install APK picks an APK, installs it with progress, reloads', (
    tester,
  ) async {
    final phone = FakePhoneFiles(
      files: [(name: 'app.apk', path: '/cache/file_picker/1/app.apk')],
    );
    engine.delay = const Duration(milliseconds: 50);
    final phoneFiles = await pumpTv(tester, engine, files: phone);
    await openTvTab(tester, 'Apps');
    final listed = engine.callsOf('tv.apps').length;
    await tester.tap(find.byKey(const ValueKey('apps-install')));
    await tester.pump();
    await tester.pump();
    engine.eventsOut.add({
      'event': 'tv.progress',
      'id': tvId,
      'op': 'install',
      'done': 512 * 1024,
      'total': 1024 * 1024,
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('tv-progress')), findsOneWidget);
    expect(find.text('Installing app.apk'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('tv-progress-text'))).data,
      '512 KB of 1.0 MB',
    );
    await tester.pumpAndSettle();
    expect(phoneFiles.picks.single, ['apk']);
    expect(argsOf(engine, 'tv.install').single, {
      'id': tvId,
      'path': '/cache/file_picker/1/app.apk',
      'replace': true,
    });
    expect(phoneFiles.cleanups, 1);
    expect(find.text('Installed app.apk'), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-progress')), findsNothing);
    expect(engine.callsOf('tv.apps').length, listed + 1);
  });

  testWidgets('a cancelled pick installs nothing', (tester) async {
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Apps');
    await tester.tap(find.byKey(const ValueKey('apps-install')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('tv.install'), isEmpty);
  });

  testWidgets('a failed listing says why and offers to try again', (
    tester,
  ) async {
    engine.answers['tv.apps'] = {
      'ok': false,
      'error': {'type': 'unavailable', 'message': 'TV did not answer'},
    };
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Apps');
    expect(find.textContaining('TV did not answer'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
