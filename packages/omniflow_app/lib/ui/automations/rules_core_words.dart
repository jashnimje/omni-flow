import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show alignedWords;

import '../../rules/rule_spec.dart';

/// The words of the people triggers and conditions, the engine starting
/// and an interval lined up on the clock. The aligned words come from the
/// engine, so the app and the engine say the same.
const engineStartIcon = Symbols.power_settings_new_rounded;

String peopleTriggerText(PeopleTrigger t) =>
    t.kind == PeopleTrigger.firstArrives
    ? 'The first person gets home'
    : 'The last person leaves';

String peopleConditionText(PeopleCondition c) =>
    c.kind == PeopleCondition.allAway ? 'Everyone is away' : 'Anyone is home';

/// "Every 10 min", "Every hour at :05", "Every 15 min from 09:00 to 18:00".
String intervalText(IntervalTrigger t) {
  final aligned = t.offsetSeconds > 0 || t.between != null;
  final every = aligned && t.seconds == 3600
      ? 'Every hour'
      : 'Every ${durationText(t.seconds * 1000)}';
  if (!aligned) return every;
  return '$every ${alignedWords(t.seconds, t.offsetSeconds, t.between)}';
}

/// The icon a held trigger adds to its row.
const IconData heldIcon = Symbols.timer_rounded;
