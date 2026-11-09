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

  /// A value the keystore cannot decrypt (its key stayed on another phone)
  /// is dropped, so the engine reports the secret as missing and asks for it
  /// again instead of failing every call.
  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException {
      try {
        await _storage.delete(key: key);
      } on PlatformException {
        // The next write replaces it.
      }
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
