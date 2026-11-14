import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../design/design.dart';
import 'fun_prefs.dart';

/// A short burst of confetti over the whole screen. It never takes a tap,
/// and screen readers do not see it.
class ConfettiBurst extends StatefulWidget {
  const ConfettiBurst({super.key, this.onDone, this.seed});

  final VoidCallback? onDone;

  /// Fixes the pieces, for tests.
  final int? seed;

  static const duration = Duration(milliseconds: 1400);

  @override
  State<ConfettiBurst> createState() => _ConfettiBurstState();
}

class _ConfettiBurstState extends State<ConfettiBurst>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: ConfettiBurst.duration,
  );
  late final List<_Piece> _pieces;

  static const _colors = [
    OmniColors.accent,
    OmniColors.trigger,
    OmniColors.condition,
    OmniColors.transformer,
    OmniColors.flowControl,
    OmniColors.warn,
  ];

  @override
  void initState() {
    super.initState();
    final random = Random(widget.seed);
    _pieces = [
      for (var i = 0; i < 48; i++)
        _Piece(
          // Out from the top centre, a fan of up to 70 degrees each way.
          angle: -pi / 2 + (random.nextDouble() - 0.5) * pi * 0.78,
          speed: 0.55 + random.nextDouble() * 0.6,
          spin: (random.nextDouble() - 0.5) * 14,
          size: 5 + random.nextDouble() * 5,
          color: _colors[i % _colors.length],
          round: random.nextBool(),
        ),
    ];
    _controller.forward().whenComplete(() => widget.onDone?.call());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          key: const ValueKey('confetti'),
          size: Size.infinite,
          painter: _ConfettiPainter(_pieces, _controller),
        ),
      ),
    ),
  );
}

class _Piece {
  const _Piece({
    required this.angle,
    required this.speed,
    required this.spin,
    required this.size,
    required this.color,
    required this.round,
  });

  final double angle;
  final double speed;
  final double spin;
  final double size;
  final Color color;
  final bool round;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.pieces, this.progress) : super(repaint: progress);

  final List<_Piece> pieces;
  final Animation<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final origin = Offset(size.width / 2, size.height * 0.32);
    final reach = size.shortestSide * 0.75;
    final fade = t < 0.7 ? 1.0 : (1 - (t - 0.7) / 0.3).clamp(0.0, 1.0);
    final paint = Paint();
    for (final p in pieces) {
      // Thrown out, slowing, then falling.
      final out = reach * p.speed * (1 - pow(1 - t, 2.2));
      final fall = size.height * 0.45 * t * t;
      final at = origin + Offset(cos(p.angle) * out, sin(p.angle) * out + fall);
      paint.color = p.color.withValues(alpha: fade);
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(p.spin * t);
      if (p.round) {
        canvas.drawCircle(Offset.zero, p.size / 2, paint);
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset.zero,
              width: p.size,
              height: p.size * 0.5,
            ),
            const Radius.circular(1),
          ),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.pieces != pieces;
}

/// Celebrates with a burst over [context]'s screen and a short [message].
/// The message always shows; the burst only with celebrations on and
/// animations allowed. Nothing waits for it.
Future<void> celebrate(
  BuildContext context,
  WidgetRef ref, {
  String? message,
}) async {
  if (message != null) showMessage(message);
  final on = await ref.read(celebrationsProvider.notifier).isOn();
  if (!on || !context.mounted || OmniMotion.reduced(context)) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => ConfettiBurst(
      onDone: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}
