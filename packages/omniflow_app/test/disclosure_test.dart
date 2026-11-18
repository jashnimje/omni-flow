import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/theme.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool reducedMotion = false,
  double textScale = 1,
  Size size = const Size(412, 915),
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: omniTheme(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reducedMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: ListView(padding: OmniSpace.screenPadding, children: [child]),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OmniDisclosure _activity({ValueChanged<bool>? onChanged}) => OmniDisclosure(
  icon: OmniIcons.info,
  title: 'Activity',
  summary: '5 changes today',
  onChanged: onChanged,
  children: const [
    OmniListRow(title: 'Turned on by you', value: '2:43 PM'),
    OmniListRow(title: 'Brightness 60% by you', value: '2:41 PM'),
  ],
);

SemanticsNode _header(WidgetTester tester) =>
    tester.getSemantics(find.bySemanticsLabel('Activity, 5 changes today'));

void main() {
  testWidgets('starts collapsed, with its rows hidden', (tester) async {
    await _pump(tester, _activity());
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('5 changes today'), findsOneWidget);
    expect(find.text('Turned on by you'), findsNothing);
  });

  testWidgets('a tap on the header opens it, and a second closes it', (
    tester,
  ) async {
    final changes = <bool>[];
    await _pump(tester, _activity(onChanged: changes.add));
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Turned on by you'), findsOneWidget);
    expect(find.text('Brightness 60% by you'), findsOneWidget);

    await tester.tap(find.text('5 changes today'));
    await tester.pumpAndSettle();
    expect(find.text('Turned on by you'), findsNothing);
    expect(changes, [true, false]);
  });

  testWidgets('screen readers hear a button that says expanded or collapsed', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _activity());
    expect(
      _header(tester),
      matchesSemantics(
        label: 'Activity, 5 changes today',
        isButton: true,
        hasExpandedState: true,
        isExpanded: false,
        hasTapAction: true,
      ),
    );

    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(
      _header(tester),
      matchesSemantics(
        label: 'Activity, 5 changes today',
        isButton: true,
        hasExpandedState: true,
        isExpanded: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('the header row is at least 56 dp high', (tester) async {
    await _pump(
      tester,
      const OmniDisclosure(
        icon: OmniIcons.settings,
        title: 'More settings',
        children: [],
      ),
    );
    final header = find.ancestor(
      of: find.text('More settings'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(header.first).height, greaterThanOrEqualTo(56));
    await _pump(tester, _activity());
    final twoLine = find.ancestor(
      of: find.text('Activity'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(twoLine.first).height, greaterThanOrEqualTo(72));
  });

  testWidgets('opens over time, and at once under reduced motion', (
    tester,
  ) async {
    double height() => tester.getSize(find.byType(OmniDisclosure)).height;

    await _pump(tester, _activity());
    final closed = height();
    await tester.tap(find.text('Activity'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final midway = height();
    await tester.pumpAndSettle();
    final open = height();
    expect(midway, greaterThan(closed));
    expect(midway, lessThan(open));

    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    await _pump(tester, _activity(), reducedMotion: true);
    await tester.tap(find.text('Activity'));
    await tester.pump();
    expect(height(), open);
  });

  testWidgets('keeps its open state in the page storage', (tester) async {
    final bucket = PageStorageBucket();
    Widget page(bool shown) => PageStorage(
      bucket: bucket,
      child: shown ? _activity() : const SizedBox(),
    );
    await _pump(tester, page(true));
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();

    await _pump(tester, page(false));
    expect(find.text('Activity'), findsNothing);
    await _pump(tester, page(true));
    expect(find.text('Turned on by you'), findsOneWidget);
  });

  testWidgets('a disclosure inside another opens on its own', (tester) async {
    await _pump(
      tester,
      const OmniDisclosure(
        icon: OmniIcons.settings,
        title: 'More settings',
        summary: 'Room, name, follow the sun',
        children: [
          OmniListRow(title: 'Room', subtitle: 'Bedroom'),
          OmniDisclosure(
            icon: OmniIcons.info,
            title: 'Developer details',
            summary: 'Ids and the messages sent to it',
            children: [OmniListRow(title: 'Id', value: 'wiz-a8bb50e1')],
          ),
        ],
      ),
    );
    await tester.tap(find.text('More settings'));
    await tester.pumpAndSettle();
    expect(find.text('Developer details'), findsOneWidget);
    expect(find.text('Id'), findsNothing);
    await tester.tap(find.text('Developer details'));
    await tester.pumpAndSettle();
    expect(find.text('Id'), findsOneWidget);
  });

  testWidgets('holds at 200 % text size, closed and open, with no overflow', (
    tester,
  ) async {
    await _pump(
      tester,
      const OmniDisclosure(
        icon: OmniIcons.settings,
        title: 'More settings',
        summary: 'Room, name, follow the sun, developer details',
        children: [
          OmniListRow(
            title: 'Follow the sun',
            subtitle: 'Warm at night, cool at midday',
            trailing: Switch(value: false, onChanged: null),
          ),
        ],
      ),
      textScale: 2,
      size: const Size(360, 800),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('More settings'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Follow the sun'), findsOneWidget);
    final summary = tester.renderObject<RenderParagraph>(
      find.text('Room, name, follow the sun, developer details'),
    );
    expect(summary.didExceedMaxLines, isFalse);
  });

  testWidgets('a detail page puts its sections after the body, closed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: omniTheme(),
        home: DetailPage(
          title: 'Bedroom light',
          children: (context) => const [Text('Brightness')],
          sections: (context) => [_activity()],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final body = tester.getTopLeft(find.text('Brightness'));
    final section = tester.getTopLeft(find.text('Activity'));
    expect(section.dy, greaterThan(body.dy));
    expect(find.text('Turned on by you'), findsNothing);
  });
}
