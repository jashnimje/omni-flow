import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// A hue and saturation wheel: the hue goes round, the saturation grows
/// from white in the middle to full colour at the edge. The ring marks
/// [value]. It moves with the finger and reports [onPick] only on release,
/// so a light gets one command per gesture. Screen readers turn the hue
/// in steps of 15 degrees.
class OmniColourWheel extends StatefulWidget {
  const OmniColourWheel({
    super.key,
    required this.value,
    required this.onPick,
    this.size = 220,
    this.label = 'Colour wheel',
  });

  /// The colour shown as picked, or null for none.
  final Color? value;

  /// Null shows the wheel disabled.
  final ValueChanged<Color>? onPick;
  final double size;
  final String label;

  /// The fully bright colour at [hue] (0 to 360) and [saturation] (0 to 1).
  static Color colourAt(double hue, double saturation) =>
      HSVColor.fromAHSV(1, hue % 360, saturation.clamp(0.0, 1.0), 1).toColor();

  @override
  State<OmniColourWheel> createState() => _OmniColourWheelState();
}

class _OmniColourWheelState extends State<OmniColourWheel> {
  HSVColor? _dragging;

  HSVColor? get _shown =>
      _dragging ??
      (widget.value == null ? null : HSVColor.fromColor(widget.value!));

  HSVColor _at(Offset local) {
    final r = widget.size / 2;
    final d = local - Offset(r, r);
    final hue = (math.atan2(d.dy, d.dx) * 180 / math.pi + 360) % 360;
    return HSVColor.fromAHSV(1, hue, (d.distance / r).clamp(0.0, 1.0), 1);
  }

  void _move(Offset local) => setState(() => _dragging = _at(local));

  void _end() {
    final picked = _dragging;
    if (picked == null) return;
    HapticFeedback.selectionClick();
    widget.onPick?.call(picked.toColor());
    setState(() => _dragging = null);
  }

  HSVColor _turned(int direction) {
    final now = _shown ?? HSVColor.fromAHSV(1, 0, 1, 1);
    final next = now.withHue((now.hue + direction * 15) % 360);
    return next.withSaturation(next.saturation == 0 ? 1 : next.saturation);
  }

  void _turn(int direction) =>
      widget.onPick?.call(_turned(direction).toColor());

  String _words(HSVColor? c) => c == null
      ? 'none picked'
      : 'hue ${c.hue.round()} degrees, '
            'saturation ${(c.saturation * 100).round()} percent';

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPick != null;
    final shown = _shown;
    return Semantics(
      label: widget.label,
      value: _words(shown),
      increasedValue: _words(_turned(1)),
      decreasedValue: _words(_turned(-1)),
      enabled: enabled,
      onIncrease: enabled ? () => _turn(1) : null,
      onDecrease: enabled ? () => _turn(-1) : null,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: enabled
              ? (d) {
                  _move(d.localPosition);
                  _end();
                }
              : null,
          onPanStart: enabled ? (d) => _move(d.localPosition) : null,
          onPanUpdate: enabled ? (d) => _move(d.localPosition) : null,
          onPanEnd: enabled ? (_) => _end() : null,
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: _WheelPainter(
              shown,
              ring: OmniColors.text,
              edge: OmniPalette.of(context).line,
            ),
          ),
        ),
      ),
    );
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.picked, {required this.ring, required this.edge});

  final HSVColor? picked;
  final Color ring;
  final Color edge;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final centre = Offset(r, r);
    final rect = Rect.fromCircle(center: centre, radius: r);
    canvas.drawCircle(
      centre,
      r,
      Paint()
        ..shader = SweepGradient(
          colors: [
            for (var h = 0; h <= 360; h += 60)
              HSVColor.fromAHSV(1, h % 360, 1, 1).toColor(),
          ],
        ).createShader(rect),
    );
    canvas.drawCircle(
      centre,
      r,
      Paint()
        ..shader = const RadialGradient(
          colors: [Colors.white, Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    canvas.drawCircle(
      centre,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = edge,
    );
    final p = picked;
    if (p == null) return;
    final angle = p.hue * math.pi / 180;
    final at =
        centre + Offset(math.cos(angle), math.sin(angle)) * (p.saturation * r);
    canvas.drawCircle(at, 11, Paint()..color = p.toColor());
    canvas.drawCircle(
      at,
      11,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = ring,
    );
    canvas.drawCircle(
      at,
      13,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0x99000000),
    );
  }

  @override
  bool shouldRepaint(_WheelPainter old) =>
      old.picked != picked || old.ring != ring || old.edge != edge;
}
