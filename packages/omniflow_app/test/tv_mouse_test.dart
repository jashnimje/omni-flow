import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/tv_calls.dart';

import 'automations_fixtures.dart' show tapKey;
import 'tv_fixtures.dart';

void main() {
  Future<void> openMouse(WidgetTester tester) async {
    await tester.tap(find.text('Mouse'));
    await tester.pumpAndSettle();
  }

  testWidgets('with the helper running, a drag moves the TV pointer live '
      'and a click taps where it is', (tester) async {
    final engine = tvEngine()
      ..answers.addAll({
        TvPointerCalls.status: {
          'ok': true,
          'installed': true,
          'overlayAllowed': true,
          'running': true,
        },
        TvPointerCalls.pointer: {'ok': true, 'x': 0.5, 'y': 0.5},
        TvPointerCalls.click: {'ok': true},
      });
    await pumpTv(tester, engine);
    await openMouse(tester);
    expect(argsOf(engine, TvPointerCalls.status).single['allowPairing'], false);
    expect(find.byKey(const ValueKey('tv-mouse-live')), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-mouse-install-helper')), findsNothing);
    // The TV shows the pointer, so no picture is fetched.
    expect(argsOf(engine, 'tv.screenshot'), isEmpty);
    expect(argsOf(engine, TvPointerCalls.pointer).single['to'], [0.5, 0.5]);

    final pad = find.byKey(const ValueKey('tv-mouse-pad'));
    await tester.drag(pad, const Offset(120, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    final moves = argsOf(
      engine,
      TvPointerCalls.pointer,
    ).where((a) => a['by'] != null).toList();
    expect(moves, isNotEmpty);
    // Moves are gathered, not one call per touch event.
    expect(moves.length, lessThan(10));
    final dx = moves.fold<double>(
      0,
      (sum, a) => sum + ((a['by'] as List).first as double),
    );
    expect(dx, greaterThan(0));

    await tapKey(tester, 'tv-mouse-click');
    expect(argsOf(engine, TvPointerCalls.click), hasLength(1));
    expect(argsOf(engine, 'tv.input.tap'), isEmpty);
  });

  testWidgets('without the helper, the picture stays and an install button '
      'explains what it installs', (tester) async {
    final engine = tvEngine()
      ..answers.addAll({
        TvPointerCalls.status: {
          'ok': true,
          'installed': false,
          'overlayAllowed': false,
          'running': false,
        },
        'tv.input.tap': {'ok': true},
        'tv.screenshot': {
          'ok': false,
          'error': {'type': 'timeout', 'message': 'asleep'},
        },
      });
    await pumpTv(tester, engine);
    await openMouse(tester);
    expect(argsOf(engine, 'tv.screenshot'), isNotEmpty);
    await tapKey(tester, 'tv-mouse-click');
    expect(argsOf(engine, 'tv.input.tap'), hasLength(1));
    expect(argsOf(engine, TvPointerCalls.click), isEmpty);

    await tester.ensureVisible(
      find.byKey(const ValueKey('tv-mouse-install-helper')),
    );
    await tapKey(tester, 'tv-mouse-install-helper');
    expect(find.textContaining('never uses the network'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(argsOf(engine, TvPointerCalls.install), isEmpty);
    await tester.pump(const Duration(seconds: 2));
  });
}
