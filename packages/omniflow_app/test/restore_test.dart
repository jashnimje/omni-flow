import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/home/first_run.dart';
import 'package:omniflow_app/ui/onboarding/home_setup.dart' show SetupStep;
import 'package:omniflow_app/ui/settings/phone_access.dart';
import 'package:omniflow_app/ui/settings/restore_flow.dart';

import 'fake_engine.dart';
import 'home_devices_test.dart' show FakeAccess;
import 'screen_harness.dart';
import 'tv_fixtures.dart' show FakePhoneFiles;

/// A backup made from scratch: a person, a light, a TV paired over ADB
/// and an automation at night.
const _backup = <String, Object?>{
  'schema': 'omniflow.backup',
  'version': 1,
  'exportedAt': '2026-10-03T08:35:00.000Z',
  'rooms': [
    {'id': 'den', 'name': 'Den', 'order': 0},
  ],
  'things': [
    {'id': 'sam', 'name': 'Sam', 'driver': 'person', 'host': 'virtual'},
    {
      'id': 'den_light',
      'name': 'Den light',
      'driver': 'philips_wiz_udp',
      'host': '192.168.1.40',
      'room': 'den',
      'settings': <String, Object?>{},
    },
    {
      'id': 'den_tv',
      'name': 'Den TV',
      'driver': 'android_tv_adb',
      'host': '192.168.1.41',
    },
  ],
  'automations': [
    {'id': 'lights_out', 'source': 'rule', 'enabled': true, 'flow': {}},
  ],
  'home': {
    'location': {'latitude': 12.97, 'longitude': 77.59},
  },
};

/// What the engine answers to a restore of [_backup] on an empty home.
const _done = <String, Object?>{
  'ok': true,
  'add': {
    'rooms': ['den'],
    'things': ['sam', 'den_light', 'den_tv'],
    'automations': ['lights_out'],
  },
  'replace': <String, Object?>{},
  'skip': <String, Object?>{},
  'waitForApproval': <Object?>[],
  'needsSecrets': [
    {
      'id': 'den_tv',
      'name': 'Den TV',
      'pair': true,
      'pairing': 'adb',
      'category': 'media',
    },
  ],
};

