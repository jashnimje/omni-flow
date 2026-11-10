import 'package:flutter/material.dart';

import 'tokens.dart';

/// The pill slider of the mockups: the fill grows from the left with the
/// [label] on it and the value on the right. It moves as the finger moves
/// but reports [onChangeEnd] only on release, so a device gets one command
/// per gesture. Screen readers can step it up and down.
class OmniLabelledSlider extends StatefulWidget {
  const OmniLabelledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.onChangeEnd,
    this.min = 0,
    this.max = 100,
    this.step,
    this.format,
    this.onChanged,
    this.fill,
    this.labelOnFill,
    this.height = 36,
  });

  final String label;
  final double value;
  final double min;
  final double max;

  /// Values snap to this step; screen readers step by it (or 5% of the
  /// range without one).
  final double? step;

  /// The value as shown ("80%", "3000 K"). Defaults to the rounded number.
  final String Function(double value)? format;

  /// Null shows the slider disabled.
  final ValueChanged<double>? onChangeEnd;
  final ValueChanged<double>? onChanged;

  /// Paints the fill (the warmth gradient); a flat accent fill without it.
  final Gradient? fill;

  /// The label colour while the fill is under it (dark on the warmth
  /// gradient). Over the empty track the label is always light.
  final Color? labelOnFill;
  final double height;

  @override
  State<OmniLabelledSlider> createState() => _OmniLabelledSliderState();
}

class _OmniLabelledSliderState extends State<OmniLabelledSlider> {
  late double _value = _clamp(widget.value);
  bool _dragging = false;

  double _clamp(double v) {
    final step = widget.step;
    final snapped = step == null || step <= 0
        ? v
        : widget.min + ((v - widget.min) / step).round() * step;
    return snapped.clamp(widget.min, widget.max).toDouble();
  }

  @override
  void didUpdateWidget(OmniLabelledSlider old) {
    super.didUpdateWidget(old);
    if (!_dragging && old.value != widget.value) _value = _clamp(widget.value);
  }

  double get _fraction => widget.max <= widget.min
      ? 0
      : (_value - widget.min) / (widget.max - widget.min);

  String _text(double v) => widget.format?.call(v) ?? '${v.round()}';

  void _setFrom(Offset local, double width) {
    final f = (local.dx / width).clamp(0.0, 1.0);
    final v = _clamp(widget.min + f * (widget.max - widget.min));
    if (v == _value) return;
    setState(() => _value = v);
    widget.onChanged?.call(v);
  }

  void _end() {
    _dragging = false;
    widget.onChangeEnd?.call(_value);
  }

  void _nudge(int direction) {
    final step = widget.step ?? (widget.max - widget.min) / 20;
    setState(() => _value = _clamp(_value + direction * step));
    widget.onChangeEnd?.call(_value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChangeEnd != null;
    final step = widget.step ?? (widget.max - widget.min) / 20;
    return Semantics(
      slider: true,
      enabled: enabled,
      label: widget.label,
      value: _text(_value),
      increasedValue: _text(_clamp(_value + step)),
      decreasedValue: _text(_clamp(_value - step)),
      onIncrease: enabled ? () => _nudge(1) : null,
      onDecrease: enabled ? () => _nudge(-1) : null,
      excludeSemantics: true,
      child: SizedBox(
        height: OmniSpace.target,
        child: LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth;
            final filled = width * _fraction;
            final labelLit = filled > 96;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: enabled
                  ? (d) {
                      _setFrom(d.localPosition, width);
                      _end();
                    }
                  : null,
              onHorizontalDragStart: enabled
                  ? (d) {
                      _dragging = true;
                      _setFrom(d.localPosition, width);
                    }
                  : null,
              onHorizontalDragUpdate: enabled
                  ? (d) => _setFrom(d.localPosition, width)
                  : null,
              onHorizontalDragEnd: enabled ? (_) => _end() : null,
              // A tap also cancels the drag recogniser; sending then would
              // send the old value before onTapUp sends the new one.
              onHorizontalDragCancel: enabled
                  ? () {
                      if (_dragging) _end();
                    }
                  : null,
              child: Center(
                child: Opacity(
                  opacity: enabled ? 1 : 0.5,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(widget.height / 2),
                    child: SizedBox(
                      height: widget.height,
                      child: Stack(
                        children: [
                          const Positioned.fill(
                            child: ColoredBox(color: OmniColors.raised),
                          ),
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: filled,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: widget.fill == null
                                    ? OmniColors.sliderFill
                                    : null,
                                gradient: widget.fill,
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      widget.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: labelLit
                                            ? widget.labelOnFill ??
                                                  OmniColors.text
                                            : OmniColors.text,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    _text(_value),
                                    style: OmniText.number.copyWith(
                                      // Over the fill the muted grey would
                                      // drop below AA.
                                      color: _fraction > 0.8
                                          ? widget.labelOnFill ??
                                                OmniColors.text
                                          : OmniColors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
