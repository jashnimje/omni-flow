import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/design.dart';
import 'confetti.dart';
import 'home_stats.dart';
import 'week_bars.dart';
import 'your_home_page.dart';

/// Home's top card: what the automations did today, the week as small
/// bars and the streak. A tap opens Your home. It celebrates each
/// achievement the engine reports as newly earned. Nothing shows until the
/// numbers load, or when the engine has none.
class HomeTodayCard extends ConsumerWidget {
  const HomeTodayCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(homeStatsProvider, (_, next) {
      final stats = next.value;
      if (stats == null) return;
      final shown = ref.read(celebratedProvider);
      final fresh = [
        for (final id in stats.newlyEarned)
          if (shown.add(id)) id,
      ];
      if (fresh.isEmpty) return;
      unawaited(celebrate(context, ref, message: earnedMessage(stats, fresh)));
    });
    final stats = ref.watch(homeStatsProvider).value;
    if (stats == null) return const SizedBox.shrink();
    final line = todayLine(stats);
    return OmniCard(
      key: const ValueKey('home-today'),
      onTap: () => openYourHome(context),
      child: Semantics(
        button: true,
        label:
            '${line.title}. ${line.detail}. '
            '${stats.streak == 1 ? '1 day' : '${stats.streak} days'} in a row',
        hint: 'Opens Your home',
        excludeSemantics: true,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Your home today', style: OmniText.caption),
                  const SizedBox(height: 2),
                  Text(line.title, style: OmniText.bodyStrong),
                  Text(
                    line.detail,
                    key: const ValueKey('home-today-detail'),
                    style: OmniText.caption.copyWith(
                      color: OmniColors.onAccentSoft,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: OmniSpace.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                StreakFlame(days: stats.streak),
                const SizedBox(height: OmniSpace.xs),
                WeekBars(runs: [for (final d in stats.days) d.runs]),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The card's two lines: what ran today, and the taps it saved.
({String title, String detail}) todayLine(HomeStats stats) {
  final today = stats.today;
  if (today.automationsRun == 0) {
    return (
      title: 'Nothing has run yet today',
      detail: stats.week.tapsSaved > 0
          ? 'Saved you ${_taps(stats.week.tapsSaved)} this week'
          : 'Run a scene or let an automation start on its own',
    );
  }
  return (
    title: today.automationsRun == 1
        ? '1 automation ran'
        : '${today.automationsRun} automations ran',
    detail: today.tapsSaved > 0
        ? 'Saved you ${_taps(today.tapsSaved)}'
        : '${today.stepsDone == 1 ? '1 step' : '${today.stepsDone} steps'} done',
  );
}

String _taps(int n) => n == 1 ? '1 tap' : '$n taps';

/// The achievements already celebrated in this session. A reply read twice
/// (the automations and a run changing at once) celebrates once.
final celebratedProvider = Provider<Set<String>>((ref) => <String>{});

/// What a celebration of [ids] says: the one achievement, or how many.
String earnedMessage(HomeStats stats, List<String> ids) {
  if (ids.length == 1) {
    final title = stats.achievement(ids.single)?.title ?? 'an achievement';
    return 'You earned $title';
  }
  return 'You earned ${ids.length} achievements';
}
