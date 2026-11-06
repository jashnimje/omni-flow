import 'dart:async';
import 'dart:convert';

/// One line from a newline-delimited JSON stream. [json] is null when the
/// line is not a JSON object, so the raw text still reaches the inspector.
class NdjsonLine {
  const NdjsonLine(this.raw, this.json);

  final String raw;
  final Map<String, Object?>? json;
}

/// Turns raw bytes from a serial port (or any byte stream) into lines.
///
/// UTF-8 is decoded as a stream, so a character split across two reads is
/// rebuilt instead of corrupted. `\r` is dropped, blank lines are skipped,
/// and a line longer than [maxLineLength] is cut off and reported as
/// truncated, so a board that never sends a newline cannot grow memory.
class NdjsonDecoder extends StreamTransformerBase<List<int>, NdjsonLine> {
  const NdjsonDecoder({this.maxLineLength = 4096});

  final int maxLineLength;

  @override
  Stream<NdjsonLine> bind(Stream<List<int>> stream) async* {
    final buffer = StringBuffer();
    var overflowed = false;
    await for (final text in stream.transform(
      const Utf8Decoder(allowMalformed: true),
    )) {
      for (final rune in text.runes) {
        if (rune == 0x0A) {
          if (overflowed) {
            yield NdjsonLine('${buffer.toString()}...(truncated)', null);
          } else {
            final line = buffer.toString().trim();
            if (line.isNotEmpty) yield parseNdjsonLine(line);
          }
          buffer.clear();
          overflowed = false;
        } else if (rune == 0x0D) {
          continue;
        } else if (buffer.length < maxLineLength) {
          buffer.writeCharCode(rune);
        } else {
          overflowed = true;
        }
      }
    }
    final rest = buffer.toString().trim();
    if (rest.isNotEmpty) {
      yield overflowed
          ? NdjsonLine('$rest...(truncated)', null)
          : parseNdjsonLine(rest);
    }
  }
}

NdjsonLine parseNdjsonLine(String line) {
  if (line.startsWith('{')) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) {
        return NdjsonLine(line, Map<String, Object?>.from(decoded));
      }
    } on FormatException {
      // Not JSON: keep the raw text.
    }
  }
  return NdjsonLine(line, null);
}

/// One command line for a board: compact JSON plus a newline.
List<int> encodeNdjson(Map<String, Object?> command) =>
    utf8.encode('${jsonEncode(command)}\n');
