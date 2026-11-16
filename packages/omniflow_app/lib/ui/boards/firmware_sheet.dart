import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../state/providers.dart';
import '../design/design.dart';
import '../../api/screen_calls.dart';

/// The boards OmniFlow ships firmware for, with what each is called and
/// the asset the app carries.
const firmwareChips = {
  'esp32': (name: 'ESP32', asset: 'assets/firmware/esp32.bin'),
  'esp8266': (
    name: 'ESP8266 (NodeMCU, Wemos D1)',
    asset: 'assets/firmware/esp8266.bin',
  ),
  'uno': (name: 'Arduino Uno or Nano', asset: 'assets/firmware/uno.hex'),
};

/// Writes firmware to a board plugged into the phone: OmniFlow's own, so
/// a blank board becomes one OmniFlow can use, or the user's own build.
Future<void> showFirmwareSheet(BuildContext context) =>
    showOmniSheet<void>(context, builder: (_) => const _FirmwareSheet());

class _FirmwareSheet extends ConsumerStatefulWidget {
  const _FirmwareSheet();

  @override
  ConsumerState<_FirmwareSheet> createState() => _FirmwareSheetState();
}

class _FirmwareSheetState extends ConsumerState<_FirmwareSheet> {
  List<String>? _ports;
  String? _port;
  var _chip = 'esp32';

  /// The user's own image, when they picked one.
  ({String name, String path})? _own;
  ({String stage, double done})? _progress;
  StreamSubscription<Map<String, Object?>>? _events;
  String? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _look();
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  Future<void> _look() async {
    setState(() => _ports = null);
    final r = await ref.read(engineClientProvider).call(BoardCalls.ports);
    if (!mounted) return;
    final ports = [
      for (final p in (r['ports'] as List? ?? const []))
        if ('$p'.startsWith('usb:')) '$p',
    ];
    setState(() {
      _ports = ports;
      _port = ports.length == 1 ? ports.single : null;
    });
  }

  Future<void> _pickOwn() async {
    final ext = _chip == 'uno' ? 'hex' : 'bin';
    final files = await ref.read(phoneFilesProvider).pick(extensions: [ext]);
    if (files.isEmpty || !mounted) return;
    setState(() => _own = files.first);
  }

  /// The image as a file the engine reads: the user's, or the app's asset
  /// copied out of the APK.
  Future<String> _imagePath() async {
    if (_own case final own?) return own.path;
    final asset = firmwareChips[_chip]!.asset;
    final data = await rootBundle.load(asset);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${asset.split('/').last}');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file.path;
  }

  Future<void> _flash() async {
    final port = _port;
    if (port == null) return;
    final ok = await confirm(
      context,
      title: 'Write firmware to this board?',
      body:
          'It replaces what the board runs now, and its Wi-Fi and pins are '
          'set up again afterwards. Keep the cable in until it says done.',
      action: 'Write it',
    );
    if (!ok || !mounted) return;
    final engine = ref.read(engineClientProvider);
    setState(() {
      _error = null;
      _result = null;
      _progress = (stage: 'Starting', done: 0);
    });
    await _events?.cancel();
    _events = engine.events
        .where((e) => e['event'] == 'board.flashProgress' && e['port'] == port)
        .listen((e) {
          if (!mounted) return;
          setState(
            () => _progress = (
              stage: '${e['stage']}',
              done: (e['done'] as num? ?? 0).toDouble(),
            ),
          );
        });
    String file;
    try {
      file = await _imagePath();
    } on Object {
      if (!mounted) return;
      setState(() {
        _progress = null;
        _error = 'This copy of the app has no firmware for that board.';
      });
      return;
    }
    final r = await engine.call(BoardCalls.flash, {
      'port': port,
      'chip': _chip,
      'file': file,
    });
    if (!mounted) return;
    setState(() {
      _progress = null;
      if (r['ok'] == true) {
        final seconds = ((r['ms'] as num? ?? 0) / 1000).round();
        _result = _own == null
            ? 'OmniFlow is on the board ($seconds s). Set it up next: give '
                  'it a name and your Wi-Fi.'
            : 'Your firmware is on the board ($seconds s).';
      } else {
        _error = errorMessage(r);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ports = _ports;
    final progress = _progress;
    return OmniSheet(
      title: 'Install firmware',
      subtitle: 'For a new board, or to put OmniFlow back on one.',
      children: [
        if (ports == null)
          const Padding(
            padding: EdgeInsets.all(OmniSpace.lg),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (ports.isEmpty) ...[
          const OmniBanner.info(
            'Plug the board into this phone with a USB data cable, and say '
            'yes if the phone asks to let OmniFlow use it.',
            key: ValueKey('fw-none'),
          ),
          OmniButton.ghost(
            key: const ValueKey('fw-look-again'),
            label: 'Look again',
            icon: OmniIcons.retry,
            onPressed: _look,
          ),
        ] else ...[
          for (final p in ports)
            OmniListRow(
              key: ValueKey('fw-port-$p'),
              icon: OmniIcons.board,
              title: ports.length == 1 ? 'The board on USB' : p,
              trailing: p == _port
                  ? const Icon(OmniIcons.check, color: OmniColors.accent)
                  : null,
              onTap: () => setState(() => _port = p),
            ),
          const OmniSectionHeader('Which board is it?'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final MapEntry(key: chip, value: c) in firmwareChips.entries)
                OmniFilterChip(
                  key: ValueKey('fw-chip-$chip'),
                  label: c.name,
                  selected: _chip == chip,
                  onTap: () => setState(() {
                    _chip = chip;
                    _own = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: OmniSpace.sm),
          OmniListRow(
            key: const ValueKey('fw-own'),
            icon: OmniIcons.edit,
            title: _own == null ? 'OmniFlow firmware' : _own!.name,
            subtitle: _own == null
                ? 'Or tap to write your own ${_chip == 'uno' ? '.hex' : '.bin'}, built with the Arduino IDE or arduino-cli'
                : 'Your own firmware. Tap to choose another',
            chevron: true,
            onTap: _pickOwn,
          ),
          const Text(
            'A Pico W is flashed by holding BOOTSEL while plugging it in, '
            'then copying the firmware to the drive it shows.',
            style: OmniText.caption,
          ),
          if (progress case final p?) ...[
            const SizedBox(height: OmniSpace.md),
            Text(p.stage, key: const ValueKey('fw-stage')),
            const SizedBox(height: OmniSpace.xs),
            LinearProgressIndicator(
              key: const ValueKey('fw-progress'),
              value: p.stage == 'Writing' ? p.done : null,
            ),
          ],
          if (_error case final e?)
            OmniBanner.error(key: const ValueKey('fw-error'), e),
          if (_result case final r?)
            OmniBanner.info(key: const ValueKey('fw-done'), r),
          const SizedBox(height: OmniSpace.md),
          OmniButton(
            key: const ValueKey('fw-write'),
            label: progress == null ? 'Write firmware' : 'Writing…',
            onPressed: progress != null || _port == null ? null : _flash,
          ),
        ],
      ],
    );
  }
}
