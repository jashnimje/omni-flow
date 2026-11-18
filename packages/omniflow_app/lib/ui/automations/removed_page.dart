import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/clock.dart' show hour12Provider;
import '../../state/providers.dart';
import '../design/design.dart';
import 'automations_state.dart';
import 'dialogs.dart' show whenInline;

/// The automations removed lately, newest first, from automation.removed.
final removedAutomationsProvider = FutureProvider.autoDispose<List<Json>>(
  (ref) async =>
      (await ref.watch(engineApiProvider).removedAutomations()).or(const []),
);

/// How many days [keptUntil] is away, counting a part day as a day.
int daysLeft(DateTime keptUntil, {DateTime? now}) {
  final left = keptUntil.difference(now ?? DateTime.now());
  if (left.isNegative) return 0;
  return (left.inMinutes / Duration.minutesPerDay).ceil();
}

/// "3 days left", "1 day left", "Goes today".
String daysLeftWords(int days) => switch (days) {
  0 => 'Goes today',
  1 => '1 day left',
  _ => '$days days left',
};

/// Opens Recently removed.
Future<void> openRecentlyRemoved(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const RemovedPage()));

/// Recently removed: each automation removed lately, when, and how long it
/// is kept, with Restore. A restored one comes back as it was, on or off.
class RemovedPage extends ConsumerStatefulWidget {
  const RemovedPage({super.key});

  @override
  ConsumerState<RemovedPage> createState() => _RemovedPageState();
}

class _RemovedPageState extends ConsumerState<RemovedPage> {
  final _restoring = <String>{};

  Future<void> _restore(Json row) async {
    final id = '${row['id']}';
    final name = '${row['name'] ?? id}';
    setState(() => _restoring.add(id));
    final reply = await ref.read(engineApiProvider).unremoveAutomation(id);
    if (!mounted) return;
    setState(() => _restoring.remove(id));
    if (!reply.ok) return;
    showMessage('$name is back, as it was.');
    ref.invalidate(removedAutomationsProvider);
    await ref.read(automationsProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final removed = ref.watch(removedAutomationsProvider);
    return ListPage(
      title: 'Recently removed',
      state: OmniLoad.of(
        removed,
        isEmpty: (v) => v.isEmpty,
        onRetry: () => ref.invalidate(removedAutomationsProvider),
        error: 'The removed automations did not load.',
      ),
      empty: const OmniEmptyState(
        key: ValueKey('removed-empty'),
        icon: OmniIcons.automations,
        title: 'Nothing removed lately',
        message:
            'An automation you remove stays here for a while, so you can '
            'put it back.',
      ),
      children: (context) => [
        Padding(
          padding: const EdgeInsets.only(bottom: OmniSpace.sm),
          child: Text(
            'Restore puts an automation back as it was, on or off.',
            style: OmniText.captionOf(context),
          ),
        ),
        for (final row in removed.requireValue) _row(row),
      ],
    );
  }

  Widget _row(Json row) {
    final id = '${row['id']}';
    final removedAt = DateTime.tryParse('${row['removedAt']}')?.toLocal();
    final keptUntil = DateTime.tryParse('${row['keptUntil']}')?.toLocal();
    return OmniListRow(
      key: ValueKey('removed-$id'),
      icon: OmniIcons.automations,
      title: '${row['name'] ?? id}',
      subtitle: [
        if (removedAt != null)
          'Removed ${whenInline(removedAt, hour12: ref.watch(hour12Provider))}',
        if (keptUntil != null) daysLeftWords(daysLeft(keptUntil)),
      ].join(' · '),
      trailing: TextButton(
        key: ValueKey('restore-$id'),
        onPressed: _restoring.contains(id) ? null : () => _restore(row),
        style: TextButton.styleFrom(
          minimumSize: const Size(OmniSpace.target, OmniSpace.target),
        ),
        child: Text('Restore', semanticsLabel: 'Restore ${row['name'] ?? id}'),
      ),
    );
  }
}
