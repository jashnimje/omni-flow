// This test pins the builder's JSON to the engine's rule normalizer so the
// two cannot drift apart unnoticed.

import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show normalizeRule;

void main() {
  test('every trigger, condition and step the builder writes is already '
      'the engine\'s stored rule form', () {
    final spec = RuleSpec(
      name: 'Arrive home',
      when: [
        OnTrigger(thing: 'front_door', key: 'scanned', mode: OnMode.event),
        OnTrigger(thing: 'jade', key: 'home', to: true, hasTo: true),
        OnTrigger(thing: 'lamp', key: 'power'),
        OnTrigger(thing: 'room', key: 'temp', mode: OnMode.crosses, above: 28),
        TimeTrigger('18:30', days: ['sat']),
        IntervalTrigger(600),
        const ManualTrigger(),
      ],
      onlyIf: [
        CompareCondition('state', 'jade.home', '==', true),
        CompareCondition('var', r'$Away', '!=', false),
        BetweenCondition('17:00', '05:00'),
        DaysCondition(['sat', 'sun']),
      ],
      then: [
        DoStep('lamp', 'brightness', params: {'value': 40}),
        DoStep('tv', 'wake'),
        WaitStep(2000),
        WaitForStep(
          OnTrigger(thing: 'jade', key: 'home', to: false, hasTo: true),
          timeoutMs: 60000,
          onTimeout: [NotifyStep('Still home')],
        ),
        IfStep(
          conditions: [CompareCondition('var', r'$Away', '==', false)],
          then: [ToggleStep('lamp', 'power')],
          otherwise: [NotifyStep('Away', body: 'Lamp left alone')],
        ),
        TogetherStep([
          [SetStep(r'$Away', false)],
          [RunStep('evening')],
        ]),
      ],
    ).toJson();

    final stored = normalizeRule(spec);
    expect(stored['id'], 'arrive_home');
    expect({...stored}..remove('id'), spec);
    expect(RuleSpec.fromJson(stored).toJson(), stored);
  });
}
