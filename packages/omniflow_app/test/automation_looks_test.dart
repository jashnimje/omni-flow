import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/new_automation.dart'
    show TemplateGallery;
import 'package:omniflow_app/ui/design/automation_look.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/home/run_section.dart' show RunTile;

import 'automations_fixtures.dart' as fx;
import 'fake_engine.dart';
import 'home_devices_test.dart' show household, pump, tapKey;

/// The automation look: colours and icons on automations, scenes and
/// templates, Home's Run section, and the templates gallery.

Map<String, Object?> manualRule({
  String id = 'lights_out',
  String name = 'Lights out',
  bool manualOnly = true,
  bool needsApproval = false,
}) => {
  'id': id,
  'name': name,
  'source': 'rule',
  'enabled': true,
  'approved': !needsApproval,
  'needsApproval': needsApproval,
  'color': '#A78BFA',
  'icon': 'moon',
  'askFirst': false,
  'notifyOnRun': true,
  'manualOnly': manualOnly,
  'sentence': [
    {'kind': 'when', 'text': 'When I run it'},
    {'kind': 'then', 'text': 'turn off desk lamp'},
  ],
  'devices': ['desk_lamp'],
};

FakeEngine homeWithRun() {
  final engine = household();
  final list = engine.answers['automation.list']!;
  engine.answers['automation.list'] = {
    ...list,
    'automations': [
      ...(list['automations'] as List),
      manualRule(),
      manualRule(id: 'on_its_own', name: 'On its own', manualOnly: false),
    ],
  };
  final scenes = engine.answers['scene.list']!;
  engine.answers['scene.list'] = {
    'ok': true,
    'scenes': [
      {...((scenes['scenes'] as List).single as Map), 'color': '#FB923C'},
    ],
  };
  return engine;
}

