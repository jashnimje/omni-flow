import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/home.dart';

/// Answers core API commands from canned data and records every call.
/// A command with no canned answer gets `{"ok": true}`.
class FakeEngine implements EngineClient {
  final calls = <(String, Map<String, Object?>)>[];
  final eventsOut = StreamController<Map<String, Object?>>.broadcast();

  /// Commands whose call throws instead of answering.
  final throwOn = <String>{};

  /// Runs before a command is answered, to change what later calls see.
  void Function(String command, Map<String, Object?> args)? onCall;

  /// How long each answer takes, for slow-engine tests.
  Duration? delay;

  /// Answers that depend on the args, ahead of [answers].
  final answerers =
      <String, Map<String, Object?> Function(Map<String, Object?> args)>{};

  final answers = <String, Map<String, Object?>>{
    'device.list': {
      'ok': true,
      'devices': [lamp()],
    },
    'flow.list': {
      'ok': true,
      'flows': [
        {
          'id': 'evening',
          'name': 'Evening desk',
          'enabled': true,
          'approved': true,
          'loaded': true,
        },
        {
          'id': 'wake_mac',
          'name': 'Wake the Mac',
          'enabled': true,
          'approved': false,
          'loaded': false,
        },
      ],
    },
    'flow.cards': {
      'ok': true,
      'tree': true,
      'when': [
        {'node': 'trig', 'type': 'zone_change', 'label': 'Arrived at desk'},
      ],
      'then': [
        {
          'kind': 'if',
          'node': 'cond',
          'type': 'all_of',
          'label': 'Evening',
          'then': [
            {
              'kind': 'step',
              'node': 'lamp',
              'type': 'device_capability',
              'label': 'Lamp warm',
            },
          ],
          'else': [],
        },
      ],
    },
    'command.interpret': {
      'ok': true,
      'kind': 'call',
      'command': 'device.invoke',
      'args': {
        'id': 'desk_lamp',
        'capability': 'brightness',
        'params': {'value': 50},
      },
      'summary': 'Desk lamp: 50%',
    },
  };

  static Map<String, Object?> lamp({
    Map<String, Object?> state = const {'state': false, 'dimming': 30},
    List<Map<String, Object?>> extra = const [],
  }) => {
    'id': 'desk_lamp',
    'name': 'Desk lamp',
    'driver': 'philips_wiz_udp',
    'host': '192.168.1.40',
    'room': 'Study',
    'settings': const <String, Object?>{},
    'state': state,
    'capabilities': [
      {
        'id': 'power',
        'type': 'toggle',
        'label': 'Power',
        'stateKey': 'state',
        'params': {
          'value': {'type': 'boolean'},
        },
      },
      {
        'id': 'brightness',
        'type': 'level',
        'label': 'Brightness',
        'stateKey': 'dimming',
        'params': {
          'value': {'type': 'number', 'min': 10, 'max': 100, 'unit': '%'},
        },
      },
      {'id': 'wake', 'type': 'action', 'label': 'Wake', 'params': {}},
      ...extra,
    ],
  };

  set devices(List<Map<String, Object?>> devices) =>
      answers['device.list'] = {'ok': true, 'devices': devices};

  @override
  Future<Map<String, Object?>> call(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    calls.add((command, args));
    if (delay case final delay?) await Future<void>.delayed(delay);
    onCall?.call(command, args);
    if (throwOn.contains(command)) throw StateError('$command broke');
    return answerers[command]?.call(args) ??
        answers[command] ??
        const {'ok': true};
  }

  @override
  Stream<Map<String, Object?>> get events => eventsOut.stream;

  List<(String, Map<String, Object?>)> callsOf(String command) =>
      calls.where((c) => c.$1 == command).toList();
}

Future<void> pumpApp(
  WidgetTester tester,
  FakeEngine engine, {
  String? hubError,
  List<Override> overrides = const [],
}) async {
  // A phone-wide screen (412 dp), tall enough that the Add device button
  // does not cover the controls under test.
  tester.view.physicalSize = const Size(1236, 4800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        engineClientProvider.overrideWithValue(engine),
        hubErrorProvider.overrideWithValue(hubError),
        ...overrides,
      ],
      child: const OmniFlowApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the Add page, then the sheet that adds a device by its driver.
Future<void> openDriverSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('add-device')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('add-by-driver')));
  await tester.pumpAndSettle();
}

/// Opens a device's menu and picks [item].
Future<void> openDeviceMenu(
  WidgetTester tester,
  String deviceId,
  String item,
) async {
  await tester.tap(find.byKey(ValueKey('device-menu-$deviceId')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}
