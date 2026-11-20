import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/add/add_by_hand_page.dart';
import 'package:omniflow_app/ui/add/add_page.dart';
import 'package:omniflow_app/ui/add/wiz_import_page.dart';
import 'package:omniflow_app/ui/devices/open_device.dart' show DeviceRoute;
import 'package:omniflow_app/ui/shell/links.dart';

import 'fake_engine.dart';
import 'screen_harness.dart';

const _link =
    'https://wiz-s3-local-integration-eu.s3.eu-west-1.amazonaws.com/'
    'export/123.json?X-Amz-Signature=abc';

class _Hands implements WizImportHands {
  String? clipboard;
  String? file;
  String? shared;
  var picks = 0;

  @override
  Future<String?> pasted() async => clipboard;

  @override
  Future<String?> pickFile() async {
    picks++;
    return file;
  }

  @override
  Future<String?> takeShared() async {
    final s = shared;
    shared = null;
    return s;
  }
}

const _imported = {
  'ok': true,
  'home': 'My home',
  'added': [
    {
      'id': 'desk_lamp',
      'name': 'Desk lamp',
      'room': 'Bedroom',
      'host': '192.168.1.40',
    },
  ],
  'updated': [
    {'id': 'hall_light', 'name': 'Hall light', 'host': '192.168.1.41'},
  ],
  'notFound': [
    {
      'name': 'Porch',
      'mac': 'a8bb50000003',
      'reason': 'It did not answer on this Wi-Fi. Check it is switched on',
    },
  ],
  'roomsCreated': ['Bedroom'],
  'message':
      'Added 1 light and updated 1 light. 1 was not found on this '
      'Wi-Fi.',
};

