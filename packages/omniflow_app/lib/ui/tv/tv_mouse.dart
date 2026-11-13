import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../api/tv_calls.dart';
import '../design/design.dart';
import 'tv_controller.dart';
import 'tv_page.dart' show Keycodes;

/// A touchpad for apps that want a pointer: a browser, a game's menu, a
/// settings screen with no focus. Android TV draws no pointer for touches
/// sent over ADB, so the TV's picture sits above the pad with the pointer
/// drawn on it. One finger moves it, a tap clicks where it is, two fingers
/// scroll, and a long press holds.
class TvMouse extends StatefulWidget {
  const TvMouse({super.key, required this.tv, required this.active});

  final TvController tv;

  /// Whether the tab is on screen: the picture only refreshes then.
  final bool active;

  @override
  State<TvMouse> createState() => _TvMouseState();
}

class _TvMouseState extends State<TvMouse> {
  /// How far the pointer moves for a drag the width of the pad: a little
  /// over the screen, as a laptop touchpad feels.
  static const _speed = 1.2;

  Offset _pointer = const Offset(0.5, 0.5);
  Uint8List? _frame;
  Size _screen = const Size(1920, 1080);
  Timer? _refresh;
  var _reading = false;

  /// Why the last picture did not come, shown in its place.
  String? _error;

  TvController get tv => widget.tv;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(TvMouse old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _refresh?.cancel();
    super.dispose();
  }

  void _sync() {
    if (widget.active) {
      if (_refresh != null) return;
      unawaited(_read());
      _refresh = Timer.periodic(
        const Duration(milliseconds: 900),
        (_) => _read(),
      );
    } else {
      _refresh?.cancel();
      _refresh = null;
    }
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    try {
      final r = await tv.client.call(
        TvCalls.screenshot,
        TvCalls.readArgs(tv.id),
      );
      if (!mounted) return;
      if (r['ok'] != true) {
        final error = r['error'] as Map?;
        setState(
          () => _error = error?['type'] == 'needs_user'
              ? 'Pair the TV to see its screen here.'
              : 'The TV did not send its screen. It may be asleep.',
        );
        return;
      }
      final w = (r['width'] as num?)?.toDouble();
      final h = (r['height'] as num?)?.toDouble();
      setState(() {
        _error = null;
        _frame = base64Decode('${r['png']}');
        if (w != null && h != null && w > 0 && h > 0) _screen = Size(w, h);
      });
    } finally {
      _reading = false;
    }
  }

  void _move(Offset delta, Size pad) {
    if (pad.isEmpty) return;
    setState(() {
      _pointer = Offset(
        (_pointer.dx + delta.dx / pad.width * _speed).clamp(0.0, 1.0),
        (_pointer.dy + delta.dy / pad.height * _speed).clamp(0.0, 1.0),
      );
    });
  }

  Future<void> _click() async {
    await tv.call(
      TvCalls.tap,
      TvCalls.tapArgs(tv.id, _pointer.dx, _pointer.dy),
    );
    unawaited(_read());
  }

  /// A hold is a swipe that does not move.
  Future<void> _hold() async {
    await tv.call(
      TvCalls.swipe,
      TvCalls.swipeArgs(tv.id, _pointer, _pointer, ms: 700),
    );
    unawaited(_read());
  }

  /// Two fingers scroll the page under the pointer, the way a touchpad does:
  /// drawing them up moves the page up.
  Future<void> _scroll(Offset by, Size pad) async {
    if (pad.isEmpty) return;
    final dy = (by.dy / pad.height).clamp(-0.6, 0.6);
    final dx = (by.dx / pad.width).clamp(-0.6, 0.6);
    if (dy.abs() < 0.02 && dx.abs() < 0.02) return;
    await tv.call(
      TvCalls.swipe,
      TvCalls.swipeArgs(
        tv.id,
        _pointer,
        Offset(
          (_pointer.dx + dx).clamp(0.0, 1.0),
          (_pointer.dy + dy).clamp(0.0, 1.0),
        ),
        ms: 250,
      ),
    );
    unawaited(_read());
  }

  // The pad's own reading of touches: one finger moves the pointer, a short
  // still touch clicks, a long still one holds, and two fingers scroll.
  final _touches = <int, Offset>{};
  DateTime? _downAt;
  var _travel = 0.0;
  var _scrolling = false;
  var _held = false;
  Offset? _scrollStart;
  Timer? _holdTimer;

  static const _still = 12.0;

