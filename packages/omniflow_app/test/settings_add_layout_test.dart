import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/add/add_phone_page.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/home/first_run.dart';
import 'package:omniflow_app/ui/onboarding/home_setup.dart';
import 'package:omniflow_app/ui/settings/phone_access.dart';
import 'package:omniflow_app/ui/settings/rooms_page.dart';
import 'package:omniflow_app/ui/settings/variables_page.dart';
import 'package:omniflow_app/ui/shell/hub_banner.dart';

import 'fake_engine.dart';
import 'home_devices_test.dart' show FakeAccess;
import 'screen_harness.dart';

/// A small phone in logical pixels (360 x 640 at 3x).
const _phone = Size(1080, 1920);

/// The bottom of [key]'s box is on screen, above the bottom edge.
void expectOnScreen(WidgetTester tester, String key) {
  final box = tester.getRect(find.byKey(ValueKey(key)));
  final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  expect(box.bottom, lessThanOrEqualTo(screen.height), reason: key);
  expect(box.top, greaterThanOrEqualTo(0), reason: key);
}

void main() {
  testWidgets('home setup keeps Back, Skip and its action on screen on a '
      'small phone', (tester) async {
    tester.view.devicePixelRatio = 3;
    await pumpScreen(
      tester,
      FakeEngine(),
      const HomeSetupPage(start: SetupStep.presence),
      size: _phone,
      overrides: [
        phoneAccessProvider.overrideWithValue(
          FakeAccess(const PhoneAccessState()),
        ),
      ],
    );
    expect(find.text('How does the phone know you are home?'), findsOne);
    expectOnScreen(tester, 'setup-use-wifi');
    expectOnScreen(tester, 'step-skip');
    expectOnScreen(tester, 'step-back');
    expect(find.byType(OmniStepBar), findsOneWidget);
  });

  testWidgets('another phone keeps Pair on screen under the long steps', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 3;
    await pumpScreen(
      tester,
      FakeEngine()..answers['android.find'] = {'ok': true, 'phones': const []},
      const AddPhonePage(),
      size: _phone,
    );
    expectOnScreen(tester, 'phone-next');
    await tester.tap(find.byKey(const ValueKey('phone-next')));
    await tester.pumpAndSettle();
    expectOnScreen(tester, 'phone-pair');
  });

  testWidgets('variables add from the header, with no page button over the '
      'last row', (tester) async {
    tester.view.devicePixelRatio = 3;
    await pumpScreen(
      tester,
      FakeEngine()
        ..answers['var.list'] = {
          'ok': true,
          'variables': {for (var i = 0; i < 20; i++) 'V$i': i},
        },
      const VariablesPage(),
      size: _phone,
    );
    expect(find.byType(FloatingActionButton), findsNothing);
    expectOnScreen(tester, 'var-add');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('var-clear-V9')),
      200,
    );
    await tester.pumpAndSettle();
    expectOnScreen(tester, 'var-clear-V9');
  });

  testWidgets('removing a room asks with a red Remove', (tester) async {
    final engine = FakeEngine()
      ..answers['room.list'] = {
        'ok': true,
        'rooms': [
          {'id': 'den', 'name': 'Den', 'order': 0, 'deviceCount': 0},
        ],
      };
    await pumpScreen(tester, engine, const RoomsPage());
    await tester.tap(find.byKey(const ValueKey('room-remove-den')));
    await tester.pumpAndSettle();
    final button = tester.widget<OmniButton>(
      find.byKey(const ValueKey('confirm')),
    );
    expect(button.kind, OmniButtonKind.destructive);
  });

  testWidgets('phone setup shows a skeleton while it reads, not a blank page', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      FakeEngine(),
      const PhoneAccessPage(),
      settle: false,
      overrides: [
        phoneAccessStateProvider.overrideWith(
          (ref) => Future<PhoneAccessState>.delayed(
            const Duration(seconds: 1),
            () => const PhoneAccessState(),
          ),
        ),
      ],
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(OmniPageSkeleton), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a stopped hub says automations are stopped, and Start starts '
      'it', (tester) async {
    final engine = FakeEngine()
      ..answers['engine.status'] = {'ok': true, 'hubRunning': false}
      ..answers['hub.start'] = {'ok': true};
    await pumpScreen(
      tester,
      engine,
      Scaffold(
        body: Consumer(
          builder: (context, ref, _) => hubBanner(ref) ?? const SizedBox(),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('hub-stopped')), findsOneWidget);
    engine.answers['engine.status'] = {'ok': true, 'hubRunning': true};
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(engine.callsOf('hub.start'), hasLength(1));
    expect(find.byKey(const ValueKey('hub-stopped')), findsNothing);
  });

  testWidgets('variables of OmniFlow only do not say there are none', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      FakeEngine()
        ..answers['var.list'] = {
          'ok': true,
          'variables': {'WifiSsid': 'Home'},
        },
      const VariablesPage(),
    );
    expect(find.text('Nothing saved yet'), findsNothing);
    expect(find.text('None of your own yet'), findsOneWidget);
  });

  testWidgets(
    'first run keeps Start fresh and Get started on screen on a small phone',
    (tester) async {
      tester.view.devicePixelRatio = 3;
      await pumpScreen(
        tester,
        FakeEngine(),
        FirstRunScreen(onDone: (_) async {}),
        size: _phone,
        overrides: [
          phoneAccessProvider.overrideWithValue(
            FakeAccess(const PhoneAccessState()),
          ),
        ],
      );
      expectOnScreen(tester, 'first-run-fresh');
      await tester.tap(find.byKey(const ValueKey('first-run-fresh')));
      await tester.pumpAndSettle();
      expectOnScreen(tester, 'first-run-start');
    },
  );
}
