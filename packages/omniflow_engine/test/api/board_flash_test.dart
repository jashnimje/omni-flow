import 'dart:io';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/flash/esp_rom.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import '../devices/flash/fake_rom.dart';

class _Links implements SerialLinks {
  _Links(this.rom);

  final FakeRom rom;

  @override
  Future<List<String>> ports() async => ['usb:/dev/bus/usb/001/005'];

  @override
  Future<SerialLink> open(String path, int baud) async => rom;
}

void main() {
  late Directory home;
  late File image;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_flash');
    image = File('${home.path}/fw.bin')
      ..writeAsBytesSync(Uint8List.fromList(List.filled(1500, 7)));
  });

  tearDown(() => home.delete(recursive: true));

  Future<OmniEngine> open({SerialLinks? links}) => OmniEngine.open(
    home: Directory('${home.path}/engine'),
    secrets: InMemorySecretStore(),
    mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    serialLinks: links,
  );

  test('flashes an ESP32 on the phone USB and reports progress', () async {
    final rom = FakeRom.listen(EspChip.esp32)..start();
    final engine = await open(links: _Links(rom));
    addTearDown(engine.close);
    final events = <Map<String, Object?>>[];
    final sub = engine.events.listen(events.add);
    addTearDown(sub.cancel);
    final r = await engine.handle('board.flash', {
      'port': 'usb:/dev/bus/usb/001/005',
      'chip': 'esp32',
      'file': image.path,
    });
    expect(r['ok'], isTrue, reason: '$r');
    expect(r['bytes'], 1500);
    expect(rom.flash.length, 2);
    final stages = [
      for (final e in events)
        if (e['event'] == 'board.flashProgress') e['stage'],
    ];
    expect(stages.first, 'Connecting');
    expect(stages.last, 'Done');
  });

  test('a computer port, an unknown chip and a missing file are refused', () async {
    final engine = await open();
    addTearDown(engine.close);
    Future<String> type(Map<String, Object?> args) async =>
        '${((await engine.handle('board.flash', args))['error'] as Map)['type']}';
    expect(
      await type({
        'port': '/dev/cu.usbserial-1',
        'chip': 'esp32',
        'file': image.path,
      }),
      'invalid',
    );
    expect(
      await type({'port': 'usb:x', 'chip': 'pico_w', 'file': image.path}),
      'invalid',
    );
  });

  test('an agent may not flash', () {
    expect(
      agentRefusal('board.flash', const {}, AgentAccess.setup),
      contains('for the user only'),
    );
  });
}
