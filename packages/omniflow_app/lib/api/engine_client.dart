import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

/// The app's only way into the engine: core API commands and the event
/// stream. The app holds no device, flow or protocol logic of its own.
///
/// On Android the engine lives in a foreground service's isolate and the UI
/// uses `ServiceEngineClient`, which sends the same messages over the
/// service's data channel. [InProcessEngineClient] is the engine in the
/// calling isolate: the service uses it, and so do tests.
abstract interface class EngineClient {
  Future<Map<String, Object?>> call(
    String command, [
    Map<String, Object?> args = const {},
  ]);
  Stream<Map<String, Object?>> get events;
}

class InProcessEngineClient implements EngineClient {
  InProcessEngineClient(this.engine);

  final OmniEngine engine;

  @override
  Future<Map<String, Object?>> call(
    String command, [
    Map<String, Object?> args = const {},
  ]) => engine.handle(command, args);

  @override
  Stream<Map<String, Object?>> get events => engine.events;
}

/// Secrets in the Android keystore (and the macOS keychain in tests).
class SecureStorageSecretStore implements SecretStore {
  SecureStorageSecretStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// A keystore read that fails throws [SecretReadException] and keeps the
  /// entry. The failure can be passing (the keystore busy or locked), and
  /// dropping the entry then would wipe the hub settings or a device's key
  /// for good. Saving the secret again replaces a value that cannot be read.
  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException catch (e) {
      throw SecretReadException(key, e.code);
    }
  }

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// The phone's keystore could not read the secret [key]. It is kept as it
/// was, so trying again later can work.
class SecretReadException implements Exception {
  const SecretReadException(this.key, [this.code]);

  final String key;

  /// The platform's error code, for the log.
  final String? code;

  @override
  String toString() =>
      'This phone could not read a saved key ($key). It is kept. Try again, '
      'or enter it again if it was saved on another phone';
}
