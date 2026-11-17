import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../design/automation_look.dart';
import '../design/design.dart';
import 'automations_state.dart';
import 'review_page.dart';
import 'scenes.dart' show automationIconFor;

/// Opens Waiting for approval on top of the page [context] is in, so Back
/// returns there.
Future<void> openWaitingForApproval(BuildContext context) =>
    Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => const WaitingPage()));

/// Waiting for approval: every automation an agent made that has not run
/// yet, each opening its review. A list of its own, so the way here and
/// the way back stay where the person came from.
class WaitingPage extends ConsumerWidget {
  const WaitingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(automationsProvider);
    final waiting = [
      for (final a in async.value ?? const <AutomationSummary>[])
        if (a.needsApproval) a,
    ];
    return ListPage(
      title: 'Waiting for approval',
      state: OmniLoad.of(
        async,
        isEmpty: (_) => waiting.isEmpty,
        onRetry: () => ref.read(automationsProvider.notifier).retry(),
        error: 'OmniFlow did not answer, so the list cannot show.',
      ),
      empty: const OmniEmptyState(
        key: ValueKey('waiting-empty'),
        icon: OmniIcons.agent,
        title: 'Nothing waiting',
        message:
            'An automation an agent makes waits here until you approve it. '
            'It does not run before that.',
      ),
      children: (context) => [
        for (final a in waiting)
          OmniListRow(
            key: ValueKey('waiting-${a.id}'),
            leading: AutomationBadge(
              icon: automationIconFor(a),
              color: a.color,
              size: 32,
            ),
            title: a.name,
            subtitle: a.sentence.isEmpty
                ? 'Made by an agent'
                : a.sentence.map((p) => p.text).join(),
            subtitleLines: 2,
            trailing: const StatusDot(StatusKind.warning),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => ReviewPage(id: a.id)),
            ),
          ),
      ],
    );
  }
}
