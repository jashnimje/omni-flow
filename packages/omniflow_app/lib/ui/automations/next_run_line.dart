import 'package:flutter/material.dart';

import '../../api/engine_calls.dart' show AutomationSummary;
import '../design/design.dart';

/// "today 18:30", "tomorrow 06:30", "Mon 07:00" within a week, else
/// "3 Dec 07:00".
String nextRunWords(DateTime at, {DateTime? now}) {
  final t = at.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  // Calendar days as UTC dates: local midnights are 23 or 25 hours apart
  // across a clock change.
  final days = DateTime.utc(
    t.year,
    t.month,
    t.day,
  ).difference(DateTime.utc(n.year, n.month, n.day)).inDays;
  final time =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
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

/// "Next: today 18:30" on an automation's card, while it is on and a time,
/// sun or interval trigger has a next run.
class NextRunLine extends StatelessWidget {
  const NextRunLine(this.automation, {super.key, required this.enabled});

  final AutomationSummary automation;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final a = automation;
    final next = a.nextRun;
    if (next == null || !enabled || a.needsApproval) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        'Next: ${nextRunWords(next)}',
        key: ValueKey('next-run-${a.id}'),
        style: OmniText.caption,
      ),
    );
  }
}
