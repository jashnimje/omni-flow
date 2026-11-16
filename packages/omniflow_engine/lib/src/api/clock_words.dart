import 'dart:async';

/// The argument a client sends with a command to say how its person reads
/// the time: `true` for a 12-hour clock ("7:30 PM"). Without it, or with
/// `false`, the words of that command read 24 hours ("19:30"). Each call
/// says it for itself, so two phones on one hub each read their own.
const hour12Arg = 'hour12';

const _hour12Key = #omniflowHour12;

/// Whether the command being handled asked for a 12-hour clock.
bool get callHour12 => Zone.current[_hour12Key] == true;

/// Runs [body] with [callHour12] set to [hour12].
R withHour12<R>(bool hour12, R Function() body) =>
    runZoned(body, zoneValues: {_hour12Key: hour12});

/// The commands whose words carry a time of day: a client sends
/// [hour12Arg] with these. Any command accepts it.
const clockWordCommands = {
  'automation.list',
  'automation.get',
  'automation.diagram',
  'automation.dry_run',
  'automation.skips',
  'automation.removed',
  'automation.log',
  'rule.words',
  'rule.parse',
  'scene.list',
  'suggest.list',
  'flow.dryRun',
  'command.interpret',
};

/// [hhmm] (`"19:30"`) as the person reads the time: `"7:30 PM"` on a
/// 12-hour clock, unchanged on a 24-hour one. Text that is not `HH:MM`
/// (a template token) is returned as it is.
String clockWords(Object? hhmm, {required bool hour12}) {
  final text = '$hhmm';
  if (!hour12) return text;
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text.trim());
  if (m == null) return text;
  final hour = int.parse(m.group(1)!);
  final minute = m.group(2)!;
  if (hour > 23 || int.parse(minute) > 59) return text;
  final shown = hour % 12 == 0 ? 12 : hour % 12;
  return '$shown:$minute ${hour < 12 ? 'AM' : 'PM'}';
}

/// [at]'s time of day as [clockWords] says it.
String clockOfDay(DateTime at, {required bool hour12}) => clockWords(
  '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
  hour12: hour12,
);

/// When an automation runs next, in words: "today 7:30 PM" (or "today
/// 19:30"), "tomorrow 6:30 AM", "Mon 7:00 AM" within a week, else "3 Dec
/// 7:00 AM". [now] is the clock to count days from.
String nextRunText(DateTime at, {required bool hour12, DateTime? now}) {
  final t = at.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  // Calendar days as UTC dates: local midnights are 23 or 25 hours apart
  // across a clock change.
  final days = DateTime.utc(
    t.year,
    t.month,
    t.day,
  ).difference(DateTime.utc(n.year, n.month, n.day)).inDays;
  final time = clockOfDay(t, hour12: hour12);
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return switch (days) {
    <= 0 => 'today $time',
    1 => 'tomorrow $time',
    < 7 => '${weekdays[t.weekday - 1]} $time',
    _ => '${t.day} ${months[t.month - 1]} $time',
  };
}
