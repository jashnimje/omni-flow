import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/automation_view.dart'
    show SentenceContext;
import 'package:test/test.dart';

/// The things a rule may name in these tests, by driver.
const _things = {
  'lamp': 'philips_wiz_udp',
  'jade': 'person',
  'home': 'place',
  'office': 'place',
  'front_door': 'nfc_tag',
};

FlowReferences refs({Set<String> flows = const {'evening'}}) {
  final registry = DriverRegistry.withBuiltIns();
  DriverManifest manifest(String thing) => registry[_things[thing]!]!;
  return FlowReferences(
    devices: _things.keys.toSet(),
    flows: flows,
    capabilityOf: (d, c) =>
        _things.containsKey(d) ? manifest(d).capability(c) : null,
    stateKeysOf: (t) => {
      if (_things.containsKey(t))
        for (final c in manifest(t).capabilities) ?stateKeyOf(c.stateJsonPath),
    },
    eventsOf: (t) => {
      if (_things.containsKey(t))
        for (final c in manifest(t).capabilities)
          if (c.type == CapabilityType.event) c.id,
    },
  );
}

const context = RuleContext(
  places: {'home': 'home', 'office': 'office', 'office_zone': 'office'},
  person: 'jade',
  personHome: 'home',
);

/// The issues a rule has, at rule paths, from its shape or its graph.
List<Map<String, String>> issuesOf(Map<String, Object?> rule) {
  try {
    final compiled = compileRule(
      normalizeRule(rule, context: context),
      refs: refs(),
    );
    final flow = FlowSpec.parse(compiled.flow);
    return [
      for (final i in compiled.toRulePaths(validateFlow(flow, refs: refs())))
        i.toJson(),
    ];
  } on ValidationException catch (e) {
    return [for (final i in e.issues) i.toJson()];
  }
}

Map<String, Object?> nodeOf(Map<String, Object?> flow, String id) =>
    (flow['nodes'] as List).cast<Map<String, Object?>>().firstWhere(
      (n) => n['id'] == id,
    );

Set<String> edgesOf(Map<String, Object?> flow) => {
  for (final e in (flow['edges'] as List).cast<Map>())
    '${e['from']['node']}.${e['from']['port']} -> ${e['to']['node']}',
};

