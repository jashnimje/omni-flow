// These tests run the automation screens' engine calls against the real
// engine, so the reply shapes the screens read cannot drift from it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

const _light = {
  'schemaVersion': 1,
  'id': 'test_light',
  'name': 'Test light',
  'category': 'light',
  'transport': {'type': 'virtual'},
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'command': {'set': 'power', 'value': '{{value}}'},
      'stateJsonPath': r'$.power',
    },
    {
      'id': 'brightness',
      'type': 'level',
      'label': 'Brightness',
      'params': {
        'value': {'type': 'number', 'min': 0, 'max': 100, 'unit': '%'},
      },
      'command': {'set': 'brightness', 'value': '{{value}}'},
      'stateJsonPath': r'$.brightness',
    },
  ],
};

void main() {
  late Directory home;
  late OmniEngine engine;
  late EngineApi api;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_app_automations');
    engine = await OmniEngine.open(home: home, secrets: InMemorySecretStore());
    api = EngineApi(InProcessEngineClient(engine));
    for (final (command, args) in [
      ('driver.register', {'manifest': _light}),
      ('device.add', {'id': 'lamp', 'name': 'Lamp', 'driver': 'test_light'}),
      ('device.add', {'id': 'jade', 'name': 'Jade', 'driver': 'person'}),
    ]) {
      final r = await engine.handle(command, args);
      expect(r['ok'], isTrue, reason: '$command -> $r');
    }
  });

  tearDown(() async {
    await engine.close();
    await home.delete(recursive: true);
  });

  test('a rule saved from the editor lists with its sentence, and its dry '
      'run says what each step would send', () async {
    final rule = RuleSpec(
      name: 'Arrive home',
      when: [OnTrigger(thing: 'jade', key: 'home', to: true, hasTo: true)],
      then: [
        DoStep('lamp', 'brightness', params: {'value': 70}),
      ],
    ).toJson();
    final saved = await api.saveRule(rule, trusted: true);
    expect(saved.ok, isTrue, reason: '${saved.failure?.message}');
    expect(saved.value!['approved'], isTrue);

    final list = (await api.automations()).value!;
    final a = list.singleWhere((x) => x.id == 'arrive_home');
    expect(a.source, 'rule');
    expect(a.sentence.map((p) => p.kind), contains(SentenceKind.when));
    expect(a.sentence.map((p) => p.kind), contains(SentenceKind.then));
    expect(a.controls, ['lamp']);
    expect(a.devices, containsAll(['jade', 'lamp']));
    expect(a.revision, isNotNull);

    final dry = (await api.dryRun(rule: rule)).value!.single;
    expect(dry.dryRun, isTrue);
    final step = dry.steps.singleWhere((n) => n.type == 'device_capability');
    expect(step.port, 'out');
    expect((step.output!['result'] as Map)['params'], {'value': 70});
    expect(dry.steps.first.label, isNotNull);
  });

  test('a keep rule with no trigger saves, and the engine names the row of '
      'a bad step', () async {
    final keep = RuleSpec(
      name: 'Lamp off while away',
      then: [
        KeepStep(
          'lamp',
          'power',
          value: false,
          whileConditions: [
            CompareCondition('state', 'jade.home', '==', false),
          ],
        ),
      ],
    );
    expect(keep.complete, isTrue);
    expect((await api.saveRule(keep.toJson(), trusted: true)).ok, isTrue);

    final bad = RuleSpec(
      name: 'Bad',
      when: [const ManualTrigger()],
      then: [WaitStep(10), DoStep('lamp', 'fly')],
    ).toJson();
    final failure = (await api.saveRule(bad, trusted: true)).failure!;
    expect(failure.issuesAt('then[1]'), isNotEmpty);
    expect(failure.issuesAt('then[0]'), isEmpty);
  });

  test('templates list their placeholders and fill into a rule the editor '
      'reads', () async {
    final templates = (await api.templates()).value!;
    final arrive = templates.singleWhere((t) => t.id == 'arrive_home');
    expect(arrive.placeholders.map((p) => p.kind), ['person', 'toggles']);
    final filled = await api.fillTemplate('arrive_home', {
      'person': 'jade',
      'things': ['lamp.power'],
    });
    final spec = RuleSpec.fromJson(filled.value!);
    expect(spec.complete, isTrue);
    expect((spec.when.single as OnTrigger).thing, 'jade');
    expect((spec.then.single as DoStep).thing, 'lamp');
  });

  test(
    'a scene saved by the user is approved and lists with its actions',
    () async {
      final id = await api.saveScene(
        const Scene(
          name: 'Movie',
          icon: 'movie',
          actions: [
            SceneAction('lamp.brightness', {'value': 20}),
          ],
        ),
      );
      expect(id.value, 'movie');
      final scene = (await api.scenes()).value!.single;
      expect(scene.icon, 'movie');
      expect(scene.actions.single.action, 'lamp.brightness');
      final row = (await api.automations()).value!.singleWhere(
        (a) => a.id == 'movie',
      );
      expect(row.isScene, isTrue);
      expect(row.needsApproval, isFalse);
      expect(row.icon, 'movie');
      final runs = (await api.runScene('movie')).value!;
      expect(runs.single.ok, isTrue);
    },
  );
}
