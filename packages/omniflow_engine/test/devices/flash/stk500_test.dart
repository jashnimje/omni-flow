import 'dart:async';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/flash/esp_rom.dart';
import 'package:omniflow_engine/src/devices/flash/stk500.dart';
import 'package:test/test.dart';

/// Optiboot on an Uno: STK500 v1 over serial, with a 32 KiB flash.
class _FakeOptiboot implements SerialLink {
  final _out = StreamController<List<int>>();
  final flash = Uint8List(32768)..fillRange(0, 32768, 0xFF);
  final _buf = <int>[];
  var _address = 0;
  var left = false;

  @override
  Stream<List<int>> get input => _out.stream;

  @override
  Future<void> write(List<int> bytes) async {
    _buf.addAll(bytes);
    while (_buf.isNotEmpty && _buf.contains(0x20)) {
      final cmd = _buf.first;
      final need = switch (cmd) {
        0x30 || 0x50 || 0x51 => 2,
        0x55 => 4,
        0x64 => 5 + 128,
        0x74 => 5,
        _ => 2,
      };
      if (_buf.length < need) return;
      final c = _buf.sublist(0, need);
      _buf.removeRange(0, need);
      switch (cmd) {
        case 0x55:
          _address = (c[1] | (c[2] << 8)) * 2;
          _out.add([0x14, 0x10]);
        case 0x64:
          flash.setRange(_address, _address + 128, c.sublist(4, 4 + 128));
          _out.add([0x14, 0x10]);
        case 0x74:
          _out.add([0x14, ...flash.sublist(_address, _address + 128), 0x10]);
        case 0x51:
          left = true;
          _out.add([0x14, 0x10]);
        default:
          _out.add([0x14, 0x10]);
      }
    }
  }

  @override
  Future<void> setLines({bool? dtr, bool? rts}) async {}

  @override
  Future<void> setBaud(int baud) async {}

  @override
  Future<void> close() => _out.close();
}

Future<void> _noWait(Duration _) async {}

void main() {
  test('an Intel HEX file becomes one image, gaps filled with 0xFF', () {
    final image = parseIntelHex(
      ':03000000010203F7\n'
      ':02000600AABB93\n'
      ':00000001FF\n',
    );
    expect(image, [1, 2, 3, 0xFF, 0xFF, 0xFF, 0xAA, 0xBB]);
    expect(
      () => parseIntelHex(':03000000010203F6\n'),
      throwsA(isA<FlashException>()),
    );
  });

  test('writes every page to an Uno, checks each, and leaves', () async {
    final board = _FakeOptiboot();
    final image = Uint8List.fromList([for (var i = 0; i < 300; i++) i & 0xFF]);
    await Stk500Flasher(board, delay: _noWait).flash(image);
    expect(board.flash.sublist(0, 300), image);
    expect(board.flash.sublist(300, 384), everyElement(0xFF));
    expect(board.left, isTrue);
  });

  test(
    'an image bigger than an Uno is refused before anything is sent',
    () async {
      await expectLater(
        Stk500Flasher(_FakeOptiboot(), delay: _noWait).flash(Uint8List(40000)),
        throwsA(isA<FlashException>()),
      );
    },
  );
}
