import '../../manifest/driver_manifest.dart';
import '../channels.dart';
import 'tv_socket.dart';

/// One open, paired connection to a TV.
class TvConnection {
  TvConnection(this.socket, this.host, this.port);

  final TvSocket socket;
  final String host;
  final int port;
  var _nextId = 0;

  int nextId() => ++_nextId;
}

/// How one TV family pairs and takes commands over [TvSocket].
abstract interface class TvProtocol {
  /// The device secret setting that keeps the pairing key.
  String get pairingSecret;

  /// The address to open, with [pairingKey] when the family sends it there.
  Uri uri(String host, int? port, TransportSpec transport, String? pairingKey);

  /// Checks a rendered command before anything is sent and returns it in
  /// the form [deliver] takes.
  Object parse(Object? rendered);

  /// Pairs on a freshly opened socket. Returns the pairing key the TV
  /// issued, or null when it issued none. Throws [TvPairingException] when
  /// the TV refuses. Without [allowPairing], a TV that shows its prompt
  /// (it does not know [pairingKey]) fails with [PairingRequiredException]
  /// at once rather than waiting for someone to answer it.
  Future<String?> pair(
    TvSocket socket, {
    required String deviceId,
    required TransportSpec transport,
    required String? pairingKey,
    required bool allowPairing,
    required Duration timeout,
  });

  Future<ChannelReply> deliver(
    TvConnection connection,
    Object command, {
    required String deviceId,
    required Duration timeout,
  });
}
