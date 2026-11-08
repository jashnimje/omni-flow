import '../manifest/validation.dart';
import 'flow.dart';
import 'node_types.dart';

/// Every problem with [flow], in one pass. The CLI, the app and the MCP
/// tools all call this and show the same list.
List<ValidationIssue> validateFlow(
  FlowSpec flow, {
  Map<String, NodeType>? types,
  FlowReferences refs = const FlowReferences(),
}) {
  final registry = types ?? builtInNodeTypes;
  final issues = IssueCollector();

  // 1. Unique ids.
  final nodeIds = <String>{};
  for (var i = 0; i < flow.nodes.length; i++) {
    if (!nodeIds.add(flow.nodes[i].id)) {
      issues.add(
        r'$.nodes['
            '$i].id',
        'duplicates "${flow.nodes[i].id}"',
      );
    }
  }
  final edgeIds = <String>{};
  for (var i = 0; i < flow.edges.length; i++) {
    if (!edgeIds.add(flow.edges[i].id)) {
      issues.add(
        r'$.edges['
            '$i].id',
        'duplicates "${flow.edges[i].id}"',
      );
    }
  }

  // Types and configs.
  final typeOf = <String, NodeType>{};
  for (var i = 0; i < flow.nodes.length; i++) {
    final node = flow.nodes[i];
    final type = registry[node.type];
    final path =
        r'$.nodes['
        '$i]';
    if (type == null) {
      issues.add('$path.type', 'unknown node type ${node.type}');
      continue;
    }
    typeOf[node.id] = type;
    type.check(node.config, '$path.config', issues, refs);
  }

  // 2. Edges reference real nodes and ports.
  for (var i = 0; i < flow.edges.length; i++) {
    final edge = flow.edges[i];
    final path =
        r'$.edges['
        '$i]';
    final from = typeOf[edge.from.node];
    final to = typeOf[edge.to.node];
    if (!nodeIds.contains(edge.from.node)) {
      issues.add('$path.from.node', 'no node ${edge.from.node}');
    } else if (from != null && !from.outputs.contains(edge.from.port)) {
      issues.add(
        '$path.from.port',
        '${from.type} has no output port ${edge.from.port} (has ${from.outputs.join(', ')})',
      );
    }
    if (!nodeIds.contains(edge.to.node)) {
      issues.add('$path.to.node', 'no node ${edge.to.node}');
    } else if (to != null) {
      if (!to.hasInput) {
        issues.add(
          '$path.to.node',
          '${edge.to.node} is a trigger and takes no input',
        );
      } else if (edge.to.port != 'in') {
        issues.add(
          '$path.to.port',
          'the input port is in, not ${edge.to.port}',
        );
      }
    }
  }

  // 3. Acyclic (Kahn).
  final valid = flow.edges
      .where(
        (e) => nodeIds.contains(e.from.node) && nodeIds.contains(e.to.node),
      )
      .toList();
  final indegree = {for (final id in nodeIds) id: 0};
  for (final e in valid) {
    indegree[e.to.node] = indegree[e.to.node]! + 1;
  }
  final queue = [
    for (final e in indegree.entries)
      if (e.value == 0) e.key,
  ];
  var visited = 0;
  while (queue.isNotEmpty) {
    final id = queue.removeLast();
    visited++;
    for (final e in valid.where((e) => e.from.node == id)) {
      indegree[e.to.node] = indegree[e.to.node]! - 1;
      if (indegree[e.to.node] == 0) queue.add(e.to.node);
    }
  }
  if (visited < nodeIds.length) {
    final leftover = {
      for (final e in indegree.entries)
        if (e.value > 0) e.key,
    };
    bool reachesItself(String start) {
      final seen = <String>{};
      final stack = [start];
      while (stack.isNotEmpty) {
        final id = stack.removeLast();
        for (final e in valid.where(
          (e) => e.from.node == id && leftover.contains(e.to.node),
        )) {
          if (e.to.node == start) return true;
          if (seen.add(e.to.node)) stack.add(e.to.node);
        }
      }
      return false;
    }

    final inCycle = leftover.where(reachesItself).toList()..sort();
    issues.add(
      r'$.edges',
      'the graph has a cycle through ${inCycle.join(', ')}. Use a repeat node for loops',
    );
  }

  // 4. A trigger exists, and every other node is reachable from one.
  final triggers = [
    for (final n in flow.nodes)
      if (typeOf[n.id]?.category == NodeCategory.trigger) n.id,
  ];
  if (triggers.isEmpty) issues.add(r'$.nodes', 'needs at least one trigger');
  final reachable = <String>{...triggers};
  final frontier = [...triggers];
  while (frontier.isNotEmpty) {
    final id = frontier.removeLast();
    for (final e in valid.where((e) => e.from.node == id)) {
      if (reachable.add(e.to.node)) frontier.add(e.to.node);
    }
  }
  for (var i = 0; i < flow.nodes.length; i++) {
    final id = flow.nodes[i].id;
    if (typeOf.containsKey(id) && !reachable.contains(id)) {
      issues.add(
        r'$.nodes['
            '$i]',
        '$id is not reachable from any trigger',
      );
    }
  }

  // 5. A debounce gate waits while its run stays active, so single mode
  // drops every later event and queued mode never suppresses one.
  if ((flow.mode == RunMode.single || flow.mode == RunMode.queued) &&
      flow.nodes.any((n) => n.type == 'debounce')) {
    issues.add(
      r'$.mode',
      'a debounce gate does not work in ${flow.mode.name} mode. Use mode restart',
    );
  }

  // 6. No run_flow chain leads back here: the waiting run would never end.
  final calls = {...refs.calls, flow.id: runFlowTargets(flow)};
  bool leadsBack(String start) {
    final seen = <String>{};
    final stack = [start];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (id == flow.id) return true;
      if (seen.add(id)) stack.addAll(calls[id] ?? const {});
    }
    return false;
  }

  for (var i = 0; i < flow.nodes.length; i++) {
    final n = flow.nodes[i];
    final target = n.config['flowId'];
    if (n.type != 'run_flow' || target is! String) continue;
    if (leadsBack(target)) {
      issues.add(
        r'$.nodes['
        '$i].config.flowId',
        target == flow.id
            ? 'a flow cannot run itself'
            : 'running $target leads back to ${flow.id}, a cycle that never finishes',
      );
    }
  }

  return issues.issues;
}

/// The flows [flow] starts with `run_flow` nodes.
Set<String> runFlowTargets(FlowSpec flow) => {
  for (final n in flow.nodes)
    if (n.type == 'run_flow' && n.config['flowId'] is String)
      n.config['flowId'] as String,
};

/// Parses and validates, throwing a [ValidationException] with every issue.
FlowSpec parseAndValidateFlow(
  Object? json, {
  Map<String, NodeType>? types,
  FlowReferences refs = const FlowReferences(),
}) {
  final flow = FlowSpec.parse(json);
  final issues = validateFlow(flow, types: types, refs: refs);
  if (issues.isNotEmpty) throw ValidationException('flow ${flow.id}', issues);
  return flow;
}
