import 'dart:io';
import 'dart:typed_data';

import '../../transports/udp_transport.dart';

final macPattern = RegExp(r'^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$');

/// Sends a Wake-on-LAN magic packet. Tests pass a fake.
typedef WakeOnLanSender = Future<void> Function(Uint8List packet);

/// Broadcasts [packet] to 255.255.255.255:9 from a throwaway send-only
/// socket on an ephemeral port, closed straight after.
Future<void> broadcastWakeOnLan(Uint8List packet) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    socket.broadcastEnabled = true;
    final sent = socket.send(packet, InternetAddress('255.255.255.255'), 9);
    if (sent != packet.length) {
      throw SocketException('sent $sent of ${packet.length} wake bytes');
    }
  } finally {
    socket.close();
  }
}

/// The magic packet for [mac], which must be six hex pairs split by `:` or `-`.
Uint8List wakeOnLanPacketFor(String mac) {
  if (!macPattern.hasMatch(mac)) {
    throw ArgumentError('mac must look like AA:BB:CC:DD:EE:FF');
  }
  return wakeOnLanPacket(mac);
}
