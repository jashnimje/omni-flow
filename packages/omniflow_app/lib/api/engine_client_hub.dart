import 'engine_client.dart';

/// The app's own messages about the link to the Mac mini hub, between the
/// service's hub client and the UI. The engine never sends or answers them.
abstract final class HubLink {
  /// Answered by the service's hub client with the link's [HubLinkView]
  /// as JSON. On a phone engine it is an unknown command.
  static const status = 'app.hub.link';

  /// Ends the wait between retries and connects again now.
  static const reconnect = 'app.hub.reconnect';

  /// The event the hub client adds each time the link changes.
  static const event = 'hub.link';

  /// The hub's own commands the app calls in hub mode.
  static const discover = 'hub.discover';
  static const clients = 'hub.clients';
}

enum HubLinkState { connecting, connected, unreachable, versionMismatch }

/// The link to the hub as the UI shows it.
class HubLinkView {
  const HubLinkView({
    required this.state,
    required this.address,
    this.phone,
    this.person,
    this.connectedSince,
    this.hubVersion,
    this.appVersion,
    this.reason,
  });

  final HubLinkState state;
  final String address;
  final String? phone;
  final String? person;
  final DateTime? connectedSince;
  final String? hubVersion;
  final String? appVersion;

  /// Why it is not connected, in plain words.
  final String? reason;

  bool get connected => state == HubLinkState.connected;

  /// For a version mismatch: true when the hub is the older one.
  bool get hubIsOlder =>
      compareVersions(hubVersion ?? '', appVersion ?? '') < 0;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'address': address,
    'phone': ?phone,
    'person': ?person,
    'connectedSince': ?connectedSince?.toUtc().toIso8601String(),
    'hubVersion': ?hubVersion,
    'appVersion': ?appVersion,
    'reason': ?reason,
  };

  static HubLinkView? fromJson(Map<String, Object?> json) {
    final state = HubLinkState.values
        .where((s) => s.name == json['state'])
        .firstOrNull;
    final address = json['address'];
    if (state == null || address is! String) return null;
    final since = json['connectedSince'];
    return HubLinkView(
      state: state,
      address: address,
      phone: json['phone'] as String?,
      person: json['person'] as String?,
      connectedSince: since is String ? DateTime.tryParse(since) : null,
      hubVersion: json['hubVersion'] as String?,
      appVersion: json['appVersion'] as String?,
      reason: json['reason'] as String?,
    );
  }
}

/// Compares two `major.minor.patch` versions by number: below zero when
/// [a] is older.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.split('+').first.split('.')) int.tryParse(p) ?? 0,
  ];
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// Whether two versions can talk: the same major and minor.
bool versionsMatch(String a, String b) {
  List<String> head(String v) => v.split('.').take(2).toList();
  return head(a).join('.') == head(b).join('.');
}

/// The hub calls the app makes: discovering hubs on the phone's own
/// engine, and the phones a hub has connected.
class HubCalls {
  const HubCalls(this._client);

  final EngineClient _client;

  /// Hubs on the Wi-Fi (`_ssh._tcp`), each `{name, host, port}`. Null when
  /// this engine cannot look, so the page asks for an address instead.
  Future<List<Map<String, Object?>>?> discover() async {
    final result = await _client.call(HubLink.discover);
    if (result['ok'] != true) return null;
    final list = result['hubs'] ?? result['hosts'] ?? result['found'];
    return [
      for (final h in (list as List? ?? const []))
        if (h is Map) Map<String, Object?>.from(h),
    ];
  }

  /// The phones connected to the hub now. Null when the hub cannot say.
  Future<List<Map<String, Object?>>?> clients() async {
    final result = await _client.call(HubLink.clients);
    if (result['ok'] != true) return null;
    return [
      for (final c in (result['clients'] as List? ?? const []))
        if (c is Map) Map<String, Object?>.from(c),
    ];
  }

  Future<HubLinkView?> link() async {
    final result = await _client.call(HubLink.status);
    if (result['ok'] != true) return null;
    return HubLinkView.fromJson(result);
  }

  Future<void> reconnect() => _client.call(HubLink.reconnect);

  /// The hub's whole home, for taking it back to this phone.
  Future<Map<String, Object?>?> export() async {
    final result = await _client.call('config.export');
    final backup = result['backup'];
    return result['ok'] == true && backup is Map
        ? Map<String, Object?>.from(backup)
        : null;
  }
}
