import 'dart:convert';

import '../manifest/validation.dart';

const supportedFlowSchemaVersion = 1;

/// What happens when a trigger fires while an earlier run is still going.
enum RunMode {
  single,
  restart,
  queued,
  parallel;

  static RunMode? fromWire(Object? name) =>
      values.where((m) => m.name == name).firstOrNull;
}

class NodeSpec {
  const NodeSpec({
    required this.id,
    required this.type,
    required this.label,
    required this.config,
    this.x = 0,
    this.y = 0,
  });

  final String id;
  final String type;
  final String label;
  final Map<String, Object?> config;
  final double x;
  final double y;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'label': label,
    'config': config,
    'position': {'x': x, 'y': y},
  };
}

class PortRef {
  const PortRef(this.node, this.port);

  final String node;
  final String port;

  Map<String, Object?> toJson() => {'node': node, 'port': port};
}

class EdgeSpec {
  const EdgeSpec({required this.id, required this.from, required this.to});

  final String id;
  final PortRef from;
  final PortRef to;

  Map<String, Object?> toJson() => {
    'id': id,
    'from': from.toJson(),
    'to': to.toJson(),
  };
}

/// A parsed flow. [FlowSpec.parse] checks the JSON shape only; whether the
/// graph makes sense is the job of `validateFlow`.
class FlowSpec {
  const FlowSpec({
    required this.id,
    required this.name,
    required this.nodes,
    required this.edges,
    this.enabled = true,
    this.mode = RunMode.single,
    this.cooldownSeconds = 0,
  });

  final String id;
  final String name;
  final bool enabled;
  final RunMode mode;
  final int cooldownSeconds;
  final List<NodeSpec> nodes;
  final List<EdgeSpec> edges;

  NodeSpec? node(String id) => nodes.where((n) => n.id == id).firstOrNull;

  Iterable<EdgeSpec> edgesFrom(String nodeId, String port) =>
      edges.where((e) => e.from.node == nodeId && e.from.port == port);

  Map<String, Object?> toJson() => {
    'schemaVersion': supportedFlowSchemaVersion,
    'id': id,
    'name': name,
    'enabled': enabled,
    'mode': mode.name,
    'cooldownSeconds': cooldownSeconds,
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': edges.map((e) => e.toJson()).toList(),
  };

  FlowSpec copyWith({bool? enabled}) => FlowSpec(
    id: id,
    name: name,
    nodes: nodes,
    edges: edges,
    enabled: enabled ?? this.enabled,
    mode: mode,
    cooldownSeconds: cooldownSeconds,
  );

  static FlowSpec parseJson(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw ValidationException('flow', [
        ValidationIssue(r'$', 'is not valid JSON: ${e.message}'),
      ]);
    }
    return parse(decoded);
  }

  static FlowSpec parse(Object? json) {
    if (json is! Map) {
      throw ValidationException('flow', [
        const ValidationIssue(r'$', 'must be an object'),
      ]);
    }
    final map = Map<String, Object?>.from(json);
    final issues = IssueCollector();
    const root = r'$';
    final version = map['schemaVersion'];
    if (version == null) {
      issues.add('$root.schemaVersion', 'is required');
    } else if (version != supportedFlowSchemaVersion) {
      issues.add(
        '$root.schemaVersion',
        'version $version is not supported (this engine reads $supportedFlowSchemaVersion)',
      );
    }
    final id = issues.requiredString(map, 'id', root);
    if (id != null && !_id.hasMatch(id)) {
      issues.add('$root.id', 'must be lower snake case');
    }
    final name = issues.requiredString(map, 'name', root);
    final enabled = map['enabled'] ?? true;
    if (enabled is! bool) issues.add('$root.enabled', 'must be true or false');
    final mode = map['mode'] == null
        ? RunMode.single
        : RunMode.fromWire(map['mode']);
    if (mode == null) {
      issues.add(
        '$root.mode',
        'must be one of ${RunMode.values.map((m) => m.name).join(', ')}',
      );
    }
    final cooldown =
        issues.optionalInt(map, 'cooldownSeconds', root, min: 0) ?? 0;

    final nodes = <NodeSpec>[];
    final rawNodes = issues.optionalList(map, 'nodes', root);
    if (rawNodes.isEmpty) issues.add('$root.nodes', 'needs at least one node');
    for (var i = 0; i < rawNodes.length; i++) {
      final path = '$root.nodes[$i]';
      final raw = rawNodes[i];
      if (raw is! Map) {
        issues.add(path, 'must be an object');
        continue;
      }
      final node = Map<String, Object?>.from(raw);
      final nodeId = issues.requiredString(node, 'id', path);
      final type = issues.requiredString(node, 'type', path);
      final config = issues.optionalMap(node, 'config', path) ?? const {};
      final position = node['position'];
      if (nodeId == null || type == null) continue;
      nodes.add(
        NodeSpec(
          id: nodeId,
          type: type,
          label: node['label'] is String ? node['label'] as String : nodeId,
          config: config,
          x: position is Map && position['x'] is num
              ? (position['x'] as num).toDouble()
              : 0,
          y: position is Map && position['y'] is num
              ? (position['y'] as num).toDouble()
              : 0,
        ),
      );
    }

    final edges = <EdgeSpec>[];
    final rawEdges = issues.optionalList(map, 'edges', root);
    for (var i = 0; i < rawEdges.length; i++) {
      final path = '$root.edges[$i]';
      final raw = rawEdges[i];
      if (raw is! Map) {
        issues.add(path, 'must be an object');
        continue;
      }
      final edge = Map<String, Object?>.from(raw);
      final edgeId = issues.requiredString(edge, 'id', path);
      final from = _portRef(edge['from'], '$path.from', issues);
      final to = _portRef(edge['to'], '$path.to', issues);
      if (edgeId == null || from == null || to == null) continue;
      edges.add(EdgeSpec(id: edgeId, from: from, to: to));
    }

    if (issues.hasIssues ||
        id == null ||
        name == null ||
        mode == null ||
        enabled is! bool) {
      throw ValidationException('flow ${id ?? ''}'.trim(), issues.issues);
    }
    return FlowSpec(
      id: id,
      name: name,
      enabled: enabled,
      mode: mode,
      cooldownSeconds: cooldown,
      nodes: List.unmodifiable(nodes),
      edges: List.unmodifiable(edges),
    );
  }

  static PortRef? _portRef(Object? json, String path, IssueCollector issues) {
    if (json is! Map) {
      issues.add(path, 'must be an object with node and port');
      return null;
    }
    final map = Map<String, Object?>.from(json);
    final node = issues.requiredString(map, 'node', path);
    final port = issues.requiredString(map, 'port', path);
    return node == null || port == null ? null : PortRef(node, port);
  }
}

final _id = RegExp(r'^[a-z][a-z0-9_]*$');
