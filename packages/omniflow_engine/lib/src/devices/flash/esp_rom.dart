import 'dart:async';
import 'dart:typed_data';

import '../serial_channel.dart';

/// SLIP framing, as the ESP ROM bootloader speaks it: each packet between
/// 0xC0 bytes, with 0xC0 and 0xDB escaped.
abstract final class Slip {
  static const end = 0xC0;
  static const esc = 0xDB;

  static Uint8List encode(List<int> packet) {
    final out = BytesBuilder(copy: false)..addByte(end);
    for (final b in packet) {
      if (b == end) {
        out.add(const [esc, 0xDC]);
      } else if (b == esc) {
        out.add(const [esc, 0xDD]);
      } else {
        out.addByte(b);
      }
    }
    out.addByte(end);
    return out.toBytes();
  }
}

/// Splits a byte stream into SLIP packets.
class SlipReader {
  final _packets = StreamController<Uint8List>.broadcast();
  final _current = BytesBuilder(copy: false);
  var _inPacket = false;
  var _escaped = false;

  Stream<Uint8List> get packets => _packets.stream;

  void add(List<int> bytes) {
    for (final b in bytes) {
      if (b == Slip.end) {
        if (_inPacket && _current.length > 0) {
          _packets.add(_current.takeBytes());
        }
        _inPacket = true;
        _escaped = false;
        continue;
      }
      if (!_inPacket) continue;
      if (_escaped) {
        _current.addByte(
          b == 0xDC
              ? Slip.end
              : b == 0xDD
              ? Slip.esc
              : b,
        );
        _escaped = false;
      } else if (b == Slip.esc) {
        _escaped = true;
      } else {
        _current.addByte(b);
      }
    }
  }

  Future<void> close() => _packets.close();
}

/// The chips the OmniFlow firmware runs on, as their ROM reports them.
enum EspChip {
  esp8266(0xfff0c101, 2),
  esp32(0x00f01d83, 4);

  const EspChip(this.magic, this.statusBytes);

  /// What the ROM reads at 0x40001000.
  final int magic;

  /// How many status bytes end each ROM reply.
  final int statusBytes;
}

/// A step of a flash, for a progress bar.
typedef FlashProgress = void Function(String stage, double done);

/// The flash failed, with a reason a person can act on.
class FlashException implements Exception {
  FlashException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Writes an image to an ESP32 or ESP8266 through its ROM bootloader over
/// a serial link, the protocol esptool uses: reset into the bootloader with
/// DTR and RTS, sync, find the chip, erase, write 1 KiB blocks, then reset
/// into the new firmware. No stub is uploaded, so nothing but the image
/// reaches the chip.
class EspRomFlasher {
  EspRomFlasher(this._link, {this.fastBaud = 460800, this.delay = _sleep});

  final SerialLink _link;

  /// The speed the ROM is moved to for the write, where it can (ESP32).
  final int fastBaud;
  final Future<void> Function(Duration) delay;

  static Future<void> _sleep(Duration d) => Future<void>.delayed(d);

  static const _sync = 0x08;
  static const _readReg = 0x0A;
  static const _flashBegin = 0x02;
  static const _flashData = 0x03;
  static const _flashEnd = 0x04;
  static const _spiSetParams = 0x0B;
  static const _spiAttach = 0x0D;
  static const _changeBaud = 0x0F;
  static const blockSize = 0x400;

  final _reader = SlipReader();
  EspChip? _chip;
  StreamSubscription<List<int>>? _input;

  /// Flashes [image] at [offset] and starts it. Returns the chip found.
  Future<EspChip> flash(
    Uint8List image, {
    int offset = 0,
    FlashProgress? progress,
    EspChip? expect,
  }) async {
    _input = _link.input.listen(_reader.add);
    try {
      progress?.call('Connecting', 0);
      await _enterBootloader();
      await _syncUp();
      final chip = _chip = await _detect();
      if (expect != null && chip != expect) {
        await _hardReset();
        throw FlashException(
          'the board is an ${chip.name}, not an ${expect.name}: pick the '
          '${chip.name} firmware. Nothing was written',
        );
      }
      if (chip == EspChip.esp32) {
        await _command(_spiAttach, Uint8List(8));
        await _command(
          _spiSetParams,
          _words([0, 4 << 20, 64 << 10, 4 << 10, 256, 0xffff]),
        );
        await _command(_changeBaud, _words([fastBaud, 0]));
        await _link.setBaud(fastBaud);
        await delay(const Duration(milliseconds: 50));
      }
      final blocks = (image.length + blockSize - 1) ~/ blockSize;
      progress?.call('Erasing', 0);
      await _command(
        _flashBegin,
        _words([
          chip == EspChip.esp8266
              ? esp8266EraseSize(offset, image.length)
              : image.length,
          blocks,
          blockSize,
          offset,
        ]),
        // Erasing takes up to 30 s a megabyte.
        timeout: Duration(seconds: 10 + 30 * (image.length >> 20) + 30),
      );
      for (var seq = 0; seq < blocks; seq++) {
        final block = Uint8List(blockSize)..fillRange(0, blockSize, 0xFF);
        final start = seq * blockSize;
        block.setRange(
          0,
          (image.length - start).clamp(0, blockSize),
          image,
          start,
        );
        await _command(
          _flashData,
          Uint8List.fromList([
            ..._words([blockSize, seq, 0, 0]),
            ...block,
          ]),
          checksum: espChecksum(block),
          timeout: const Duration(seconds: 5),
        );
        progress?.call('Writing', (seq + 1) / blocks);
      }
      await _command(_flashEnd, _words([1]));
      await _hardReset();
      progress?.call('Done', 1);
      return chip;
    } finally {
      await _input?.cancel();
    }
  }

