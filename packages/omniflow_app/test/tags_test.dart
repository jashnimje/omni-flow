import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/nfc/nfc.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/automations/rule_editor.dart';
import 'package:omniflow_app/ui/tags/tag_page.dart';
import 'package:omniflow_app/ui/tags/tags_page.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show tagRecords;

import 'fake_engine.dart';
import 'screen_harness.dart';

/// The phone's reader for writing: [write] completes the write it waits on.
class WritingNfc implements NfcAdapter {
  TagPayload? writing;
  Completer<NfcScan>? write;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> startReading(void Function(NfcScan scan) onScan) async {}

  @override
  Future<NfcScan> writeNext(TagPayload payload) {
    writing = payload;
    return (write = Completer<NfcScan>()).future;
  }

  @override
  void cancelWrite() {
    if (write case final w? when !w.isCompleted) {
      w.completeError(const NfcWriteError('Cancelled'));
    }
  }

  @override
  Future<void> stop() async {}
}

/// Two hours back, or two minutes in the first hours after midnight, so
/// the scan stays on today and the page says "Today" whatever the clock.
final _early = DateTime.now().hour < 3;
final scannedAt = DateTime.now().toUtc().subtract(
  _early ? const Duration(minutes: 2) : const Duration(hours: 2),
);
final scannedAgo = _early ? '2 min ago' : '2 h ago';

Map<String, Object?> tag({Map<String, Object?>? state}) => {
  'id': 'front_door',
  'name': 'Front door tag',
  'driver': 'nfc_tag',
  'host': 'virtual',
  'settings': const {'uid': '04A1B2C3'},
  'state':
      state ??
      {'last_scanned': scannedAt.toIso8601String(), 'last_source': 'phone'},
  'capabilities': const <Object?>[],
};

