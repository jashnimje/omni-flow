import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../design/design.dart';
import 'fun_prefs.dart';
import 'home_today_card.dart' show listenForAchievements;
import 'home_stats.dart';
import 'week_bars.dart';

void openYourHome(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const YourHomePage()));

/// Settings, Your activity: the week in numbers and bars, the streak, the
/// busiest automation, every achievement, and the Celebrations switch. An
/// achievement earned while it is open is celebrated here, never on Home.
class YourHomePage extends ConsumerWidget {
  const YourHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    listenForAchievements(context, ref);
    final stats = ref.watch(homeStatsProvider);
    final celebrations = ref.watch(celebrationsProvider);
    final s = stats.value;
    return ListPage(
      key: const ValueKey('your-home'),
      title: 'Your activity',
      state: s != null
          ? const OmniLoad.data()
          : stats.isLoading
          ? const OmniLoad.loading()
          : OmniLoad.error(
              'Your activity did not load.',
              () => ref.invalidate(homeStatsProvider),
            ),
      children: (context) => [
        if (s!.totalRuns == 0 && s.week.automationsRun == 0)
          const OmniEmptyState(
            key: ValueKey('your-home-empty'),
            icon: Symbols.celebration_rounded,
            title: 'Nothing has run yet',
            message:
                'When your scenes and automations run, you will see what '
                'they did for you here.',
          )
        else
          _Week(stats: s),
        OmniSectionHeader(
          'Achievements',
          trailingText: '${s.earnedCount} of ${s.achievements.length}',
        ),
        _AchievementGrid(achievements: s.achievements),
        const SizedBox(height: OmniSpace.md),
        OmniCard(
          child: OmniListRow(
            key: const ValueKey('celebrations-switch'),
            title: 'Celebrations',
            subtitle: 'A little confetti when you earn something',
            icon: Symbols.celebration_rounded,
            divider: false,
            trailing: Switch(
              value: celebrations,
              onChanged: (on) =>
                  ref.read(celebrationsProvider.notifier).set(on),
            ),
          ),
        ),
      ],
    );
  }
}

class _Week extends StatelessWidget {
  const _Week({required this.stats});

  final HomeStats stats;

  @override
  Widget build(BuildContext context) {
    final week = stats.week;
    final busiest = stats.busiest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OmniSectionHeader('This week'),
        OmniCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _Number(
                    '${week.automationsRun}',
                    week.automationsRun == 1 ? 'run' : 'runs',
                  ),
                  _Number(
                    '${week.stepsDone}',
                    week.stepsDone == 1 ? 'step done' : 'steps done',
                  ),
                  _Number(
                    '${week.devicesChanged}',
                    week.devicesChanged == 1
                        ? 'device changed'
                        : 'devices changed',
                  ),
                  _Number(
                    '${week.tapsSaved}',
                    week.tapsSaved == 1 ? 'tap saved' : 'taps saved',
                  ),
                ],
              ),
              const SizedBox(height: OmniSpace.md),
              Center(
                child: WeekBars(
                  key: const ValueKey('your-home-bars'),
                  runs: [for (final d in stats.days) d.runs],
                  height: 64,
                  barWidth: 14,
                  labels: [for (final d in stats.days) dayLetter(d.date)],
                ),
              ),
            ],
          ),
        ),
        OmniCard(
          child: Row(
            children: [
              StreakFlame(days: stats.streak, size: 28),
              const SizedBox(width: OmniSpace.md),
              Expanded(
                child: Text(
                  streakLine(stats.streak, stats.bestStreak),
                  key: const ValueKey('your-home-streak'),
                  style: OmniText.body,
                ),
              ),
            ],
          ),
        ),
        if (busiest != null)
          OmniCard(
            key: const ValueKey('your-home-busiest'),
            child: OmniListRow(
              title: busiest.name,
              subtitle: busiest.runs == 1
                  ? 'Your busiest automation, ran once this week'
                  : 'Your busiest automation, ran ${busiest.runs} times '
                        'this week',
              subtitleLines: 2,
              icon: Symbols.trophy_rounded,
              divider: false,
            ),
          ),
      ],
    );
  }
}

/// What the streak card says.
String streakLine(int streak, int best) {
  final now = switch (streak) {
    0 => 'No streak yet. Let something run today to start one.',
    1 => '1 day in a row with something running.',
    _ => '$streak days in a row with something running.',
  };
  return best > streak ? '$now Your best is $best days.' : now;
}

class _Number extends StatelessWidget {
  const _Number(this.value, this.label);

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Semantics(
      label: '$value $label',
      excludeSemantics: true,
      child: Column(
        children: [
          Text(value, style: OmniText.number),
          Text(
            label,
            style: OmniText.caption,
            textAlign: TextAlign.center,
            maxLines: 2,
          ),
        ],
      ),
    ),
  );
}

/// The icon each achievement wears.
IconData achievementIcon(String id) => switch (id) {
  'first_device' => OmniIcons.light,
  'first_automation' => OmniIcons.automations,
  'first_scene' => OmniIcons.scene,
  'first_tag' => OmniIcons.tag,
  'first_board' => OmniIcons.board,
  'runs_10' || 'runs_100' || 'runs_1000' => Symbols.military_tech_rounded,
  'streak_7' => Symbols.local_fire_department_rounded,
  'asks_you' => Symbols.forum_rounded,
  'web_request' => Symbols.public_rounded,
  'sunset_rule' => OmniIcons.sun,
  'tv_controlled' => OmniIcons.tv,
  _ => Symbols.emoji_events_rounded,
};

class _AchievementGrid extends StatelessWidget {
  const _AchievementGrid({required this.achievements});

  final List<Achievement> achievements;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final columns = box.maxWidth >= 520 ? 4 : (box.maxWidth >= 340 ? 3 : 2);
      final width = (box.maxWidth - OmniSpace.gap * (columns - 1)) / columns;
      return Wrap(
        spacing: OmniSpace.gap,
        runSpacing: OmniSpace.gap,
        children: [
          for (final a in achievements)
            SizedBox(width: width, child: _AchievementTile(a)),
        ],
      );
    },
  );
}

class _AchievementTile extends StatelessWidget {
  const _AchievementTile(this.a);

  final Achievement a;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    final at = a.earnedAt;
    final detail = a.earned
        ? (at == null ? 'Earned' : 'Earned ${shortDate(at)}')
        : a.how;
    return Semantics(
      key: ValueKey('achievement-${a.id}'),
      label: '${a.title}, ${a.earned ? detail : 'not earned yet. ${a.how}'}',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 112),
        padding: const EdgeInsets.all(OmniSpace.md),
        decoration: BoxDecoration(
          color: a.earned ? palette.accentSoft : palette.card,
          borderRadius: BorderRadius.circular(OmniRadii.tile),
          border: Border.all(
            color: a.earned ? palette.accentLine : palette.line,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              achievementIcon(a.id),
              size: 26,
              fill: a.earned ? 1 : 0,
              color: a.earned ? palette.accent : OmniColors.muted,
            ),
            const SizedBox(height: OmniSpace.sm),
            Text(
              a.title,
              style: OmniText.label.copyWith(
                color: a.earned ? OmniColors.text : OmniColors.muted,
              ),
            ),
            const SizedBox(height: OmniSpace.xs),
            Text(
              detail,
              style: OmniText.caption.copyWith(
                color: a.earned ? palette.onAccentSoft : OmniColors.muted,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// A date as "12 Nov 2026".
String shortDate(DateTime at) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${at.day} ${months[at.month - 1]} ${at.year}';
}
