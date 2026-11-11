import 'dart:async';
import 'dart:convert';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// A board on a phone's USB port: answers describe and pin.write lines.
class _FakeLink implements SerialLink {
  final _in = StreamController<List<int>>();
  final written = <Map<String, Object?>>[];
  var baud = 0;
  var closed = false;
  ({bool? dtr, bool? rts})? lines;

  @override
  Stream<List<int>> get input => _in.stream;

  @override
  Future<void> write(List<int> bytes) async {
    for (final line in utf8.decode(bytes).split('\n')) {
      if (line.trim().isEmpty) continue;
      final json = jsonDecode(line) as Map<String, Object?>;
      written.add(json);
      final reply = switch (json['cmd']) {
        'describe' => {'event': 'describe', 'board': 'esp32', 'node': 'desk'},
        _ => {'event': 'ok'},
      };
      _in.add(utf8.encode('${jsonEncode({...reply, 'id': json['id']})}\n'));
    }
  }

  @override
  Future<void> setLines({bool? dtr, bool? rts}) async =>
      lines = (dtr: dtr, rts: rts);

  @override
  Future<void> setBaud(int baud) async => this.baud = baud;

  @override
  Future<void> close() async {
    closed = true;
    await _in.close();
  }
}

class _FakeLinks implements SerialLinks {
  var link = _FakeLink();
  final opened = <(String, int)>[];

  @override
  Future<List<String>> ports() async => ['usb:/dev/bus/usb/001/002'];

  @override
  Future<SerialLink> open(String path, int baud) async {
    opened.add((path, baud));
    return link = _FakeLink();
  }
}

void main() {
  test('a board on a platform USB port is found and driven', () async {
    final links = _FakeLinks();
    final channel = SerialChannel(links: links);
    addTearDown(channel.close);
    final manifest = DriverRegistry.withBuiltIns()['omniflow_board']!;
    final found = await channel.discover(manifest, ports: () => links.ports());
    expect(found.single['host'], 'usb:/dev/bus/usb/001/002');
    expect(found.single['stableId'], 'desk');
    expect(links.opened.single.$2, 115200);

    final reply = await channel.send(
      ChannelRequest(
        device: const Device(
          id: 'desk',
          name: 'Desk',
          driverId: 'omniflow_board',
          host: 'usb:/dev/bus/usb/001/002',
        ),
        manifest: manifest,
        command: const {'cmd': 'pin.write', 'pin': 4, 'value': 1},
        context: const TemplateContext(),
      ),
    );
    expect(reply.json?['event'], 'ok');
    expect(links.link.written.last, containsPair('cmd', 'pin.write'));
  });

  test('a usb: port counts as a serial host', () {
    expect(isSerialHost('usb:/dev/bus/usb/001/002'), isTrue);
    expect(isLinkPort('usb:/dev/bus/usb/001/002'), isTrue);
    expect(isLinkPort('/dev/cu.usbmodem1101'), isFalse);
  });
}