void main() {
  late FakeEngine engine;
  late WritingNfc nfc;

  setUp(() {
    engine = FakeEngine();
    nfc = WritingNfc();
    engine.devices = [tag(), FakeEngine.lamp()];
    engine.answers['automation.list'] = {
      'ok': true,
      'automations': [
        {
          'id': 'door_mutes_tv',
          'name': 'Door tag mutes TV',
          'source': 'rule',
          'enabled': true,
          'approved': true,
          'sentence': [
            {'kind': 'when', 'text': 'When front door tag is scanned'},
            {'kind': 'text', 'text': '→'},
            {'kind': 'then', 'text': 'toggle TV mute'},
          ],
          'devices': ['front_door', 'lounge_tv'],
        },
      ],
      'loadIssues': const <Object?>[],
    };
    engine.answerers['device.history'] = (args) => {
      'ok': true,
      'entries': args['key'] == 'last_scanned'
          ? [
              {
                'at': scannedAt.toIso8601String(),
                'key': 'last_scanned',
                'value': scannedAt.toIso8601String(),
              },
            ]
          : [
              {
                'at': scannedAt.toIso8601String(),
                'key': 'last_source',
                'value': 'phone',
              },
            ],
    };
    engine.answers['tag.write_payload'] = {
      'ok': true,
      'id': 'front_door',
      'uri': 'omniflow://tag/front_door',
      'records': tagRecords('front_door'),
    };
  });

  Future<void> pumpTag(WidgetTester tester) => pumpScreen(
    tester,
    engine,
    const TagPage(id: 'front_door'),
    overrides: [nfcAdapterProvider.overrideWithValue(nfc)],
  );

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  group('5.3 tag page', () {
    testWidgets('says when it was scanned and by what, what a scan runs, '
        'and the recent scans', (tester) async {
      await pumpTag(tester);
      expect(find.text('Scanned $scannedAgo'), findsOneWidget);
      expect(find.text('by this phone · card 04:A1:B2:C3'), findsOneWidget);
      expect(engine.callsOf('automation.list').single.$2, {
        'tag': 'front_door',
      });
      expect(find.text('Door tag mutes TV'), findsOneWidget);
      expect(find.text('toggle TV mute'), findsOneWidget);
      expect(engine.callsOf('device.history').first.$2, {
        'id': 'front_door',
        'key': 'last_scanned',
        'limit': 10,
      });
      expect(find.textContaining('Today'), findsOneWidget);
      expect(find.textContaining('· this phone'), findsOneWidget);
    });

    testWidgets('a tag never scanned and used by nothing says so', (
      tester,
    ) async {
      engine.devices = [tag(state: const {})];
      engine.answers['automation.list'] = {
        'ok': true,
        'automations': const <Object?>[],
      };
      engine.answerers['device.history'] = (_) => {
        'ok': true,
        'entries': const <Object?>[],
      };
      await pumpTag(tester);
      expect(find.text('Not scanned yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('tag-no-automations')), findsOneWidget);
      expect(find.byKey(const ValueKey('tag-no-scans')), findsOneWidget);
    });

    testWidgets('Write to a new tag writes the link the engine gives', (
      tester,
    ) async {
      await pumpTag(tester);
      await tester.tap(find.byKey(const ValueKey('tag-write')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('tag.write_payload').single.$2, {
        'id': 'front_door',
      });
      expect(nfc.writing?.uri, 'omniflow://tag/front_door');
      expect(find.text('Hold a tag to the phone'), findsOneWidget);
      nfc.write!.complete(const NfcScan('04A22B1C', []));
      await tester.pumpAndSettle();
      expect(find.text('Wrote Front door tag on tag 04A22B1C'), findsOneWidget);
    });

    testWidgets('a write that fails says why, retries, and Cancel gives up', (
      tester,
    ) async {
      await pumpTag(tester);
      await tester.tap(find.byKey(const ValueKey('tag-write')));
      await tester.pumpAndSettle();
      nfc.write!.completeError(const NfcWriteError('This tag is locked'));
      await tester.pumpAndSettle();
      expect(find.text('This tag is locked'), findsOneWidget);
      await tapKey(tester, 'write-tag-retry');
      expect(find.text('Hold a tag to the phone'), findsOneWidget);
      await tapKey(tester, 'write-tag-cancel');
      expect(find.byKey(const ValueKey('write-tag-status')), findsNothing);
      expect(nfc.write!.isCompleted, isTrue);
    });

    testWidgets('Do something when scanned opens a rule with the scan as its '
        'trigger', (tester) async {
      await pumpTag(tester);
      await tapKey(tester, 'tag-new-automation');
      final editor = tester.widget<RuleEditorPage>(find.byType(RuleEditorPage));
      expect(editor.initial?['when'], [
        {'on': 'front_door.scanned', 'event': true},
      ]);
    });

    testWidgets('removing the tag asks first, says what stops, then removes', (
      tester,
    ) async {
      await pumpTag(tester);
      await tapKey(tester, 'tag-more');
      await tapKey(tester, 'tag-remove');
      expect(find.text('Remove Front door tag?'), findsOneWidget);
      expect(find.textContaining('1 automation stops working'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('tag.remove'), isEmpty);

      await tapKey(tester, 'tag-more');
      await tapKey(tester, 'tag-remove');
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('tag.remove').single.$2, {'id': 'front_door'});
      expect(find.byType(TagPage), findsNothing);
    });

    testWidgets('a different card is used only after a confirm', (
      tester,
    ) async {
      await pumpTag(tester);
      await tapKey(tester, 'tag-more');
      await tapKey(tester, 'tag-forget-card');
      expect(find.text('Use a different card?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('tag.save'), isEmpty);

      await tapKey(tester, 'tag-more');
      await tapKey(tester, 'tag-forget-card');
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('tag.save').single.$2, {
        'id': 'front_door',
        'name': 'Front door tag',
        'uid': null,
      });
    });

    testWidgets('meets the tap target, label and contrast guidelines', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpTag(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });

  group('tags list', () {
    testWidgets('lists the tags, and an empty list offers to add one', (
      tester,
    ) async {
      await pumpScreen(tester, engine, const TagsPage());
      expect(find.text('Front door tag'), findsOneWidget);
      expect(find.text('scanned $scannedAgo'), findsOneWidget);
    });

    testWidgets('no tags says how to add one', (tester) async {
      engine.devices = [FakeEngine.lamp()];
      await pumpScreen(tester, engine, const TagsPage());
      expect(find.text('No NFC tags yet'), findsOneWidget);
    });

    testWidgets('Add a tag saves it by name, then writes it', (tester) async {
      await pumpScreen(
        tester,
        engine,
        const TagsPage(),
        overrides: [nfcAdapterProvider.overrideWithValue(nfc)],
      );
      await tapKey(tester, 'tags-add');
      await tester.enterText(
        find.byKey(const ValueKey('tag-name')),
        'Desk tag',
      );
      await tester.pump();
      await tapKey(tester, 'tag-add-write');
      expect(engine.callsOf('tag.save').single.$2, {
        'id': 'desk_tag',
        'name': 'Desk tag',
      });
      expect(engine.callsOf('tag.write_payload').single.$2, {'id': 'desk_tag'});
      expect(find.text('Hold a tag to the phone'), findsOneWidget);
    });
  });

  test('times read the way the tag page says them', () {
    final now = DateTime(2026, 11, 8, 19);
    expect(agoText(DateTime(2026, 11, 8, 18, 59, 40), now: now), 'just now');
    expect(agoText(DateTime(2026, 11, 8, 18, 30), now: now), '30 min ago');
    expect(agoText(DateTime(2026, 11, 8, 17), now: now), '2 h ago');
    expect(
      agoText(DateTime(2026, 11, 8, 23), now: DateTime(2026, 11, 9, 1)),
      '2 h ago',
      reason: 'across midnight',
    );
    expect(agoText(DateTime(2026, 11, 7, 9), now: now), 'yesterday');
    expect(agoText(DateTime(2026, 11, 3, 9), now: now), '3 Nov');
    expect(whenText(DateTime(2026, 11, 8, 17, 40), now: now), 'Today 17:40');
    expect(whenText(DateTime(2026, 11, 7, 9, 12), now: now), 'Yesterday 09:12');
    expect(uidText('04A1B2C3'), '04:A1:B2:C3');
    expect(tagIdFor('Front door tag'), 'front_door_tag');
  });
}
