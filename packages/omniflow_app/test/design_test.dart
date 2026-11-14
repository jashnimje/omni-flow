import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/theme.dart';

Future<void> pumpDesign(
  WidgetTester tester,
  Widget child, {
  bool reducedMotion = false,
}) async {
  tester.view.physicalSize = const Size(1236, 2400);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: omniTheme(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: Scaffold(
          body: Padding(padding: const EdgeInsets.all(14), child: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('tile', () {
    testWidgets('reads its name and state, and taps and long presses', (
      tester,
    ) async {
      var taps = 0;
      var holds = 0;
      var toggles = 0;
      await pumpDesign(
        tester,
        SizedBox(
          width: 180,
          child: OmniTile(
            icon: OmniIcons.light,
            name: 'Desk lamp',
            state: '80% · warm',
            on: true,
            level: 0.8,
            tint: const Color(0xFFFFD93D),
            tapHint: 'Opens it',
            iconKey: const ValueKey('icon'),
            iconLabel: 'Turn off Desk lamp',
            onIconTap: () => toggles++,
            onTap: () => taps++,
            onLongPress: () => holds++,
          ),
        ),
      );
      expect(find.text('Desk lamp'), findsOneWidget);
      expect(find.byType(FractionallySizedBox), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(OmniTile)),
        matchesSemantics(
          label: 'Desk lamp, 80% · warm',
          hint: 'Opens it',
          isButton: true,
          hasTapAction: true,
          hasLongPressAction: true,
          onLongPressHint: 'Open controls',
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('icon'))),
        matchesSemantics(
          label: 'Turn off Desk lamp',
          isButton: true,
          hasToggledState: true,
          isToggled: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.text('Desk lamp'));
      await tester.longPress(find.text('Desk lamp'));
      await tester.tap(find.byKey(const ValueKey('icon')));
      expect((taps, holds, toggles), (1, 1, 1));
      // A bright yellow light gives a muted tile its text still reads on.
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });

    testWidgets('a pending switch shimmers, then rests', (tester) async {
      Widget tile({required bool pending}) => MaterialApp(
        theme: omniTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: OmniTile(
              icon: OmniIcons.light,
              name: 'Desk lamp',
              on: true,
              pending: pending,
            ),
          ),
        ),
      );
      await tester.pumpWidget(tile(pending: true));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(ShaderMask), findsOneWidget);
      await tester.pumpWidget(tile(pending: false));
      await tester.pump();
      expect(find.byType(ShaderMask), findsNothing);
    });

    testWidgets('an offline tile keeps its name readable in muted grey', (
      tester,
    ) async {
      await pumpDesign(
        tester,
        const SizedBox(
          width: 180,
          child: OmniTile(
            icon: OmniIcons.light,
            name: 'Hall bulb',
            state: 'Offline',
            offline: true,
          ),
        ),
      );
      final name = tester.widget<Text>(find.text('Hall bulb'));
      expect(name.style?.color, OmniColors.muted);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });
  });

  testWidgets('a list row shows its value, dot or chevron, and taps', (
    tester,
  ) async {
    var taps = 0;
    await pumpDesign(
      tester,
      Column(
        children: [
          OmniListRow(
            icon: OmniIcons.tv,
            title: 'Living room TV',
            subtitle: 'Android TV · Netflix · vol 35',
            dot: StatusKind.online,
            onTap: () => taps++,
          ),
          const OmniListRow(title: 'Netflix', value: 'running'),
          const OmniListRow(title: 'Room', subtitle: 'Hall', chevron: true),
        ],
      ),
    );
    expect(find.text('running'), findsOneWidget);
    expect(find.byIcon(OmniIcons.chevron), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Online')), findsOneWidget);
    await tester.tap(find.text('Living room TV'));
    expect(taps, 1);
    expect(
      tester.getSize(find.byType(OmniListRow).first).height,
      greaterThanOrEqualTo(48),
    );
  });

  group('chips', () {
    testWidgets('a filter chip has a 48 dp target and says it is selected', (
      tester,
    ) async {
      String? tapped;
      await pumpDesign(
        tester,
        Wrap(
          children: [
            OmniFilterChip(
              label: 'All',
              count: 6,
              selected: true,
              onTap: () => tapped = 'all',
            ),
            OmniFilterChip(
              label: 'Needs you',
              count: 1,
              dot: StatusKind.warning,
              onTap: () => tapped = 'needs',
            ),
          ],
        ),
      );
      expect(find.text('All 6'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('All 6')),
        matchesSemantics(
          label: 'All 6',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      final chip = tester.getRect(find.byType(OmniFilterChip).last);
      expect(chip.height, greaterThanOrEqualTo(48));
      await tester.tapAt(Offset(chip.center.dx, chip.top + 2));
      expect(tapped, 'needs');
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });

    testWidgets('a segmented control reports the segment tapped', (
      tester,
    ) async {
      var picked = 'room';
      await pumpDesign(
        tester,
        StatefulBuilder(
          builder: (context, setState) => OmniSegmented<String>(
            segments: const [
              OmniSegment('room', 'By room'),
              OmniSegment('type', 'By type'),
              OmniSegment('problems', 'Problems', count: 1),
            ],
            selected: picked,
            onChanged: (v) => setState(() => picked = v),
          ),
        ),
      );
      await tester.tap(find.text('Problems 1'));
      await tester.pumpAndSettle();
      expect(picked, 'problems');
      expect(
        tester.getSemantics(find.bySemanticsLabel('Problems 1')),
        matchesSemantics(
          label: 'Problems 1',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });
  });

  group('labelled slider', () {
    testWidgets('a drag moves it and sends one value on release', (
      tester,
    ) async {
      final ends = <double>[];
      final moves = <double>[];
      await pumpDesign(
        tester,
        OmniLabelledSlider(
          label: 'Brightness',
          value: 20,
          step: 1,
          format: (v) => '${v.round()}%',
          onChanged: moves.add,
          onChangeEnd: ends.add,
        ),
      );
      expect(find.text('20%'), findsOneWidget);
      final box = tester.getRect(find.byType(OmniLabelledSlider));
      final gesture = await tester.startGesture(
        Offset(box.left + box.width * 0.2, box.center.dy),
      );
      await gesture.moveBy(Offset(box.width * 0.3, 0));
      await gesture.moveBy(Offset(box.width * 0.3, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(moves.length, greaterThan(1));
      expect(ends, hasLength(1));
      expect(ends.single, closeTo(80, 2));
      expect(find.text('${ends.single.round()}%'), findsOneWidget);
    });

    testWidgets('screen readers step it up and down', (tester) async {
      final ends = <double>[];
      await pumpDesign(
        tester,
        OmniLabelledSlider(
          label: 'Warmth',
          value: 3000,
          min: 2200,
          max: 6500,
          step: 100,
          format: (v) => '${v.round()} K',
          onChangeEnd: ends.add,
        ),
      );
      final node = tester.getSemantics(find.byType(OmniLabelledSlider));
      expect(
        node,
        matchesSemantics(
          label: 'Warmth',
          value: '3000 K',
          increasedValue: '3100 K',
          decreasedValue: '2900 K',
          isSlider: true,
          hasEnabledState: true,
          isEnabled: true,
          hasIncreaseAction: true,
          hasDecreaseAction: true,
        ),
      );
      tester.semantics.increase(find.semantics.byLabel('Warmth'));
      await tester.pumpAndSettle();
      expect(ends, [3100]);
    });
  });

  testWidgets('a sentence is chips for when, only if and then', (tester) async {
    await pumpDesign(
      tester,
      const AutomationSentence([
        SentencePart(SentenceKind.when, 'When I get home'),
        SentencePart(SentenceKind.onlyIf, 'after 6 pm'),
        SentencePart(SentenceKind.text, '→'),
        SentencePart(SentenceKind.then, 'TV on'),
      ]),
    );
    final when = tester.widget<Text>(find.text('When I get home'));
    expect(when.style?.color, OmniColors.trigger);
    final onlyIf = tester.widget<Text>(find.text('after 6 pm'));
    expect(onlyIf.style?.color, OmniColors.condition);
    expect(find.byType(SentenceChip), findsNWidgets(3));
    expect(
      find.bySemanticsLabel('When I get home after 6 pm → TV on'),
      findsOneWidget,
    );
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  });

  testWidgets('a rule block heads its rows and adds one', (tester) async {
    var added = 0;
    await pumpDesign(
      tester,
      OmniRuleBlock(
        kind: SentenceKind.when,
        heading: 'When',
        caption: 'any of these',
        addLabel: 'Add trigger',
        onAdd: () => added++,
        children: const [OmniStepRow(text: 'I get home')],
      ),
    );
    expect(find.text('WHEN · any of these'), findsOneWidget);
    await tester.tap(find.text('Add trigger'));
    expect(added, 1);
  });

  group('step row', () {
    testWidgets('removes, shows an error, and names its buttons', (
      tester,
    ) async {
      var removed = 0;
      await pumpDesign(
        tester,
        Column(
          children: [
            OmniStepRow(
              icon: OmniIcons.light,
              text: 'Hall bulb · on, 70%',
              error: 'hall_bulb has no capability dim',
              onRemove: () => removed++,
            ),
            const OmniStepRow(
              icon: OmniIcons.wait,
              text: 'Wait 3 s',
              style: StepRowStyle.wait,
            ),
            const OmniStepRow(
              icon: OmniIcons.branch,
              text: 'If TV is on Netflix',
              style: StepRowStyle.flow,
              trailingText: '2',
            ),
          ],
        ),
      );
      expect(find.text('hall_bulb has no capability dim'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove Hall bulb · on, 70%'));
      expect(removed, 1);
      expect(find.text('2'), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });

    testWidgets('the handle reorders rows in a reorderable list', (
      tester,
    ) async {
      final steps = ['TV on', 'Wait 3 s', 'Lights on'];
      await pumpDesign(
        tester,
        StatefulBuilder(
          builder: (context, setState) => SizedBox(
            height: 400,
            child: ReorderableListView(
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) => setState(() {
                steps.insert(to, steps.removeAt(from));
              }),
              children: [
                for (final (i, s) in steps.indexed)
                  OmniStepRow(key: ValueKey(s), text: s, reorderIndex: i),
              ],
            ),
          ),
        ),
      );
      final handle = find.descendant(
        of: find.byKey(const ValueKey('TV on')),
        matching: find.byIcon(OmniIcons.drag),
      );
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 140));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(steps.first, 'Wait 3 s');
    });
  });

  testWidgets('banners say their kind and act', (tester) async {
    var acted = 0;
    var closed = 0;
    await pumpDesign(
      tester,
      Column(
        children: [
          const OmniBanner.info('Nothing was sent.'),
          OmniBanner.warning(
            'Claude made "Movie night". Review before it can run.',
            actionLabel: 'Review',
            onAction: () => acted++,
          ),
          OmniBanner.error(
            'Not answering since 18:20.',
            onClose: () => closed++,
          ),
        ],
      ),
    );
    expect(find.byIcon(OmniIcons.warning), findsOneWidget);
    expect(find.byIcon(OmniIcons.error), findsOneWidget);
    await tester.tap(find.text('Review'));
    await tester.tap(find.byTooltip('Dismiss'));
    expect((acted, closed), (1, 1));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  });

  testWidgets('the power button is a named toggle', (tester) async {
    var on = false;
    await pumpDesign(
      tester,
      StatefulBuilder(
        builder: (context, setState) => OmniPowerButton(
          on: on,
          label: 'Desk lamp power',
          onPressed: () => setState(() => on = !on),
        ),
      ),
    );
    await tester.tap(find.byType(OmniPowerButton));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byType(OmniPowerButton)),
      matchesSemantics(
        label: 'Desk lamp power',
        isButton: true,
        hasToggledState: true,
        isToggled: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
  });

  testWidgets('cards, hero, section header and empty state lay out', (
    tester,
  ) async {
    var edits = 0;
    await pumpDesign(
      tester,
      SingleChildScrollView(
        child: Column(
          children: [
            OmniSectionHeader(
              'Scenes',
              actionLabel: 'Edit',
              onAction: () => edits++,
            ),
            const OmniSectionHeader('Found nearby', trailingText: '3'),
            const OmniHeroCard(
              title: 'On · 80%',
              subtitle: 'Warm white · Living room',
              footer: 'Last 24 h · low 21.0 · high 29.5',
            ),
            OmniCard(
              title: 'Arrive home',
              trailing: Switch(value: true, onChanged: (_) {}),
              child: const Text('Ran today 19:02 · 3 steps'),
            ),
            const OmniEmptyState(
              icon: OmniIcons.search,
              title: 'Nothing added yet',
              message: 'We looked on HomeWiFi and found 3 things.',
            ),
            const OmniStepBar(count: 3, current: 2),
            const OmniProgressBar(value: 0.64, semanticLabel: 'Uploading'),
          ],
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    expect(edits, 1);
    expect(find.bySemanticsLabel('Step 2 of 3'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Uploading')),
      matchesSemantics(label: 'Uploading', value: '64%'),
    );
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  });

  group('sheet', () {
    testWidgets('opens over everything with its title and grab handle', (
      tester,
    ) async {
      await pumpDesign(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showOmniSheet<void>(
              context,
              builder: (_) => OmniSheet(
                title: 'Desk lamp',
                subtitle: 'Philips WiZ · Living room',
                trailing: Switch(value: true, onChanged: (_) {}),
                children: [
                  OmniButton.ghost(label: 'Open device', onPressed: () {}),
                ],
              ),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Desk lamp'), findsOneWidget);
      expect(find.text('Open device'), findsOneWidget);
    });

    testWidgets('appears at once under reduced motion', (tester) async {
      await pumpDesign(
        tester,
        reducedMotion: true,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showOmniSheet<void>(
              context,
              builder: (_) => const OmniSheet(title: 'Quick', children: []),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      final shown = tester.getRect(find.text('Quick'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('Quick')), shown);
    });
  });

  testWidgets('buttons have 48 dp targets and the danger one is red', (
    tester,
  ) async {
    await pumpDesign(
      tester,
      Column(
        children: [
          OmniButton(label: 'Approve', onPressed: () {}),
          OmniButton.ghost(label: 'Test run', onPressed: () {}),
          OmniButton.danger(label: 'Reject', onPressed: () {}),
          Row(
            children: [
              OmniIconAction(
                icon: OmniIcons.star,
                label: 'Favourite',
                selected: true,
                onPressed: () {},
              ),
            ],
          ),
        ],
      ),
    );
    final reject = tester.widget<Text>(find.text('Reject'));
    expect(
      DefaultTextStyle.of(tester.element(find.text('Reject'))).style.color ??
          reject.style?.color,
      OmniColors.bad,
    );
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  });

  test('device icons come from the manifest, the category, then the types', () {
    expect(OmniIcons.forDevice({'icon': 'tv'}), OmniIcons.tv);
    expect(OmniIcons.forDevice({'category': 'lighting'}), OmniIcons.light);
    expect(
      OmniIcons.forDevice({
        'capabilities': [
          {'type': 'toggle'},
          {'type': 'level'},
        ],
      }),
      OmniIcons.light,
    );
    expect(
      OmniIcons.forDevice({
        'capabilities': [
          {'type': 'toggle'},
        ],
      }),
      OmniIcons.plug,
    );
    expect(OmniIcons.forDevice(const {}), OmniIcons.device);
  });
}
