import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/automations/pickers.dart';
import 'package:omniflow_app/ui/automations/rule_words.dart';
import 'package:omniflow_app/ui/settings/backup_page.dart';

import 'automations_fixtures.dart' show tapKey;
import 'fake_engine.dart';
import 'screen_harness.dart';
import 'tv_fixtures.dart' show FakePhoneFiles;

void main() {
  test('a sun trigger reads and writes as the engine has it', () {
    final t = RuleTrigger.fromJson({
      'sun': 'sunset',
      'offset': -30,
      'days': ['sat', 'sun'],
    });
    expect(t, isA<SunTrigger>());
    expect(t.toJson(), {
      'sun': 'sunset',
      'offset': -30,
      'days': ['sat', 'sun'],
    });
    expect(sunText(t as SunTrigger), startsWith('30 min before sunset'));
    expect(sunText(SunTrigger('sunrise')), 'At sunrise');
  });

  group('the sun form', () {
    late FakeEngine engine;
    setUp(() => engine = FakeEngine());

    Future<SunTrigger?> open(WidgetTester tester) async {
      SunTrigger? picked;
      await pumpScreen(
        tester,
        engine,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () async => picked = await sunTriggerForm(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tapKey(tester, 'open');
      return picked;
    }

    testWidgets('with no home location it asks for one before Done', (
      tester,
    ) async {
      engine.answers['home.location'] = {'ok': true, 'location': null};
      await open(tester);
      expect(find.byKey(const ValueKey('sun-no-home')), findsOneWidget);
      expect(find.text('Set where home is first'), findsOneWidget);
    });

    testWidgets('makes 20 minutes before sunrise', (tester) async {
      engine.answers['home.location'] = {
        'ok': true,
        'location': {'latitude': 19.07, 'longitude': 72.87},
        'today': {
          'sunrise': '2026-11-09T06:40:00.000',
          'sunset': '2026-11-09T18:02:00.000',
        },
      };
      SunTrigger? picked;
      await pumpScreen(
        tester,
        engine,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () async => picked = await sunTriggerForm(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tapKey(tester, 'open');
      expect(find.textContaining('sunrise 06:40'), findsOneWidget);
      await tester.tap(find.text('Sunrise'));
      await tester.tap(find.text('Before'));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('sun-minutes')), '20');
      await tester.pump();
      await tapKey(tester, 'form-done');
      expect(picked?.toJson(), {'sun': 'sunrise', 'offset': -20});
    });
  });

  group('backup and restore', () {
    late FakeEngine engine;
    late Directory dir;
    setUp(() {
      engine = FakeEngine();
      dir = Directory.systemTemp.createTempSync('omni_backup_ui');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('Back up now writes the export to Download', (tester) async {
      engine.answers['config.export'] = {
        'ok': true,
        'backup': {'schema': 'omniflow.backup', 'version': 1},
      };
      await pumpScreen(
        tester,
        engine,
        const BackupPage(),
        overrides: [
          phoneFilesProvider.overrideWithValue(
            FakePhoneFiles(downloads: dir.path),
          ),
        ],
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('backup-export')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      final files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.single.path, contains('omniflow-backup-'));
      expect(
        jsonDecode(files.single.readAsStringSync()),
        containsPair('schema', 'omniflow.backup'),
      );
      expect(find.byKey(const ValueKey('backup-saved')), findsOneWidget);
    });

    testWidgets('Back up to Drive saves the file and opens Share with it', (
      tester,
    ) async {
      engine.answers['config.export'] = {
        'ok': true,
        'backup': {'schema': 'omniflow.backup', 'version': 1},
      };
      final shared = <String>[];
      await pumpScreen(
        tester,
        engine,
        const BackupPage(),
        overrides: [
          phoneFilesProvider.overrideWithValue(
            FakePhoneFiles(downloads: dir.path),
          ),
          shareFileProvider.overrideWithValue((path) async => shared.add(path)),
        ],
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('backup-share')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(shared.single, contains('omniflow-backup-'));
      expect(File(shared.single).existsSync(), isTrue);
    });

    testWidgets('a restore shows what changes, then lists the keys to enter', (
      tester,
    ) async {
      final file = File('${dir.path}/b.json')
        ..writeAsStringSync(jsonEncode({'schema': 'omniflow.backup'}));
      engine.answerers['config.import'] = (args) => args['dryRun'] == true
          ? {
              'ok': true,
              'add': {
                'things': ['plug'],
                'automations': ['evening'],
              },
              'replace': <String, Object?>{},
            }
          : {
              'ok': true,
              'waitForApproval': ['mac_sleep'],
              'needsSecrets': [
                {
                  'id': 'plug',
                  'name': 'Desk plug',
                  'secrets': ['localKey'],
                },
              ],
            };
      await pumpScreen(
        tester,
        engine,
        const BackupPage(),
        overrides: [
          phoneFilesProvider.overrideWithValue(
            FakePhoneFiles(files: [(name: 'b.json', path: file.path)]),
          ),
        ],
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('backup-restore')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('It adds 2 items.'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('confirm')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(engine.callsOf('config.import').map((c) => c.$2['dryRun']), [
        true,
        null,
      ]);
      expect(find.byKey(const ValueKey('backup-waiting')), findsOneWidget);
      expect(find.text('Desk plug'), findsOneWidget);
    });
  });
}
