import 'dart:convert';

import 'package:omniflow_engine/omniflow_engine.dart';

import 'hub_key.dart';

/// Where the home runs: the engine on this phone, or the Mac mini hub that
/// this phone is a screen and a set of sensors for.
enum HomeMode { phone, hub }

/// How this phone reaches the hub, and the name the hub knows it by.
class HubSettings {
  const HubSettings({
    required this.host,
    required this.user,
    required this.phone,
    this.port = 22,
    this.hostKey,
  });

  final String host;
  final int port;
  final String user;

  /// This phone's id on the hub, the name given to `omni hub allow`, and the
  /// `phone` on every reading it sends.
  final String phone;

  /// The hub's host key the user matched against `omni hub fingerprint`,
  /// as `<type> SHA256:...`.
  final String? hostKey;

  String get address => port == 22 ? '$user@$host' : '$user@$host:$port';

  HubSettings withHostKey(String key) => HubSettings(
    host: host,
    port: port,
    user: user,
    phone: phone,
    hostKey: key,
  );

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'user': user,
    'phone': phone,
    'hostKey': ?hostKey,
  };

  static HubSettings? fromJson(Object? json) {
    if (json is! Map) return null;
    final host = json['host'];
    final user = json['user'];
    final phone = json['phone'];
    final port = json['port'];
    if (host is! String || user is! String || phone is! String) return null;
    return HubSettings(
      host: host,
      user: user,
      phone: phone,
      port: port is int ? port : 22,
      hostKey: json['hostKey'] as String?,
    );
  }
}

/// The home mode, the hub settings and this phone's hub key, kept in the
/// phone's keystore so the UI and the service read the same values.
class HubSettingsStore {
  HubSettingsStore(this._store);

  final SecretStore _store;

  static const modeKey = 'app/home/mode';
  static const settingsKey = 'app/hub/settings';

  /// The private key, as the SSH client reads it from the secret store.
  static const privateKeyKey = 'app/hub/ssh_key';
  static const publicKeyKey = 'app/hub/ssh_key.pub';

  Future<HomeMode> mode() async =>
      await _store.read(modeKey) == HomeMode.hub.name
      ? HomeMode.hub
      : HomeMode.phone;

  Future<void> setMode(HomeMode mode) => _store.write(modeKey, mode.name);

  Future<HubSettings?> settings() async {
    final raw = await _store.read(settingsKey);
    if (raw == null) return null;
    try {
      return HubSettings.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<void> save(HubSettings settings) =>
      _store.write(settingsKey, jsonEncode(settings.toJson()));

  /// This phone's key, made the first time it is asked for. The private
  /// half never leaves the keystore.
  Future<HubKey> phoneKey(String phone) async {
    final private = await _store.read(privateKeyKey);
    final public = await _store.read(publicKeyKey);
    if (private != null && public != null) {
      return HubKey(privatePem: private, publicLine: public);
    }
    final key = HubKey.generate(phone);
    await _store.write(privateKeyKey, key.privatePem);
    await _store.write(publicKeyKey, key.publicLine);
    return key;
  }

  /// The public half alone, or null before a key was made.
  Future<String?> publicKey() => _store.read(publicKeyKey);

  /// Pins the host key the user matched, where the SSH client checks it.
  Future<void> pinHostKey(HubSettings settings, String offered) =>
      HostKeyPins(_store).pin(settings.host, settings.port, offered);

  Future<String?> pinnedHostKey(HubSettings settings) =>
      HostKeyPins(_store).pinned(settings.host, settings.port);
}
