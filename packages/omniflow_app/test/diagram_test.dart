import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/diagram_calls.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_app/ui/automations/sentence_row.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/diagram/diagram.dart';

import 'automations_fixtures.dart';
import 'diagram_fixtures.dart';
import 'fake_engine.dart';
import 'screen_harness.dart';

Diagram _diagram([Map<String, Object?>? reply]) =>
    Diagram.fromJson(reply ?? everyPartDiagram());

/// The index of the edge from [from] to [to] in the fixture.
int _edge(String from, String to) {
  final edges = everyPartDiagram()['edges'] as List;
  return edges.indexWhere((e) => e['from'] == from && e['to'] == to);
}

DiagramNode _node(WidgetTester tester, String id) => tester
    .widget<DiagramNodeCard>(find.byKey(ValueKey('diagram-node-$id')))
    .node;

DiagramPainter _painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find
                  .descendant(
                    of: find.byKey(const ValueKey('diagram-canvas')),
                    matching: find.byType(CustomPaint),
                  )
                  .first,
            )
            .painter!
        as DiagramPainter;

/// The spec the last `automation.diagram` call drew.
Map<String, Object?> _drawnSpec(FakeEngine engine) => Map<String, Object?>.from(
  engine.callsOf(DiagramCalls.diagram).last.$2['spec'] as Map,
);

Future<void> _openEditor(
  WidgetTester tester,
  FakeEngine engine, {
  RuleView view = RuleView.diagram,
  MemoryRuleViewStore? store,
}) async {
  engine.answers[DiagramCalls.diagram] = everyPartDiagram();
  await pumpScreen(
    tester,
    engine,
    RuleEditorPage(initial: everyPartSpec()),
    overrides: [
      ruleViewStoreProvider.overrideWithValue(
        store ?? MemoryRuleViewStore(view),
      ),
    ],
  );
}

