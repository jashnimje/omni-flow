import 'dart:typed_data';

/// The legacy ADB wire protocol (no TLS): a 24-byte little-endian header of
/// six words, then the payload.
abstract final class AdbCommand {
  static const sync = 0x434e5953;
  static const cnxn = 0x4e584e43;
  static const auth = 0x48545541;
  static const open = 0x4e45504f;
  static const okay = 0x59414b4f;
  static const clse = 0x45534c43;
  static const wrte = 0x45545257;

  static String name(int command) => switch (command) {
    sync => 'SYNC',
    cnxn => 'CNXN',
    auth => 'AUTH',
    open => 'OPEN',
    okay => 'OKAY',
    clse => 'CLSE',
    wrte => 'WRTE',
    _ => '0x${command.toRadixString(16)}',
  };
}

/// The `arg0` of an AUTH message.
abstract final class AdbAuthType {
  static const token = 1;
  static const signature = 2;
  static const rsaPublicKey = 3;
}

/// The protocol version that still carries a data checksum. Newer versions
/// drop it, and a device answering a host at this version keeps it.
const adbVersion = 0x01000000;

/// The largest payload this host sends in a shell OPEN.
const adbMaxData = 4096;

/// The largest payload this host asks the device to send in one message.
/// File transfers come in 64 KiB sync chunks, so 4 KiB messages would
/// split each into sixteen round trips.
const adbHostMaxData = 256 * 1024;

/// The largest payload accepted from a device (adbd's MAX_PAYLOAD is 1 MiB).
const adbMaxIncomingData = 1024 * 1024;

const adbHeaderLength = 24;

class AdbProtocolException implements Exception {
  AdbProtocolException(this.message);

  final String message;

  @override
  String toString() => 'AdbProtocolException: $message';
}

class AdbMessage {
  AdbMessage(this.command, this.arg0, this.arg1, [Uint8List? data])
    : data = data ?? Uint8List(0);

  final int command;
  final int arg0;
  final int arg1;
  final Uint8List data;

  Uint8List encode() {
    final out = Uint8List(adbHeaderLength + data.length);
    ByteData.sublistView(out)
      ..setUint32(0, command, Endian.little)
      ..setUint32(4, arg0, Endian.little)
      ..setUint32(8, arg1, Endian.little)
      ..setUint32(12, data.length, Endian.little)
      ..setUint32(16, adbChecksum(data), Endian.little)
      ..setUint32(20, command ^ 0xffffffff, Endian.little);
    out.setRange(adbHeaderLength, out.length, data);
    return out;
  }

  @override
  String toString() =>
      '${AdbCommand.name(command)}($arg0, $arg1, ${data.length} bytes)';
}

/// The legacy data checksum: the byte sum, modulo 2^32.
int adbChecksum(List<int> data) {
  var sum = 0;
  for (final b in data) {
    sum = (sum + b) & 0xffffffff;
  }
  return sum;
}

/// Splits a byte stream into messages. Throws [AdbProtocolException] on a
/// bad magic, an oversized payload or a checksum that does not match.
class AdbMessageReader {
  final _buffer = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  List<AdbMessage> add(List<int> chunk) {
    _buffer.add(_pending);
    _buffer.add(chunk);
    var bytes = _buffer.takeBytes();
    final out = <AdbMessage>[];
    while (bytes.length >= adbHeaderLength) {
      final header = ByteData.sublistView(bytes, 0, adbHeaderLength);
      final command = header.getUint32(0, Endian.little);
      final magic = header.getUint32(20, Endian.little);
      if (magic != command ^ 0xffffffff) {
        throw AdbProtocolException(
          'bad magic on message 0x${command.toRadixString(16)}',
        );
      }
      final length = header.getUint32(12, Endian.little);
      if (length > adbMaxIncomingData) {
        throw AdbProtocolException('payload of $length bytes is too large');
      }
      if (bytes.length < adbHeaderLength + length) break;
      final data = Uint8List.fromList(
        bytes.sublist(adbHeaderLength, adbHeaderLength + length),
      );
      final checksum = header.getUint32(16, Endian.little);
      // Devices on a version past 0x01000000 send 0 here.
      if (checksum != 0 && checksum != adbChecksum(data)) {
        throw AdbProtocolException(
          'checksum mismatch on ${AdbCommand.name(command)}',
        );
      }
      out.add(
        AdbMessage(
          command,
          header.getUint32(4, Endian.little),
          header.getUint32(8, Endian.little),
          data,
        ),
      );
      bytes = Uint8List.sublistView(bytes, adbHeaderLength + length);
    }
    _pending = Uint8List.fromList(bytes);
    return out;
  }
}