void main() {
  group('the restore result', () {
    Future<void> show(WidgetTester tester, Map<String, Object?> done) =>
        pumpScreen(
          tester,
          FakeEngine(),
          Scaffold(body: ListView(children: [RestoreResult(done)])),
        );

    testWidgets('says what came back, and only what still needs the user', (
      tester,
    ) async {
      await show(tester, _done);
      expect(
        find.text('Restored 3 things, 1 room and 1 automation.'),
        findsOneWidget,
      );
      expect(find.text('Still to do'), findsOneWidget);
      expect(find.text('Den TV'), findsOneWidget);
      expect(
        find.text('Pair again: the TV asks to allow this phone once'),
        findsOneWidget,
      );
      expect(find.text('Den light'), findsNothing);
      expect(find.byKey(const ValueKey('backup-waiting')), findsNothing);
    });

    testWidgets('names the key a thing needs, and says when nothing does', (
      tester,
    ) async {
      await show(tester, {
        ..._done,
        'needsSecrets': [
          {
            'id': 'plug',
            'name': 'Desk plug',
            'secrets': ['localKey'],
            'labels': ['Local key'],
            'category': 'power',
          },
        ],
      });
      expect(
        find.text('Enter its Local key again: tap to start'),
        findsOneWidget,
      );

      await show(tester, {..._done, 'needsSecrets': <Object?>[]});
      expect(
        find.text(
          'Restored 3 things, 1 room and 1 automation. Nothing else needs '
          'you.',
        ),
        findsOneWidget,
      );
      expect(find.text('Still to do'), findsNothing);
    });

    test('a backup answers the setup steps it holds', () {
      expect(stepsCoveredBy(_backup), {
        SetupStep.you,
        SetupStep.home,
        SetupStep.device,
        SetupStep.automation,
      });
      expect(stepsCoveredBy(const {'schema': 'omniflow.backup'}), isEmpty);
    });
  });

  group('the first run asks about a backup first', () {
    late FakeEngine engine;
    late Directory dir;
    late FakeAccess access;
    Set<SetupStep>? covered;

    setUp(() {
      engine = FakeEngine();
      dir = Directory.systemTemp.createTempSync('omni_first_restore');
      access = FakeAccess(const PhoneAccessState());
      covered = null;
      engine.answerers['config.import'] = (args) => args['dryRun'] == true
          ? {'ok': true, 'add': _done['add'], 'replace': <String, Object?>{}}
          : _done;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> open(WidgetTester tester, FakePhoneFiles files) async {
      await pumpScreen(
        tester,
        engine,
        FirstRunScreen(onDone: (steps) async => covered = steps),
        overrides: [
          phoneAccessProvider.overrideWithValue(access),
          phoneFilesProvider.overrideWithValue(files),
        ],
      );
      // The backup folder is read with real file calls, one after another.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    Future<void> tapAsync(WidgetTester tester, String key) async {
      await tester.runAsync(() async {
        await tester.tap(find.byKey(ValueKey(key)));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('Start fresh is one tap, then the usual setup', (tester) async {
      await open(tester, FakePhoneFiles(downloads: dir.path));
      expect(find.text('Have a backup?'), findsOneWidget);
      expect(find.byKey(const ValueKey('first-run-restore')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('first-run-restore-found')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('first-run-fresh')));
      await tester.pumpAndSettle();
      expect(find.text('Connect anything to anything'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('first-run-start')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(covered, isEmpty);
      expect(engine.callsOf('config.import'), isEmpty);
    });

    testWidgets('Start fresh holds when the screen is built again', (
      tester,
    ) async {
      final generation = ValueNotifier(0);
      await pumpScreen(
        tester,
        engine,
        ValueListenableBuilder<int>(
          valueListenable: generation,
          builder: (_, n, _) => FirstRunScreen(
            key: ValueKey('first-run-$n'),
            onDone: (steps) async => covered = steps,
          ),
        ),
        overrides: [
          phoneAccessProvider.overrideWithValue(access),
          phoneFilesProvider.overrideWithValue(
            FakePhoneFiles(downloads: dir.path),
          ),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('first-run-fresh')));
      await tester.pumpAndSettle();
      // The device list reloading builds Home, and this screen, again.
      generation.value++;
      await tester.pumpAndSettle();
      expect(find.text('Have a backup?'), findsNothing);
      expect(find.byKey(const ValueKey('first-run-start')), findsOneWidget);
    });

    testWidgets('a picked backup restores, then skips the setup it covers', (
      tester,
    ) async {
      final file = File('${dir.path}/picked.json')
        ..writeAsStringSync(jsonEncode(_backup));
      final files = FakePhoneFiles(
        files: [(name: 'picked.json', path: file.path)],
        downloads: null,
      );
      await open(tester, files);
      await tapAsync(tester, 'first-run-restore');
      // The system picker, for any file type, so a backup in Drive shows.
      expect(files.picks, [null]);
      expect(find.textContaining('It adds 5 items.'), findsOneWidget);
      await tapAsync(tester, 'confirm');
      expect(engine.callsOf('config.import').map((c) => c.$2['dryRun']), [
        true,
        null,
      ]);
      expect(
        find.text('Restored 3 things, 1 room and 1 automation.'),
        findsOneWidget,
      );
      expect(
        find.text('Pair again: the TV asks to allow this phone once'),
        findsOneWidget,
      );
      expect(find.text('Continue'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('first-run-start')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(covered, contains(SetupStep.you));
      expect(covered, contains(SetupStep.home));
      expect(covered, isNot(contains(SetupStep.presence)));
    });

    testWidgets('a backup this install wrote is offered with its date and '
        'counts', (tester) async {
      File('${dir.path}/omniflow-backup-2026-11-19-1405.json')
          .writeAsStringSync(jsonEncode(_backup));
      File('${dir.path}/notes.json').writeAsStringSync('{}');
      await open(tester, FakePhoneFiles(downloads: dir.path));
      final row = find.byKey(const ValueKey('first-run-restore-found'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('3 things, 1 automation'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('3 Oct')),
        findsOneWidget,
      );
      await tapAsync(tester, 'first-run-restore-found');
      await tapAsync(tester, 'confirm');
      expect(engine.callsOf('config.import'), hasLength(2));
      expect(
        engine.callsOf('config.import').last.$2['backup'],
        containsPair('exportedAt', '2026-10-03T08:35:00.000Z'),
      );
    });
  });
}
