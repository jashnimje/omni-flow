import 'dart:convert';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

Future<List<NdjsonLine>> decode(
  List<List<int>> chunks, {
  int maxLineLength = 4096,
}) =>
    Stream.fromIterable(chunks)
        .transform(NdjsonDecoder(maxLineLength: maxLineLength))
        .toList();

void main() {
  test('splits lines across chunk boundaries and parses JSON objects', () async {
    final bytes = utf8.encode(
      '{"node":"pico","event":"boot"}\r\n{"event":"button_press","gpio":14}\n',
    );
    final chunks = [
      for (var i = 0; i < bytes.length; i += 5)
        bytes.sublist(i, (i + 5).clamp(0, bytes.length)),
    ];
    final lines = await decode(chunks);
    expect(lines.map((l) => l.json), [
      {'node': 'pico', 'event': 'boot'},
      {'event': 'button_press', 'gpio': 14},
    ]);
  });

  test('rebuilds a multibyte character split across two reads', () async {
    final bytes = utf8.encode('{"name":"Ü-lamp °"}\n');
    final split = bytes.indexOf(0xC3) + 1;
    final lines = await decode([bytes.sublist(0, split), bytes.sublist(split)]);
    expect(lines.single.json, {'name': 'Ü-lamp °'});
  });

  test('keeps non-JSON lines as raw text and skips blank lines', () async {
    final lines = await decode([
      utf8.encode('MicroPython v1.24\n\n{not json\n'),
    ]);
    expect(lines.map((l) => l.raw), ['MicroPython v1.24', '{not json']);
    expect(lines.every((l) => l.json == null), isTrue);
  });

  test('cuts off a line longer than the limit', () async {
    final lines = await decode([
      utf8.encode('${'x' * 50}\n{"ok":true}\n'),
    ], maxLineLength: 20);
    expect(lines.first.raw, '${'x' * 20}...(truncated)');
    expect(lines.first.json, isNull);
    expect(lines.last.json, {'ok': true});
  });

  test('emits a final line with no trailing newline', () async {
    final lines = await decode([utf8.encode('{"event":"ack","id":1}')]);
    expect(lines.single.json, {'event': 'ack', 'id': 1});
  });

  test('encodes a command as compact JSON plus a newline', () {
    expect(
      utf8.decode(
        encodeNdjson({'cmd': 'ir_send', 'hex': '0x20DF10EF', 'id': 2}),
      ),
      '{"cmd":"ir_send","hex":"0x20DF10EF","id":2}\n',
    );
  });
}
