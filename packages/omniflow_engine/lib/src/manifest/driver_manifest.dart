import 'dart:convert';

import 'capability.dart';
import 'validation.dart';

const supportedManifestSchemaVersion = 1;

enum TransportType {
  udp('udp'),
  tcp('tcp'),
  tuya('tuya'),
  http('http'),
  mqtt('mqtt'),
  exec('exec'),
  serial('serial'),
  adb('adb'),

  /// An OmniFlow board (protocol v2): USB serial when the device host is a
  /// serial port path, Wi-Fi UDP otherwise. Its devices also get one
  /// capability per pin named in their `pins` setting.
  omniflow('omniflow'),

  /// JSON over a WebSocket (LG webOS, Samsung Tizen TVs).
  websocket('websocket'),

  /// No network at all: the engine itself keeps the thing's state, from
  /// inputs such as the phone's sensors (the phone, people, places, tags).
  virtual('virtual');

  const TransportType(this.wireName);

  final String wireName;

  /// Why a manifest cannot use this transport yet: the engine has no channel
  /// for it. Null when it can.
  String? get notYetSupported => switch (this) {
    tcp => 'tcp is not supported yet',
    _ => null,
  };

  bool get isSupported => notYetSupported == null;

  static TransportType? fromWire(Object? name) =>
      values.where((t) => t.wireName == name).firstOrNull;
}

enum PayloadEncoding {
  json('json'),
  text('text'),
  hex('hex');

  const PayloadEncoding(this.wireName);

  final String wireName;

  static PayloadEncoding? fromWire(Object? name) =>
      values.where((t) => t.wireName == name).firstOrNull;
}

const discoveryMethods = {
  'udp_broadcast',
  'mdns',
  'tuya_broadcast',
  'ssdp',
  'serial',
  'ble',
};

/// RFC 6763 service names: an underscore, 1 to 15 letters, digits or
/// hyphens, then `._tcp` or `._udp`.
final mdnsServicePattern = RegExp(r'^_[A-Za-z0-9-]{1,15}\._(tcp|udp)$');

/// How a device of a driver is paired, which `device.pair` runs.
enum PairingMethod {
  /// The TV shows "Allow USB debugging?" for the engine's ADB key.
  adb('adb'),

  /// The TV shows a prompt and issues a key (LG webOS, Samsung Tizen).
  tv('tv'),

  /// The user presses the Hue bridge's link button, then the bridge issues
  /// a username.
  hueBridge('hue_bridge'),

  /// Nothing to pair over the network: the user stores a secret, for
  /// example a Home Assistant access token.
  secret('secret');

  const PairingMethod(this.wireName);

  final String wireName;

  static PairingMethod? fromWire(Object? name) =>
      values.where((m) => m.wireName == name).firstOrNull;
}

/// A manifest's `pairing` entry. An `adb` or `websocket` transport pairs
/// that way without one.
class PairingSpec {
  const PairingSpec(this.method, {this.secret, this.instructions});

  final PairingMethod method;

  /// The secret setting the user stores, for [PairingMethod.secret].
  final String? secret;

  /// What the user does, in the driver author's words.
  final String? instructions;
}

/// The kinds of step a device of a driver goes through after it is added.
enum SetupKind {
  /// Runs the driver's pairing (`device.pair`).
  pair('pair'),

  /// The user stores a secret setting (`secret.set`).
  secret('secret'),

  /// The user sets a plain setting (`thing.configure`).
  configure('configure');

  const SetupKind(this.wireName);

  final String wireName;

  static SetupKind? fromWire(Object? name) =>
      values.where((k) => k.wireName == name).firstOrNull;
}

/// One entry of a manifest's `setup`: `pair`, `secret:<key>` or
/// `configure:<key>`, with a trailing `?` when the step can be skipped.
class SetupStep {
  const SetupStep(this.kind, {this.key, this.optional = false});

  final SetupKind kind;

