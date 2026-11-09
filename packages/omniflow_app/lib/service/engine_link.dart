import 'dart:convert';
import 'dart:math';

/// The UI end of the message pipe to the service isolate that owns the
/// engine. Messages are JSON strings, so only serializable command results
/// and events cross it.
abstract interface class EngineLink {
  void send(String message);
  Stream<String> get incoming;
  Future<void> close();
}

/// A random id for a session or a service instance.
String newLinkId() {
  final random = Random();
  return List.generate(
    4,
    (_) => random.nextInt(1 << 32),
  ).map((n) => n.toRadixString(16)).join();
}

/// The messages between the UI and the service.
///
/// UI to service: `hello` and `call`, each with the client's session `s`.
/// Service to UI: `ready` and `reply` for one session, `event` and `stopped`
/// for whichever UI is listening. The session keeps a reopened UI from
/// taking replies meant for the one Android closed. `ready` and `stopped`
/// carry the service instance `i`, because a restart destroys the old task
/// after the new client exists and its `stopped` reaches that client too.
abstract final class LinkMessage {
  static const hello = 'hello';
  static const ready = 'ready';
  static const call = 'call';
  static const reply = 'reply';
  static const event = 'event';
  static const stopped = 'stopped';

  static String encode(Map<String, Object?> message) => jsonEncode(message);

  /// The message, or null for anything that is not one.
  static Map<String, Object?>? decode(Object? raw) {
    if (raw is! String) return null;
    try {
      final message = jsonDecode(raw);
      return message is Map<String, Object?> && message['t'] is String
          ? message
          : null;
    } on FormatException {
      return null;
    }
  }
}
