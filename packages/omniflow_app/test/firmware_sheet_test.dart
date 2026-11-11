import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/boards/firmware_sheet.dart';

import 'fake_engine.dart';
import 'screen_harness.dart';
import 'tv_fixtures.dart' show FakePhoneFiles;

class _Opener extends StatelessWidget {
  const _Opener();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const ValueKey('open'),
        onPressed: () => showFirmwareSheet(context),
        child: const Text('open'),
      ),
    ),
  );
}

void main() {
  late FakeEngine engine;

  setUp(() {
    engine = FakeEngine();
    engine.answers['board.ports'] = {
      'ok': true,
      'ports': ['usb:/dev/bus/usb/001/007'],
      'canFlash': true,
    };
    engine.answerers['board.flash'] = (args) {
      engine.eventsOut.add({
        'event': 'board.flashProgress',
        'port': args['port'],
        'stage': 'Writing',
        'done': 0.5,
      });
      return {'ok': true, 'chip': args['chip'], 'bytes': 1000, 'ms': 4200};
    };
  });

  testWidgets('writes your own firmware to the board on USB after asking', (
    tester,
  ) async {
    final files = FakePhoneFiles(
      files: [(name: 'blink.ino.bin', path: '/tmp/blink.ino.bin')],
    );
    await pumpScreen(
      tester,
      engine,
      const _Opener(),
      overrides: [phoneFilesProvider.overrideWithValue(files)],
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.text('The board on USB'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fw-chip-esp8266')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('fw-own')));
    await tester.pumpAndSettle();
    expect(files.picks.single, ['bin']);
    expect(find.text('blink.ino.bin'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fw-write')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('board.flash'), isEmpty, reason: 'asks first');
    await tester.tap(find.text('Write it'));
    await tester.pumpAndSettle();
    expect(engine.callsOf('board.flash').single.$2, {
      'port': 'usb:/dev/bus/usb/001/007',
      'chip': 'esp8266',
      'file': '/tmp/blink.ino.bin',
    });
    expect(
      find.textContaining('Your firmware is on the board (4 s)'),
      findsOneWidget,
    );
  });

  testWidgets('with nothing plugged in it says how to connect', (tester) async {
    engine.answers['board.ports'] = {'ok': true, 'ports': <String>[]};
    await pumpScreen(tester, engine, const _Opener());
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fw-none')), findsOneWidget);
  });
}
