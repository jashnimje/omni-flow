import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../serial_channel.dart';
import 'esp_rom.dart' show FlashException, FlashProgress;

/// An Intel HEX file as one image from address 0, with the gaps 0xFF.
Uint8List parseIntelHex(String text) {
  final bytes = <int, int>{};
  var base = 0;
  var maxAddress = 0;
  for (final (n, raw) in const LineSplitter().convert(text).indexed) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (!line.startsWith(':') || line.length < 11 || line.length.isEven) {
      throw FlashException('line ${n + 1} of the HEX file is not a record');
    }
    final data = [
      for (var i = 1; i < line.length; i += 2)
        int.parse(line.substring(i, i + 2), radix: 16),
    ];
    if (data.fold<int>(0, (a, b) => a + b) & 0xFF != 0) {
      throw FlashException('line ${n + 1} of the HEX file has a bad checksum');
    }
    final count = data[0];
    final address = (data[1] << 8) | data[2];
    final type = data[3];
    final payload = data.sublist(4, 4 + count);
    switch (type) {
      case 0x00:
        for (var i = 0; i < payload.length; i++) {
          bytes[base + address + i] = payload[i];
        }
        if (base + address + payload.length > maxAddress) {
          maxAddress = base + address + payload.length;
        }
      case 0x01:
        break;
      case 0x02:
        base = ((payload[0] << 8) | payload[1]) << 4;
      case 0x04:
        base = ((payload[0] << 8) | payload[1]) << 16;
    }
  }
  final image = Uint8List(maxAddress)..fillRange(0, maxAddress, 0xFF);
  bytes.forEach((a, b) => image[a] = b);
  return image;
}

/// Writes an image to an Arduino Uno or Nano through Optiboot, its serial
/// bootloader, with the STK500 v1 commands avrdude sends: reset with DTR,
/// sync, then a 128-byte page at a time, each read back to check it.
class Stk500Flasher {
  Stk500Flasher(this._link, {this.delay = _sleep});

  final SerialLink _link;
  final Future<void> Function(Duration) delay;

  static Future<void> _sleep(Duration d) => Future<void>.delayed(d);

  static const pageSize = 128;
  static const _eop = 0x20;
  static const _insync = 0x14;
  static const _ok = 0x10;

  /// The ATmega328P's flash, less the 512 bytes Optiboot keeps.
  static const maxImage = 32768 - 512;

  final _pending = <int>[];
  Completer<void>? _more;
  StreamSubscription<List<int>>? _input;

  Future<void> flash(Uint8List image, {FlashProgress? progress}) async {
    if (image.length > maxImage) {
      throw FlashException(
        'the image is ${image.length} bytes, more than the $maxImage an Uno '
        'holds',
      );
    }
    _input = _link.input.listen((bytes) {
      _pending.addAll(bytes);
      _more?.complete();
      _more = null;
    });
    try {
      progress?.call('Connecting', 0);
      await _reset();
      await _sync();
      await _command([0x50, _eop]);
      final pages = (image.length + pageSize - 1) ~/ pageSize;
      for (var p = 0; p < pages; p++) {
        final page = Uint8List(pageSize)..fillRange(0, pageSize, 0xFF);
        final start = p * pageSize;
        page.setRange(
          0,
          (image.length - start).clamp(0, pageSize),
          image,
          start,
        );
        final word = start >> 1;
        await _command([0x55, word & 0xFF, word >> 8, _eop]);
        await _command([0x64, 0, pageSize, 0x46, ...page, _eop]);
        await _command([0x55, word & 0xFF, word >> 8, _eop]);
        final back = await _command([
          0x74,
          0,
          pageSize,
          0x46,
          _eop,
        ], read: pageSize);
        for (var i = 0; i < pageSize; i++) {
          if (back[i] != page[i]) {
            throw FlashException(
              'the board read back byte ${start + i} wrong: the flash may be '
              'worn, try again',
            );
          }
        }
        progress?.call('Writing', (p + 1) / pages);
      }
      await _command([0x51, _eop]);
      progress?.call('Done', 1);
    } finally {
      await _input?.cancel();
    }
  }

  /// DTR down then up pulses the board's reset line through its capacitor,
  /// and Optiboot listens for about a second after.
  Future<void> _reset() async {
    await _link.setLines(dtr: false, rts: false);
    await delay(const Duration(milliseconds: 250));
    await _link.setLines(dtr: true, rts: true);
    await delay(const Duration(milliseconds: 50));
  }

  Future<void> _sync() async {
    for (var attempt = 0; attempt < 10; attempt++) {
      _pending.clear();
      try {
        await _command([
          0x30,
          _eop,
        ], timeout: const Duration(milliseconds: 300));
        return;
      } on TimeoutException {
        continue;
      } on FlashException {
        continue;
      }
    }
    throw FlashException(
      'The board did not answer its bootloader. Check it is an Uno or Nano '
      'with Optiboot, and press its reset button as the flash starts',
    );
  }

  Future<Uint8List> _command(
    List<int> bytes, {
    int read = 0,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    await _link.write(bytes);
    final reply = await _take(read + 2, timeout);
    if (reply.first != _insync || reply.last != _ok) {
      throw FlashException('the bootloader lost sync');
    }
    return Uint8List.fromList(reply.sublist(1, 1 + read));
  }

  Future<List<int>> _take(int n, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_pending.length < n) {
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) throw TimeoutException('no reply', timeout);
      _more = Completer<void>();
      await _more!.future.timeout(left);
    }
    final out = _pending.sublist(0, n);
    _pending.removeRange(0, n);
    return out;
  }
}
