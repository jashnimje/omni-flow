import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_app/service/phone_actions.dart';
import 'package:omniflow_app/service/phone_inputs.dart';
import 'package:omniflow_app/api/engine_calls.dart' show Json;
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/form_parts.dart' show ParamControls;
import 'package:omniflow_app/ui/devices/capability_control.dart'
    show ParamsForm;
import 'package:omniflow_app/ui/automations/phone_words.dart';

import 'automations_fixtures.dart';
import 'design_test.dart' show pumpDesign;
import 'fake_engine.dart';
import 'service_fake_engine.dart';

class _Hands implements PhoneHands {
  final ran = <(String, Map<String, Object?>)>[];
  final watched = <Map<String, Object?>>[];
  final asked = <List<String>>[];
  Map<String, Object?> answer = const {'ok': true};
  List<Map<String, Object?>> events = const [];

  @override
  Future<Map<String, Object?>> run(
    String action,
    Map<String, Object?> params,
  ) async {
    ran.add((action, params));
    return answer;
  }

  @override
  Future<void> watch(Map<String, Object?> watch) async => watched.add(watch);

  @override
  Future<List<Map<String, Object?>>> calendar(List<String> words) async {
    asked.add(words);
    return events;
  }
}

final _phone = <String, Object?>{
  'id': 'phone',
  'name': 'This phone',
  'driver': 'phone',
  'state': const <String, Object?>{},
  'capabilities': const [],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('phone actions in the service', () {
    late ServiceFakeEngine engine;
    late _Hands hands;
    late PhoneActionRunner runner;

    setUp(() {
      engine = ServiceFakeEngine();
      hands = _Hands();
      engine.answers['phone.ready'] = {
        'ok': true,
        'phone': 'jade_phone',
        'watch': {
          'shake': true,
          'calendarWords': ['gym'],
        },
      };
      runner = PhoneActionRunner(engine, hands: hands);
    });

    tearDown(() => runner.stop());

    Future<void> ask(String phone, String action, [Map? params]) async {
      engine.eventsOut.add({
        'event': 'phone.action',
        'phone': phone,
        'requestId': 'r-$action',
        'action': action,
        'params': ?params,
      });
      await pumpEventQueue();
    }

    test(
      'says ready, turns on what the automations use, and keeps its id',
      () async {
        runner.start();
        await pumpEventQueue();
        expect(engine.argsOf('phone.ready'), hasLength(1));
        expect(runner.phone, 'jade_phone');
        expect(hands.watched.single['shake'], isTrue);
        expect(hands.asked.single, ['gym']);
        await runner.sayReady();
        // Sent on every ready, so a permission granted later in Settings
        // starts the watch: the phone side registers only what is missing.
        expect(hands.watched, hasLength(2));
        expect(hands.watched.last, hands.watched.first);
        expect(hands.asked, hasLength(1), reason: 'the calendar is not stale');
      },
    );

    test('acts only on requests for its own phone, and answers each', () async {
      runner.start();
      await pumpEventQueue();
      await ask('sam_phone', 'vibrate');
      expect(hands.ran, isEmpty);
      await ask('jade_phone', 'speak', {'text': 'Hello'});
      expect(hands.ran.single.$1, 'speak');
      expect(hands.ran.single.$2, {'text': 'Hello'});
      expect(engine.argsOf('phone.actionDone').single, {
        'requestId': 'r-speak',
        'ok': true,
      });
      hands.answer = const {
        'ok': false,
        'error': 'This phone has no torch',
        'errorType': 'device_error',
      };
      await ask('jade_phone', 'torch', {'value': true});
      expect(engine.argsOf('phone.actionDone').last, {
        'requestId': 'r-torch',
        'ok': false,
        'error': 'This phone has no torch',
        'errorType': 'device_error',
      });
    });

    test('before it said ready it answers as the default phone', () async {
      engine.answers['phone.ready'] = {'ok': false};
      runner.start();
      await pumpEventQueue();
      await ask('phone', 'vibrate');
      expect(hands.ran.single.$1, 'vibrate');
    });

    test(
      'a matching calendar event is reported when it starts and ends',
      () async {
        final now = DateTime.now();
        hands.events = [
          {
            'words': 'gym',
            'title': 'Gym with Sam',
            'begin': now
                .add(const Duration(milliseconds: 40))
                .millisecondsSinceEpoch,
            'end': now
                .add(const Duration(milliseconds: 80))
                .millisecondsSinceEpoch,
          },
          {
            'words': 'gym',
            'title': 'Old gym',
            'begin': now
                .subtract(const Duration(hours: 2))
                .millisecondsSinceEpoch,
            'end': now
                .subtract(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          },
        ];
        runner.start();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(engine.argsOf('phone.calendar'), [
          {'event': 'started', 'words': 'gym', 'title': 'Gym with Sam'},
          {'event': 'ended', 'words': 'gym', 'title': 'Gym with Sam'},
        ]);
      },
    );

    test('stopping turns every sensor off', () async {
      runner.start();
      await pumpEventQueue();
      await runner.stop();
      expect(hands.watched.last, isEmpty);
      await ask('jade_phone', 'vibrate');
      expect(hands.ran, isEmpty);
    });
  });

  group('the newer phone readings', () {
    late ServiceFakeEngine engine;
    late StreamController<Object?> readings;
    late PhoneInputs inputs;

    setUp(() {
      engine = ServiceFakeEngine();
      readings = StreamController<Object?>();
      inputs = PhoneInputs(engine, readings: readings.stream)..start();
    });

    tearDown(() => inputs.stop());

    Future<void> send(Object? reading) async {
      readings.add(reading);
      await pumpEventQueue();
    }

    test('each becomes its phone command, repeats dropped', () async {
      await send({'kind': 'alarm', 'atMs': 1794470400000});
      await send({'kind': 'alarm', 'atMs': 1794470400000});
      await send({'kind': 'alarm'});
      await send({'kind': 'call', 'state': 'ringing'});
      await send({'kind': 'call', 'state': 'dialling'});
      await send({
        'kind': 'media',
        'playing': true,
        'package': 'com.spotify.music',
        'label': 'Spotify',
        'title': 'A song',
      });
      await send({'kind': 'media', 'playing': true});
      await send({'kind': 'shake'});
      await send({'kind': 'face_down', 'on': true});
      await send({'kind': 'face_down', 'on': true});
      await send({'kind': 'headphones', 'plugged': false});
      await send({'kind': 'boot'});
      await send({'kind': 'package', 'package': 'com.x', 'updated': true});
      await send({'kind': 'package'});
      expect(engine.argsOf('phone.alarm'), [
        {'at': '2026-11-12T08:00:00.000Z'},
        <String, Object?>{},
      ]);
      expect(engine.argsOf('phone.call'), [
        {'state': 'ringing'},
      ]);
      expect(engine.argsOf('phone.media'), [
        {
          'playing': true,
          'package': 'com.spotify.music',
          'label': 'Spotify',
          'title': 'A song',
        },
      ]);
      expect(engine.argsOf('phone.shake'), hasLength(1));
      expect(engine.argsOf('phone.faceDown'), [
        {'on': true},
      ]);
      expect(engine.argsOf('phone.headphones'), [
        {'plugged': false},
      ]);
      expect(engine.argsOf('phone.boot'), hasLength(1));
      expect(engine.argsOf('phone.package'), [
        {'package': 'com.x', 'updated': true},
      ]);
    });
  });

  group('words', () {
    OnTrigger on(String key, [Map<String, Object?>? match]) =>
        OnTrigger(thing: 'phone', key: key, mode: OnMode.event, match: match);

    test('the newer triggers read plainly', () {
      expect(
        phoneMoreTriggerText(on('alarm_soon', {'minutes': 20})),
        '20 min before my next alarm',
      );
      expect(phoneMoreTriggerText(on('call_ringing')), 'A call rings');
      expect(
        phoneMoreTriggerText(
          on('media_started', {'package': 'com.spotify.music'}),
        ),
        'Spotify starts playing',
      );
      expect(
        phoneMoreTriggerText(on('calendar_ended', {'words': 'gym'})),
        'A calendar event with "gym" ends',
      );
      expect(
        phoneMoreTriggerText(
          OnTrigger(thing: 'phone', key: 'face_down', to: true, hasTo: true),
        ),
        'The phone is put face down',
      );
      expect(phoneMoreTriggerText(on('app_opened')), isNull);
      expect(phoneMoreTriggerIcon('shaken'), isNotNull);
    });

    test('the phone actions read plainly', () {
      expect(phoneStepWhat('speak', {'text': 'Hi'}), 'say "Hi"');
      expect(phoneStepWhat('torch', {'value': true}), 'torch on');
      expect(phoneStepWhat('media', {'key': 'next'}), 'next track');
      expect(phoneStepWhat('set_timer', {'minutes': 90}), 'set a 90 min timer');
      expect(phoneStepWhat('set_timer', {'minutes': 120}), 'set a 2 h timer');
      expect(
        phoneStepWhat('open_link', {'url': 'https://example.com/a'}),
        'open example.com',
      );
      expect(phoneStepWhat('power', const {}), isNull);
    });
  });

  group('the phone page', () {
    testWidgets('Open an app names the app and picks it from "Choose an '
        'app", not a raw Package field', (tester) async {
      Json? sent;
      await pumpDesign(
        tester,
        SingleChildScrollView(
          child: ParamsForm(
            label: 'Open an app',
            heading: false,
            params: const {
              'package': {'type': 'string'},
            },
            choices: {
              'package': () async => [
                (value: 'com.netflix.mediaclient', label: 'Netflix'),
              ],
            },
            onSubmit: (values) async {
              sent = values;
              return true;
            },
          ),
        ),
      );
      expect(find.text('App'), findsOneWidget);
      expect(find.text('Package'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('param-package-pick')));
      await tester.pumpAndSettle();
      expect(find.text('Choose an app'), findsOneWidget);
      await tester.tap(find.text('Netflix'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('params-run-Open an app')));
      await tester.pumpAndSettle();
      expect(sent, {'package': 'com.netflix.mediaclient'});
    });

    test('param fields read as words', () {
      expect(ParamControls.labelOf('url'), 'Link');
      expect(ParamControls.labelOf('key'), 'Button');
      expect(ParamControls.labelOf('phoneMac'), 'Phone MAC address');
      expect(ParamControls.labelOf('long_press'), 'Long press');
      expect(ParamControls.labelOf('minutes'), 'Minutes');
      expect(ParamControls.choiceTitleOf('package'), 'Choose an app');
    });
  });

  group('the editor', () {
    late FakeEngine engine;

    setUp(() {
      engine = automationsEngine()..devices = [...household(), _phone];
    });

    testWidgets('offers the newer phone triggers and saves them', (
      tester,
    ) async {
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(
          initial: {
            'name': 'Wake light',
            'when': [],
            'then': [
              {'wait': 1000},
            ],
          },
        ),
      );
      await tapAdd(tester, 'Add trigger');
      await tapKey(tester, 'category-Calls, media and more');
      for (final key in [
        'pick-phone-alarm',
        'pick-phone-call',
        'pick-phone-media',
        'pick-phone-calendar',
        'pick-phone-shake',
        'pick-phone-facedown',
        'pick-phone-headphones',
        'pick-phone-boot',
        'pick-phone-install',
      ]) {
        await tester.scrollUntilVisible(
          find.byKey(ValueKey(key)),
          200,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('pick-phone-alarm')),
        -200,
        scrollable: find.byType(Scrollable).last,
      );
      await tapKey(tester, 'pick-phone-alarm');
      await tester.enterText(
        find.byKey(const ValueKey('phone-alarm-minutes')),
        '30',
      );
      await tester.pump();
      await tapKey(tester, 'form-done');
      expect(find.text('30 min before my next alarm'), findsOneWidget);
      await tapKey(tester, 'rule-save');
      expect(savedSpec(engine)['when'], [
        {
          'on': 'phone.alarm_soon',
          'event': true,
          'match': {'minutes': 30},
        },
      ]);
    });
  });
}
