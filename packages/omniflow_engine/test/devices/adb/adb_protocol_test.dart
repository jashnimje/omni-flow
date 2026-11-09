import 'dart:typed_data';

import 'package:omniflow_engine/src/devices/adb/adb_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('a message encodes the 24-byte little-endian header', () {
    final bytes = AdbMessage(
      AdbCommand.cnxn,
      adbVersion,
      adbMaxData,
      Uint8List.fromList('host::\x00'.codeUnits),
    ).encode();
    final header = ByteData.sublistView(bytes, 0, 24);
    expect(bytes.sublist(0, 4), 'CNXN'.codeUnits);
    expect(header.getUint32(4, Endian.little), 0x01000000);
    expect(header.getUint32(8, Endian.little), 4096);
    expect(header.getUint32(12, Endian.little), 7);
    expect(
      header.getUint32(16, Endian.little),
      'host::'.codeUnits.fold<int>(0, (a, b) => a + b),
    );
    expect(header.getUint32(20, Endian.little), AdbCommand.cnxn ^ 0xffffffff);
    expect(String.fromCharCodes(bytes.sublist(24)), 'host::\x00');
  });

  test('the command words spell their names in little-endian ASCII', () {
    for (final (command, name) in [
      (AdbCommand.auth, 'AUTH'),
      (AdbCommand.open, 'OPEN'),
      (AdbCommand.okay, 'OKAY'),
      (AdbCommand.wrte, 'WRTE'),
      (AdbCommand.clse, 'CLSE'),
    ]) {
      final bytes = AdbMessage(command, 0, 0).encode();
      expect(String.fromCharCodes(bytes.sublist(0, 4)), name);
    }
  });

  test('the reader joins messages split across chunks', () {
    final a = AdbMessage(
      AdbCommand.wrte,
      1,
      2,
      Uint8List.fromList([1, 2, 3]),
    ).encode();
    final b = AdbMessage(AdbCommand.clse, 1, 2).encode();
    final stream = [...a, ...b];
    final reader = AdbMessageReader();
    final got = [
      ...reader.add(stream.sublist(0, 10)),
      ...reader.add(stream.sublist(10, 30)),
      ...reader.add(stream.sublist(30)),
    ];
    expect(got.map((m) => m.command), [AdbCommand.wrte, AdbCommand.clse]);
    expect(got.first.data, [1, 2, 3]);
  });

  test('the reader accepts a payload larger than the host max', () {
    final big = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 7);
    final got = AdbMessageReader().add(
      AdbMessage(AdbCommand.wrte, 1, 2, big).encode(),
    );
    expect(got.single.data.length, 64 * 1024);
  });

  test('the reader accepts a zero checksum from a newer device', () {
    final bytes = AdbMessage(
      AdbCommand.wrte,
      1,
      2,
      Uint8List.fromList([9, 9]),
    ).encode();
    ByteData.sublistView(bytes).setUint32(16, 0, Endian.little);
    expect(AdbMessageReader().add(bytes).single.data, [9, 9]);
  });

  test('the reader refuses a bad magic, checksum or size', () {
    final badMagic = AdbMessage(AdbCommand.okay, 1, 2).encode();
    ByteData.sublistView(badMagic).setUint32(20, 0, Endian.little);
    expect(
      () => AdbMessageReader().add(badMagic),
      throwsA(isA<AdbProtocolException>()),
    );

    final badSum = AdbMessage(
      AdbCommand.wrte,
      1,
      2,
      Uint8List.fromList([1]),
    ).encode();
    ByteData.sublistView(badSum).setUint32(16, 99, Endian.little);
    expect(
      () => AdbMessageReader().add(badSum),
      throwsA(isA<AdbProtocolException>()),
    );

    final huge = AdbMessage(AdbCommand.wrte, 1, 2).encode();
    ByteData.sublistView(huge).setUint32(12, 2 * 1024 * 1024, Endian.little);
    expect(
      () => AdbMessageReader().add(huge),
      throwsA(isA<AdbProtocolException>()),
    );
  });
}