  /// The setting the step fills, for [SetupKind.secret] and
  /// [SetupKind.configure].
  final String? key;

  /// An optional step is offered but never blocks `done`.
  final bool optional;

  String get wireName =>
      '${kind.wireName}${key == null ? '' : ':$key'}${optional ? '?' : ''}';

  static final pattern = RegExp(
    r'^(pair|secret|configure)(?::([A-Za-z][A-Za-z0-9_]*))?(\?)?$',
  );
}

class TransportSpec {
  const TransportSpec({
    required this.type,
    required this.payload,
    this.port,
    this.listenPort,
    this.options = const {},
  });

  final TransportType type;
  final PayloadEncoding payload;
  final int? port;
  final int? listenPort;

  /// Transport-specific keys (a Tuya protocol version, an MQTT topic prefix).
  final Map<String, Object?> options;
}

class DiscoverySpec {
  const DiscoverySpec(this.method, this.config);

  final String method;
  final Map<String, Object?> config;
}

class SettingSpec {
  const SettingSpec({
    required this.key,
    required this.label,
    this.secret = false,
  });

  final String key;
  final String label;
  final bool secret;
}

class Reliability {
  const Reliability({this.timeoutMs = 1000, this.retries = 0});

  final int timeoutMs;
  final int retries;
}

/// A validated `.omni_driver.json`. Build one with [DriverManifest.parse].
class DriverManifest {
  const DriverManifest({
    required this.id,
    required this.name,
    required this.category,
    required this.transport,
    required this.capabilities,
    this.icon,
    this.discovery = const [],
    this.settings = const [],
    this.statePush,
    this.statePoll,
    this.reliability = const Reliability(),
    this.pairing,
    this.setup = const [],
  });

  final String id;
  final String name;
  final String category;
  final String? icon;
  final TransportSpec transport;
  final List<DiscoverySpec> discovery;
  final List<SettingSpec> settings;
  final Map<String, Object?>? statePush;
  final Map<String, Object?>? statePoll;
  final Reliability reliability;
  final List<CapabilitySpec> capabilities;
  final PairingSpec? pairing;

  /// What a device of this driver needs after it is added, in order. The
  /// engine reports the first step not done yet as `next`.
  final List<SetupStep> setup;

  /// How [pairing] or the transport says a device is paired, or null when
  /// it needs no pairing.
  PairingSpec? get pairingSpec =>
      pairing ??
      switch (transport.type) {
        TransportType.adb => const PairingSpec(PairingMethod.adb),
        TransportType.websocket => const PairingSpec(PairingMethod.tv),
        _ => null,
      };

  CapabilitySpec? capability(String id) =>
      capabilities.where((c) => c.id == id).firstOrNull;

  /// True when the device's state is the whole object it pushes or answers
  /// a poll with (a Zigbee button's `action`, WiZ `rssi`), so it can hold
  /// keys no capability declares. False when every pushed topic lands under
  /// one named key and nothing is polled.
  bool get reportsUndeclaredState {
    if (statePoll != null) return true;
    final push = statePush;
    if (push == null) return false;
    final topics = push['topics'];
    if (topics is! List) return true;
    return topics.any((t) => t is! Map || t['key'] is! String);
  }

  /// This manifest with [extra] capabilities after its own, for drivers whose
  /// capabilities depend on the device (an OmniFlow board's pins and
  /// peripherals). When [keep] is given, only the own capabilities it
  /// accepts stay.
  DriverManifest withCapabilities(
    List<CapabilitySpec> extra, {
    bool Function(CapabilitySpec capability)? keep,
  }) {
    final kept = keep == null ? capabilities : capabilities.where(keep);
    if (extra.isEmpty && kept.length == capabilities.length) return this;
    return DriverManifest(
      id: id,
      name: name,
      category: category,
      icon: icon,
      transport: transport,
      discovery: discovery,
      settings: settings,
      statePush: statePush,
      statePoll: statePoll,
      reliability: reliability,
      capabilities: List.unmodifiable([...kept, ...extra]),
      pairing: pairing,
      setup: setup,
    );
  }

