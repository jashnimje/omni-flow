import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart'
    show clockOfDay, clockWordCommands, clockWords, hour12Arg, nextRunText;

import '../api/engine_client.dart';

/// Whether this phone shows a 12-hour clock ("7:30 PM"): its 24-hour
/// setting, which the engine's words and the app's own times both follow.
final hour12Provider = Provider<bool>((ref) => !_alwaysUse24HourFormat());

bool _alwaysUse24HourFormat() {
  try {
    return WidgetsBinding.instance.platformDispatcher.alwaysUse24HourFormat;
  } on Object {
    // No binding yet (a plain Dart test): the platform's own setting.
    return PlatformDispatcher.instance.alwaysUse24HourFormat;
  }
}

/// [hhmm] (`"19:30"`) as this phone reads the time.
String clockText(Ref ref, String hhmm) =>
    clockWords(hhmm, hour12: ref.read(hour12Provider));

/// [at]'s time of day as this phone reads the time.
String timeOfDayText(bool hour12, DateTime at) =>
    clockOfDay(at.toLocal(), hour12: hour12);

/// "today 7:30 PM" for an automation's next run, as this phone reads the
/// time.
String nextRunTextFor(bool hour12, DateTime at, {DateTime? now}) =>
    nextRunText(at, hour12: hour12, now: now);

/// Asks for 12-hour words ("7:30 PM") with every command whose words carry
/// a time, on a phone set to a 12-hour clock, so rules and sun times read
/// as the rest of the phone. The engine words 24 hours otherwise.
class ClockClient implements EngineClient {
  ClockClient(this.inner, {required this.hour12});

  final EngineClient inner;
  final bool hour12;

  @override
  Future<Map<String, Object?>> call(
    String command, [
    Map<String, Object?> args = const {},
  ]) => inner.call(
    command,
    hour12 &&
            clockWordCommands.contains(command) &&
            !args.containsKey(hour12Arg)
        ? {...args, hour12Arg: hour12}
        : args,
  );

  @override
  Stream<Map<String, Object?>> get events => inner.events;

  @override
  bool operator ==(Object other) =>
      other is ClockClient && other.inner == inner && other.hour12 == hour12;

  @override
  int get hashCode => Object.hash(inner, hour12);
}
