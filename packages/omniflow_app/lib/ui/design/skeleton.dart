import 'package:flutter/material.dart';

import 'tile.dart';
import 'tokens.dart';

/// A soft light that sweeps across [child] while something loads. It
/// sweeps a few times and then holds still, and under reduced motion it
/// never moves.
class OmniShimmer extends StatefulWidget {
  const OmniShimmer({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  /// One sweep, and how many before it rests.
  static const period = Duration(milliseconds: 1400);
  static const sweeps = 8;

  @override
  State<OmniShimmer> createState() => _OmniShimmerState();
}

class _OmniShimmerState extends State<OmniShimmer>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: OmniShimmer.period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(OmniShimmer old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.enabled && !OmniMotion.reduced(context);
    if (run && !_controller.isAnimating && _controller.value == 0) {
      _controller.repeat(count: OmniShimmer.sweeps);
    } else if (!run && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value;
        if (t == 0 || t == 1) return child!;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(-1.5 + 3 * t, -0.2),
            end: Alignment(-0.5 + 3 * t, 0.2),
            colors: const [
              Color(0x00FFFFFF),
              Color(0x1FFFFFFF),
              Color(0x00FFFFFF),
            ],
          ).createShader(bounds),
          child: child,
        );
      },
    );
  }
}

/// One grey shape of a skeleton.
class OmniBone extends StatelessWidget {
  const OmniBone({
    super.key,
    this.width,
    required this.height,
    this.radius = OmniShape.xs,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: OmniPalette.of(context).raised,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

/// [rows] list rows' shapes while a list loads, read as [label].
class OmniListSkeleton extends StatelessWidget {
  const OmniListSkeleton({
    super.key,
    this.rows = 5,
    this.label = 'Loading',
    this.rowHeight = 56,
  });

  final int rows;
  final String label;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    return Semantics(
      label: label,
      child: OmniShimmer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < rows; i++)
              Container(
                height: rowHeight,
                margin: const EdgeInsets.only(bottom: OmniSpace.sm),
                padding: const EdgeInsets.symmetric(horizontal: OmniSpace.md),
                decoration: BoxDecoration(
                  color: palette.card,
                  borderRadius: BorderRadius.circular(OmniRadii.card),
                ),
                child: Row(
                  children: [
                    const OmniBone(
                      width: 32,
                      height: 32,
                      radius: OmniRadii.iconBox,
                    ),
                    const SizedBox(width: OmniSpace.md),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FractionallySizedBox(
                            widthFactor: i.isEven ? 0.5 : 0.4,
                            child: const OmniBone(height: 12),
                          ),
                          const SizedBox(height: 6),
                          FractionallySizedBox(
                            widthFactor: i.isEven ? 0.7 : 0.6,
                            child: const OmniBone(height: 10),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A detail page's shape while it loads: the hero card, then [rows] list
/// rows, read as [label].
class OmniPageSkeleton extends StatelessWidget {
  const OmniPageSkeleton({super.key, this.rows = 3, this.label = 'Loading'});

  final int rows;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    container: true,
    child: ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const OmniShimmer(
            child: OmniBone(height: 140, radius: OmniRadii.hero),
          ),
          const SizedBox(height: OmniSpace.lg),
          OmniListSkeleton(rows: rows, label: label),
        ],
      ),
    ),
  );
}

/// [count] tiles' shapes in a grid of [columns] while a grid loads.
class OmniTileGridSkeleton extends StatelessWidget {
  const OmniTileGridSkeleton({
    super.key,
    this.count = 6,
    this.columns = 2,
    this.label = 'Loading',
  });

  final int count;
  final int columns;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    container: true,
    child: ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var r = 0; r * columns < count; r++)
            Padding(
              padding: const EdgeInsets.only(bottom: OmniSpace.gap),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var c = 0; c < columns; c++) ...[
                    if (c > 0) const SizedBox(width: OmniSpace.gap),
                    Expanded(
                      child: r * columns + c < count
                          ? const OmniTileSkeleton()
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
