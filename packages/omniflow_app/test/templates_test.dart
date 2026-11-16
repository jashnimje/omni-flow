import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/theme.dart';

Future<void> pumpPage(
  WidgetTester tester,
  Widget page, {
  OmniPalette palette = OmniPalette.teal,
  double textScale = 1,
  Size size = const Size(412, 860),
  EdgeInsets systemBars = EdgeInsets.zero,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = FakeViewPadding(
    top: systemBars.top,
    bottom: systemBars.bottom,
  );
  tester.view.viewPadding = FakeViewPadding(
    top: systemBars.top,
    bottom: systemBars.bottom,
  );
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: omniTheme(palette: palette),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

const _empty = OmniEmptyState(icon: OmniIcons.info, title: 'Nothing yet');
const _longTitle = 'The living room lamp by the window seat';

List<Widget> _rows(BuildContext context) => const [
  OmniSectionHeader('Lights in the living room'),
  OmniListRow(
    title: 'A long row title that has to wrap at large text sizes',
    subtitle: 'And a subtitle under it',
    value: '80%',
  ),
  Text('Data row'),
];

/// One template under test: how to build it for a state, which skeleton
/// it shows while loading and what its empty state says.
typedef _Case = ({
  String name,
  Widget Function(OmniLoad state) build,
  Type skeleton,
  String emptyText,
});

final List<_Case> _cases = [
  (
    name: 'TabPage',
    build: (s) => TabPage(
      title: _longTitle,
      subtitle: 'Two things need you',
      state: s,
      empty: _empty,
      children: _rows,
    ),
    skeleton: OmniListSkeleton,
    emptyText: 'Nothing yet',
  ),
  (
    name: 'TabPage tiles',
    build: (s) => TabPage(
      title: 'Home',
      state: s,
      skeleton: OmniSkeleton.tiles,
      empty: _empty,
      children: _rows,
    ),
    skeleton: OmniTileGridSkeleton,
    emptyText: 'Nothing yet',
  ),
  (
    name: 'ListPage',
    build: (s) => ListPage(
      title: _longTitle,
      state: s,
      empty: _empty,
      search: const TextField(),
      children: _rows,
    ),
    skeleton: OmniListSkeleton,
    emptyText: 'Nothing yet',
  ),
  (
    name: 'ListPage.builder',
    build: (s) => ListPage.builder(
      title: 'Scenes',
      state: s,
      empty: _empty,
      itemCount: 3,
      itemBuilder: (context, i) => _rows(context)[i],
    ),
    skeleton: OmniListSkeleton,
    emptyText: 'Nothing yet',
  ),
  (
    name: 'DetailPage',
    build: (s) => DetailPage(
      title: _longTitle,
      state: s,
      hero: const OmniHeroCard(title: 'On', subtitle: '80% warm'),
      children: _rows,
    ),
    skeleton: OmniPageSkeleton,
    emptyText: 'This is not here any more',
  ),
  (
    name: 'FormPage',
    build: (s) => FormPage(
      title: _longTitle,
      state: s,
      onCommit: () {},
      secondaryLabel: 'Test it first',
      onSecondary: () {},
      children: _rows,
    ),
    skeleton: OmniPageSkeleton,
    emptyText: 'Nothing here yet',
  ),
  (
    name: 'EditorPage',
    build: (s) => EditorPage(
      title: _longTitle,
      state: s,
      empty: _empty,
      onPrimary: () {},
      secondaryLabel: 'Test run',
      onSecondary: () {},
      views: OmniSegmented<int>(
        segments: const [OmniSegment(0, 'Sentence'), OmniSegment(1, 'Diagram')],
        selected: 0,
        onChanged: (_) {},
      ),
      children: _rows,
    ),
    skeleton: OmniPageSkeleton,
    emptyText: 'Nothing yet',
  ),
  (
    name: 'SheetTemplate',
    build: (s) => Scaffold(
      body: SheetTemplate(
        title: _longTitle,
        state: s,
        empty: _empty,
        primaryLabel: 'Save it',
        onPrimary: () {},
        secondaryLabel: 'Not now',
        onSecondary: () {},
        children: _rows,
      ),
    ),
    skeleton: OmniListSkeleton,
    emptyText: 'Nothing yet',
  ),
  (
    name: 'PickerSheet',
    build: (s) => Scaffold(
      body: PickerSheet<String>(
        title: _longTitle,
        state: s,
        sections: s.isEmpty
            ? const []
            : const [
                PickerSection([
                  PickerItem(value: 'a', title: 'Data row'),
                ], title: 'Suggestions'),
              ],
      ),
    ),
    skeleton: OmniListSkeleton,
    emptyText: 'Nothing here yet',
  ),
  (
    name: 'StepFlow',
    build: (s) => StepFlow(
      title: _longTitle,
      count: 3,
      current: 2,
      heading: 'Find the hub on your network',
      why: 'The phone and the hub need the same Wi-Fi.',
      state: s,
      onPrimary: () {},
      onSkip: () {},
      onBack: () {},
      children: _rows,
    ),
    skeleton: OmniListSkeleton,
    emptyText: 'Nothing here yet',
  ),
];

void main() {
  group('OmniLoad', () {
    test('reads an AsyncValue', () {
      expect(OmniLoad.of(const AsyncLoading<int>()).isLoading, isTrue);
      expect(OmniLoad.of(const AsyncData(3)).isData, isTrue);
      expect(
        OmniLoad.of(
          const AsyncData(<int>[]),
          isEmpty: (v) => v.isEmpty,
        ).isEmpty,
        isTrue,
      );
      final error = OmniLoad.of(
        AsyncError<int>(StateError('raw'), StackTrace.empty),
        error: 'The rooms did not load.',
      );
      expect(error.isError, isTrue);
      expect(error.message, 'The rooms did not load.');
    });

    test('reads flags, error first', () {
      expect(OmniLoad.flags(loading: true, error: 'x').isError, isTrue);
      expect(OmniLoad.flags(loading: true, isEmpty: true).isLoading, isTrue);
      expect(OmniLoad.flags(isEmpty: true).isEmpty, isTrue);
      expect(OmniLoad.flags().isData, isTrue);
    });
  });

  for (final c in _cases) {
    group(c.name, () {
      testWidgets('loading shows the shared skeleton', (tester) async {
        await pumpPage(tester, c.build(const OmniLoad.loading()));
        expect(find.byType(c.skeleton), findsOneWidget);
        expect(find.text('Data row'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      });

      testWidgets('error shows what happened and Try again', (tester) async {
        var retries = 0;
        await pumpPage(
          tester,
          c.build(OmniLoad.error('The list did not load.', () => retries++)),
        );
        expect(find.text('The list did not load.'), findsOneWidget);
        expect(find.text('Data row'), findsNothing);
        await tester.tap(find.text('Try again'));
        expect(retries, 1);
      });

      testWidgets('empty shows the shared empty state', (tester) async {
        await pumpPage(tester, c.build(const OmniLoad.empty()));
        expect(find.text(c.emptyText), findsOneWidget);
        expect(find.text('Data row'), findsNothing);
      });

      testWidgets('data shows the screen rows', (tester) async {
        await pumpPage(tester, c.build(const OmniLoad.data()));
        expect(find.text('Data row'), findsOneWidget);
        expect(find.byType(OmniListSkeleton), findsNothing);
      });

      testWidgets('text at 200% does not overflow', (tester) async {
        await pumpPage(
          tester,
          c.build(const OmniLoad.data(error: 'It did not refresh.')),
          textScale: 2,
          size: const Size(360, 740),
        );
        expect(tester.takeException(), isNull);
        await pumpPage(
          tester,
          c.build(OmniLoad.error('The list did not load.', () {})),
          textScale: 2,
          size: const Size(360, 740),
        );
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('a failed refresh keeps the data under the error banner', (
    tester,
  ) async {
    var retries = 0;
    await pumpPage(
      tester,
      ListPage(
        title: 'Scenes',
        state: OmniLoad.data(
          error: 'The scenes did not refresh.',
          onRetry: () => retries++,
        ),
        children: _rows,
      ),
    );
    expect(find.text('The scenes did not refresh.'), findsOneWidget);
    expect(find.text('Data row'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('the sheet keeps its last button above a 48 dp system bar', (
    tester,
  ) async {
    await pumpPage(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => SheetTemplate.show<void>(
              context,
              builder: (_) => SheetTemplate(
                title: 'Name it',
                primaryLabel: 'Save',
                onPrimary: () {},
                children: (_) => [for (var i = 0; i < 3; i++) Text('Row $i')],
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
      size: const Size(412, 860),
      systemBars: const EdgeInsets.only(top: 24, bottom: 48),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final save = tester.getRect(find.byKey(const ValueKey('template-primary')));
    expect(save.bottom, lessThanOrEqualTo(860 - 48 - OmniSpace.lg));
  });

  testWidgets('an OmniSheet without actions ends above the system bar', (
    tester,
  ) async {
    await pumpPage(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOmniSheet<void>(
              context,
              builder: (_) => OmniSheet(
                title: 'Pair it',
                children: [
                  OmniButton(
                    key: const ValueKey('last'),
                    label: 'Pair',
                    onPressed: () {},
                  ),
                ],
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
      systemBars: const EdgeInsets.only(bottom: 48),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final last = tester.getRect(find.byKey(const ValueKey('last')));
    expect(last.bottom, lessThanOrEqualTo(860 - 48 - OmniSpace.lg + 0.5));
  });

  testWidgets('the last row of a tab clears the floating button', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await pumpPage(
      tester,
      Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          key: const ValueKey('fab'),
          onPressed: () {},
          icon: const Icon(OmniIcons.add),
          label: const Text('Add'),
        ),
        body: TabPage(
          title: 'Devices',
          controller: scroll,
          children: (_) => [
            for (var i = 0; i < 30; i++)
              SizedBox(
                key: ValueKey('row-$i'),
                height: 56,
                child: Text('Row $i'),
              ),
          ],
        ),
      ),
      systemBars: const EdgeInsets.only(bottom: 48),
    );
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final last = tester.getRect(find.byKey(const ValueKey('row-29')));
    final fab = tester.getRect(find.byKey(const ValueKey('fab')));
    expect(last.bottom, lessThanOrEqualTo(fab.top));
  });

  group('confirm', () {
    Future<void> open(WidgetTester tester, {required bool destructive}) async {
      await pumpPage(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => confirm(
                context,
                title: 'Remove the lamp?',
                body: 'Its history is deleted.',
                action: 'Remove',
                destructive: destructive,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    Color? fill(WidgetTester tester) => tester
        .widget<FilledButton>(
          find.descendant(
            of: find.byKey(const ValueKey('confirm')),
            matching: find.byWidgetPredicate((w) => w is FilledButton),
          ),
        )
        .style
        ?.backgroundColor
        ?.resolve({});

    testWidgets('a destructive confirm fills its action red', (tester) async {
      await open(tester, destructive: true);
      expect(fill(tester), OmniColors.bad);
    });

    testWidgets('a plain confirm uses the accent', (tester) async {
      await open(tester, destructive: false);
      expect(fill(tester), OmniColors.accent);
    });
  });

  testWidgets('components follow a non-teal palette', (tester) async {
    final palette = OmniPalette.teal
        .withScheme(
          ColorScheme.fromSeed(
            seedColor: const Color(0xFF8E24AA),
            brightness: Brightness.dark,
          ),
        )
        .pureBlack();
    expect(palette.accent, isNot(OmniColors.accent));
    expect(palette.line, isNot(OmniColors.line));
    await pumpPage(
      tester,
      Scaffold(
        body: Column(
          children: [
            OmniButton(
              key: const ValueKey('primary'),
              label: 'Save',
              onPressed: () {},
            ),
            const OmniListRow(title: 'Lamp', value: '80%'),
            const StatusDot(StatusKind.online),
            OmniFilterChip(label: 'All', selected: true, onTap: () {}),
            const OmniSheetHandle(),
          ],
        ),
      ),
      palette: palette,
    );
    final button = tester.widget<FilledButton>(
      find.descendant(
        of: find.byKey(const ValueKey('primary')),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    expect(button.style?.backgroundColor?.resolve({}), palette.accent);
    expect(button.style?.foregroundColor?.resolve({}), palette.onAccent);
    expect(tester.widget<Text>(find.text('80%')).style?.color, palette.accent);
    final dot = tester.widget<Container>(
      find.descendant(
        of: find.byType(StatusDot),
        matching: find.byType(Container),
      ),
    );
    expect((dot.decoration! as BoxDecoration).color, palette.accent);
    final handle = tester.widget<Container>(
      find.byKey(const ValueKey('omni-sheet-handle')),
    );
    expect((handle.decoration! as BoxDecoration).color, palette.line);
    final chip = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(OmniFilterChip),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect((chip.decoration! as BoxDecoration).color, palette.accent);
  });

  group('FormPage', () {
    testWidgets('says what is missing while Save is off', (tester) async {
      await pumpPage(
        tester,
        FormPage(
          title: 'New scene',
          onCommit: null,
          missing: 'Give it a name first.',
          children: _rows,
        ),
      );
      expect(find.text('Give it a name first.'), findsOneWidget);
      final save = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(const ValueKey('template-primary')),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('asks before discarding changes', (tester) async {
      var discarded = 0;
      await pumpPage(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FormPage(
                    title: 'New scene',
                    onCommit: () {},
                    dirty: true,
                    discardWhat: 'this scene',
                    onDiscard: () => discarded++,
                    children: _rows,
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm')));
      await tester.pumpAndSettle();
      expect(discarded, 1);
      expect(find.text('New scene'), findsNothing);
      expect(find.text('Open'), findsOneWidget);
    });

    testWidgets('the instant variant has no bottom bar', (tester) async {
      await pumpPage(
        tester,
        FormPage.instant(title: 'Appearance', children: _rows),
      );
      expect(find.byType(OmniActionBar), findsNothing);
      expect(find.text('Data row'), findsOneWidget);
    });
  });

  testWidgets('StepFlow shows the step bar and its three actions', (
    tester,
  ) async {
    final taps = <String>[];
    await pumpPage(
      tester,
      StepFlow(
        title: 'Set up the hub',
        count: 3,
        current: 2,
        heading: 'Find the hub',
        onPrimary: () => taps.add('next'),
        onSkip: () => taps.add('skip'),
        onBack: () => taps.add('back'),
        onHelp: () => taps.add('help'),
        children: _rows,
      ),
    );
    expect(find.bySemanticsLabel('Step 2 of 3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('step-primary')));
    await tester.tap(find.byKey(const ValueKey('step-skip')));
    await tester.tap(find.byKey(const ValueKey('step-back')));
    await tester.tap(find.byKey(const ValueKey('step-help')));
    expect(taps, ['next', 'skip', 'back', 'help']);
  });

  group('PickerSheet', () {
    final sections = [
      PickerSection([
        for (var i = 0; i < 10; i++)
          PickerItem(
            value: 'room$i',
            title: 'Room $i',
            key: ValueKey('room$i'),
          ),
      ], title: 'Rooms'),
    ];

    testWidgets('searches past eight choices and returns the pick', (
      tester,
    ) async {
      String? picked;
      await pumpPage(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await showPickerSheet<String>(
                context,
                title: 'Room',
                sections: sections,
                selected: 'room1',
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('room1')),
          matching: find.byKey(const ValueKey('picker-chosen')),
        ),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const ValueKey('picker-search')), '7');
      await tester.pumpAndSettle();
      expect(find.text('Room 1'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('room7')));
      await tester.pumpAndSettle();
      expect(picked, 'room7');
    });

    testWidgets('says when nothing matches', (tester) async {
      await pumpPage(
        tester,
        Scaffold(
          body: PickerSheet<String>(title: 'Room', sections: sections),
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('picker-search')), 'zz');
      await tester.pumpAndSettle();
      expect(find.text('Nothing matches'), findsOneWidget);
    });

    testWidgets('has no search for a short list', (tester) async {
      await pumpPage(
        tester,
        Scaffold(
          body: PickerSheet<String>(
            title: 'Mode',
            sections: const [
              PickerSection([PickerItem(value: 'home', title: 'Home')]),
            ],
          ),
        ),
      );
      expect(find.byKey(const ValueKey('picker-search')), findsNothing);
    });
  });

  testWidgets('PromptSheet returns the trimmed text and checks it', (
    tester,
  ) async {
    String? name;
    await pumpPage(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => name = await showPromptSheet(
              context,
              title: 'Rename the room',
              label: 'Name',
              initial: 'Den',
              validate: (t) => t == 'Kitchen' ? 'That name is taken.' : null,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('prompt-field')),
      'Kitchen',
    );
    await tester.pump();
    expect(find.text('That name is taken.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('prompt-field')),
      '  Study  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('prompt-save')));
    await tester.pumpAndSettle();
    expect(name, 'Study');
  });
}