void main() {
  group('the contract fields parse', () {
    test('automation.list summaries carry colour, icon and behaviour', () {
      final a = AutomationSummary.fromJson({...manualRule(), 'askFirst': true});
      expect(a.color, '#A78BFA');
      expect(a.icon, 'moon');
      expect(a.askFirst, isTrue);
      expect(a.notifyOnRun, isTrue);
      expect(a.manualOnly, isTrue);
      final bare = AutomationSummary.fromJson({'id': 'x'});
      expect(
        (bare.color, bare.askFirst, bare.notifyOnRun, bare.manualOnly),
        (null, false, false, false),
      );
    });

    test('scenes carry and save their colour', () {
      final s = Scene.fromJson({'id': 'm', 'name': 'M', 'color': '#34D399'});
      expect(s.color, '#34D399');
      expect(s.toJson()['color'], '#34D399');
      expect(const Scene(name: 'N').toJson().containsKey('color'), isFalse);
    });

    test('templates carry category, icon and colour', () {
      final t = AutomationTemplate.fromJson({
        'id': 'bedtime',
        'category': 'Morning and night',
        'icon': 'moon',
        'color': '#4D9DFF',
      });
      expect(
        (t.category, t.icon, t.color),
        ('Morning and night', 'moon', '#4D9DFF'),
      );
    });
  });

  group('AutomationLook', () {
    test('maps every contract colour and icon, case-blind', () {
      expect(AutomationLook.colors, hasLength(8));
      expect(AutomationLook.icons, hasLength(16));
      expect(AutomationLook.colorOf('#4d9dff'), const Color(0xFF4D9DFF));
      expect(AutomationLook.colorName('#FACC15'), 'Yellow');
      expect(AutomationLook.iconOf('moon'), AutomationLook.icons['moon']);
    });

    test('falls back to the plain look for anything unknown', () {
      expect(AutomationLook.colorOf('#123456'), isNull);
      expect(AutomationLook.colorOf(null), isNull);
      expect(AutomationLook.badgeOf(null), OmniColors.raised);
      expect(AutomationLook.badgeInkOf('#nope'), OmniColors.text);
      expect(AutomationLook.tintOf(null), OmniColors.card);
      expect(AutomationLook.lineOf(null), OmniColors.line);
      expect(AutomationLook.iconOf('nope'), OmniIcons.automations);
      expect(
        AutomationLook.iconOf(null, fallback: OmniIcons.scene),
        OmniIcons.scene,
      );
    });
  });

  group('Automations list', () {
    testWidgets('a card wears its colour and icon and says how it behaves', (
      tester,
    ) async {
      final engine = fx.automationsEngine(
        automations: [
          {...manualRule(), 'askFirst': true},
          manualRule(id: 'plain', name: 'Plain')
            ..remove('color')
            ..remove('icon')
            ..['notifyOnRun'] = false,
        ],
      );
      await fx.pumpPage(tester, engine, const AutomationsScreen());
      final badge = tester.widget<AutomationBadge>(
        find.byKey(const ValueKey('badge-lights_out')),
      );
      expect(badge.color, '#A78BFA');
      expect(badge.icon, AutomationLook.icons['moon']);
      expect(find.byKey(const ValueKey('asks-first-lights_out')), findsOne);
      expect(find.byKey(const ValueKey('tells-you-lights_out')), findsOne);
      expect(find.text('Asks first'), findsOneWidget);
      expect(find.text('Tells you when it runs'), findsOneWidget);
      expect(find.byKey(const ValueKey('asks-first-plain')), findsNothing);
      expect(find.byKey(const ValueKey('tells-you-plain')), findsNothing);
      final plain = tester.widget<AutomationBadge>(
        find.byKey(const ValueKey('badge-plain')),
      );
      expect(plain.color, isNull);
    });

    testWidgets('a scene row wears its colour', (tester) async {
      final engine = fx.automationsEngine(
        automations: [
          {...fx.automationRows().last, 'color': '#F472B6'},
        ],
      );
      await fx.pumpPage(tester, engine, const AutomationsScreen());
      await fx.tapKey(tester, 'filter-scenes');
      final badge = tester.widget<AutomationBadge>(
        find.byKey(const ValueKey('badge-movie')),
      );
      expect(badge.color, '#F472B6');
      expect(badge.icon, sceneIconFor('movie'));
    });
  });

  group('Home Run', () {
    testWidgets('one Run section of scenes and manual automations, above '
        'favourites', (tester) async {
      await pump(tester, homeWithRun());
      expect(find.byKey(const ValueKey('home-run')), findsOneWidget);
      expect(find.text('Run'), findsOneWidget);
      expect(find.byKey(const ValueKey('scene-movie')), findsOneWidget);
      expect(find.byKey(const ValueKey('run-lights_out')), findsOneWidget);
      expect(find.byKey(const ValueKey('run-on_its_own')), findsNothing);
      expect(find.byKey(const ValueKey('run-desk_button')), findsNothing);
      final run = tester.getTopLeft(find.text('Run')).dy;
      final favourites = tester.getTopLeft(find.text('Favourites')).dy;
      expect(run < favourites, isTrue);
      final scene = tester.getTopLeft(
        find.byKey(const ValueKey('scene-movie')),
      );
      final rule = tester.getTopLeft(
        find.byKey(const ValueKey('run-lights_out')),
      );
      expect(scene.dy, rule.dy, reason: 'three columns at phone width');
    });

    testWidgets('tiles are labelled for screen readers', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, homeWithRun());
      expect(
        tester.getSemantics(find.byKey(const ValueKey('run-lights_out'))),
        matchesSemantics(
          label: 'Lights out, Tap to run',
          hint: 'Runs it',
          isButton: true,
          hasTapAction: true,
          hasLongPressAction: true,
          onLongPressHint: 'Open it',
        ),
      );
      semantics.dispose();
    });

    testWidgets('a tap runs it, shows a progress, then a check', (
      tester,
    ) async {
      final engine = homeWithRun();
      await pump(tester, engine);
      engine.delay = const Duration(milliseconds: 300);
      await tester.tap(find.byKey(const ValueKey('run-lights_out')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('run-busy-lights_out')), findsOne);
      expect(find.text('Running'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(engine.callsOf('automation.run').single.$2, {'id': 'lights_out'});
      expect(find.byKey(const ValueKey('run-done-lights_out')), findsOne);
      expect(find.text('Done'), findsOneWidget);
      await tester.pump(RunTile.doneFor);
      expect(find.byKey(const ValueKey('run-done-lights_out')), findsNothing);
      expect(find.text('Tap to run'), findsOneWidget);
    });

    testWidgets('a scene tile runs the scene', (tester) async {
      final engine = homeWithRun();
      await pump(tester, engine);
      await tapKey(tester, 'scene-movie');
      expect(engine.callsOf('scene.run').single.$2, {'id': 'movie'});
      expect(find.byKey(const ValueKey('run-done-movie')), findsOne);
    });

    testWidgets('a failed run shows the plain reason on the tile', (
      tester,
    ) async {
      final engine = homeWithRun();
      engine.answers['automation.run'] = {
        'ok': true,
        'runs': [
          {
            'run': 'r1',
            'flow': 'lights_out',
            'outcome': 'failed',
            'startedAt': '2026-11-12T20:00:00Z',
            'nodes': [
              {
                'node': 'then[0]',
                'type': 'do',
                'label': 'Turn off desk lamp',
                'error': 'the lamp did not answer',
              },
            ],
          },
        ],
      };
      await pump(tester, engine);
      await tapKey(tester, 'run-lights_out');
      expect(find.byKey(const ValueKey('run-failed-lights_out')), findsOne);
      expect(
        find.text('Turn off desk lamp failed: the lamp did not answer'),
        findsOneWidget,
      );
    });

    testWidgets('a refused run shows the engine message', (tester) async {
      final engine = homeWithRun();
      engine.answers['automation.run'] = {
        'ok': false,
        'error': {'type': 'not_found', 'message': 'No such automation'},
      };
      await pump(tester, engine);
      await tapKey(tester, 'run-lights_out');
      expect(find.byKey(const ValueKey('run-failed-lights_out')), findsOne);
      final text = tester.widget<Text>(
        find.byKey(const ValueKey('run-state-lights_out')),
      );
      expect(text.data, isNotEmpty);
      expect(text.data, isNot('Tap to run'));
    });

    testWidgets('a long press opens the automation', (tester) async {
      await pump(tester, homeWithRun());
      await tester.longPress(find.byKey(const ValueKey('run-lights_out')));
      await tester.pumpAndSettle();
      expect(find.byType(AutomationPage), findsOneWidget);
    });

    testWidgets('a long press on a scene opens the scene', (tester) async {
      await pump(tester, homeWithRun());
      await tester.longPress(find.byKey(const ValueKey('scene-movie')));
      await tester.pumpAndSettle();
      expect(find.byType(SceneEditorPage), findsOneWidget);
    });

    testWidgets('one waiting for review opens its review on tap', (
      tester,
    ) async {
      final engine = household();
      final list = engine.answers['automation.list']!;
      engine.answers['automation.list'] = {
        ...list,
        'automations': [manualRule(needsApproval: true)],
      };
      engine.answers['scene.list'] = {'ok': true, 'scenes': []};
      await pump(tester, engine);
      expect(find.text('Needs your review'), findsOneWidget);
      await tapKey(tester, 'run-lights_out');
      expect(engine.callsOf('automation.run'), isEmpty);
      expect(find.byType(ReviewPage), findsOneWidget);
    });

    testWidgets('with nothing to run the section offers to save a scene', (
      tester,
    ) async {
      final engine = household();
      engine.answers['scene.list'] = {'ok': true, 'scenes': []};
      await pump(tester, engine);
      expect(find.byKey(const ValueKey('home-run')), findsOneWidget);
      expect(find.byType(RunTile), findsNothing);
      await tapKey(tester, 'run-capture');
      expect(find.text('Save how things are now'), findsWidgets);
      expect(find.byKey(const ValueKey('capture-name')), findsOneWidget);
    });
  });

  group('Templates gallery', () {
    AutomationTemplate t(String id, String? category) => AutomationTemplate(
      id: id,
      name: 'Name $id',
      description: 'What $id does',
      category: category,
      icon: 'moon',
      color: '#4D9DFF',
    );

    test('groups follow the contract order, unknown ones last', () {
      final groups = TemplateGallery.groupsOf([
        t('tag', 'Buttons and tags'),
        t('odd', 'Something new'),
        t('home', 'Arrive and leave'),
        t('bed', 'Morning and night'),
        t('wake', 'Morning and night'),
        t('none', null),
      ]);
      expect(
        [for (final (c, g) in groups) '$c: ${g.map((x) => x.id).join(',')}'],
        [
          'Arrive and leave: home',
          'Morning and night: bed,wake',
          'Buttons and tags: tag',
          'More: odd,none',
        ],
      );
    });

    testWidgets('the New sheet shows illustrated cards under category '
        'headers', (tester) async {
      final engine = fx.automationsEngine();
      engine.answers['automation.templates'] = {
        'ok': true,
        'templates': [
          {
            'id': 'tag_toggle',
            'name': 'Tag toggle',
            'description': 'Scan an NFC tag to switch something.',
            'category': 'Buttons and tags',
            'icon': 'bolt',
            'color': '#FACC15',
          },
          {
            'id': 'bedtime',
            'name': 'Bedtime',
            'description': 'At bedtime, turn things off.',
            'category': 'Morning and night',
            'icon': 'moon',
            'color': '#A78BFA',
          },
        ],
      };
      await fx.pumpPage(
        tester,
        engine,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('new'),
              onPressed: () => openNewAutomation(context),
              child: const Text('New'),
            ),
          ),
        ),
      );
      await fx.tapKey(tester, 'new');
      final night = tester.getTopLeft(find.text('Morning and night')).dy;
      final tags = tester.getTopLeft(find.text('Buttons and tags')).dy;
      expect(night < tags, isTrue);
      final bedtime = tester.getTopLeft(find.text('Bedtime')).dy;
      expect(night < bedtime && bedtime < tags, isTrue);
      final badge = tester.widget<AutomationBadge>(
        find.descendant(
          of: find.byKey(const ValueKey('template-bedtime')),
          matching: find.byType(AutomationBadge),
        ),
      );
      expect(
        (badge.color, badge.icon),
        ('#A78BFA', AutomationLook.icons['moon']),
      );
      await fx.tapKey(tester, 'template-bedtime');
      expect(find.byType(TemplatePage), findsOneWidget);
    });
  });
}