  /// High risk when any capability, or the transport itself, executes commands on a host.
  bool get isHighRisk =>
      transport.type == TransportType.exec ||
      capabilities.any((c) => c.type.isHighRisk);

  static DriverManifest parseJson(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw ValidationException('driver manifest', [
        ValidationIssue(r'$', 'is not valid JSON: ${e.message}'),
      ]);
    }
    return parse(decoded);
  }

  /// Validates [json] and returns the manifest, or throws a
  /// [ValidationException] listing every issue found.
  static DriverManifest parse(Object? json) {
    final issues = IssueCollector();
    if (json is! Map) {
      throw ValidationException('driver manifest', [
        const ValidationIssue(r'$', 'must be an object'),
      ]);
    }
    final map = Map<String, Object?>.from(json);
    const root = r'$';

    final version = map['schemaVersion'];
    if (version == null) {
      issues.add('$root.schemaVersion', 'is required');
    } else if (version != supportedManifestSchemaVersion) {
      issues.add(
        '$root.schemaVersion',
        'version $version is not supported (this engine reads $supportedManifestSchemaVersion)',
      );
    }
    final id = issues.requiredString(map, 'id', root);
    if (id != null && !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(id)) {
      issues.add('$root.id', 'must be lower snake case');
    }
    final name = issues.requiredString(map, 'name', root);
    final category = issues.requiredString(map, 'category', root);
    final icon = issues.optionalString(map, 'icon', root);

    final transport = _parseTransport(
      map['transport'],
      '$root.transport',
      issues,
    );

    final discovery = <DiscoverySpec>[];
    final rawDiscovery = issues.optionalList(map, 'discovery', root);
    for (var i = 0; i < rawDiscovery.length; i++) {
      final path = '$root.discovery[$i]';
      final entry = rawDiscovery[i];
      if (entry is! Map || !discoveryMethods.contains(entry['method'])) {
        issues.add(
          '$path.method',
          'must be one of ${discoveryMethods.join(', ')}',
        );
        continue;
      }
      issues.jsonPath(entry['matchJsonPath'], '$path.matchJsonPath');
      issues.jsonPath(entry['idJsonPath'], '$path.idJsonPath');
      final config = Map<String, Object?>.from(entry);
      issues.optionalInt(config, 'windowMs', path, min: 1, max: 60000);
      issues.optionalString(config, 'idSetting', path);
      if (entry['method'] == 'mdns') {
        final service = issues.requiredString(config, 'service', path);
        if (service != null && !mdnsServicePattern.hasMatch(service)) {
          issues.add('$path.service', 'must be a service type like _hue._tcp');
        }
        issues.optionalString(config, 'idTxt', path);
        final idInstance = config['idInstance'];
        if (idInstance != null && idInstance is! bool) {
          issues.add('$path.idInstance', 'must be true or false');
        } else if (idInstance == true && config['idTxt'] != null) {
          issues.add('$path.idInstance', 'cannot be used with idTxt');
        }
      }
      discovery.add(
        DiscoverySpec(
          entry['method'] as String,
          Map<String, Object?>.from(entry),
        ),
      );
    }

    final settings = <SettingSpec>[];
    final seenSettings = <String>{};
    final rawSettings = issues.optionalList(map, 'settings', root);
    for (var i = 0; i < rawSettings.length; i++) {
      final path = '$root.settings[$i]';
      final entry = rawSettings[i];
      if (entry is! Map) {
        issues.add(path, 'must be an object');
        continue;
      }
      final setting = Map<String, Object?>.from(entry);
      final key = issues.requiredString(setting, 'key', path);
      if (key == null) continue;
      if (!seenSettings.add(key)) issues.add('$path.key', 'duplicates "$key"');
      settings.add(
        SettingSpec(
          key: key,
          label: setting['label'] is String ? setting['label'] as String : key,
          secret: setting['secret'] == true,
        ),
      );
    }

    final reliabilityMap =
        issues.optionalMap(map, 'reliability', root) ?? const {};
    final reliability = Reliability(
      timeoutMs:
          issues.optionalInt(
            reliabilityMap,
            'timeoutMs',
            '$root.reliability',
            min: 1,
          ) ??
          1000,
      retries:
          issues.optionalInt(
            reliabilityMap,
            'retries',
            '$root.reliability',
            min: 0,
            max: 10,
          ) ??
          0,
    );

    final capabilities = <CapabilitySpec>[];
    final seenCapabilities = <String>{};
    final rawCapabilities = issues.optionalList(map, 'capabilities', root);
    if (rawCapabilities.isEmpty) {
      issues.add('$root.capabilities', 'needs at least one capability');
    }
    for (var i = 0; i < rawCapabilities.length; i++) {
      final path = '$root.capabilities[$i]';
      final capability = CapabilitySpec.parse(rawCapabilities[i], path, issues);
      if (capability == null) continue;
      if (!seenCapabilities.add(capability.id)) {
        issues.add('$path.id', 'duplicates "${capability.id}"');
      }
      capabilities.add(capability);
    }

    for (var i = 0; i < discovery.length; i++) {
      final key = discovery[i].config['idSetting'];
      if (key is String && !settings.any((s) => s.key == key && !s.secret)) {
        issues.add(
          '$root.discovery[$i].idSetting',
          '$key is not a setting that is not secret',
        );
      }
    }

    final pairing = _parsePairing(map['pairing'], '$root.pairing', issues, {
      for (final s in settings)
        if (s.secret) s.key,
    }, transport?.type);

    final setup = _parseSetup(
      issues.optionalList(map, 'setup', root),
      '$root.setup',
      issues,
      settings,
      canPair:
          pairing != null ||
          transport?.type == TransportType.adb ||
          transport?.type == TransportType.websocket,
    );

    final statePush = issues.optionalMap(map, 'statePush', root);
    final statePoll = issues.optionalMap(map, 'statePoll', root);
    issues.jsonPath(statePush?['jsonPath'], '$root.statePush.jsonPath');
    issues.jsonPath(statePoll?['jsonPath'], '$root.statePoll.jsonPath');

    if (issues.hasIssues ||
        id == null ||
        name == null ||
        category == null ||
        transport == null) {
      throw ValidationException(
        'driver manifest ${id ?? ''}'.trim(),
        issues.issues,
      );
    }
    return DriverManifest(
      id: id,
      name: name,
      category: category,
      icon: icon,
      transport: transport,
      discovery: List.unmodifiable(discovery),
      settings: List.unmodifiable(settings),
      statePush: statePush,
      statePoll: statePoll,
      reliability: reliability,
      capabilities: List.unmodifiable(capabilities),
      pairing: pairing,
      setup: List.unmodifiable(setup),
    );
  }

  static List<SetupStep> _parseSetup(
    List<Object?> raw,
    String path,
    IssueCollector issues,
    List<SettingSpec> settings, {
    required bool canPair,
  }) {
    final steps = <SetupStep>[];
    final seen = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final at = '$path[$i]';
      final entry = raw[i];
      final match = entry is String
          ? SetupStep.pattern.firstMatch(entry)
          : null;
      if (match == null) {
        issues.add(at, 'must be pair, secret:<key> or configure:<key>');
        continue;
      }
      final kind = SetupKind.fromWire(match.group(1))!;
      final key = match.group(2);
      final optional = match.group(3) != null;
      final setting = settings.where((s) => s.key == key).firstOrNull;
      switch (kind) {
        case SetupKind.pair:
          if (key != null || optional) {
            issues.add(at, 'pair takes no key and cannot be optional');
            continue;
          }
          if (!canPair) {
            issues.add(at, 'pair needs a pairing entry or a TV transport');
            continue;
          }
        case SetupKind.secret:
          if (setting == null || !setting.secret) {
            issues.add(at, '${key ?? 'secret'} needs a secret setting key');
            continue;
          }
        case SetupKind.configure:
          if (setting == null || setting.secret) {
            issues.add(at, '${key ?? 'configure'} needs a plain setting key');
            continue;
          }
      }
      if (!seen.add('${kind.wireName}:$key')) {
        issues.add(at, 'duplicates ${entry as String}');
        continue;
      }
      steps.add(SetupStep(kind, key: key, optional: optional));
    }
    return steps;
  }

  static PairingSpec? _parsePairing(
    Object? json,
    String path,
    IssueCollector issues,
    Set<String> secretSettings,
    TransportType? transport,
  ) {
    if (json == null) return null;
    if (json is! Map) {
      issues.add(path, 'must be an object');
      return null;
    }
    final map = Map<String, Object?>.from(json);
    final method = PairingMethod.fromWire(map['method']);
    if (method == null) {
      issues.add(
        '$path.method',
        'must be one of ${PairingMethod.values.map((m) => m.wireName).join(', ')}',
      );
      return null;
    }
    final needs = switch (method) {
      PairingMethod.adb => TransportType.adb,
      PairingMethod.tv => TransportType.websocket,
      PairingMethod.hueBridge => TransportType.http,
      PairingMethod.secret => null,
    };
    if (needs != null && transport != null && transport != needs) {
      issues.add(
        '$path.method',
        '${method.wireName} pairing needs the ${needs.wireName} transport',
      );
    }
    final secret = issues.optionalString(map, 'secret', path);
    if (method == PairingMethod.secret && secret == null) {
      issues.add('$path.secret', 'names the secret setting the user stores');
    }
    if (method == PairingMethod.hueBridge &&
        !secretSettings.contains('username')) {
      issues.add(path, 'hue_bridge pairing stores a secret setting username');
    }
    if (secret != null && !secretSettings.contains(secret)) {
      issues.add('$path.secret', '$secret is not a secret setting');
    }
    final instructions = issues.optionalString(map, 'instructions', path);
    if (instructions != null && instructions.length > 400) {
      issues.add('$path.instructions', 'must be at most 400 characters');
    }
    return PairingSpec(method, secret: secret, instructions: instructions);
  }

  static TransportSpec? _parseTransport(
    Object? json,
    String path,
    IssueCollector issues,
  ) {
    if (json is! Map) {
      issues.add(path, json == null ? 'is required' : 'must be an object');
      return null;
    }
    final map = Map<String, Object?>.from(json);
    final type = TransportType.fromWire(map['type']);
    if (type == null) {
      issues.add(
        '$path.type',
        'must be one of ${TransportType.values.where((t) => t.isSupported).map((t) => t.wireName).join(', ')}',
      );
    } else if (!type.isSupported) {
      issues.add('$path.type', type.notYetSupported!);
    }
    final payload = map['payload'] == null
        ? PayloadEncoding.json
        : PayloadEncoding.fromWire(map['payload']);
    if (payload == null) {
      issues.add(
        '$path.payload',
        'must be one of ${PayloadEncoding.values.map((p) => p.wireName).join(', ')}',
      );
    }
    final port = issues.optionalInt(map, 'port', path, min: 1, max: 65535);
    final listenPort = issues.optionalInt(
      map,
      'listenPort',
      path,
      min: 1,
      max: 65535,
    );
    if (type == null || payload == null) return null;
    return TransportSpec(
      type: type,
      payload: payload,
      port: port,
      listenPort: listenPort,
      options: Map.unmodifiable(
        Map.fromEntries(
          map.entries.where(
            (e) => !const {
              'type',
              'payload',
              'port',
              'listenPort',
            }.contains(e.key),
          ),
        ),
      ),
    );
  }
}
