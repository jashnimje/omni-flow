import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/settings/whats_new.dart';

import 'fake_engine.dart';
import 'screen_harness.dart';

class _Seen implements SeenVersion {
  _Seen(this.value);

  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String version) async => value = version;
}

void main() {
  Future<void> open(WidgetTester tester, SeenVersion seen) => pumpScreen(
    tester,
    FakeEngine(),
    Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          key: const ValueKey('open'),
          onPressed: () => showWhatsNewAfterUpdate(context, seen),
          child: const Text('open'),
        ),
      ),
    ),
  );

  testWidgets('after an update the new notes show once', (tester) async {
    final seen = _Seen('0.1.0');
    await open(tester, seen);
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.text('New in OmniFlow $appVersion'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('whats-new-ok')));
    await tester.pumpAndSettle();
    expect(seen.value, appVersion);
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.text('New in OmniFlow $appVersion'), findsNothing);
  });

  testWidgets('a first install shows nothing', (tester) async {
    final seen = _Seen(null);
    await open(tester, seen);
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.textContaining('New in OmniFlow'), findsNothing);
    expect(seen.value, appVersion);
  });

  testWidgets('an update from before 0.2.0, with a home, shows the notes', (
    tester,
  ) async {
    final seen = _Seen(null);
    await pumpScreen(
      tester,
      FakeEngine(),
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open'),
            onPressed: () => showWhatsNewAfterUpdate(
              context,
              seen,
              hasHome: () async => true,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.text('New in OmniFlow $appVersion'), findsOneWidget);
  });

  test('the newest notes are for this version', () {
    expect(releaseNotes.first.version, appVersion);
  });
}
