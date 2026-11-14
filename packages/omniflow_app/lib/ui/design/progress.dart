import 'package:flutter/material.dart';

import 'tokens.dart';

/// A rounded progress bar. A null [value] is a transfer or wait of unknown
/// length: it animates, or under reduced motion holds still.
class OmniProgressBar extends StatelessWidget {
  const OmniProgressBar({
    super.key,
    this.value,
    this.height = 6,
    this.semanticLabel,
    this.color,
  });

  final double? value;
  final double height;
  final String? semanticLabel;

  /// The fill. Defaults to the accent.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final still = value == null && OmniMotion.reduced(context);
    final v = value?.clamp(0.0, 1.0).toDouble();
    return Semantics(
      label: semanticLabel,
      value: v == null ? 'in progress' : '${(v * 100).round()}%',
      child: ExcludeSemantics(
        child: LinearProgressIndicator(
          value: still ? 0.3 : v,
          minHeight: height,
          color: color ?? OmniPalette.of(context).accent,
          backgroundColor: OmniPalette.of(context).raised,
          borderRadius: BorderRadius.circular(height / 2),
        ),
      ),
    );
  }
}

/// The step bar of a guided flow: [count] segments, the first [current]
/// of them filled.
class OmniStepBar extends StatelessWidget {
  const OmniStepBar({super.key, required this.count, required this.current});

  final int count;

  /// 1-based: the step the user is on.
  final int current;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Step $current of $count',
    child: Row(
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: AnimatedContainer(
              duration: OmniMotion.of(context),
              height: 4,
              decoration: BoxDecoration(
                color: i < current
                    ? OmniPalette.of(context).accent
                    : OmniPalette.of(context).raised,
                borderRadius: BorderRadius.circular(OmniShape.xs / 2),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
