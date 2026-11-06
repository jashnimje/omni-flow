import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

enum PacketDirection { outgoing, incoming }

/// One packet seen by a transport, for the packet inspector and `omni sniff`.
class CapturedPacket {
  CapturedPacket({
    required this.transport,
    required this.direction,
    required this.remote,
    required this.bytes,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final String transport;
  final PacketDirection direction;

  /// `host:port`, a serial port path, or another transport-specific address.
  final String remote;
  final Uint8List bytes;
  final DateTime timestamp;

  String get text => utf8.decode(bytes, allowMalformed: true);
}

/// A bounded ring buffer of captured packets plus a live stream.
///
/// Old packets drop off the front once [capacity] is reached, so a tap left
/// running never grows without bound.
class PacketTap {
  PacketTap({this.capacity = 500});

  final int capacity;
  final _buffer = ListQueue<CapturedPacket>();
  final _live = StreamController<CapturedPacket>.broadcast();

  List<CapturedPacket> get recent => List.unmodifiable(_buffer);

  Stream<CapturedPacket> get stream => _live.stream;

  void record(CapturedPacket packet) {
    _buffer.addLast(packet);
    while (_buffer.length > capacity) {
      _buffer.removeFirst();
    }
    if (!_live.isClosed) _live.add(packet);
  }

  Future<void> close() => _live.close();
}
