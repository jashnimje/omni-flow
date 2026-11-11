import 'dart:async';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/flash/esp_rom.dart';

/// An ESP ROM bootloader on the other end of a serial link.
class FakeRom implements SerialLink {
  FakeRom(this.chip, {this.answersSync = true});

  final EspChip chip;
  final bool answersSync;
  final _out = StreamController<List<int>>();
  final _reader = SlipReader();
  final lines = <({bool? dtr, bool? rts})>[];
  final ops = <int>[];
  final flash = <int, Uint8List>{};
  int? erased;
  var baud = 115200;

  FakeRom.listen(this.chip) : answersSync = true;

  void start() => _reader.packets.listen(_onPacket);

  @override
  Stream<List<int>> get input => _out.stream;

  @override
  Future<void> write(List<int> bytes) async => _reader.add(bytes);

  void _onPacket(Uint8List p) {
    final view = ByteData.sublistView(p);
    final op = p[1];
    final size = view.getUint16(2, Endian.little);
    final checksum = view.getUint32(4, Endian.little);
    final data = p.sublist(8, 8 + size);
    ops.add(op);
    var value = 0;
    var ok = true;
    switch (op) {
      case 0x08:
        if (!answersSync) return;
      case 0x0A:
        value = chip.magic;
      case 0x02:
        erased = ByteData.sublistView(data).getUint32(0, Endian.little);
      case 0x03:
        final seq = ByteData.sublistView(data).getUint32(4, Endian.little);
        final block = data.sublist(16);
        ok = espChecksum(block) == checksum;
        flash[seq] = block;
    }
    final status = Uint8List(chip.statusBytes)..[0] = ok ? 0 : 1;
    final reply = ByteData(8)
      ..setUint8(0, 1)
      ..setUint8(1, op)
      ..setUint16(2, status.length, Endian.little)
      ..setUint32(4, value, Endian.little);
    _out.add(Slip.encode([...reply.buffer.asUint8List(), ...status]));
  }

  @override
  Future<void> setLines({bool? dtr, bool? rts}) async =>
      lines.add((dtr: dtr, rts: rts));

  @override
  Future<void> setBaud(int baud) async => this.baud = baud;

  @override
  Future<void> close() async => _out.close();
}
