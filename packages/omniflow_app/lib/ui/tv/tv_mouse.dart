import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart' show showMessage;
import '../design/design.dart';
import 'tv_controller.dart';
import 'tv_frame.dart';
import 'tv_page.dart' show Keycodes;

/// Whether the TV runs OmniFlow's pointer helper, which draws a live
/// pointer on the TV itself. [unanswered] is a TV that did not say, which
/// keeps the picture without offering an install.
enum _Helper { unknown, unanswered, missing, running }

/// A touchpad for apps that want a pointer: a browser, a game's menu, a
/// settings screen with no focus. With OmniFlow's pointer helper on the TV
/// the pointer moves live on the TV. Without it, Android TV draws no
/// pointer for touches sent over ADB, so the TV's picture sits above the
/// pad with the pointer drawn on it. One finger moves it, a tap clicks
/// where it is, two fingers scroll, and a long press holds.
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

  /// How often a drag sends the live pointer a move: about 30 a second.
  static const _sendEvery = Duration(milliseconds: 33);

  Offset _pointer = const Offset(0.5, 0.5);
  Uint8List? _frame;
  Size _screen = const Size(1920, 1080);
  Timer? _refresh;
  var _reading = false;

  /// Why the last picture did not come, shown in its place.
  String? _error;

  var _helper = _Helper.unknown;
  var _checking = false;
  var _installing = false;

  /// The drag not sent to the live pointer yet, as fractions of the screen.
  Offset _unsent = Offset.zero;
  Timer? _sendTimer;
  var _sending = false;

  TvController get tv => widget.tv;

  bool get _live => _helper == _Helper.running;

  /// Whether the app is in front: the picture stops refreshing behind the
  /// lock screen or another app.
  var _inFront = true;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        _inFront = false;
        _sync();
      },
      onShow: () {
        _inFront = true;
        _sync();
      },
    );
    _sync();
  }

  @override
  void didUpdateWidget(TvMouse old) {
    super.didUpdateWidget(old);
    // Opening the tab again asks a TV that did not answer before.
    if (widget.active && !old.active && _helper == _Helper.unanswered) {
      _helper = _Helper.unknown;
    }
    _sync();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _holdTimer?.cancel();
    _refresh?.cancel();
    _sendTimer?.cancel();
    super.dispose();
  }

  void _sync() {
    if (widget.active && _helper == _Helper.unknown) {
      unawaited(_checkHelper());
    }
    // The picture waits for the answer, as a TV with the helper needs none.
    if (widget.active && _inFront && _helper != _Helper.unknown && !_live) {
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

  Future<void> _checkHelper() async {
    if (_checking) return;
    _checking = true;
    try {
      final r = await tv.client.call(
        TvPointerCalls.status,
        TvCalls.readArgs(tv.id),
      );
      if (!mounted) return;
      setState(
        () => _helper = r['ok'] != true
            ? _Helper.unanswered
            : TvPointerCalls.isRunning(r)
            ? _Helper.running
            : _Helper.missing,
      );
      _sync();
      if (_live) await _showLive();
    } finally {
      _checking = false;
    }
  }

  /// Puts the TV's pointer where the pad's is, so a click lands there.
  Future<void> _showLive() async {
    final r = await tv.client.call(TvPointerCalls.pointer, {
      'id': tv.id,
      'to': [_pointer.dx, _pointer.dy],
    });
    if ((r['error'] as Map?)?['type'] == 'not_ready') _lostHelper();
  }

  /// The helper stopped answering: back to the picture until it is
  /// installed or started again.
  void _lostHelper() {
    if (!mounted || !_live) return;
    setState(() => _helper = _Helper.missing);
    _sync();
  }

  Future<void> _installHelper() async {
    final ok = await confirm(
      context,
      title: 'Install the pointer helper on the TV?',
      body:
          'OmniFlow puts its own small app on the TV that draws a mouse '
          'pointer, so you see it move as you drag here. It may draw over '
          'other apps and keeps running in the background. It never uses '
          'the network: it has no internet permission and takes moves only '
          'from OmniFlow over the TV\'s debugging link. You can uninstall '
          'it from the TV\'s apps at any time.',
      action: 'Install',
    );
    if (!ok || !mounted) return;
    setState(() => _installing = true);
    try {
      final String path;
      try {
        path = await _helperApk();
      } on Object {
        showMessage(
          'This build of OmniFlow does not carry the pointer helper.',
        );
        return;
      }
      final r = await tv.call(
        TvPointerCalls.install,
        TvPointerCalls.installArgs(tv.id, path),
      );
      if (!mounted || r['ok'] != true) return;
      setState(
        () => _helper = TvPointerCalls.isRunning(r)
            ? _Helper.running
            : _Helper.missing,
      );
      _sync();
      if (_live) await _showLive();
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  /// The bundled APK as a file the engine reads.
  Future<String> _helperApk() async {
    final data = await rootBundle.load(TvPointerCalls.asset);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${TvPointerCalls.asset.split('/').last}');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file.path;
  }

  Future<void> _read() async {
    if (_reading || _live) return;
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
      final png = await decodeFrame('${r['png']}');
      if (!mounted) return;
      setState(() {
        _error = null;
        _frame = png;
        if (w != null && h != null && w > 0 && h > 0) _screen = Size(w, h);
      });
    } finally {
      _reading = false;
    }
  }

  void _move(Offset delta, Size pad) {
    if (pad.isEmpty) return;
    final by = Offset(
      delta.dx / pad.width * _speed,
      delta.dy / pad.height * _speed,
    );
    setState(() {
      _pointer = Offset(
        (_pointer.dx + by.dx).clamp(0.0, 1.0),
        (_pointer.dy + by.dy).clamp(0.0, 1.0),
      );
    });
    if (!_live) return;
    _unsent += by;
    _sendTimer ??= Timer(_sendEvery, _sendMove);
  }

  /// Sends the drag gathered since the last move, one call at a time.
  Future<void> _sendMove() async {
    _sendTimer = null;
    if (_sending || _unsent == Offset.zero) return;
    final by = _unsent;
    _unsent = Offset.zero;
    _sending = true;
    try {
      final r = await tv.client.call(
        TvPointerCalls.pointer,
        TvPointerCalls.byArgs(tv.id, by),
      );
      if (r['ok'] != true) {
        if ((r['error'] as Map?)?['type'] == 'not_ready') _lostHelper();
        return;
      }
    } finally {
      _sending = false;
      if (_unsent != Offset.zero && _live) {
        _sendTimer ??= Timer(_sendEvery, _sendMove);
      }
    }
  }

  Future<void> _click() async {
    if (_live) {
      await tv.call(TvPointerCalls.click, TvCalls.idArgs(tv.id));
      return;
    }
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
          padding: const EdgeInsets.symmetric(horizontal: OmniSpace.xs),
          child: OmniButton.ghost(
            key: ValueKey(key),
            label: label,
            icon: icon,
            onPressed: onTap,
          ),
        ),
      );

  /// The TV's picture with the pointer drawn on it, for a TV without the
  /// helper.
  Widget _picture() {
    final frame = _frame;
    return AspectRatio(
      aspectRatio: _screen.width / _screen.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(OmniShape.md),
        child: ColoredBox(
          color: Colors.black,
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              fit: StackFit.expand,
              children: [
                if (frame != null)
                  TvFrame(frame, fit: BoxFit.fill)
                else if (_error case final e?)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(OmniSpace.md),
                      child: Text(
                        e,
                        key: const ValueKey('tv-mouse-error'),
                        textAlign: TextAlign.center,
                        style: OmniText.captionOf(context),
                      ),
                    ),
                  )
                else
                  const Center(child: CircularProgressIndicator()),
                Positioned(
                  left: _pointer.dx * box.maxWidth - 2,
                  top: _pointer.dy * box.maxHeight - 2,
                  child: IgnorePointer(
                    child: Icon(
                      Icons.navigation_rounded,
                      key: const ValueKey('tv-mouse-pointer'),
                      size: 22,
                      color: OmniPalette.of(context).accent,
                      shadows: const [Shadow(blurRadius: 3)],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('tv-mouse'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_live)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: OmniSpace.xs),
            child: Text(
              'The pointer moves on the TV as you drag.',
              key: const ValueKey('tv-mouse-live'),
              textAlign: TextAlign.center,
              style: OmniText.captionOf(context),
            ),
          )
        else ...[
          _picture(),
          if (_helper == _Helper.missing) ...[
            const SizedBox(height: OmniSpace.sm),
            OmniButton.ghost(
              key: const ValueKey('tv-mouse-install-helper'),
              label: _installing
                  ? 'Installing the pointer helper...'
                  : 'Install the pointer helper on the TV',
              icon: Icons.mouse_rounded,
              onPressed: _installing ? null : _installHelper,
            ),
          ],
        ],
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
                  color: OmniPalette.of(context).card,
                  borderRadius: BorderRadius.circular(OmniRadii.card),
                  border: Border.all(color: OmniPalette.of(context).line),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Drag to move · tap to click\nTwo fingers to scroll · hold to long-press',
                  textAlign: TextAlign.center,
                  style: OmniText.captionOf(context),
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
