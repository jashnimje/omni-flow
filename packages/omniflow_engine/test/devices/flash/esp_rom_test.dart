import 'dart:async';
import 'dart:typed_data';

import 'package:omniflow_engine/src/devices/flash/esp_rom.dart';
import 'package:test/test.dart';

import 'fake_rom.dart';

Uint8List _image(int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (i * 7 + 3) & 0xFF]);

Future<void> _noWait(Duration _) async {}

void main() {
  test('SLIP escapes the frame and escape bytes and reads them back', () async {
    final packet = [1, 0xC0, 2, 0xDB, 3];
    final encoded = Slip.encode(packet);
    expect(encoded, [0xC0, 1, 0xDB, 0xDC, 2, 0xDB, 0xDD, 3, 0xC0]);
    final reader = SlipReader();
    final got = reader.packets.first;
    reader.add(encoded.sublist(0, 4));
    reader.add(encoded.sublist(4));
    expect(await got, packet);
  });

  for (final chip in EspChip.values) {
    test('writes a whole image to an ${chip.name} and starts it', () async {
      final rom = FakeRom.listen(chip)..start();
      final image = _image(2500);
      final stages = <String>[];
      final found = await EspRomFlasher(
        rom,
        delay: _noWait,
      ).flash(image, progress: (stage, _) => stages.add(stage));
      expect(found, chip);
      final written = BytesBuilder();
      for (var seq = 0; seq < rom.flash.length; seq++) {
        written.add(rom.flash[seq]!);
      }
      final bytes = written.toBytes();
      expect(rom.flash.length, 3);
      expect(bytes.sublist(0, image.length), image);
      expect(bytes.sublist(image.length), everyElement(0xFF));
      expect(rom.ops.last, 0x04);
      expect(rom.lines.first, (dtr: false, rts: true));
      expect(rom.lines.last, (dtr: null, rts: false));
      expect(rom.baud, chip == EspChip.esp32 ? 460800 : 115200);
      expect(
        stages,
        containsAllInOrder(['Connecting', 'Erasing', 'Writing', 'Done']),
      );
      if (chip == EspChip.esp8266) {
        expect(rom.erased, esp8266EraseSize(0, image.length));
      }
    });
  }

  test('a board that never syncs says what to press', () async {
    final rom = FakeRom(EspChip.esp32, answersSync: false)..start();
    await expectLater(
      EspRomFlasher(rom, delay: _noWait).flash(_image(10)),
      throwsA(
        isA<FlashException>().having(
          (e) => e.message,
          'message',
          contains('BOOT'),
        ),
      ),
    );
  });

  test('the wrong chip is refused before anything is erased', () async {
    final rom = FakeRom.listen(EspChip.esp32)..start();
    await expectLater(
      EspRomFlasher(
        rom,
        delay: _noWait,
      ).flash(_image(10), expect: EspChip.esp8266),
      throwsA(
        isA<FlashException>().having(
          (e) => e.message,
          'message',
          contains('Nothing was written'),
        ),
      ),
    );
    expect(rom.ops, isNot(contains(0x02)));
  });

  test('the ESP8266 erase size follows esptool', () {
    expect(esp8266EraseSize(0, 0x1000), 0x1000);
    expect(esp8266EraseSize(0, 0x100000), 0xF0000);
  });
}
