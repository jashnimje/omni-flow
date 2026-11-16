import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../settings/backup_page.dart' show shareFileProvider;
import 'tv_controller.dart';
import 'tv_frame.dart';

/// Where the TV's screenshots and recordings land on the phone.
Future<String> tvSaveDir(WidgetRef ref, {bool phone = false}) async {
  final base = await ref.read(phoneFilesProvider).downloadsDir();
  final dir = Directory(
    '${base ?? Directory.systemTemp.path}/${phone ? 'Phone' : 'TV'}',
  );
  await dir.create(recursive: true);
  return dir.path;
}

/// What a save to the phone that failed says: the folder is full, gone or
/// not writable.
const couldNotSave =
    'Could not save it on this phone. Check there is space free and try '
    'again.';

String _stamp(DateTime t) =>
    '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}'
    '${_two(t.second)}';

String _two(int n) => n.toString().padLeft(2, '0');

/// 4.6: the TV's screen on the phone. Live view shows a new frame as fast as
/// the TV takes them, and a tap or swipe on it is sent to the TV, so apps
/// that want a touch screen work. Screenshots and recordings save to
/// Download, OmniFlow, TV.
class TvScreenTab extends ConsumerStatefulWidget {
  const TvScreenTab({super.key, required this.tv, required this.active});

  final TvController tv;

  /// Whether the tab is the one on screen: live view only reads then.
  final bool active;

  @override
  ConsumerState<TvScreenTab> createState() => _TvScreenTabState();
}

class _TvScreenTabState extends ConsumerState<TvScreenTab> {
  Uint8List? _frame;
  Size? _size;
  var _live = false;
  var _looping = false;
  String? _error;
  late final AppLifecycleListener _lifecycle;
  var _inFront = true;

  // Recording.
  var _seconds = 60;
  bool? _recording;
  DateTime? _since;
  String? _recordFile;
  String? _saved;
  Timer? _tick;
  var _busy = false;

  Offset? _dragFrom;
  DateTime? _dragAt;

