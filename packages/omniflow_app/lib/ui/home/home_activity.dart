import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/clock.dart' show hour12Provider;
import '../design/design.dart';
import '../devices/device_text.dart' show when;
import 'home_data.dart';
import 'suggestion_card.dart';

/// One line of Home's Activity: what happened, in plain words, and when.
typedef HomeEvent = ({String words, DateTime at});

/// What happened in the home today, newest first: the automations and
/// scenes that ran (or did not finish) and the devices that stopped
/// answering. Never an id or a raw value.
List<HomeEvent> homeEvents(
  List<AutomationSummary> summaries,
  List<DeviceView> devices, {
  DateTime? now,
}) {
  final today = (now ?? DateTime.now()).toLocal();
  bool isToday(DateTime at) {
    final t = at.toLocal();
    return t.year == today.year && t.month == today.month && t.day == today.day;
  }

  final events = <HomeEvent>[
    for (final a in summaries)
      if (a.lastRun case final run? when isToday(run.at))
        (
          words: run.ok ? '${a.name} ran' : '${a.name} did not finish',
          at: run.at,
        ),
    for (final d in devices)
      if (!d.online && d.lastSeen != null && isToday(d.lastSeen!))
        (words: '${d.name} stopped answering', at: d.lastSeen!),
  ]..sort((a, b) => b.at.compareTo(a.at));
  return events;
}

/// Home's Activity section, collapsed at the end: what ran and changed
/// today.
class HomeActivitySection extends ConsumerWidget {
  const HomeActivitySection({super.key, required this.devices});

  /// Home's devices, for the ones that stopped answering.
  final List<DeviceView> devices;

  /// How many lines it lists.
  static const shown = 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaries = ref.watch(summariesProvider).value;
    if (summaries == null) return const SizedBox.shrink();
    final events = homeEvents(summaries, devices);
    final hour12 = ref.watch(hour12Provider);
    final muted = OmniPalette.of(context).muted;
    return OmniDisclosure(
      key: const ValueKey('home-activity'),
      storageId: 'home-activity',
      icon: OmniIcons.history,
      title: 'Activity',
      summary: switch (events.length) {
        0 => 'Nothing yet today',
        1 => '1 thing happened today',
        final n => '$n things happened today',
      },
      children: [
        if (events.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: OmniSpace.md),
            child: Text(
              'What runs and changes today shows here.',
              style: OmniText.captionOf(context),
            ),
          ),
        for (final (i, e) in events.take(shown).indexed)
          OmniListRow(
            key: ValueKey('home-activity-$i'),
            title: e.words,
            value: when(e.at, hour12: hour12),
            valueColor: muted,
            divider: i < events.take(shown).length - 1,
          ),
      ],
    );
  }
}

/// Home's Ideas for you: the automations the engine suggests from your
/// habits, folded away until you want them. Nothing shows when there is
/// none.
class HomeIdeasSection extends ConsumerWidget {
  const HomeIdeasSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ideas = ref.watch(suggestionsProvider).value ?? const [];
    if (ideas.isEmpty) return const SizedBox.shrink();
    return OmniDisclosure(
      key: const ValueKey('home-ideas'),
      storageId: 'home-ideas',
      icon: OmniIcons.autoAwesome,
      title: 'Ideas for you',
      summary: ideas.length == 1
          ? '1 automation you could add'
          : '${ideas.length} automations you could add',
      children: const [
        SizedBox(height: OmniSpace.sm),
        SuggestionCard(),
      ],
    );
  }
}