void main() {
  final everyStep = <String, Object?>{
    'name': 'Every step',
    'when': [
      {
        'on': 'jade.home',
        'change': {'to': true},
      },
      {
        'time': '18:00',
        'days': ['mon', 'fri'],
      },
      {'on': 'front_door.scanned', 'event': true},
      {'interval': 60},
      {'manual': true},
    ],
    'onlyIf': [
      {'state': 'lamp.power', 'op': '==', 'value': false},
      {
        'between': ['17:00', '23:00'],
      },
    ],
    'then': [
      {
        'do': 'lamp.brightness',
        'params': {'value': 80},
      },
      {'toggle': 'lamp.power'},
      {'wait': 2000},
      {
        'waitFor': {
          'on': 'office.inside',
          'change': {'to': true},
          'timeoutMs': 60000,
          'onTimeout': [
            {
              'notify': {'title': 'Nobody came'},
            },
          ],
        },
      },
      {
        'if': [
          {'var': r'$Mode', 'value': 'away'},
        ],
        'then': [
          {
            'set': {'var': r'$Mode', 'value': 'home'},
          },
        ],
        'else': [
          {'run': 'evening'},
        ],
      },
      {
        'together': [
          [
            {
              'do': 'lamp.power',
              'params': {'value': true},
            },
          ],
          [
            {'wait': 500},
            {
              'notify': {'title': 'Lamp on'},
            },
          ],
        ],
      },
      {'notify': 'Done'},
    ],
  };

  group('compiling', () {
    test('every trigger and step kind becomes its node, and validates', () {
      final compiled = compileRule(
        normalizeRule(everyStep, context: context),
        refs: refs(),
      );
      final flow = compiled.flow;
      final types = {
        for (final n in (flow['nodes'] as List).cast<Map>()) n['id']: n['type'],
      };
      expect(types, {
        'when_0': 'on',
        'when_1': 'time_of_day',
        'when_2': 'on',
        'when_3': 'interval',
        'when_4': 'manual',
        'only_if': 'all_of',
        'then_0': 'device_capability',
        'then_1': 'device_toggle',
        'then_2': 'delay',
        'then_3': 'wait_until',
        'then_3_wait_for_on_timeout_0': 'notify',
        'then_4': 'compare',
        'then_4_then_0': 'set_variable',
        'then_4_else_0': 'run_flow',
        'then_5': 'parallel',
        'then_5_together_0_0': 'device_capability',
        'then_5_together_1_0': 'delay',
        'then_5_together_1_1': 'notify',
        'then_6': 'notify',
      });
      expect(validateFlow(FlowSpec.parse(flow), refs: refs()), isEmpty);
      expect(edgesOf(flow), {
        for (var i = 0; i < 5; i++) 'when_$i.out -> only_if',
        'only_if.true -> then_0',
        'then_0.out -> then_1',
        'then_1.out -> then_2',
        'then_2.out -> then_3',
        'then_3.matched -> then_4',
        'then_3.timeout -> then_3_wait_for_on_timeout_0',
        'then_4.true -> then_4_then_0',
        'then_4.false -> then_4_else_0',
        'then_4_then_0.out -> then_5',
        'then_4_else_0.out -> then_5',
        'then_5.branch -> then_5_together_0_0',
        'then_5.branch -> then_5_together_1_0',
        'then_5_together_1_0.out -> then_5_together_1_1',
        'then_5.done -> then_6',
      });
      expect(nodeOf(flow, 'when_0')['config'], {
        'thing': 'jade',
        'key': 'home',
        'change': {'to': true},
      });
      expect(nodeOf(flow, 'when_2')['config'], {
        'thing': 'front_door',
        'key': 'scanned',
        'event': true,
      });
      expect(nodeOf(flow, 'then_3')['config'], {
        'thing': 'office',
        'key': 'inside',
        'change': {'to': true},
        'timeoutMs': 60000,
      });
      expect(nodeOf(flow, 'only_if')['config'], {
        'rules': [
          {
            'type': 'compare',
            'left': {'state': 'lamp.state'},
            'op': '==',
            'right': {'literal': false},
          },
          {'type': 'time_window', 'start': '17:00', 'end': '23:00'},
        ],
      });
      expect(nodeOf(flow, 'then_0')['label'], 'set lamp.brightness to 80');
      expect(flow['mode'], 'single');
    });

    test('a rule with no onlyIf starts its steps from every trigger', () {
      final flow = compileRule(
        normalizeRule({
          'name': 'Doorbell',
          'when': ['nfc:front_door', 'manual'],
          'then': ['notify:Someone is at the door'],
        }, context: context),
      ).flow;
      expect(edgesOf(flow), {'when_0.out -> then_0', 'when_1.out -> then_0'});
      expect(flow['id'], 'doorbell');
    });

    test('an if with no else goes on to the next step either way', () {
      final flow = compileRule(
        normalizeRule({
          'name': 'Maybe',
          'when': ['manual'],
          'then': [
            {
              'if': {'state': 'jade.home', 'value': true},
              'then': ['lamp.power=true'],
            },
            'notify:after',
          ],
        }, context: context),
      ).flow;
      expect(
        edgesOf(flow),
        containsAll(['then_0_then_0.out -> then_1', 'then_0.false -> then_1']),
      );
      expect(nodeOf(flow, 'then_0')['type'], 'compare');
    });

    test('the rule runs: a waitFor timeout ends it after onTimeout', () async {
      final rule = normalizeRule({
        'name': 'Wait',
        'when': ['manual'],
        'then': [
          {
            'waitFor': {
              'on': 'jade.home',
              'change': {'to': true},
              'timeoutMs': 1000,
              'onTimeout': ['notify:late'],
            },
          },
          'notify:arrived',
        ],
      }, context: context);
      final trace = await FlowRunner(
        FlowSpec.parse(compileRule(rule).flow),
        _NoEffects(),
        clock: InstantFlowClock(DateTime(2026)),
      ).fire('when_0', {});
      expect(trace.outcome, RunOutcome.completed);
      expect(
        [for (final n in trace.nodes) n.nodeId],
        ['when_0', 'then_0', 'then_0_wait_for_on_timeout_0'],
      );
    });
  });

  group('validation paths', () {
    test('shape problems point at the rule path', () {
      expect(
        issuesOf({
          'name': 'Bad',
          'when': [
            'soon',
            {'on': 'jade'},
          ],
          'onlyIf': [
            {'state': 'lamp.power', 'op': '~', 'value': 1},
          ],
          'then': [
            'lamp.power=true',
            {'do': 'lamp'},
            {'wait': -1},
            {
              'together': [
                ['wait:1s'],
              ],
            },
            {'notify': 3},
            {'do': 'lamp.power', 'toggle': 'lamp.power'},
          ],
          'colour': 'red',
        }),
        unorderedEquals([
          {'path': 'colour', 'message': startsWith('is not a rule key')},
          {'path': 'when[0]', 'message': startsWith('"soon" is not a trigger')},
          {'path': 'when[1].on', 'message': contains('thing.key')},
          {'path': 'onlyIf[0].op', 'message': startsWith('must be one of')},
          {'path': 'then[1].do', 'message': contains('thing.action')},
          {'path': 'then[2].wait', 'message': contains('milliseconds')},
          {'path': 'then[3].together', 'message': contains('two or more')},
          {'path': 'then[4].notify', 'message': contains('title')},
          {'path': 'then[5]', 'message': contains('not both')},
        ]),
      );
    });

    test('graph problems come back at the rule path that caused them', () {
      expect(
        issuesOf({
          'name': 'Wrong things',
          'when': [
            'garage.door',
            {'on': 'lamp.colour'},
            {'on': 'front_door.opened', 'event': true},
          ],
          'onlyIf': [
            'jade.home',
            {'state': 'cellar.temp', 'op': '>', 'value': 3},
          ],
          'then': [
            {
              'do': 'lamp.brightness',
              'params': {'value': 900},
            },
            'lamp.launch=true',
            {
              'if': [
                {
                  'anyOf': [
                    {'state': 'jade.mood', 'value': 'ok'},
                  ],
                },
              ],
              'then': ['toggle:lamp.brightness'],
            },
            {
              'together': [
                ['run:nowhere'],
                [
                  {
                    'waitFor': {'on': 'ghost.home', 'timeoutMs': 10},
                  },
                ],
              ],
            },
          ],
        }),
        unorderedEquals([
          {'path': 'when[0].on', 'message': 'no thing garage'},
          {
            'path': 'when[1].on',
            'message': startsWith('lamp has no state colour'),
          },
          {
            'path': 'when[2].on',
            'message': startsWith('front_door has no event opened'),
          },
          {'path': 'onlyIf[1].state', 'message': 'no thing cellar'},
          {'path': 'then[0].params.value', 'message': isNotEmpty},
          {'path': 'then[1].do', 'message': 'lamp has no capability launch'},
          {
            'path': 'then[2].if[0].anyOf[0].state',
            'message': startsWith('jade has no state mood'),
          },
          {'path': 'then[2].then[0].toggle', 'message': contains('on/off')},
          {'path': 'then[3].together[0][0].run', 'message': 'no flow nowhere'},
          {
            'path': 'then[3].together[1][0].waitFor.on',
            'message': 'no thing ghost',
          },
        ]),
      );
    });

    test('a rule that runs itself is refused at its run step', () {
      expect(
        issuesOf({
          'name': 'Evening',
          'when': ['manual'],
          'then': ['run:evening'],
        }),
        [
          {'path': 'then[0].run', 'message': 'a flow cannot run itself'},
        ],
      );
    });
  });

  group('shorthand', () {
    test('triggers', () {
      final cases = <String, Map<String, Object?>>{
        'manual': {'manual': true},
        'time:18:00': {'time': '18:00'},
        'time:07:30@mon,fri': {
          'time': '07:30',
          'days': ['mon', 'fri'],
        },
        'every:5m': {'interval': 300},
        'every:30': {'interval': 30},
        'nfc:front_door': {'on': 'front_door.scanned', 'event': true},
        'event:desk.button': {'on': 'desk.button', 'event': true},
        'home:entered': {
          'on': 'jade.home',
          'change': {'to': true},
        },
        'home:left': {
          'on': 'jade.home',
          'change': {'to': false},
        },
        'office_zone:entered': {
          'on': 'office.inside',
          'change': {'to': true},
        },
        'jade.home': {'on': 'jade.home', 'change': <String, Object?>{}},
        'jade.place=office': {
          'on': 'jade.place',
          'change': {'to': 'office'},
        },
        'room.temp>28': {
          'on': 'room.temp',
          'crosses': {'above': 28},
        },
        'room.temp<10.5': {
          'on': 'room.temp',
          'crosses': {'below': 10.5},
        },
      };
      for (final c in cases.entries) {
        expect(expandTrigger(c.key, context), c.value, reason: c.key);
      }
      expect(
        expandTrigger(
          'home:entered',
          const RuleContext(places: {'home': 'home'}),
        ),
        {
          'on': 'home.inside',
          'change': {'to': true},
        },
        reason: 'with no household person the place itself answers',
      );
      for (final bad in [
        'time:25:00',
        'every:0s',
        'cellar:entered',
        'x.y>hot',
      ]) {
        expect(
          () => expandTrigger(bad, context),
          throwsA(isA<ShorthandException>()),
          reason: bad,
        );
      }
    });

    test('conditions', () {
      expect(expandCondition('jade.home'), {
        'state': 'jade.home',
        'op': '==',
        'value': true,
      });
      expect(expandCondition('room.temp>=20'), {
        'state': 'room.temp',
        'op': '>=',
        'value': 20,
      });
      expect(expandCondition(r'$Mode=away'), {
        'var': r'$Mode',
        'op': '==',
        'value': 'away',
      });
      expect(expandCondition('lamp.power != true'), {
        'state': 'lamp.power',
        'op': '!=',
        'value': true,
      });
      expect(expandCondition('time:18:00-23:30'), {
        'between': ['18:00', '23:30'],
      });
      expect(expandCondition('days:sat,sun'), {
        'days': ['sat', 'sun'],
      });
      expect(expandCondition('not:jade.home'), {
        'not': {'state': 'jade.home', 'op': '==', 'value': true},
      });
    });

    test('steps', () {
      final cases = <String, Map<String, Object?>>{
        'lamp.power=true': {
          'do': 'lamp.power',
          'params': {'value': true},
        },
        'tv.launch_app={"app":"netflix"}': {
          'do': 'tv.launch_app',
          'params': {'app': 'netflix'},
        },
        'tv.home': {'do': 'tv.home'},
        'toggle:lamp.power': {'toggle': 'lamp.power'},
        'wait:2s': {'wait': 2000},
        'wait:250ms': {'wait': 250},
        'wait:1m': {'wait': 60000},
        'notify:"Welcome home"': {
          'notify': {'title': 'Welcome home'},
        },
        r'set:$Mode=away': {
          'set': {'var': r'$Mode', 'value': 'away'},
        },
        'run:evening': {'run': 'evening'},
      };
      for (final c in cases.entries) {
        expect(expandStep(c.key), c.value, reason: c.key);
      }
      expect(() => expandStep('wait:2'), throwsA(isA<ShorthandException>()));
    });

    test('a rule written in shorthand is stored expanded', () {
      final rule = normalizeRule({
        'name': 'Welcome home',
        'when': ['home:entered'],
        'onlyIf': ['lamp.power=false'],
        'then': ['lamp.power=true', 'wait:2s', 'notify:Welcome'],
      }, context: context);
      expect(rule, {
        'id': 'welcome_home',
        'name': 'Welcome home',
        'when': [
          {
            'on': 'jade.home',
            'change': {'to': true},
          },
        ],
        'onlyIf': [
          {'state': 'lamp.power', 'op': '==', 'value': false},
        ],
        'then': [
          {
            'do': 'lamp.power',
            'params': {'value': true},
          },
          {'wait': 2000},
          {
            'notify': {'title': 'Welcome'},
          },
        ],
      });
    });
  });

  test('normalizing a stored rule again changes nothing', () {
    final once = normalizeRule(everyStep, context: context);
    expect(normalizeRule(once, context: context), once);
  });

  test('ids come from the name', () {
    expect(ruleIdFor('Evening lights'), 'evening_lights');
    expect(ruleIdFor('  Lamp -> on!  '), 'lamp_on');
    expect(ruleIdFor('7am alarm'), 'rule_7am_alarm');
  });

  test('names with no ASCII letters still get ids of their own', () {
    final ids = [
      for (final n in ['🌙', '☀️', 'शाम', 'Évening']) ruleIdFor(n),
    ];
    expect(ids.toSet(), hasLength(4));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
    }
    expect(ruleIdFor('शाम'), ruleIdFor('शाम'), reason: 'the same on re-save');
    expect(ids[3], startsWith('vening_'));
  });

  group('compare values that are references', () {
    Map<String, Object?> withValue(Object? value) => {
      'name': 'Ref',
      'when': ['manual'],
      'onlyIf': [
        {'state': 'lamp.power', 'op': '==', 'value': value},
      ],
      'then': ['notify:x'],
    };

    test('a bad reference is an issue at its path, not a crash', () {
      for (final (value, path) in [
        ({'state': 'nodot'}, 'onlyIf[0].value.state'),
        ({'state': 5}, 'onlyIf[0].value.state'),
        ({'var': 'Mode'}, 'onlyIf[0].value.var'),
        ({'msg': 'a b'}, 'onlyIf[0].value.msg'),
      ]) {
        expect(issuesOf(withValue(value)), [
          {'path': path, 'message': startsWith('must be')},
        ], reason: '$value');
      }
    });

    test('good references and a literal compile', () {
      for (final value in [
        {'state': 'jade.home'},
        {'var': r'$Mode'},
        {'msg': 'payload.temp'},
        {'literal': 'x y'},
      ]) {
        expect(issuesOf(withValue(value)), isEmpty, reason: '$value');
      }
    });
  });

  test('a non-list where a list goes says so', () {
    List<Object?> paths(Map<String, Object?> rule) => [
      for (final i in issuesOf(rule)) (i['path'], i['message']),
    ];
    expect(
      paths({
        'name': 'x',
        'when': 'manual',
        'then': ['notify:x'],
      }),
      [('when', 'must be a list')],
    );
    expect(
      paths({
        'name': 'x',
        'when': <Object?>[],
        'then': ['notify:x'],
      }),
      [('when', 'needs at least one item')],
    );
    final rule = normalizeRule({
      'name': 'x',
      'when': ['manual'],
      'then': [
        {
          'if': 'jade.home',
          'then': ['notify:hi'],
        },
      ],
    }, context: context);
    expect((rule['then'] as List).single, {
      'if': [
        {'state': 'jade.home', 'op': '==', 'value': true},
      ],
      'then': [
        {
          'notify': {'title': 'hi'},
        },
      ],
    });
  });

  test('shorthand takes a space after the colon', () {
    expect(expandStep('toggle: lamp.power'), {'toggle': 'lamp.power'});
    expect(expandStep('run: evening'), {'run': 'evening'});
    expect(expandTrigger('nfc: front_door', context), {
      'on': 'front_door.scanned',
      'event': true,
    });
    expect(expandTrigger('event: desk.button', context), {
      'on': 'desk.button',
      'event': true,
    });
    expect(expandTrigger('time: 18:00', context), {'time': '18:00'});
    expect(expandCondition('time: 18:00-23:00'), {
      'between': ['18:00', '23:00'],
    });
  });

  test('a TV power check reads as its sensor, not its Power key', () {
    final words = SentenceContext(
      names: const {'tv': 'TV'},
      drivers: {'tv': DriverRegistry.withBuiltIns()['android_tv_adb']!},
    );
    expect(
      words.condition({'state': 'tv.power', 'op': '==', 'value': 'on'}),
      'TV power is on',
    );
    expect(words.action('tv.power', null), 'TV power key');
  });

  group('try and otherwise', () {
    final rule = normalizeRule({
      'name': 'Open a film app',
      'when': ['manual'],
      'then': [
        {
          'try': ['lamp.power=true', 'notify:opened'],
          'otherwise': ['notify:fallback'],
        },
        'notify:after',
      ],
    }, context: context);

    Future<List<String>> ran({required bool fails}) async {
      final effects = _NoEffects();
      if (fails) {
        effects.onInvoke = (_, _) => throw StateError('not installed');
      }
      final trace = await FlowRunner(
        FlowSpec.parse(compileRule(rule).flow),
        effects,
        clock: InstantFlowClock(DateTime(2026)),
      ).fire('when_0', {});
      expect(trace.outcome, RunOutcome.completed);
      return [for (final n in trace.nodes) '${n.nodeId}:${n.port}'];
    }

    test('a step that works skips otherwise', () async {
      expect(await ran(fails: false), [
        'when_0:out',
        'then_0_try_0:out',
        'then_0_try_1:out',
        'then_1:out',
      ]);
    });

    test('a step that fails runs otherwise instead of the rest', () async {
      expect(await ran(fails: true), [
        'when_0:out',
        'then_0_try_0:error',
        'then_0_otherwise_0:out',
        'then_1:out',
      ]);
    });

    test(
      'a nested try catches its own failure, and the outer goes on',
      () async {
        final nested = normalizeRule({
          'name': 'Nested',
          'when': ['manual'],
          'then': [
            {
              'try': [
                {
                  'try': ['lamp.power=true'],
                  'otherwise': ['notify:inner'],
                },
                'notify:outer rest',
              ],
              'otherwise': ['notify:outer fallback'],
            },
          ],
        }, context: context);
        final effects = _NoEffects()
          ..onInvoke = (_, _) => throw StateError('no answer');
        final trace = await FlowRunner(
          FlowSpec.parse(compileRule(nested).flow),
          effects,
          clock: InstantFlowClock(DateTime(2026)),
        ).fire('when_0', {});
        expect(
          [for (final n in trace.nodes) n.nodeId],
          [
            'when_0',
            'then_0_try_0_try_0',
            'then_0_try_0_otherwise_0',
            'then_0_try_1',
          ],
        );
      },
    );

    test('reads in plain words and validates', () {
      expect(issuesOf(rule), isEmpty);
      expect(
        const SentenceContext(names: {'lamp': 'Lamp'})
            .step((rule['then'] as List).first as Map<String, Object?>),
        'try Lamp power on then notify "opened", '
        'if that fails notify "fallback"',
      );
    });
  });

  group('repeat', () {
    Map<String, Object?> rule(Map<String, Object?> repeat) => normalizeRule({
      'name': 'Keep trying',
      'when': ['manual'],
      'then': [
        {'repeat': repeat},
        'notify:done',
      ],
    }, context: context);

    test('reads in plain words and compiles to a bounded repeat', () {
      final r = rule({
        'do': ['lamp.power=true'],
        'times': 10,
        'every': 3000,
        'until': 'lamp.power == true',
      });
      final flow = compileRule(r).flow;
      final node = nodeOf(flow, 'then_0');
      expect(node['type'], 'repeat');
      expect(node['config'], {
        'maxIterations': 10,
        'everyMs': 3000,
        'until': {
          'type': 'compare',
          'left': {'state': 'lamp.power'},
          'op': '==',
          'right': {'literal': true},
        },
      });
      expect(issuesOf(r), isEmpty);
      expect(
        const SentenceContext(names: {'lamp': 'Lamp'})
            .step((r['then'] as List).first as Map<String, Object?>),
        'repeat up to 10 times, every 3 s, until Lamp power is on: '
        'Lamp power on',
      );
    });

    test('stops once until holds, and goes on after', () async {
      final effects = _NoEffects();
      var sends = 0;
      effects.onInvoke = (device, capability) {
        if (++sends == 3) effects.deviceStates['lamp'] = {'power': true};
      };
      final trace = await FlowRunner(
        FlowSpec.parse(
          compileRule(
            rule({
              'do': ['lamp.power=true'],
              'until': 'lamp.power == true',
              'every': 1000,
            }),
          ).flow,
        ),
        effects,
        clock: InstantFlowClock(DateTime(2026)),
      ).fire('when_0', {});
      expect(trace.outcome, RunOutcome.completed);
      expect(sends, 3);
      expect(trace.nodes.last.nodeId, 'then_1');
    });

    test('runs times passes when nothing stops it', () async {
      final effects = _NoEffects();
      var sends = 0;
      effects.onInvoke = (_, _) => sends++;
      await FlowRunner(
        FlowSpec.parse(
          compileRule(
            rule({
              'do': ['lamp.power=true'],
              'times': 4,
            }),
          ).flow,
        ),
        effects,
        clock: InstantFlowClock(DateTime(2026)),
      ).fire('when_0', {});
      expect(sends, 4);
    });

    test('a repeat with no end, or too many passes, is refused', () {
      expect(
        issuesOf({
          'name': 'Forever',
          'when': ['manual'],
          'then': [
            {
              'repeat': {
                'do': ['lamp.power=true'],
              },
            },
          ],
        }),
        [
          {
            'path': 'then[0].repeat',
            'message': 'needs times, until, or both, so it always ends',
          },
        ],
      );
      expect(
        [
          for (final i in issuesOf({
            'name': 'Many',
            'when': ['manual'],
            'then': [
              {
                'repeat': {
                  'do': ['lamp.power=true'],
                  'times': 5000,
                },
              },
            ],
          }))
            i['path'],
        ],
        ['then[0].repeat.times'],
      );
    });
  });

  test('a dry run goes on past a waitFor', () async {
    final rule = normalizeRule({
      'name': 'Dry wait',
      'when': ['manual'],
      'then': [
        {
          'waitFor': {
            'on': 'jade.home',
            'change': {'to': true},
            'timeoutMs': 1000,
            'onTimeout': ['notify:late'],
          },
        },
        'notify:after',
      ],
    }, context: context);
    final trace = await FlowRunner(
      FlowSpec.parse(compileRule(rule).flow),
      _NoEffects(),
      clock: InstantFlowClock(DateTime(2026)),
    ).fire('when_0', {}, dryRun: true);
    expect(trace.outcome, RunOutcome.completed);
    expect(
      [for (final n in trace.nodes) '${n.nodeId}:${n.port}'],
      ['when_0:out', 'then_0:matched', 'then_1:out'],
    );
  });

  test('a thing that reports undeclared state takes any key', () {
    final registry = DriverRegistry.withBuiltIns();
    final zigbee = registry['zigbee2mqtt_device']!;
    final wiz = registry['philips_wiz_udp']!;
    expect(zigbee.reportsUndeclaredState, isTrue);
    expect(wiz.reportsUndeclaredState, isTrue);
    expect(registry['mqtt_switch']!.reportsUndeclaredState, isFalse);
    expect(registry['person']!.reportsUndeclaredState, isFalse);
    final drivers = {'btn': zigbee, 'lamp': wiz};
    final open = FlowReferences(
      devices: drivers.keys.toSet(),
      capabilityOf: (d, c) => drivers[d]?.capability(c),
      stateKeysOf: (t) => drivers[t]!.reportsUndeclaredState
          ? null
          : {
              for (final c in drivers[t]!.capabilities)
                ?stateKeyOf(c.stateJsonPath),
            },
    );
    final compiled = compileRule(
      normalizeRule({
        'name': 'Button',
        'when': ['btn.action', 'lamp.power'],
        'then': ['notify:x'],
      }),
      refs: open,
    );
    expect(validateFlow(FlowSpec.parse(compiled.flow), refs: open), isEmpty);
    expect(nodeOf(compiled.flow, 'when_0')['config'], {
      'thing': 'btn',
      'key': 'action',
      'change': <String, Object?>{},
    });
    expect(
      (nodeOf(compiled.flow, 'when_1')['config'] as Map)['key'],
      'state',
      reason: 'a capability still reads under its state key',
    );
  });
}

class _NoEffects implements FlowEffects {
  @override
  final Map<String, Object?> globals = {};

  @override
  final Map<String, Map<String, Object?>> deviceStates = {};

  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  void announce(Map<String, Object?> payload) {}

  void Function(String deviceId, String capabilityId)? onInvoke;

  @override
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    String? flowId,
  }) async {
    onInvoke?.call(deviceId, capabilityId);
    return null;
  }

  @override
  Future<void> runFlow(String flowId, Map<String, Object?> msg) async {}

  @override
  Future<void> setGlobal(String name, Object? value) async {}

  @override
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId, {
    String? flowId,
  }) async => null;
}