/// Lets the debounced re-fetch after an edit go out and come back.
Future<void> _refetch(WidgetTester tester) async {
  await tester.pump(diagramRefetchDelay + const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

void main() {
  test('a dry run handed to the diagram keeps what each check saw', () {
    final run = RunRecord.fromJson({
      'run': 'r1',
      'flow': 'warm',
      'outcome': 'completed',
      'startedAt': '2026-11-13T10:00:00Z',
      'dryRun': true,
      'nodes': [
        {'node': 'if_0', 'type': 'state_compare', 'port': 'true', 'seen': 31},
        {'node': 'then_0', 'type': 'device_capability'},
      ],
    });
    final nodes = DiagramCalls.traceOf(run)['nodes'] as List;
    expect((nodes.first as Map)['seen'], 31);
    expect((nodes.last as Map).containsKey('seen'), isFalse);
  });

  group('layout', () {
    late Diagram d;
    late DiagramLayout l;

    setUp(() {
      d = _diagram();
      l = DiagramLayout.of(d);
    });

    Rect r(String id) => l.nodes[id]!;

    test('places every node, none overlapping, all on the canvas', () {
      for (final n in d.nodes) {
        expect(l.nodes, contains(n.id), reason: n.id);
      }
      final rects = l.nodes.entries.toList();
      for (var i = 0; i < rects.length; i++) {
        final a = rects[i].value;
        expect(a.left, greaterThanOrEqualTo(0));
        expect(a.top, greaterThanOrEqualTo(0));
        expect(a.right, lessThanOrEqualTo(l.size.width));
        expect(a.bottom, lessThanOrEqualTo(l.size.height));
        for (var j = i + 1; j < rects.length; j++) {
          final b = rects[j].value;
          expect(
            a.overlaps(b),
            isFalse,
            reason: '${rects[i].key} overlaps ${rects[j].key}',
          );
        }
      }
    });

    test('triggers side by side at the top, joined into one line', () {
      expect(r('/when/0').top, r('/when/1').top);
      expect(r('/when/1').left, greaterThan(r('/when/0').right));
      for (final n in d.nodes.where((n) => n.kind != NodeKind.trigger)) {
        expect(r(n.id).top, greaterThan(r('/when/0').bottom), reason: n.id);
      }
    });

    test('yes goes down, no goes right', () {
      // The onlyIf check: on down to the steps, out right to Stops here.
      expect(r('/then/0').top, greaterThan(r('/onlyIf/0').bottom));
      expect(r('/then/0').center.dx, r('/onlyIf/0').center.dx);
      expect(r('/onlyIf/0#end').left, greaterThan(r('/onlyIf/0').right));
      // The If: yes below it on its line, otherwise to its right.
      expect(r('/then/1/then/0').top, greaterThan(r('/then/1').bottom));
      expect(r('/then/1/then/0').center.dx, r('/then/1').center.dx);
      expect(r('/then/1/else/0').left, greaterThan(r('/then/1').right));
      // The branches join again below both.
      expect(r('/then/1#merge').top, greaterThan(r('/then/1/else/0').bottom));
    });

    test('groups contain their nodes and hold nothing else', () {
      for (final g in d.nodes.where((n) => n.kind == NodeKind.group)) {
        final box = l.groups[g.id]!;
        expect(box.contains(r(g.id).center), isTrue, reason: g.id);
        for (final c in g.children) {
          final rc = r(c);
          expect(
            box.contains(rc.topLeft) && box.contains(rc.bottomRight),
            isTrue,
            reason: '$c in ${g.id}',
          );
        }
        for (final n in d.nodes) {
          if (n.id == g.id || g.children.contains(n.id)) continue;
          expect(box.overlaps(r(n.id)), isFalse, reason: '${n.id} in ${g.id}');
        }
      }
    });

    test('together side by side, the try fallback beside its box', () {
      final a = r('/then/2/together/0/0');
      final b = r('/then/2/together/1/0');
      expect(a.top, b.top);
      expect(b.left, greaterThan(a.right));
      expect(r('/then/2/together/1/1').top, greaterThan(b.bottom));
      expect(
        r('/then/3/otherwise/0').left,
        greaterThan(l.groups['/then/3']!.right),
      );
      // The ask's answer with steps sits under it.
      expect(r('/then/7/then/0').top, greaterThan(r('/then/6').bottom));
    });

    test('the same diagram lays out the same way every time', () {
      final again = DiagramLayout.of(_diagram());
      expect(again.size, l.size);
      expect(again.nodes, l.nodes);
      expect(again.order, l.order);
      expect(l.order.take(3), ['/when/0', '/when/1', '/onlyIf/0']);
    });
  });

  testWidgets('fits a 360 dp phone: readable, nothing overflows, wide '
      'graphs scroll sideways', (tester) async {
    final engine = FakeEngine();
    await pumpScreen(
      tester,
      engine,
      Scaffold(body: DiagramViewer(diagram: _diagram())),
      size: const Size(1080, 1920),
    );
    expect(tester.takeException(), isNull);
    final viewer = tester.state<DiagramViewerState>(find.byType(DiagramViewer));
    expect(viewer.scale, greaterThanOrEqualTo(DiagramViewer.minFitScale));
    expect(viewer.scale, lessThanOrEqualTo(1));
    final fits = viewer.layout.size.width * viewer.scale <= 360 + 0.5;
    expect(
      fits || (viewer.scale - DiagramViewer.minFitScale).abs() < 1e-6,
      isTrue,
      reason: 'width ${viewer.layout.size.width} at ${viewer.scale}',
    );
    final card = tester.getRect(
      find.byKey(const ValueKey('diagram-node-/then/0')),
    );
    expect(card.width, closeTo(DiagramMetrics.cardWidth * viewer.scale, 0.5));
    // Fit shows it all.
    await tester.tap(find.byKey(const ValueKey('diagram-fit')));
    await tester.pumpAndSettle();
    expect(viewer.scale, lessThan(DiagramViewer.minFitScale));
  });

  group('editing', () {
    late FakeEngine engine;

    setUp(() => engine = automationsEngine());

    testWidgets('the view switch keeps the rule, and is remembered', (
      tester,
    ) async {
      final store = MemoryRuleViewStore();
      await _openEditor(tester, engine, store: store);
      expect(find.byKey(const ValueKey('rule-editor')), findsOneWidget);
      expect(find.byKey(const ValueKey('row-then[0]')), findsOneWidget);

      await tester.tap(find.text('Diagram'));
      await tester.pumpAndSettle();
      expect(store.view, RuleView.diagram);
      expect(find.byKey(const ValueKey('diagram-editor')), findsOneWidget);
      expect(_drawnSpec(engine), {'name': 'Every part', ...everyPartSpec()});
      expect(
        find.byKey(const ValueKey('diagram-node-/then/0')),
        findsOneWidget,
      );

      await tester.tap(find.text('Sentence'));
      await tester.pumpAndSettle();
      expect(store.view, RuleView.sentence);
      expect(find.byKey(const ValueKey('row-then[0]')), findsOneWidget);
      expect(find.byKey(const ValueKey('row-when[1]')), findsOneWidget);
    });

    testWidgets('a tap opens the picker of a trigger, a check and a step', (
      tester,
    ) async {
      await _openEditor(tester, engine);
      await tester.tap(find.byKey(const ValueKey('diagram-node-/when/1')));
      await tester.pumpAndSettle();
      // The time trigger's form, as its sentence row opens it.
      expect(find.byKey(const ValueKey('form-done')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('form-done')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('diagram-node-/onlyIf/0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('opt-above-temp')), findsOneWidget);
      expect(find.byKey(const ValueKey('form-done')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('diagram-node-/then/0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('act-on-power')), findsOneWidget);
    });

    testWidgets('an If with one condition opens that condition', (
      tester,
    ) async {
      await _openEditor(tester, engine);
      await tester.tap(find.byKey(const ValueKey('diagram-node-/then/1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('opt-on-state')), findsOneWidget);
      expect(find.byKey(const ValueKey('form-done')), findsOneWidget);
    });

    testWidgets('"+" on a line adds there, and the diagram is drawn again '
        'from the unsaved rule', (tester) async {
      await _openEditor(tester, engine);
      final asked = engine.callsOf(DiagramCalls.diagram).length;
      await tester.tap(
        find.byKey(ValueKey('diagram-plus-${_edge('/then/0', '/then/1')}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pick-wait')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('form-done')));
      await _refetch(tester);
      expect(engine.callsOf(DiagramCalls.diagram).length, asked + 1);
      final then = _drawnSpec(engine)['then'] as List;
      expect(then, hasLength(9));
      expect(then[1], {'wait': 3000});
      expect((then[2] as Map).containsKey('if'), isTrue);

      // The same rule in the sentence view.
      await tester.tap(find.text('Sentence'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SentenceRow>(find.byKey(const ValueKey('row-then[1]')))
            .text,
        'Wait 3 s',
      );
    });

    testWidgets('a "+" inside a branch adds to that branch', (tester) async {
      await _openEditor(tester, engine);
      await tester.tap(
        find.byKey(
          ValueKey('diagram-plus-${_edge('/then/1', '/then/1/else/0')}'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pick-wait')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('form-done')));
      await _refetch(tester);
      final ifStep = (_drawnSpec(engine)['then'] as List)[1] as Map;
      expect(ifStep['else'], [
        {'wait': 3000},
        {
          'notify': {'title': 'Lamp is off'},
        },
      ]);
    });

    testWidgets('long press removes, and Undo puts it back in either view', (
      tester,
    ) async {
      await _openEditor(tester, engine);
      await tester.longPress(
        find.byKey(const ValueKey('diagram-node-/then/0')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('diagram-move-down')), findsOneWidget);
      expect(find.byKey(const ValueKey('diagram-move-up')), findsNothing);
      expect(find.byKey(const ValueKey('diagram-copy')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('diagram-remove')));
      await _refetch(tester);
      var then = _drawnSpec(engine)['then'] as List;
      expect(then, hasLength(7));
      expect((then.first as Map).containsKey('if'), isTrue);
      expect(find.text('Step removed'), findsOneWidget);

      await tester.tap(find.text('Sentence'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SentenceRow>(find.byKey(const ValueKey('row-then[0]')))
            .text,
        'Desk lamp · power on',
      );
      await tester.tap(find.text('Diagram'));
      await _refetch(tester);
      then = _drawnSpec(engine)['then'] as List;
      expect(then, hasLength(8));
      expect(then.first, {
        'do': 'desk_lamp.power',
        'params': {'value': true},
      });
    });

    testWidgets('move down and copy go through the same rule', (tester) async {
      await _openEditor(tester, engine);
      await tester.longPress(
        find.byKey(const ValueKey('diagram-node-/then/0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('diagram-copy')));
      await _refetch(tester);
      final then = _drawnSpec(engine)['then'] as List;
      expect(then, hasLength(9));
      expect(then[1], then[0]);
    });

    testWidgets('nodes read in order with their words and kind, and the '
        'list shows the same', (tester) async {
      final handle = tester.ensureSemantics();
      await _openEditor(tester, engine);
      expect(
        find.bySemanticsLabel(RegExp(r'^room temp temp is above 28, Check$')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^desk lamp power on, Step$')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('diagram-as-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('diagram-list')), findsOneWidget);
      final rows = tester
          .widgetList<Widget>(
            find.byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('diagram-row-'),
            ),
          )
          .map((w) => (w.key! as ValueKey<String>).value)
          .take(4)
          .toList();
      expect(rows, [
        'diagram-row-/when/0',
        'diagram-row-/when/1',
        'diagram-row-/onlyIf/0',
        'diagram-row-/then/0',
      ]);
      // A row does what a tap on the node does.
      await tester.tap(find.byKey(const ValueKey('diagram-row-/then/0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('act-on-power')), findsOneWidget);
      handle.dispose();
    });
  });

  group('runs', () {
    late FakeEngine engine;

    setUp(() {
      engine = FakeEngine();
      engine.answerers[DiagramCalls.diagram] = (args) => switch (args) {
        {'last': true} => everyPartRun(),
        _ => everyPartDiagram(),
      };
    });

    Future<void> pumpLastRun(WidgetTester tester, {bool reduced = false}) =>
        pumpScreen(
          tester,
          engine,
          Scaffold(
            body: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduced),
                child: ListView(
                  children: const [LastRunSection(id: 'every_part')],
                ),
              ),
            ),
          ),
        );

    testWidgets('the last run lights its path, its statuses and what each '
        'check saw', (tester) async {
      await pumpLastRun(tester);
      expect(engine.callsOf(DiagramCalls.diagram).first.$2, {
        'id': 'every_part',
        'last': true,
        'skipsToo': true,
      });
      expect(find.byKey(const ValueKey('last-run-diagram')), findsOneWidget);
      expect(find.textContaining('Ran '), findsOneWidget);
      expect(_node(tester, '/when/0').status, NodeStatus.ran);
      expect(_node(tester, '/when/1').status, NodeStatus.skipped);
      expect(_node(tester, '/then/1/then/0').status, NodeStatus.skipped);
      expect(_node(tester, '/then/3/try/0').status, NodeStatus.failed);
      expect(find.text('Saw 31'), findsOneWidget);
      final painter = _painter(tester);
      expect(painter.isSolid(_edge('/then/1', '/then/1/else/0')), isTrue);
      expect(painter.isSolid(_edge('/then/1', '/then/1/then/0')), isFalse);
      expect(painter.isSolid(_edge('/onlyIf/0', '/onlyIf/0#end')), isFalse);
    });

    testWidgets('a stopped trigger marks the check that said no', (
      tester,
    ) async {
      engine.answerers[DiagramCalls.diagram] = (_) => everyPartSkip();
      await pumpLastRun(tester);
      expect(find.textContaining('Stopped '), findsOneWidget);
      final check = _node(tester, '/onlyIf/0');
      expect(check.saidNo, isTrue);
      expect(check.seen, '24');
      expect(_node(tester, '/then/0').status, NodeStatus.skipped);
      expect(
        _painter(tester).isSolid(_edge('/onlyIf/0', '/onlyIf/0#end')),
        isTrue,
      );
    });

    testWidgets('a live run lights node by node', (tester) async {
      engine.answerers[DiagramCalls.diagram] = (args) => switch (args) {
        {'last': true} => {'ok': false, 'error': 'not_found'},
        _ => everyPartDiagram(),
      };
      await pumpLastRun(tester);
      expect(find.byKey(const ValueKey('last-run')), findsNothing);
      void send(String node, String status, {String? path, Object? seen}) =>
          engine.eventsOut.add({
            'event': 'run.node',
            'run': 'r2',
            'flow': 'every_part',
            'node': node,
            'path': ?path,
            'status': status,
            'port': ?(status == 'ran'
                ? (node == 'only_if' ? 'true' : 'out')
                : null),
            'seen': ?seen,
          });
      send('when_0', 'ran');
      send('only_if', 'ran', seen: 30);
      send('then_0', 'waiting', path: '/then/0');
      await tester.pump();
      await tester.pump(liveStep);
      expect(find.text('Running now'), findsWidgets);
      expect(_node(tester, '/when/0').status, NodeStatus.ran);
      expect(_node(tester, '/onlyIf/0').status, isNull);
      await tester.pump(liveStep);
      expect(_node(tester, '/onlyIf/0').status, NodeStatus.ran);
      expect(_node(tester, '/then/0').status, isNull);
      await tester.pump(liveStep);
      expect(_node(tester, '/then/0').status, NodeStatus.waiting);
      expect(_painter(tester).isSolid(_edge('/onlyIf/0', '/then/0')), isTrue);
      expect(
        _painter(tester).isSolid(_edge('/onlyIf/0', '/onlyIf/0#end')),
        isFalse,
      );
      // When it finishes, the last run is asked for again.
      final asked = engine.callsOf(DiagramCalls.diagram).length;
      engine.answerers[DiagramCalls.diagram] = (_) => everyPartRun();
      engine.eventsOut.add({
        'event': 'run.finished',
        'flow': 'every_part',
        'run': 'r2',
        'outcome': 'completed',
      });
      await tester.pump(liveStep);
      await tester.pump(liveStep);
      await tester.pumpAndSettle();
      expect(engine.callsOf(DiagramCalls.diagram).length, greaterThan(asked));
      expect(find.text('Last run'), findsOneWidget);
    });

    testWidgets('under reduced motion a live run shows at once', (
      tester,
    ) async {
      engine.answerers[DiagramCalls.diagram] = (args) => switch (args) {
        {'last': true} => {'ok': false},
        _ => everyPartDiagram(),
      };
      await pumpLastRun(tester, reduced: true);
      engine.eventsOut
        ..add({
          'event': 'run.node',
          'run': 'r3',
          'flow': 'every_part',
          'node': 'when_0',
          'status': 'ran',
          'port': 'out',
        })
        ..add({
          'event': 'run.node',
          'run': 'r3',
          'flow': 'every_part',
          'node': 'then_0',
          'path': '/then/0',
          'status': 'waiting',
        });
      await tester.pump();
      await tester.pump();
      expect(_node(tester, '/when/0').status, NodeStatus.ran);
      expect(_node(tester, '/then/0').status, NodeStatus.waiting);
    });

    testWidgets('a test run shows the same view, from the dry run', (
      tester,
    ) async {
      final dry = RunRecord.fromJson({
        'run': 'd1',
        'flow': 'every_part',
        'outcome': 'completed',
        'startedAt': '2026-11-13T08:00:00Z',
        'dryRun': true,
        'nodes': [
          {'node': 'when_0', 'type': 'state_change', 'port': 'out'},
          {'node': 'only_if', 'type': 'all_of', 'port': 'true'},
        ],
      });
      engine.answerers[DiagramCalls.diagram] = (args) =>
          args.containsKey('dryRun') ? everyPartRun() : everyPartDiagram();
      await pumpScreen(
        tester,
        engine,
        TestRunPage(
          name: 'Every part',
          dryRun: dry,
          rule: everyPartSpec(),
          unsaved: true,
        ),
      );
      final call = engine.callsOf(DiagramCalls.diagram).single.$2;
      expect(call['spec'], everyPartSpec());
      final trace = call['dryRun'] as Map;
      expect(trace['run'], 'd1');
      expect(trace['dryRun'], isTrue);
      expect((trace['nodes'] as List).first, {
        'node': 'when_0',
        'type': 'state_change',
        'port': 'out',
      });
      expect(find.byKey(const ValueKey('dry-run-diagram')), findsOneWidget);
      expect(find.byKey(const ValueKey('dry-run')), findsOneWidget);
      expect(_node(tester, '/when/0').status, NodeStatus.ran);
      // Opened full screen, it pans and zooms.
      await tester.tap(find.byKey(const ValueKey('diagram-open')));
      await tester.pumpAndSettle();
      expect(find.byType(DiagramViewer), findsOneWidget);
    });
  });

  test('a rule path names the part the editor edits', () {
    final spec = RuleSpec.fromJson(everyPartSpec());
    expect(partAt(spec, '/when/1'), isA<TimeTrigger>());
    expect(partAt(spec, '/onlyIf/0'), isA<CompareCondition>());
    expect(partAt(spec, '/then/1/if/0'), isA<CompareCondition>());
    expect(partAt(spec, '/then/1/else/0'), isA<NotifyStep>());
    expect(partAt(spec, '/then/2/together/1/1'), isA<NotifyStep>());
    expect(partAt(spec, '/then/3/otherwise/0'), isA<NotifyStep>());
    expect(partAt(spec, '/then/4/repeat/do/0'), isA<ToggleStep>());
    expect(partAt(spec, '/then/5/forEach/do/0'), isA<NotifyStep>());
    expect(partAt(spec, '/then/1/if'), isA<List<RuleCondition>>());
    expect(placeAt(spec, '/then/8')!.index, 8);
    expect(placeAt(spec, '/then/9'), isNull);
    expect(editorPath('/then/2/together/1/0'), 'then[2].together[1][0]');
    expect(editorPath('/then/4/repeat/do/0'), 'then[4].repeat.do[0]');
  });
}