  /// The classic auto-reset circuit: RTS holds EN low, DTR holds GPIO0
  /// low, so releasing EN while GPIO0 is low boots the ROM bootloader.
  Future<void> _enterBootloader() async {
    await _link.setLines(dtr: false, rts: true);
    await delay(const Duration(milliseconds: 100));
    await _link.setLines(dtr: true, rts: false);
    await delay(const Duration(milliseconds: 50));
    await _link.setLines(dtr: false);
  }

  Future<void> _hardReset() async {
    await _link.setLines(rts: true);
    await delay(const Duration(milliseconds: 100));
    await _link.setLines(rts: false);
  }

  Future<void> _syncUp() async {
    final data = Uint8List.fromList([
      0x07,
      0x07,
      0x12,
      0x20,
      ...List.filled(32, 0x55),
    ]);
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await _command(_sync, data, timeout: const Duration(milliseconds: 300));
        // The ROM answers each sync several times: let the extras pass.
        await delay(const Duration(milliseconds: 100));
        return;
      } on TimeoutException {
        if (attempt == 4) await _enterBootloader();
      }
    }
    throw FlashException(
      'The board did not go into its bootloader. Hold its BOOT button while '
      'pressing RESET, then try again',
    );
  }

  Future<EspChip> _detect() async {
    final reply = await _command(_readReg, _words([0x40001000]));
    final magic = reply.value;
    for (final chip in EspChip.values) {
      if (chip.magic == magic) return chip;
    }
    throw FlashException(
      'This chip (id 0x${magic.toRadixString(16)}) is not an ESP32 or '
      'ESP8266. OmniFlow builds firmware for those two',
    );
  }

  Future<({int value, Uint8List data})> _command(
    int op,
    Uint8List data, {
    int checksum = 0,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final packet = BytesBuilder(copy: false)
      ..add([0x00, op])
      ..add(_u16(data.length))
      ..add(_words([checksum]))
      ..add(data);
    final reply = _reader.packets
        .where((p) => p.length >= 8 && p[0] == 0x01 && p[1] == op)
        .first
        .timeout(timeout);
    await _link.write(Slip.encode(packet.toBytes()));
    final p = await reply;
    final view = ByteData.sublistView(p);
    final size = view.getUint16(2, Endian.little);
    final value = view.getUint32(4, Endian.little);
    final body = p.sublist(8, 8 + size.clamp(0, p.length - 8));
    // The last status bytes: status, then the error code.
    final tail = (_chip?.statusBytes ?? (body.length >= 4 ? 4 : 2)).clamp(
      0,
      body.length,
    );
    final status = body.sublist(body.length - tail);
    if (status.isNotEmpty && status[0] != 0) {
      throw FlashException(
        'the bootloader refused step 0x${op.toRadixString(16)} '
        '(error 0x${(status.length > 1 ? status[1] : 0).toRadixString(16)})',
      );
    }
    return (value: value, data: body);
  }

  static Uint8List _u16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

  static Uint8List _words(List<int> words) {
    final out = ByteData(words.length * 4);
    for (var i = 0; i < words.length; i++) {
      out.setUint32(i * 4, words[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }
}

/// The checksum of a FLASH_DATA block: every byte XORed onto 0xEF.
int espChecksum(List<int> data) {
  var c = 0xEF;
  for (final b in data) {
    c ^= b;
  }
  return c;
}

/// The erase size the ESP8266 ROM needs: its FLASH_BEGIN erases the first
/// sectors of each 64 KiB block twice, so esptool asks for less.
int esp8266EraseSize(int offset, int size) {
  const sectorsPerBlock = 16;
  const sectorSize = 0x1000;
  final numSectors = (size + sectorSize - 1) ~/ sectorSize;
  final startSector = offset ~/ sectorSize;
  var headSectors = sectorsPerBlock - (startSector % sectorsPerBlock);
  if (numSectors < headSectors) headSectors = numSectors;
  if (numSectors < 2 * headSectors) {
    return (numSectors + 1) ~/ 2 * sectorSize;
  }
  return (numSectors - headSectors) * sectorSize;
}
