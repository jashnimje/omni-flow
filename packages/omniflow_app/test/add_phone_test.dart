import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/add/add_page.dart';
import 'package:omniflow_app/ui/add/add_phone_page.dart';
import 'package:omniflow_app/ui/add/guided_steps_page.dart';

import 'automations_fixtures.dart' show tapKey;
import 'fake_engine.dart';
import 'screen_harness.dart';

const _code = '482913';

Map<String, Object?> _found({bool pairing = true}) => {
  'ok': true,
  'phones': [
    {
      'name': 'Pixel 8',
      'guid': 'adb-FAKE-AbCdEf',
      'host': '192.168.1.77',
      'pairingPort': ?(pairing ? 37123 : null),
      'connectPort': 41234,
    },
  ],
};

FakeEngine _engine() {
  final engine = FakeEngine();
  engine.answers.addAll({
    'android.find': _found(),
    'thing.add': {
      'ok': true,
      'id': 'phone_77',
      'next': {
        'step': 'pair',
        'method': 'adb',
        'remaining': ['pair'],
      },
    },
    'thing.next': {
      'ok': true,
      'next': {'step': 'done', 'instruction': 'The phone is ready'},
    },
  });
  engine.answerers['android.pair'] = (args) => args['code'] == _code
      ? {'ok': true, 'guid': 'adb-FAKE-AbCdEf'}
      : {
          'ok': false,
          'error': {
            'type': 'pairing_failed',
            'message':
                'The code did not match. Check the six digits and pair again',
          },
        };
  return engine;
}

/// Every string any call carried, so a test can say where the code went.
Iterable<String> _strings(Object? v) sync* {
  if (v is String) yield v;
  if (v is Map) {
    for (final e in v.values) {
      yield* _strings(e);
    }
  }
  if (v is List) {
    for (final e in v) {
      yield* _strings(e);
    }
  }
}

Future<void> _enterCode(WidgetTester tester, String code) async {
  final field = find.byKey(const ValueKey('phone-code'));
  await tester.ensureVisible(field);
  await tester.enterText(field, code);
  await tapKey(tester, 'phone-pair');
}

