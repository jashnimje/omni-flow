import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart' show RunRecord;
import 'package:omniflow_app/ui/automations/automations.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

/// automation.get for the agent's "Movie night".
Map<String, Object?> _movieNight({bool approved = false}) => {
  'ok': true,
  'id': 'movie_night',
  'name': 'Movie night',
  'source': 'rule',
  'approved': approved,
  'highRisk': false,
  'revision': 'r-movie',
  'spec': {'name': 'Movie night'},
  'flow': {
    'nodes': [
      {'id': 'when', 'type': 'on', 'label': 'When the TV opens Netflix'},
      {
        'id': 'lamp',
        'type': 'device_capability',
        'label': 'desk lamp 20%',
        'config': {
          'deviceId': 'desk_lamp',
          'capabilityId': 'brightness',
          'params': {'value': 20},
        },
      },
      {
        'id': 'bulb',
        'type': 'device_capability',
        'label': 'hall bulb off',
        'config': {
          'deviceId': 'hall_bulb',
          'capabilityId': 'power',
          'params': {'value': false},
        },
      },
    ],
  },
};

Map<String, Object?> _run(
  String id, {
  required bool ok,
  bool dryRun = false,
  DateTime? at,
}) {
  final start = at ?? DateTime.now();
  return {
    'run': id,
    'flow': 'arrive_home',
    'dryRun': dryRun,
    'outcome': ok ? 'completed' : 'failed',
    'startedAt': start.toIso8601String(),
    'finishedAt': start
        .add(const Duration(milliseconds: 1400))
        .toIso8601String(),
    'nodes': [
      {'node': 'when', 'type': 'on', 'port': 'out'},
      {'node': 'tv', 'type': 'device_capability', 'port': 'out'},
      {
        'node': 'bulb',
        'type': 'device_capability',
        'port': ok ? 'out' : 'error',
        if (!ok) 'error': 'Hall bulb timed out',
      },
    ],
  };
}

