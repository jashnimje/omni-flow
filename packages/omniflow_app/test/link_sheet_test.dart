import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/design/design.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

final _board = {
  'id': 'desk',
  'name': 'Desk board',
  'driver': 'omniflow_board',
  'board': true,
  'host': '192.168.1.77',
  'state': {'button': true, 'light': 42, 'rssi': -60},
  'capabilities': [
    {
      'id': 'button',
      'type': 'sensor',
      'label': 'button',
      'stateKey': 'button',
      'params': {},
    },
    {
      'id': 'light',
      'type': 'sensor',
      'label': 'light',
      'stateKey': 'light',
      'params': {},
    },
  ],
};

/// What link.options answers for each source, shaped like the engine's.
Map<String, Object?> _linkOptions(Map<String, Object?> args) =>
    switch (args['from']) {
      'desk.light' || 'desk.rssi' => {
        'ok': true,
        'modes': ['follow', 'threshold'],
        'targets': [
          {
            'to': 'desk_lamp.power',
            'modes': ['threshold'],
          },
          {
            'to': 'desk_lamp.brightness',
            'modes': ['follow', 'threshold'],
          },
        ],
      },
      _ => {
        'ok': true,
        'modes': ['toggle', 'follow'],
        'targets': [
          {
            'to': 'desk_lamp.power',
            'modes': ['toggle', 'follow'],
          },
        ],
      },
    };

/// Opens the link sheet from the desk board, as its device page does.
Future<void> _open(WidgetTester tester, FakeEngine engine) async {
  await pumpPage(
    tester,
    engine,
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            key: const ValueKey('open-link'),
            onPressed: () => showOmniSheet<void>(
              context,
              builder: (_) => const LinkSheet(fromDevice: 'desk'),
            ),
            child: const Text('Link'),
          ),
        ),
      ),
    ),
  );
  await tapKey(tester, 'open-link');
}

List<String> _modes(WidgetTester tester) => [
  for (final s
      in tester
          .widget<OmniSegmented<String>>(
            find.byKey(const ValueKey('link-mode')),
          )
          .segments)
    s.value,
];

void main() {
  late FakeEngine engine;

  setUp(() {
    engine = FakeEngine()..devices = [_board, FakeEngine.lamp()];
    engine.answerers['link.options'] = _linkOptions;
  });

  testWidgets('the link sheet creates a trusted toggle link', (tester) async {
    engine.answers['link.create'] = {
      'ok': true,
      'id': 'link_desk_button_desk_lamp_power_toggle',
      'name': 'desk.button toggles desk_lamp.power',
    };
    await _open(tester, engine);
    expect(engine.callsOf('link.options').first.$2, {'from': 'desk.button'});
    expect(find.text('Desk board - button'), findsOneWidget);
    await tapKey(tester, 'link-to');
    expect(find.text('Desk lamp - Brightness'), findsNothing);
    await tapText(tester, 'Desk lamp - Power');
    await tapKey(tester, 'link-create');
    expect(engine.callsOf('link.create').single.$2, {
      'from': 'desk.button',
      'to': 'desk_lamp.power',
      'mode': 'toggle',
      'trusted': true,
    });
    expect(
      find.text('Linked: desk.button toggles desk_lamp.power'),
      findsOneWidget,
    );
  });

  testWidgets('a numeric source defaults to threshold and cannot toggle', (
    tester,
  ) async {
    await _open(tester, engine);
    await tapKey(tester, 'link-from');
    await tapText(tester, 'Desk board - light');
    expect(
      tester
          .widget<OmniSegmented<String>>(
            find.byKey(const ValueKey('link-mode')),
          )
          .selected,
      'threshold',
    );
    expect(_modes(tester), isNot(contains('toggle')));
    await tapKey(tester, 'link-to');
    await tapText(tester, 'Desk lamp - Power');
    await tester.enterText(find.byKey(const ValueKey('link-limit')), '30');
    await tester.pump();
    await tapKey(tester, 'link-create');
    expect(engine.callsOf('link.create').single.$2, {
      'from': 'desk.light',
      'to': 'desk_lamp.power',
      'mode': 'threshold',
      'above': 30,
      'set': true,
      'trusted': true,
    });
  });

  testWidgets('a follow offers only the targets the engine allows for it', (
    tester,
  ) async {
    await _open(tester, engine);
    await tapKey(tester, 'link-from');
    await tapText(tester, 'Desk board - light');
    await tapText(tester, 'Follow');
    await tapKey(tester, 'link-to');
    expect(find.text('Desk lamp - Power'), findsNothing);
    expect(find.text('Desk lamp - Brightness'), findsWidgets);
  });

  testWidgets('raw state keys stay behind the switch', (tester) async {
    await _open(tester, engine);
    await tapKey(tester, 'link-from');
    expect(find.text('Desk board - rssi'), findsNothing);
    await tapText(tester, 'Desk board - button');
    await tapKey(tester, 'link-more');
    await tapKey(tester, 'link-from');
    expect(find.text('Desk board - rssi'), findsWidgets);
  });

  testWidgets('a source the engine refuses shows why', (tester) async {
    engine.answerers['link.options'] = (_) => {
      'ok': false,
      'error': {'type': 'not_found', 'message': 'desk has no state button'},
    };
    await _open(tester, engine);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('link-error')),
        matching: find.text('Desk has no state button.'),
      ),
      findsOneWidget,
    );
    expect(buttonEnabled(tester, 'link-create'), isFalse);
  });
}