  Offset _middle() {
    var sum = Offset.zero;
    for (final p in _touches.values) {
      sum += p;
    }
    return sum / _touches.length.toDouble();
  }

  void _down(PointerDownEvent e, Size pad) {
    _touches[e.pointer] = e.localPosition;
    if (_touches.length == 1) {
      _downAt = DateTime.now();
      _travel = 0;
      _scrolling = false;
      _held = false;
      _holdTimer?.cancel();
      _holdTimer = Timer(const Duration(milliseconds: 600), () {
        if (_touches.length == 1 && _travel < _still && !_scrolling) {
          _held = true;
          _hold();
        }
      });
    } else {
      _holdTimer?.cancel();
      _scrolling = true;
      _scrollStart = _middle();
    }
  }

  void _moveRaw(PointerMoveEvent e, Size pad) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.localPosition;
    if (_scrolling) return;
    _travel += e.delta.distance;
    if (_travel >= _still) _holdTimer?.cancel();
    _move(e.delta, pad);
  }

  void _up(PointerEvent e, Size pad, {bool cancelled = false}) {
    final before = _scrolling && _touches.length >= 2 ? _middle() : null;
    _touches.remove(e.pointer);
    if (_scrolling) {
      final from = _scrollStart;
      if (from != null && before != null) {
        _scrollStart = null;
        // The page follows the fingers, as on a laptop touchpad.
        _scroll(before - from, pad);
      }
    } else if (_touches.isEmpty && !cancelled && !_held) {
      final took = DateTime.now().difference(_downAt ?? DateTime.now());
      if (_travel < _still && took < const Duration(milliseconds: 350)) {
        _click();
      }
    }
    if (_touches.isEmpty) {
      _holdTimer?.cancel();
      _scrolling = false;
    }
  }

  Widget _button(String key, IconData icon, String label, VoidCallback onTap) =>
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: OmniButton.ghost(
            key: ValueKey(key),
            label: label,
            icon: icon,
            onPressed: onTap,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    return Column(
      key: const ValueKey('tv-mouse'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: _screen.width / _screen.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: Colors.black,
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  fit: StackFit.expand,
                  children: [
                    if (frame != null)
                      Image.memory(
                        frame,
                        gaplessPlayback: true,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.medium,
                      )
                    else if (_error case final e?)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(OmniSpace.md),
                          child: Text(
                            e,
                            key: const ValueKey('tv-mouse-error'),
                            textAlign: TextAlign.center,
                            style: OmniText.caption,
                          ),
                        ),
                      )
                    else
                      const Center(child: CircularProgressIndicator()),
                    Positioned(
                      left: _pointer.dx * box.maxWidth - 2,
                      top: _pointer.dy * box.maxHeight - 2,
                      child: const IgnorePointer(
                        child: Icon(
                          Icons.navigation_rounded,
                          key: ValueKey('tv-mouse-pointer'),
                          size: 22,
                          color: OmniColors.accent,
                          shadows: [Shadow(blurRadius: 3)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: OmniSpace.sm),
        LayoutBuilder(
          builder: (context, box) {
            final pad = Size(box.maxWidth, 220);
            // Raw pointers, not gestures: nothing around the pad (the page's
            // scroll) can take a drag from it, and the pointer follows the
            // finger exactly.
            return Listener(
              key: const ValueKey('tv-mouse-pad'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) => _down(e, pad),
              onPointerMove: (e) => _moveRaw(e, pad),
              onPointerUp: (e) => _up(e, pad),
              onPointerCancel: (e) => _up(e, pad, cancelled: true),
              child: Container(
                height: pad.height,
                decoration: BoxDecoration(
                  color: OmniColors.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: OmniColors.line),
                ),
                alignment: Alignment.center,
                child: const Text(
                  'Drag to move · tap to click\nTwo fingers to scroll · hold to long-press',
                  textAlign: TextAlign.center,
                  style: OmniText.caption,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: OmniSpace.sm),
        Row(
          children: [
            _button('tv-mouse-click', Icons.ads_click_rounded, 'Click', _click),
            _button('tv-mouse-hold', Icons.touch_app_rounded, 'Hold', _hold),
          ],
        ),
        const SizedBox(height: OmniSpace.xs),
        Row(
          children: [
            _button(
              'tv-mouse-back',
              Icons.arrow_back_rounded,
              'Back',
              () => tv.key(Keycodes.back),
            ),
            _button(
              'tv-mouse-home',
              OmniIcons.home,
              'Home',
              () => tv.key(Keycodes.home),
            ),
          ],
        ),
      ],
    );
  }
}