  TvController get tv => widget.tv;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () => _inFront = false,
      onShow: () {
        _inFront = true;
        _loop();
      },
    );
    unawaited(_status());
    unawaited(_grab());
  }

  @override
  void didUpdateWidget(TvScreenTab old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _loop();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _tick?.cancel();
    super.dispose();
  }

  bool get _showing => mounted && widget.active && _inFront;

  Future<bool> _grab() async {
    final r = await tv.client.call(TvCalls.screenshot, TvCalls.readArgs(tv.id));
    if (!mounted) return false;
    if (r['ok'] != true) {
      setState(() => _error = errorMessage(r));
      return false;
    }
    final png = await decodeFrame('${r['png']}');
    if (!mounted) return false;
    setState(() {
      _error = null;
      _frame = png;
      final w = (r['width'] as num?)?.toDouble();
      final h = (r['height'] as num?)?.toDouble();
      if (w != null && h != null && w > 0 && h > 0) _size = Size(w, h);
    });
    return true;
  }

  /// One frame at a time: the next is asked for once the last arrived.
  Future<void> _loop() async {
    if (_looping || !_live) return;
    _looping = true;
    try {
      while (_live && _showing) {
        if (!await _grab()) {
          if (mounted) setState(() => _live = false);
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } finally {
      _looping = false;
    }
  }

  void _setLive(bool on) {
    setState(() => _live = on);
    if (on) _loop();
  }

  Offset? _fraction(Offset local, Size box) =>
      box.isEmpty ? null : Offset(local.dx / box.width, local.dy / box.height);

  Future<void> _tap(Offset local, Size box) async {
    final f = _fraction(local, box);
    if (f == null) return;
    await tv.call(TvCalls.tap, TvCalls.tapArgs(tv.id, f.dx, f.dy));
    if (!_live) unawaited(_grab());
  }

  Future<void> _swipe(Offset from, Offset to, Size box, Duration took) async {
    final a = _fraction(from, box);
    final b = _fraction(to, box);
    if (a == null || b == null) return;
    await tv.call(
      TvCalls.swipe,
      TvCalls.swipeArgs(tv.id, a, b, ms: took.inMilliseconds.clamp(50, 2000)),
    );
    if (!_live) unawaited(_grab());
  }

  Future<void> _saveScreenshot() async {
    final frame = _frame;
    if (frame == null) return;
    final File file;
    try {
      final dir = await tvSaveDir(ref, phone: tv.isPhone);
      file = File('$dir/screenshot-${_stamp(DateTime.now())}.png');
      await file.writeAsBytes(frame, flush: true);
    } on FileSystemException {
      if (mounted) showMessage(couldNotSave);
      return;
    }
    if (!mounted) return;
    showMessage(
      'Saved to ${file.path}',
      action: 'Share',
      onAction: () => ref.read(shareFileProvider)(file.path),
    );
  }

  Future<void> _status() async {
    final r = await tv.client.call(
      TvCalls.recordStatus,
      TvCalls.readArgs(tv.id),
    );
    if (!mounted || r['ok'] != true) return;
    setState(() {
      _recording = r['recording'] == true;
      _recordFile = r['file'] as String?;
      _since = DateTime.tryParse('${r['startedAt']}')?.toLocal();
    });
    // Past the limit the tick would only ask again every second.
    if (_recording == true && !_pastLimit) _startTick();
  }

  bool get _pastLimit {
    final since = _since;
    return since != null &&
        DateTime.now().difference(since).inSeconds > _seconds + 2;
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      setState(() {});
      // screenrecord stops on its own at the limit: read where it is then.
      if (_pastLimit) {
        _tick?.cancel();
        await _status();
      }
    });
  }

  Future<void> _record() async {
    setState(() {
      _busy = true;
      _saved = null;
    });
    final r = await tv.call(
      TvCalls.recordStart,
      TvCalls.recordArgs(tv.id, _seconds),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r['ok'] == true) {
        _recording = true;
        _recordFile = r['file'] as String?;
        _since = DateTime.now();
      }
    });
    if (r['ok'] == true) _startTick();
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    final r = await tv.call(TvCalls.recordStop, TvCalls.idArgs(tv.id));
    _tick?.cancel();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r['ok'] == true) {
        _recording = false;
        _recordFile = r['file'] as String? ?? _recordFile;
      }
    });
  }

  Future<void> _download() async {
    final file = _recordFile;
    if (file == null) return;
    final String dir;
    try {
      dir = await tvSaveDir(ref, phone: tv.isPhone);
    } on FileSystemException {
      if (mounted) showMessage(couldNotSave);
      return;
    }
    if (!mounted) return;
    final r = await tv.transfer(
      TvCalls.filesDownload,
      TvCalls.downloadArgs(tv.id, file, dir, overwrite: true),
      name: file.split('/').last,
    );
    if (!mounted || r['ok'] != true) return;
    setState(() => _saved = '$dir/${file.split('/').last}');
  }

  Future<void> _deleteFromTv() async {
    final file = _recordFile;
    if (file == null) return;
    final ok = await confirm(
      context,
      title: 'Delete the recording from the ${tv.noun}?',
      body: _saved == null
          ? 'It is not saved on this phone yet, so it is gone for good.'
          : 'The copy on this phone stays.',
      action: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final r = await tv.call(
      TvCalls.filesDelete,
      TvCalls.deleteArgs(tv.id, [file], dirs: false),
    );
    if (!mounted || r['ok'] != true) return;
    setState(() => _recordFile = null);
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    final size =
        _size ?? (tv.isPhone ? const Size(1080, 2400) : const Size(1920, 1080));
    final since = _since;
    final elapsed = since == null
        ? 0
        : DateTime.now().difference(since).inSeconds;
    return ListView(
      key: const ValueKey('tv-screen'),
      padding: OmniSpace.screenPadding,
      children: [
        ScreenFit(
          portrait: size.height > size.width,
          child: AspectRatio(
            aspectRatio: size.width / size.height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ColoredBox(
                color: Colors.black,
                child: frame == null
                    ? Center(
                        child: _error == null
                            ? const CircularProgressIndicator()
                            : Padding(
                                padding: const EdgeInsets.all(OmniSpace.md),
                                child: Text(
                                  _error!,
                                  textAlign: TextAlign.center,
                                  style: OmniText.caption,
                                ),
                              ),
                      )
                    : LayoutBuilder(
                        builder: (context, box) => Semantics(
                          label: "The ${tv.noun}'s screen, live",
                          image: true,
                          child: GestureDetector(
                            key: const ValueKey('tv-screen-touch'),
                            onTapUp: (d) => _tap(d.localPosition, box.biggest),
                            onPanStart: (d) {
                              _dragFrom = d.localPosition;
                              _dragAt = DateTime.now();
                            },
                            onPanEnd: (d) {
                              final from = _dragFrom;
                              final at = _dragAt;
                              if (from == null || at == null) return;
                              final to =
                                  from + d.velocity.pixelsPerSecond * 0.15;
                              _swipe(
                                from,
                                to,
                                box.biggest,
                                DateTime.now().difference(at),
                              );
                            },
                            child: TvFrame(frame),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: OmniSpace.sm),
        Row(
          children: [
            Expanded(
              child: OmniListRow(
                key: const ValueKey('tv-screen-live'),
                icon: OmniIcons.play,
                title: 'Live view',
                subtitle: _live
                    ? 'Tap or swipe on the picture to touch the ${tv.noun}'
                    : 'A new picture as fast as the ${tv.noun} makes them',
                trailing: Switch(
                  key: const ValueKey('tv-screen-live-switch'),
                  value: _live,
                  onChanged: _setLive,
                ),
                onTap: () => _setLive(!_live),
              ),
            ),
          ],
        ),
        OmniListRow(
          key: const ValueKey('tv-screen-refresh'),
          icon: OmniIcons.retry,
          title: 'Take a fresh picture',
          onTap: _live ? null : _grab,
        ),
        OmniListRow(
          key: const ValueKey('tv-screen-save'),
          icon: OmniIcons.download,
          title: 'Save a screenshot',
          subtitle:
              'to Download, OmniFlow, ${tv.isPhone ? 'Phone' : 'TV'} on this phone',
          onTap: frame == null ? null : _saveScreenshot,
        ),
        const OmniSectionHeader('Record the screen'),
        if (_recording == true) ...[
          OmniBanner.info(
            'Recording · ${elapsed ~/ 60}:${_two(elapsed % 60)} of '
            '${_seconds ~/ 60}:${_two(_seconds % 60)}',
            key: const ValueKey('tv-record-running'),
          ),
          OmniButton(
            key: const ValueKey('tv-record-stop'),
            label: 'Stop recording',
            onPressed: _busy ? null : _stop,
          ),
        ] else ...[
          Wrap(
            spacing: 6,
            children: [
              for (final s in const [30, 60, 180])
                OmniFilterChip(
                  key: ValueKey('tv-record-$s'),
                  label: s < 60 ? '$s s' : '${s ~/ 60} min',
                  selected: _seconds == s,
                  onTap: () => setState(() => _seconds = s),
                ),
            ],
          ),
          const SizedBox(height: OmniSpace.sm),
          OmniButton(
            key: const ValueKey('tv-record-start'),
            label: 'Start recording',
            onPressed: _busy || _recording == null ? null : _record,
          ),
          Text(
            tv.isPhone
                ? 'The phone records at most 3 minutes at a time. Banking and '
                      'video apps show black, which is Android protecting them.'
                : 'The TV records at most 3 minutes at a time, and some TVs have no '
                      'video encoder for it.',
            style: OmniText.caption,
          ),
        ],
        if (_recording == false && _recordFile != null) ...[
          const SizedBox(height: OmniSpace.md),
          OmniListRow(
            key: const ValueKey('tv-record-file'),
            icon: OmniIcons.video,
            title: _recordFile!.split('/').last,
            subtitle: _saved == null ? 'on the ${tv.noun}' : 'saved to $_saved',
          ),
          if (_saved == null)
            OmniButton(
              key: const ValueKey('tv-record-download'),
              label: 'Save it to this phone',
              onPressed: tv.progress != null ? null : _download,
            )
          else
            OmniButton(
              key: const ValueKey('tv-record-share'),
              label: 'Share it',
              onPressed: () => ref.read(shareFileProvider)(_saved!),
            ),
          OmniButton.ghost(
            key: const ValueKey('tv-record-delete'),
            label: 'Delete it from the ${tv.noun}',
            onPressed: _deleteFromTv,
          ),
        ],
        const SizedBox(height: OmniSpace.xl),
      ],
    );
  }
}

/// A portrait screen (a phone) is held to most of the page height and
/// centred, so it fits on one screen. Its [child] keeps the picture's
/// aspect, so a tap lands at the same fraction of the phone's screen.
class ScreenFit extends StatelessWidget {
  const ScreenFit({super.key, required this.portrait, required this.child});

  final bool portrait;
  final Widget child;

  @override
  Widget build(BuildContext context) => portrait
      ? Center(
          child: ConstrainedBox(
            key: const ValueKey('tv-screen-portrait'),
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.62,
            ),
            child: child,
          ),
        )
      : child;
}
