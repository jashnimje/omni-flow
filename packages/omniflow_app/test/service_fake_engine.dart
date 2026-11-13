import 'dart:async';

import 'package:omniflow_app/api/engine_client.dart';

/// A minimal engine for the service tests: canned answers, recorded calls
/// and an event stream. It imports nothing from the UI, so these tests
/// build on their own.
class ServiceFakeEngine implements EngineClient {
  final calls = <(String, Map<String, Object?>)>[];
  final answers = <String, Map<String, Object?>>{};
  final throwOn = <String>{};
  final eventsOut = StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<Map<String, Object?>> call(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    calls.add((command, args));
    if (throwOn.contains(command)) throw StateError('$command failed');
    return answers[command] ?? {'ok': true};
  }

  @override
  Stream<Map<String, Object?>> get events => eventsOut.stream;

  List<Map<String, Object?>> argsOf(String command) => [
    for (final c in calls)
      if (c.$1 == command) c.$2,
  ];
}