void main() {
  testWidgets('Add lists Another phone, which explains Wireless debugging', (
    tester,
  ) async {
    final engine = _engine();
    await pumpScreen(tester, engine, const AddPage());
    await tapKey(tester, 'add-another-phone');
    expect(find.byType(AddPhonePage), findsOneWidget);
    for (var i = 0; i < phoneSetupSteps.length; i++) {
      expect(find.byKey(ValueKey('phone-step-$i')), findsOneWidget);
    }
    expect(find.textContaining('Build number 7 times'), findsOneWidget);
    expect(find.textContaining('Developer options'), findsOneWidget);
    expect(find.textContaining('Pair device with pairing code'), findsWidgets);
    expect(engine.callsOf('android.find'), hasLength(1));
    expect(find.byKey(const ValueKey('phone-found-0')), findsOneWidget);
    expect(find.textContaining('ready to pair'), findsOneWidget);
  });

  testWidgets('a found phone pairs with its code and is added on its '
      'connect port, and the code is never shown again', (tester) async {
    final engine = _engine();
    await pumpScreen(tester, engine, const AddPhonePage());
    await tapKey(tester, 'phone-found-0');
    await _enterCode(tester, _code);

    expect(engine.callsOf('android.pair').single.$2, {
      'host': '192.168.1.77',
      'port': 37123,
      'code': _code,
    });
    final add = engine.callsOf('thing.add').single.$2;
    expect(add['candidate'], {
      'driver': 'android_phone_adb',
      'host': '192.168.1.77',
      'port': 41234,
      'stableId': 'adb-FAKE-AbCdEf',
    });
    expect(add['name'], 'Pixel 8');
    expect(engine.callsOf('thing.next').single.$2, {
      'id': 'phone_77',
      'paired': true,
    });
    expect(engine.callsOf('device.pair'), isEmpty);
    expect(find.byType(GuidedStepsPage), findsOneWidget);
    expect(find.text(_code), findsNothing);
    expect(find.textContaining(_code), findsNothing);
    for (final (command, args) in engine.calls) {
      if (command == 'android.pair') continue;
      expect(_strings(args), isNot(contains(_code)), reason: command);
    }
  });

  testWidgets('a wrong code says so plainly and clears the field', (
    tester,
  ) async {
    final engine = _engine();
    await pumpScreen(tester, engine, const AddPhonePage());
    await tapKey(tester, 'phone-found-0');
    await _enterCode(tester, '000000');
    expect(find.byKey(const ValueKey('phone-error')), findsOneWidget);
    expect(find.textContaining('The code did not match'), findsOneWidget);
    expect(find.text('000000'), findsNothing);
    expect(engine.callsOf('thing.add'), isEmpty);
  });

  testWidgets('a code that is not six digits is not sent', (tester) async {
    final engine = _engine();
    await pumpScreen(tester, engine, const AddPhonePage());
    await tapKey(tester, 'phone-found-0');
    await _enterCode(tester, '123');
    expect(find.textContaining('six digits'), findsOneWidget);
    expect(engine.callsOf('android.pair'), isEmpty);
  });

  testWidgets('an engine without android.pair says it needs an update', (
    tester,
  ) async {
    final engine = _engine();
    engine.answerers.remove('android.pair');
    engine.answers['android.pair'] = {
      'ok': false,
      'error': {
        'type': 'unknown_command',
        'message': 'no command android.pair',
      },
    };
    engine.answers['android.find'] = {
      'ok': false,
      'error': {
        'type': 'unknown_command',
        'message': 'no command android.find',
      },
    };
    await pumpScreen(tester, engine, const AddPhonePage());
    expect(find.textContaining('cannot look for phones yet'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('phone-host')),
      '192.168.1.77',
    );
    await tester.enterText(
      find.byKey(const ValueKey('phone-pair-port')),
      '37123',
    );
    await _enterCode(tester, _code);
    expect(find.byKey(const ValueKey('phone-needs-update')), findsOneWidget);
    expect(find.textContaining('needs an update'), findsOneWidget);
    expect(find.text(_code), findsNothing);
    expect(engine.callsOf('thing.add'), isEmpty);
  });

  testWidgets('paired with no connect port on mDNS asks for it', (
    tester,
  ) async {
    final engine = _engine();
    engine.answers['android.find'] = {'ok': true, 'phones': const []};
    await pumpScreen(tester, engine, const AddPhonePage());
    await tester.enterText(
      find.byKey(const ValueKey('phone-host')),
      '192.168.1.80',
    );
    await tester.enterText(
      find.byKey(const ValueKey('phone-pair-port')),
      '37000',
    );
    await _enterCode(tester, _code);
    expect(find.byKey(const ValueKey('phone-connect-port')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('phone-connect-port')),
      '40111',
    );
    await tapKey(tester, 'phone-connect-add');
    final add = engine.callsOf('thing.add').single.$2['candidate'] as Map;
    expect(add['port'], 40111);
    expect(add['host'], '192.168.1.80');
    expect(add['stableId'], 'adb-FAKE-AbCdEf');
  });

  testWidgets('the classic route adds an address on port 5555 and pairs with '
      'the prompt', (tester) async {
    final engine = _engine()
      ..answers['device.pair'] = {'ok': true, 'paired': true};
    await pumpScreen(tester, engine, const AddPhonePage());
    await tester.tap(find.text('Port 5555'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('phone-classic-host')),
      '192.168.1.90',
    );
    await tapKey(tester, 'phone-classic-add');
    final add = engine.callsOf('thing.add').single.$2['candidate'] as Map;
    expect(add['port'], 5555);
    expect(add.containsKey('stableId'), isFalse);
    expect(engine.callsOf('android.pair'), isEmpty);
    expect(find.byType(GuidedStepsPage), findsOneWidget);
  });
}
