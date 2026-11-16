import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../design/design.dart';
import 'confetti.dart';
import 'home_stats.dart';

/// Celebrates each achievement the engine reports as newly earned, once
/// per session. Home's hero calls it from its build.
void listenForAchievements(BuildContext context, WidgetRef ref) {
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
}

/// Today's three numbers in Home's hero: what ran, the taps it saved and
/// the streak, each in a small box. A screen reader hears them as one
/// line, which [todaySpoken] gives.
class HomeTodayNumbers extends StatelessWidget {
  const HomeTodayNumbers({super.key, required this.stats});

  final HomeStats stats;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    final streak = stats.streak;
    return ExcludeSemantics(
      child: Row(
        key: const ValueKey('home-today'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _Number(
              key: const ValueKey('home-today-ran'),
              value: '${stats.today.automationsRun}',
              label: 'ran today',
              ink: palette.onAccentSoft,
            ),
          ),
          const SizedBox(width: OmniSpace.sm),
          Expanded(
            child: _Number(
              key: const ValueKey('home-today-taps'),
              value: '${stats.today.tapsSaved}',
              label: stats.today.tapsSaved == 1 ? 'tap saved' : 'taps saved',
              ink: palette.onAccentSoft,
            ),
          ),
          const SizedBox(width: OmniSpace.sm),
          Expanded(
            child: _Number(
              key: const ValueKey('home-today-streak'),
              value: '$streak',
              label: 'day streak',
              ink: palette.onAccentSoft,
              icon: streak > 0 ? Symbols.local_fire_department_rounded : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// The three numbers as a screen reader hears them.
String todaySpoken(HomeStats stats) {
  final line = todayLine(stats);
  final streak = stats.streak == 1 ? '1 day' : '${stats.streak} days';
  return '${line.title}. ${line.detail}. $streak in a row';
}

/// One of the hero's numbers: the figure big, what it counts under it.
class _Number extends StatelessWidget {
  const _Number({
    super.key,
    required this.value,
    required this.label,
    required this.ink,
    this.icon,
  });

  /// The shade the boxes add over the hero's gradient.
  static const shade = Color(0x38000000);

  final String value;
  final String label;
  final Color ink;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(10, OmniSpace.sm, 10, OmniSpace.sm),
    decoration: BoxDecoration(
      color: shade,
      borderRadius: BorderRadius.circular(OmniShape.md),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, fill: 1, color: OmniColors.trigger),
              const SizedBox(width: 2),
            ],
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OmniText.titleMedium.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: OmniText.caption.copyWith(color: ink),
        ),
      ],
    ),
  );
}

/// What ran today and the taps it saved, in two lines.
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
