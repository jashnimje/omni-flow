import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_engine.dart';
import 'tv_fixtures.dart';

void main() {
  late FakeEngine engine;

  setUp(() => engine = tvEngine());

  testWidgets('the console stays behind its warning until accepted', (
    tester,
  ) async {
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Console');
    expect(find.byKey(const ValueKey('console-warning')), findsOneWidget);
    expect(find.byKey(const ValueKey('console-command')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('console-accept')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('console-command')), findsOneWidget);
    expect(
      find.text(
        'Commands run directly on the TV. Only you can use this, never Claude.',
      ),
      findsOneWidget,
    );
    expect(engine.callsOf('tv.shell'), isEmpty);
  });

  testWidgets('runs a command and shows its output, exit code and history', (
    tester,
  ) async {
    engine.answerers['tv.shell'] = (args) => {
      'ok': true,
      'output': args['command'] == 'getprop ro.build.version.release'
          ? '14\n'
          : 'not found',
      'exitCode': args['command'] == 'getprop ro.build.version.release'
          ? 0
          : 127,
    };
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Console');
    await tester.tap(find.byKey(const ValueKey('console-accept')));
    await tester.pumpAndSettle();
    final box = find.byKey(const ValueKey('console-command'));
    await tester.enterText(box, 'getprop ro.build.version.release');
    await tester.tap(find.byKey(const ValueKey('console-run')));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.shell').single, {
      'id': tvId,
      'command': 'getprop ro.build.version.release',
    });
    expect(find.text('\$ getprop ro.build.version.release'), findsOneWidget);
    expect(find.text('14\n'), findsOneWidget);
    expect(find.text('exit 0'), findsOneWidget);
    expect(tester.widget<TextField>(box).controller!.text, isEmpty);

    await tester.enterText(box, 'nope');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(find.text('exit 127'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('console-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('getprop ro.build.version.release').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(box).controller!.text,
      'getprop ro.build.version.release',
    );

    await tester.tap(find.byKey(const ValueKey('console-clear')));
    await tester.pumpAndSettle();
    expect(find.text('exit 0'), findsNothing);
  });

  testWidgets('the folder a command ends in carries to the next one', (
    tester,
  ) async {
    engine.answerers['tv.shell'] = (args) => {
      'ok': true,
      'output': '',
      'exitCode': 0,
      'cwd': args['command'] == 'cd /sdcard/Download'
          ? '/sdcard/Download'
          : args['cwd'],
    };
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Console');
    await tester.tap(find.byKey(const ValueKey('console-accept')));
    await tester.pumpAndSettle();
    final box = find.byKey(const ValueKey('console-command'));
    await tester.enterText(box, 'cd /sdcard/Download');
    await tester.tap(find.byKey(const ValueKey('console-run')));
    await tester.pumpAndSettle();
    await tester.enterText(box, 'ls');
    await tester.tap(find.byKey(const ValueKey('console-run')));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.shell'), [
      {'id': tvId, 'command': 'cd /sdcard/Download'},
      {'id': tvId, 'command': 'ls', 'cwd': '/sdcard/Download'},
    ]);
    expect(find.text('/sdcard/Download \$ ls'), findsOneWidget);
  });

  testWidgets('a refused command shows the engine error as output', (
    tester,
  ) async {
    engine.answers['tv.shell'] = {
      'ok': false,
      'error': {'type': 'needs_user', 'message': 'the shell is user only'},
    };
    await pumpTv(tester, engine);
    await openTvTab(tester, 'Console');
    await tester.tap(find.byKey(const ValueKey('console-accept')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('console-command')), 'id');
    await tester.tap(find.byKey(const ValueKey('console-run')));
    await tester.pumpAndSettle();
    expect(find.text('The shell is user only.'), findsOneWidget);
  });
}
