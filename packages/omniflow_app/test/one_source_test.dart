import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/api/rule_calls.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_app/ui/automations/rule_blocks.dart';
import 'package:omniflow_app/ui/automations/rule_words.dart';
import 'package:omniflow_engine/omniflow_engine.dart'
    show InMemorySecretStore, OmniEngine;

/// The sentence editor reads the engine's words, so a part cannot read one
/// way in the editor and another on the card or the diagram.
void main() {
  late Directory home;
  late OmniEngine engine;
  late InProcessEngineClient client;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_one_source_app');
    engine = await OmniEngine.open(home: home, secrets: InMemorySecretStore());
    client = InProcessEngineClient(engine);
  });

  tearDown(() async {
    await engine.close();
    await home.delete(recursive: true);
  });

  test('the editor rows read the engine\'s words, blanks included', () async {
    final spec = RuleSpec(
      name: 'Morning',
      when: [
        TimeTrigger('07:00', days: ['mon', 'tue', 'wed', 'thu', 'fri']),
      ],
      onlyIf: [
        DaysCondition(['mon', 'wed', 'fri']),
      ],
      then: [WaitStep(300000)],
    );
    final draft = RuleDraft(spec, words: RuleWords(const []))
      ..wordsFrom = client;
    await draft.fetchWords();
    final words = RuleWords(
      const [],
      const {},
      draft.tokenLabels,
      draft.served,
    );

    final time = words.triggerParts(spec.when.single);
    expect(joinParts(time), 'At 07:00 on weekdays');
    expect(time.map((p) => p.blank), [null, Blank.time, null, Blank.days]);
    expect(words.condition(spec.onlyIf.single), 'On Mon, Wed and Fri');
    expect(joinParts(words.stepParts(spec.then.single)), 'Wait 5 min');

    // The card reads the same days once the rule is saved.
    final saved = await client.call('automation.save', {
      'form': 'rule',
      'trusted': true,
      'spec': spec.toJson(),
    });
    expect(saved['ok'], isTrue, reason: '$saved');
    final list = await client.call('automation.list');
    final card = (list['automations'] as List).single as Map;
    expect(
      ((card['sentence'] as List).first as Map)['text'],
      'At 07:00 on weekdays',
    );
  });

  test('the editor\'s own fallback days are the engine\'s too', () {
    expect(daysText(['mon', 'tue', 'wed', 'thu', 'fri']), 'on weekdays');
    expect(daysText(['fri', 'mon', 'wed']), 'on Mon, Wed and Fri');
  });

  test('save, values and keep order are the engine\'s rules', () async {
    expect(RuleSpec(name: 'x').missing, 'Choose a WHEN and a THEN to save.');
    expect(
      RuleSpec(
        name: 'x',
        when: [const ManualTrigger()],
        then: [WaitStep(1)],
      ).complete,
      isTrue,
    );
    expect(wordValue('yes'), isTrue);
    expect(wordValue('off'), isFalse);
    expect(literalFromText('on'), isTrue);
    final steps = <RuleStep>[
      KeepStep(
        'fan',
        'power',
        value: true,
        whileConditions: [CompareCondition('state', 'room.temp', '>', 28)],
      ),
      WaitStep(1000),
    ];
    keepsLast(steps);
    expect(steps.first, isA<WaitStep>());

    final reply = await RuleCalls.fetchWords(client, {'name': 'New'});
    expect(reply?.missing, 'Choose a WHEN and a THEN to save.');
  });

  test('Undo puts a removed automation back off, as it was', () async {
    final saved = await client.call('automation.save', {
      'form': 'rule',
      'trusted': true,
      'spec': {
        'name': 'Quiet',
        'enabled': false,
        'when': ['manual'],
        'then': [
          {'wait': 1000},
        ],
      },
    });
    final id = saved['id'] as String;
    final record = await client.call('automation.get', {'id': id});
    expect((await client.call('automation.remove', {'id': id}))['ok'], isTrue);
    expect(await RuleCalls.restore(client, {...record, 'id': id}), isTrue);
    final back = await client.call('automation.get', {'id': id});
    expect(back['enabled'], isFalse);
  });
}
