import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'confetti.dart';
import 'home_stats.dart';

/// Celebrates each achievement the engine reports as newly earned, once
/// per session. Your activity calls it from its build.
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
