import 'dart:async';

/// What the hub said when this phone connected.
class HubHello {
  const HubHello({this.hostKey, this.hubVersion, this.person});

  /// The host key the hub offered, `<type> SHA256:...`, when known.
  final String? hostKey;
  final String? hubVersion;

  /// The person the hub has for this phone, when it says.
  final String? person;
}

/// Why a connection to the hub did not open. [type] is `unavailable` (not
/// reachable), `version_mismatch`, `host_key` (a different key than the one
/// matched), `not_allowed` (the hub refused this phone's key) or another
/// engine error type.
class HubConnectException implements Exception {
  const HubConnectException(
    this.type,
    this.message, {
    this.hubVersion,
    this.appVersion,
  });

  final String type;
  final String message;
  final String? hubVersion;
  final String? appVersion;

  @override
  String toString() => 'HubConnectException($type): $message';
}

/// One connection to `omni hub attach` on the Mac mini: newline JSON over
/// an SSH exec channel. A new one is made for each attempt.
abstract interface class HubSession {
  /// Connects, says hello with this phone's id, and checks the version.
  /// Throws [HubConnectException].
  Future<HubHello> open();

  /// One core API command on the hub. Never throws: a lost link answers
  /// `unavailable`.
  Future<Map<String, Object?>> call(
    String command, [
    Map<String, Object?> args = const {},
  ]);

  /// The hub's events while the link is up.
  Stream<Map<String, Object?>> get events;

  /// Completes when the link drops.
  Future<void> get done;

  Future<void> close();
}

/// Makes a fresh, unopened connection.
typedef HubConnector = HubSession Function();
