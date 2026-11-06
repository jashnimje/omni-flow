/// Where secrets live (Tuya local keys, SSH and ADB keys). Manifests, flows,
/// device settings and logs only ever hold the key name.
///
/// The app backs this with the Android keystore, the CLI with the macOS
/// keychain. Both pass the same contract tests as [InMemorySecretStore].
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The key a device's secret setting is stored under.
String deviceSecretKey(String deviceId, String settingKey) =>
    'device/$deviceId/$settingKey';

class InMemorySecretStore implements SecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

class MissingSecretException implements Exception {
  MissingSecretException(this.key);

  final String key;

  @override
  String toString() => 'MissingSecretException: no secret stored for $key';
}
