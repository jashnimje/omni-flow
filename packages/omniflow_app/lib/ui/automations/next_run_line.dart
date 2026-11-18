import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show AutomationSummary;
import '../../state/clock.dart' show hour12Provider, nextRunTextFor;
import '../design/design.dart';

/// "today 18:30", "tomorrow 06:30", "Mon 07:00" within a week, else
/// "3 Dec 07:00", or with [hour12] "today 6:30 PM".
String nextRunWords(DateTime at, {DateTime? now, bool hour12 = false}) =>
    nextRunTextFor(hour12, at, now: now);

/// "Next: today 18:30" on an automation's card, while it is on and a time,
/// sun or interval trigger has a next run.
class NextRunLine extends ConsumerWidget {
  const NextRunLine(
    this.automation, {
    super.key,
    required this.enabled,
    this.color,
  });

  final AutomationSummary automation;
  final bool enabled;

  /// The words' colour, the muted caption by default. A colour card
  /// passes its white.
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = automation;
    final next = a.nextRun;
    if (next == null || !enabled || a.needsApproval) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: OmniSpace.xs),
      child: Text(
        'Next: ${nextRunWords(next, hour12: ref.watch(hour12Provider))}',
        key: ValueKey('next-run-${a.id}'),
        style: color == null
            ? OmniText.captionOf(context)
            : OmniText.caption.copyWith(color: color),
      ),
    );
  }
}