void main() {
  late FakeEngine engine;

  setUp(() => engine = automationsEngine());

  group('review', () {
    testWidgets('shows who made it, its sentence, and what it can and '
        'cannot do', (tester) async {
      engine.answers['automation.get'] = _movieNight();
      await pumpPushed(tester, engine, const ReviewPage(id: 'movie_night'));
      expect(find.text('Review "Movie night"'), findsOneWidget);
      expect(
        find.text(
          'Made by Claude. It runs only after you approve this exact version.',
        ),
        findsOneWidget,
      );
      expect(find.text('When the TV opens Netflix'), findsOneWidget);
      expect(find.text('Control Desk lamp and Hall bulb'), findsOneWidget);
      expect(find.text('Read Living room TV\'s state'), findsOneWidget);
      expect(find.byKey(const ValueKey('can-commands')), findsNothing);
      expect(
        find.textContaining(
          'run shell commands, install apps or change settings',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Approve sends exactly the revision shown', (tester) async {
      engine.answers['automation.get'] = _movieNight();
      await pumpPushed(tester, engine, const ReviewPage(id: 'movie_night'));
      await tapKey(tester, 'review-approve');
      expect(engine.callsOf('automation.approve').single.$2, {
        'id': 'movie_night',
        'revision': 'r-movie',
      });
      expect(find.byType(ReviewPage), findsNothing);
      expect(
        find.text('Approved Movie night. It runs on its own now.'),
        findsOneWidget,
      );
    });

    testWidgets('a changed automation is read again before it can be '
        'approved', (tester) async {
      engine.answers['automation.get'] = _movieNight();
      engine.answers['automation.approve'] = {
        'ok': false,
        'error': {'type': 'conflict', 'message': 'changed since revision'},
      };
      await pumpPushed(tester, engine, const ReviewPage(id: 'movie_night'));
      await tapKey(tester, 'review-approve');
      expect(find.byType(ReviewPage), findsOneWidget);
      expect(
        find.textContaining('It changed since you opened it'),
        findsOneWidget,
      );
      expect(engine.callsOf('automation.get').length, 2);
    });

    testWidgets('Reject asks first, says what is lost, and removes it', (
      tester,
    ) async {
      engine.answers['automation.get'] = _movieNight();
      await pumpPushed(tester, engine, const ReviewPage(id: 'movie_night'));
      await tapKey(tester, 'review-reject');
      expect(find.text('Reject Movie night?'), findsOneWidget);
      expect(
        find.textContaining('It is deleted and never runs'),
        findsOneWidget,
      );
      await tapKey(tester, 'confirm-cancel');
      expect(engine.callsOf('automation.remove'), isEmpty);
      await tapKey(tester, 'review-reject');
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('automation.remove').single.$2, {
        'id': 'movie_night',
      });
      expect(find.byType(ReviewPage), findsNothing);
    });

    testWidgets('a high-risk automation says it runs commands', (tester) async {
      final flow = _movieNight()..['highRisk'] = true;
      ((flow['flow'] as Map)['nodes'] as List).add({
        'id': 'sh',
        'type': 'device_capability',
        'config': {'deviceId': 'living_tv', 'capabilityId': 'shell'},
      });
      engine.answers['automation.get'] = flow;
      await pumpPushed(tester, engine, const ReviewPage(id: 'movie_night'));
      expect(find.text('Run commands on Living room TV'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('review-cannot'))).data,
        'control any device not listed above',
      );
    });

    testWidgets('one already approved has nothing to decide', (tester) async {
      engine.answers['automation.get'] = _movieNight(approved: true);
      await pumpPushed(tester, engine, const ReviewPage(id: 'movie_night'));
      expect(find.byKey(const ValueKey('review-approved')), findsOneWidget);
      expect(find.byKey(const ValueKey('review-approve')), findsNothing);
    });

    testWidgets('one that is gone says so', (tester) async {
      engine.answers['automation.get'] = {
        'ok': false,
        'error': {'type': 'not_found', 'message': 'no automation movie_night'},
      };
      await pumpPushed(tester, engine, const ReviewPage(id: 'movie_night'));
      expect(find.text('This automation is gone'), findsOneWidget);
      expect(find.byKey(const ValueKey('review-approve')), findsNothing);
    });
  });

  group('test run and history', () {
    testWidgets('the stored automation is dry-run, then its last runs open '
        'step by step', (tester) async {
      engine.answers['automation.dry_run'] = {
        'ok': true,
        'run': _run('dry', ok: true, dryRun: true),
      };
      engine.answers['automation.get'] = {
        'ok': true,
        'name': 'Arrive home',
        'flow': {
          'nodes': [
            {'id': 'when', 'label': 'When I get home'},
            {'id': 'tv', 'label': 'TV · power on'},
            {'id': 'bulb', 'label': 'Hall bulb · on, 70%'},
          ],
        },
      };
      engine.answers['automation.log'] = {
        'ok': true,
        'runs': [
          _run('r2', ok: true),
          _run(
            'r1',
            ok: false,
            at: DateTime.now().subtract(const Duration(days: 1)),
          ),
        ],
      };
      await pumpPushed(
        tester,
        engine,
        const TestRunPage(name: 'Arrive home', id: 'arrive_home'),
      );
      expect(find.text('Arrive home · test'), findsOneWidget);
      expect(engine.callsOf('automation.dry_run').single.$2, {
        'id': 'arrive_home',
      });
      expect(engine.callsOf('automation.log').single.$2, {
        'id': 'arrive_home',
        'limit': 20,
      });
      expect(find.text('Last runs'), findsOneWidget);
      expect(find.textContaining('2 steps · 1.4 s'), findsOneWidget);
      expect(find.text('Hall bulb timed out'), findsOneWidget);
      expect(find.textContaining('Yesterday'), findsOneWidget);
      await tapKey(tester, 'run-1');
      expect(find.byType(RunPage), findsOneWidget);
      expect(
        find.textContaining('This run failed: Hall bulb timed out'),
        findsOneWidget,
      );
      expect(find.text('Hall bulb · on, 70%'), findsOneWidget);
    });

    testWidgets('Run it now runs it for real and opens that run', (
      tester,
    ) async {
      engine.answers['automation.dry_run'] = {
        'ok': true,
        'run': _run('dry', ok: true, dryRun: true),
      };
      engine.answers['automation.log'] = {'ok': true, 'runs': []};
      engine.answers['automation.run'] = {
        'ok': true,
        'runs': [_run('now', ok: true)],
      };
      await pumpPushed(
        tester,
        engine,
        const TestRunPage(name: 'Arrive home', id: 'arrive_home'),
      );
      await tapKey(tester, 'run-now');
      expect(engine.callsOf('automation.run').single.$2, {'id': 'arrive_home'});
      expect(find.byType(RunPage), findsOneWidget);
    });

    testWidgets('a rule not saved yet says to save it to run it', (
      tester,
    ) async {
      await pumpPushed(
        tester,
        engine,
        TestRunPage(
          name: 'New rule',
          dryRun: RunRecord.fromJson(_run('dry', ok: true, dryRun: true)),
        ),
      );
      expect(find.byKey(const ValueKey('save-to-run')), findsOneWidget);
      expect(find.byKey(const ValueKey('run-now')), findsNothing);
    });

    testWidgets('an automation that never ran says so', (tester) async {
      engine.answers['automation.log'] = {'ok': true, 'runs': []};
      await pumpPushed(
        tester,
        engine,
        const TestRunPage(name: 'Arrive home', id: 'arrive_home'),
      );
      expect(find.byKey(const ValueKey('no-runs')), findsOneWidget);
    });

    testWidgets('a run log that does not load says so with Try again', (
      tester,
    ) async {
      engine.throwOn.add('automation.log');
      await pumpPushed(
        tester,
        engine,
        const TestRunPage(name: 'Arrive home', id: 'arrive_home'),
      );
      expect(find.textContaining('The run log did not load'), findsOneWidget);
      engine.throwOn.clear();
      engine.answers['automation.log'] = {'ok': true, 'runs': []};
      await tapText(tester, 'Try again');
      expect(find.byKey(const ValueKey('no-runs')), findsOneWidget);
    });

    testWidgets('a run named by a notification is found in the log', (
      tester,
    ) async {
      engine.answers['automation.log'] = {
        'ok': true,
        'runs': [_run('r1', ok: false)],
      };
      await pumpPushed(
        tester,
        engine,
        const RunPage(automationId: 'arrive_home', runId: 'r1'),
      );
      expect(find.textContaining('This run failed'), findsOneWidget);
      expect(find.text('Hall bulb timed out'), findsOneWidget);
    });

    testWidgets('a run gone from the log says so', (tester) async {
      engine.answers['automation.log'] = {'ok': true, 'runs': []};
      await pumpPushed(
        tester,
        engine,
        const RunPage(automationId: 'arrive_home', runId: 'old'),
      );
      expect(find.byKey(const ValueKey('run-missing')), findsOneWidget);
    });
  });
}
