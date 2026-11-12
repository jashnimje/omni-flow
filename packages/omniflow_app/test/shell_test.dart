import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/add/add_page.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/devices/device_page.dart';
import 'package:omniflow_app/ui/home/home_screen.dart';
import 'package:omniflow_app/ui/home/search_page.dart';
import 'package:omniflow_app/ui/settings/developer_page.dart';
import 'package:omniflow_app/ui/settings/inspector.dart';
import 'package:omniflow_app/ui/settings/settings_screen.dart';
import 'package:omniflow_app/ui/shell/shell.dart';

import 'fake_engine.dart';

ShellController shellOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(OmniShell)))
        .read(shellControllerProvider);

Finder fabWith(String key) => find.byKey(ValueKey(key));

void main() {
  late FakeEngine engine;

  setUp(() => engine = FakeEngine());

  testWidgets('four tabs, Home first, with the Add button on Home', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    for (final label in ['Home', 'Automations', 'Devices', 'Settings']) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('shell-tabs')),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(fabWith('add-device'), findsOneWidget);
    expect(find.text('Packets'), findsNothing);
    expect(find.byKey(const ValueKey('command-bar')), findsNothing);
  });

  testWidgets('each tab root has its own button, and Settings none', (
    tester,
  ) async {
    engine.answers['automation.list'] = {
      'ok': true,
      'automations': [
        {
          'id': 'evening',
          'name': 'Evening',
          'source': 'rule',
          'enabled': true,
          'approved': true,
          'sentence': const <Object?>[],
        },
      ],
    };
    await pumpApp(tester, engine);
    await openTab(tester, 'Automations');
    expect(fabWith('new-rule'), findsOneWidget);
    expect(find.text('New'), findsOneWidget);
    await openTab(tester, 'Devices');
    expect(fabWith('add-device'), findsOneWidget);
    await openTab(tester, 'Settings');
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('with no automations only the empty state offers New', (
    tester,
  ) async {
    engine.answers['automation.list'] = {'ok': true, 'automations': []};
    await pumpApp(tester, engine);
    await openTab(tester, 'Automations');
    expect(fabWith('new-rule'), findsNothing);
    expect(find.byKey(const ValueKey('automations-empty')), findsOneWidget);
  });

  testWidgets('a page opened in a tab keeps the tab bar and hides the button', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await tester.tap(fabWith('add-device'));
    await tester.pumpAndSettle();
    expect(find.byType(AddPage), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-tabs')), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('each tab keeps its back stack while another is shown', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await openDeveloper(tester);
    expect(find.byType(DeveloperScreen), findsOneWidget);
    await openTab(tester, 'Home');
    expect(find.byType(DeveloperScreen), findsNothing);
    await openTab(tester, 'Settings');
    expect(find.byType(DeveloperScreen), findsOneWidget);
    await openTab(tester, 'Settings');
    expect(find.byType(DeveloperScreen), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('pages open without a transition under reduced motion', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpApp(tester, engine);
    await openTab(tester, 'Settings');
    await tester.tap(find.byKey(const ValueKey('settings-developer')));
    await tester.pump();
    await tester.pump();
    final shown = tester.getRect(find.byType(Inspector));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(Inspector)), shown);
  });

  testWidgets('back pops the tab, then goes Home, then leaves the app', (
    tester,
  ) async {
    final platformCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpApp(tester, engine);
    await openDeveloper(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(shellOf(tester).tab, ShellTab.settings);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(shellOf(tester).tab, ShellTab.home);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(platformCalls, isNot(contains('SystemNavigator.pop')));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(platformCalls, contains('SystemNavigator.pop'));
  });

  testWidgets('search opens from Home and holds the command bar', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await openSearch(tester);
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('command-bar')), findsOneWidget);
  });

  testWidgets('the packet inspector lives under Settings, Developer', (
    tester,
  ) async {
    await pumpApp(tester, engine);
    await openDeveloper(tester);
    expect(find.byType(Inspector), findsOneWidget);
    expect(find.text('No packets yet.'), findsOneWidget);
  });

  group('links from notifications', () {
    testWidgets('an approval request opens the review on Automations', (
      tester,
    ) async {
      await pumpApp(tester, engine);
      await tester.binding.handlePushRoute('/review/wake_mac');
      await tester.pumpAndSettle();
      expect(shellOf(tester).tab, ShellTab.automations);
      expect(find.byType(ReviewPage), findsOneWidget);
    });

    testWidgets('a failed run opens that run', (tester) async {
      await pumpApp(tester, engine);
      await tester.binding.handlePushRoute(
        const RunLink('evening', 'r1').location,
      );
      await tester.pumpAndSettle();
      expect(shellOf(tester).tab, ShellTab.automations);
      expect(find.byType(RunPage), findsOneWidget);
      expect(engine.callsOf('automation.log').single.$2, {
        'id': 'evening',
        'limit': 50,
      });
    });

    testWidgets('a link replaces what the tab had open', (tester) async {
      await pumpApp(tester, engine);
      await tester.binding.handlePushRoute('omniflow://open/review/wake_mac');
      await tester.pumpAndSettle();
      await tester.binding.handlePushRoute('/automation/evening');
      await tester.pumpAndSettle();
      expect(find.byType(ReviewPage), findsNothing);
      expect(find.byType(AutomationPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AutomationsScreen), findsOneWidget);
    });

    testWidgets('the app launched at a link opens it once the shell is up', (
      tester,
    ) async {
      tester.binding.platformDispatcher.defaultRouteNameTestValue =
          '/settings/developer';
      addTearDown(
        tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
      );
      await pumpApp(tester, engine);
      expect(shellOf(tester).tab, ShellTab.settings);
      expect(find.byType(DeveloperScreen), findsOneWidget);
    });

    testWidgets('Add opens the add flow on the tab in front', (tester) async {
      await pumpApp(tester, engine);
      await openTab(tester, 'Settings');
      await tester.binding.handlePushRoute('/add');
      await tester.pumpAndSettle();
      expect(shellOf(tester).tab, ShellTab.settings);
      expect(find.byType(AddPage), findsOneWidget);
    });

    testWidgets('a device link opens its page on Devices', (tester) async {
      await pumpApp(tester, engine);
      await tester.binding.handlePushRoute('/device/desk_lamp');
      await tester.pumpAndSettle();
      expect(shellOf(tester).tab, ShellTab.devices);
      expect(find.byType(DevicePage), findsOneWidget);
    });

    testWidgets('a route the app does not know changes nothing', (
      tester,
    ) async {
      await pumpApp(tester, engine);
      await tester.binding.handlePushRoute('/nowhere/at/all');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });

  test('every link survives its location', () {
    const links = <ShellLink>[
      TabLink(ShellTab.home),
      TabLink(ShellTab.automations),
      TabLink(ShellTab.devices),
      TabLink(ShellTab.settings),
      SearchLink(),
      AddLink(),
      DeveloperLink(),
      AutomationLink('arrive_home'),
      RunLink('arrive home', 'run/1'),
      ReviewLink('movie_night'),
      DeviceLink('desk_lamp'),
    ];
    for (final link in links) {
      expect(ShellLink.parse(link.location), link, reason: link.location);
      expect(
        ShellLink.parse('omniflow://open${link.location}'),
        link,
        reason: link.location,
      );
    }
    expect(ShellLink.parse('/'), const TabLink(ShellTab.home));
    expect(ShellLink.parse('omniflow://tag/front_door'), isNull);
    expect(ShellLink.parse('https://example.com/device/x'), isNull);
    expect(ShellLink.parse('/device'), isNull);
    expect(ShellLink.parse(null), isNull);
  });
}
