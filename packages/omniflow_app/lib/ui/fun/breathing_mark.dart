import 'dart:math';

import 'package:flutter/material.dart';

import '../design/design.dart';

/// The OmniFlow mark, gently rising and growing like a slow breath. Still
/// under reduced motion.
class BreathingMark extends StatefulWidget {
  const BreathingMark({super.key, this.size = 72});

  final double size;

  static const period = Duration(milliseconds: 3200);

  @override
  State<BreathingMark> createState() => _BreathingMarkState();
}

class _BreathingMarkState extends State<BreathingMark>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: BreathingMark.period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (OmniMotion.reduced(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) {
      final wave = sin(_controller.value * 2 * pi);
      return Transform.translate(
        offset: Offset(0, -3 * wave),
        child: Transform.scale(scale: 1 + 0.04 * wave, child: child),
      );
    },
    child: OmniMark(size: widget.size),
  );
}

/// A friendly empty state: the breathing mark, a line, and what to do.
class FunEmptyState extends StatelessWidget {
  const FunEmptyState({
    super.key,
    required this.title,
    required this.body,
    this.action,
  });

  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: OmniSpace.xl),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const BreathingMark(),
        const SizedBox(height: OmniSpace.md),
        Text(title, style: OmniText.bodyStrong, textAlign: TextAlign.center),
        const SizedBox(height: OmniSpace.xs),
        Text(body, style: OmniText.caption, textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: OmniSpace.md), action!],
      ],
    ),
  );
}
