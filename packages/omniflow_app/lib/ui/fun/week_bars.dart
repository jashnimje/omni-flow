import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../design/design.dart';

/// Bars of runs per day, oldest on the left, today in the accent. The bars
/// grow in once when shown, and are drawn at once under reduced motion.
class WeekBars extends StatelessWidget {
  const WeekBars({
    super.key,
    required this.runs,
    this.height = 28,
    this.barWidth = 6,
    this.labels,
  });

  final List<int> runs;
  final double height;
  final double barWidth;

  /// A short label under each bar (a day letter), or none.
  final List<String>? labels;

  @override
  Widget build(BuildContext context) {
    final most = runs.fold<int>(0, (m, r) => r > m ? r : m);
    return ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: OmniMotion.of(context, const Duration(milliseconds: 500)),
        curve: Curves.easeOutCubic,
        builder: (context, grow, _) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < runs.length; i++) ...[
              if (i > 0) SizedBox(width: barWidth * 0.6),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: barWidth,
                    // An empty day keeps a stub, so the week still reads.
                    height: most == 0
                        ? 2
                        : (2 + (height - 2) * runs[i] / most * grow),
                    decoration: BoxDecoration(
                      color: i == runs.length - 1
                          ? OmniPalette.of(context).accent
                          : runs[i] == 0
                          ? OmniPalette.of(context).line
                          : OmniPalette.of(context).accentLine,
                      borderRadius: BorderRadius.circular(barWidth / 2),
                    ),
                  ),
                  if (labels case final l? when i < l.length) ...[
                    const SizedBox(height: OmniSpace.xs),
                    Text(l[i], style: OmniText.caption),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The streak flame and its count of days in a row. Grey at zero.
class StreakFlame extends StatelessWidget {
  const StreakFlame({super.key, required this.days, this.size = 18});

  final int days;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: days == 1 ? '1 day in a row' : '$days days in a row',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Symbols.local_fire_department_rounded,
          fill: days > 0 ? 1 : 0,
          size: size,
          color: days > 0 ? OmniColors.trigger : OmniColors.muted,
        ),
        const SizedBox(width: 2),
        Text(
          '$days',
          style: OmniText.label.copyWith(
            color: days > 0 ? OmniColors.trigger : OmniColors.muted,
          ),
        ),
      ],
    ),
  );
}

/// One letter per day of the week, Monday first.
String dayLetter(DateTime day) =>
    const ['M', 'T', 'W', 'T', 'F', 'S', 'S'][day.weekday - 1];
