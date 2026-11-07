import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

/// The app's only way into the engine: core API commands and the event
/// stream. The app holds no device, flow or protocol logic of its own.
///
/// Today the engine runs in the app process. On Android the plan is for it
/// to live in a foreground service, with a client that sends the same
/// messages over the service channel.
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

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