void main() {
  late FakeEngine engine;
  late _Hands hands;

  setUp(() {
    engine = FakeEngine();
    hands = _Hands();
    engine.answers['wiz.import'] = _imported;
  });

  Future<void> open(WidgetTester tester) => pumpScreen(
    tester,
    engine,
    const WizImportPage(),
    overrides: [wizImportHandsProvider.overrideWithValue(hands)],
  );

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('says how to get the link in the WiZ app\'s words', (
    tester,
  ) async {
    await open(tester);
    expect(find.text(wizExportSteps), findsOneWidget);
    expect(
      wizExportSteps,
      'In the WiZ app: Settings, your home, Integrations, Local '
      'integrations, Export. Copy the link.',
    );
    expect(find.byKey(const ValueKey('wiz-add')), findsNothing);
  });

  testWidgets('paste reads the clipboard and adds at once', (tester) async {
    hands.clipboard = '  $_link\n';
    await open(tester);
    await tap(tester, 'wiz-paste');
    expect(engine.callsOf('wiz.import').single.$2, {'text': _link});
    expect(find.byKey(const ValueKey('wiz-summary')), findsOneWidget);
  });

  testWidgets('an empty clipboard says to copy the link first, and sends '
      'nothing', (tester) async {
    await open(tester);
    await tap(tester, 'wiz-paste');
    expect(engine.callsOf('wiz.import'), isEmpty);
    expect(find.textContaining('Copy the link in the WiZ app'), findsOneWidget);
  });

  testWidgets('a picked file is sent as its text', (tester) async {
    hands.file = '{"devices": []}';
    await open(tester);
    await tap(tester, 'wiz-file');
    expect(hands.picks, 1);
    expect(engine.callsOf('wiz.import').single.$2, {'text': '{"devices": []}'});
  });

  testWidgets('the result lists added, updated and not found in plain words, '
      'and an added bulb opens its page', (tester) async {
    hands.clipboard = _link;
    await open(tester);
    await tap(tester, 'wiz-paste');
    expect(
      find.textContaining('Added 1 light and updated 1 light'),
      findsOneWidget,
    );
    expect(find.textContaining('New rooms: Bedroom.'), findsOneWidget);
    expect(find.text('Added'), findsOneWidget);
    expect(find.text('Bedroom · 192.168.1.40'), findsOneWidget);
    expect(find.text('Already here, brought up to date'), findsOneWidget);
    expect(find.text('Not found on this Wi-Fi'), findsOneWidget);
    expect(find.text('Porch'), findsOneWidget);
    await tap(tester, 'wiz-added-desk_lamp');
    expect(find.byType(DeviceRoute), findsOneWidget);
  });

  testWidgets('a refusal shows the engine\'s words', (tester) async {
    engine.answers['wiz.import'] = {
      'ok': false,
      'error': {
        'type': 'invalid',
        'message': 'That link is not a WiZ export link.',
      },
    };
    hands.clipboard = 'https://example.com/x';
    await open(tester);
    await tap(tester, 'wiz-paste');
    expect(find.text('That link is not a WiZ export link.'), findsOneWidget);
  });

  testWidgets('a share from the WiZ app opens the screen filled in, and one '
      'tap adds', (tester) async {
    hands.shared = _link;
    await open(tester);
    expect(find.byKey(const ValueKey('wiz-source')), findsOneWidget);
    expect(find.text(_link), findsOneWidget);
    expect(engine.callsOf('wiz.import'), isEmpty);
    await tap(tester, 'wiz-add');
    expect(engine.callsOf('wiz.import').single.$2, {'text': _link});
    expect(find.byKey(const ValueKey('wiz-summary')), findsOneWidget);
  });

  testWidgets('a shared export file reads as the export, not as its JSON', (
    tester,
  ) async {
    hands.shared = '{"devices": [], "udp_signing_key": "secret"}';
    await open(tester);
    expect(find.text('Your WiZ export'), findsOneWidget);
    expect(find.textContaining('udp_signing_key'), findsNothing);
  });

  test('the share opens /add/wiz', () {
    expect(ShellLink.parse('omniflow://open/add/wiz'), const WizImportLink());
    expect(ShellLink.parse('/add/wiz'), const WizImportLink());
  });

  testWidgets('adding a WiZ light by hand puts the address and the key '
      'behind Add by IP address, and offers the WiZ app first', (tester) async {
    engine.answers['driver.list'] = {
      'ok': true,
      'drivers': [
        {
          'id': 'philips_wiz_udp',
          'name': 'Philips WiZ Light (local UDP)',
          'category': 'lighting',
          'transport': 'udp',
          'importFrom': 'wiz',
          'settings': [
            {'key': 'signingKey', 'label': 'WiZ home key', 'secret': true},
          ],
        },
      ],
    };
    engine.answers['device.add'] = {
      'ok': true,
      'device': {'id': 'desk', 'name': 'Desk'},
      'next': {'step': 'done'},
    };
    engine.answers['secret.set'] = {'ok': true, 'stored': 'x'};
    await pumpScreen(
      tester,
      engine,
      const AddByHandPage(driver: 'philips_wiz_udp'),
      overrides: [wizImportHandsProvider.overrideWithValue(hands)],
    );
    expect(find.byKey(const ValueKey('add-from-wiz-app')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-host')), findsNothing);
    await tap(tester, 'add-by-ip');
    expect(find.text(ipAddressHelp), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('add-host')),
      '192.168.1.9',
    );
    await tester.enterText(
      find.byKey(const ValueKey('add-secret-signingKey')),
      '00112233445566778899aabbccddeeff',
    );
    await tester.enterText(find.byKey(const ValueKey('add-name')), 'Desk');
    await tester.pump();
    await tap(tester, 'add-save');
    expect(engine.callsOf('device.add').single.$2['host'], '192.168.1.9');
    expect(engine.callsOf('secret.set').single.$2, {
      'deviceId': 'desk',
      'key': 'signingKey',
      'value': '00112233445566778899aabbccddeeff',
    });
  });

  testWidgets('Add offers From the WiZ app, which opens the import', (
    tester,
  ) async {
    engine.answers['driver.list'] = {
      'ok': true,
      'drivers': [
        {
          'id': 'philips_wiz_udp',
          'name': 'Philips WiZ Light (local UDP)',
          'category': 'lighting',
          'transport': 'udp',
          'importFrom': 'wiz',
          'settings': const [],
        },
      ],
    };
    await pumpScreen(
      tester,
      engine,
      const AddPage(),
      overrides: [wizImportHandsProvider.overrideWithValue(hands)],
    );
    await tap(tester, 'add-from-wiz');
    expect(find.byType(WizImportPage), findsOneWidget);
  });
}
