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
  adb('adb');

  const TransportType(this.wireName);

  final String wireName;

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

const discoveryMethods = {'udp_broadcast', 'mdns', 'ssdp', 'serial', 'ble'};

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

  CapabilitySpec? capability(String id) =>
      capabilities.where((c) => c.id == id).firstOrNull;

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
    );
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
        'must be one of ${TransportType.values.map((t) => t.wireName).join(', ')}',
      );
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
