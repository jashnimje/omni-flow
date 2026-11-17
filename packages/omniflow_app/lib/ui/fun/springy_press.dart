import 'package:flutter/material.dart';

import '../design/design.dart';

/// Sinks [child] a little while a finger is down and springs it back on
/// release. It only watches the pointer, so taps still reach the child.
/// Still under reduced motion.
class SpringyPress extends StatefulWidget {
  const SpringyPress({super.key, required this.child});

  final Widget child;

  static const pressedScale = 0.95;

  @override
  State<SpringyPress> createState() => _SpringyPressState();
}

class _SpringyPressState extends State<SpringyPress> {
  var _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = OmniMotion.reduced(context);
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down && !reduced ? SpringyPress.pressedScale : 1,
        duration: reduced
            ? Duration.zero
            : _down
            ? const Duration(milliseconds: 90)
            : const Duration(milliseconds: 450),
        curve: _down ? Curves.easeOut : Curves.elasticOut,
        child: widget.child,
      ),
    );
  }
}

/// The check a run tile shows when it ran: it pops in with a little
/// overshoot inside a soft accent ring. Shown at once under reduced motion.
class PoppingCheck extends StatelessWidget {
  const PoppingCheck({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: OmniMotion.of(context, const Duration(milliseconds: 420)),
    curve: Curves.easeOutBack,
    builder: (context, t, child) => Transform.scale(
      scale: 0.4 + 0.6 * t,
      child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
    ),
    child: Container(
      width: size + 6,
      height: size + 6,
      decoration: BoxDecoration(
        color: OmniPalette.of(context).accentSoft,
        shape: BoxShape.circle,
      ),
      child: Icon(
        OmniIcons.check,
        size: size,
        color: OmniPalette.of(context).accent,
      ),
    ),
  );
}
