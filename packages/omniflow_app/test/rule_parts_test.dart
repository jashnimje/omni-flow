import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_app/ui/automations/dialogs.dart';
import 'package:omniflow_app/ui/automations/form_parts.dart';
import 'package:omniflow_app/ui/automations/rule_blocks.dart';
import 'package:omniflow_app/ui/automations/rule_words.dart';

void main() {
  test('an edit put back by hand leaves the rule saved', () {
    final draft = RuleDraft(
      RuleSpec.fromJson({
        'name': 'Lamp',
        'when': [
          {'manual': true},
        ],
        'then': [
          {'wait': 1000},
        ],
      }),
      words: RuleWords(const []),
    );
    expect(draft.dirty, isFalse);
    draft.spec.name = 'Lamp two';
    draft.changed();
    expect(draft.dirty, isTrue);
    draft.spec.name = 'Lamp';
    draft.changed();
    expect(draft.dirty, isFalse);
    draft.dirty = true;
    expect(draft.dirty, isTrue, reason: 'a template is unsaved as it is');
  });

  test('keep steps stay last', () {
    final steps = <RuleStep>[KeepStep('lamp', 'power'), WaitStep(1000)];
    keepsLast(steps);
    expect(steps.last, isA<KeepStep>());
  });

  test('a param the action does not declare is kept', () {
    final out = ParamControls.complete(
      {
        'value': {'type': 'number', 'min': 0, 'max': 100},
      },
      {'value': 40, 'transition': 500},
    );
    expect(out, {'value': 40, 'transition': 500});
  });

  test('a notify body that is not text survives a round trip', () {
    final step = RuleStep.fromJson({
      'notify': {
        'title': 'Hi',
        'body': {'from': 'agent'},
      },
    });
    expect(step.toJson(), {
      'notify': {
        'title': 'Hi',
        'body': {'from': 'agent'},
      },
    });
  });

  test('a template knows which placeholder a toggle flips', () {
    final t = AutomationTemplate.fromJson({
      'id': 'tag_toggle',
      'spec': {
        'then': [
          {'toggle': '<target>'},
          {
            'do': '<light>',
            'params': {'value': true},
          },
        ],
      },
    });
    expect(t.toggles('target'), isTrue);
    expect(t.toggles('light'), isFalse);
  });

  test('day labels count calendar days, across a clock change too', () {
    // Under TZ=Europe/London the clocks go forward on 29 March 2026, so
    // the midnights either side of it are 23 hours apart.
    final now = DateTime(2026, 3, 30, 10);
    expect(whenText(DateTime(2026, 3, 30, 0, 30), now: now), 'Today 00:30');
    expect(whenText(DateTime(2026, 3, 29, 9), now: now), 'Yesterday 09:00');
    expect(whenText(DateTime(2026, 3, 28, 9), now: now), '28 Mar 09:00');
  });
}
