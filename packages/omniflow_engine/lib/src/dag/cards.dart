import 'flow.dart';
import 'node_types.dart';

/// One card in the card view.
sealed class FlowCard {
  const FlowCard(this.node);

  final NodeSpec node;

  Map<String, Object?> toJson();
}

/// An action, transformer, gate or delay: one step.
class StepCard extends FlowCard {
  const StepCard(super.node, this.then);

  /// What follows this step, in order. Several cards here run side by side.
  final List<FlowCard> then;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'step',
    'node': node.id,
    'type': node.type,
    'label': node.label,
    if (then.isNotEmpty) 'then': then.map((c) => c.toJson()).toList(),
  };
}

/// A condition: IF, with what happens when it holds and when it does not.
class IfCard extends FlowCard {
  const IfCard(super.node, this.whenTrue, this.whenFalse);

  final List<FlowCard> whenTrue;
  final List<FlowCard> whenFalse;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'if',
    'node': node.id,
    'type': node.type,
    'label': node.label,
    'then': whenTrue.map((c) => c.toJson()).toList(),
    'else': whenFalse.map((c) => c.toJson()).toList(),
  };
}

/// The card view of a flow: its triggers (WHEN) and what follows them.
class FlowCards {
  const FlowCards(this.when, this.then);

  final List<NodeSpec> when;
  final List<FlowCard> then;

  Map<String, Object?> toJson() => {
    'when': [
      for (final n in when) {'node': n.id, 'type': n.type, 'label': n.label},
    ],
    'then': then.map((c) => c.toJson()).toList(),
  };
}

/// Projects [flow] onto WHEN / IF / THEN cards, or returns null when the
/// graph is not a tree and so needs the canvas: a non-trigger node with more
/// than one incoming edge, or triggers that lead to different first steps.
FlowCards? projectCards(FlowSpec flow, {Map<String, NodeType>? types}) {
  final registry = types ?? builtInNodeTypes;
  final triggers = [
    for (final n in flow.nodes)
      if (registry[n.type]?.category == NodeCategory.trigger) n,
  ];
  if (triggers.isEmpty) return null;
  final incoming = <String, int>{};
  for (final e in flow.edges) {
    incoming[e.to.node] = (incoming[e.to.node] ?? 0) + 1;
  }
  final firstSteps = {
    for (final t in triggers)
      for (final e in flow.edgesFrom(t.id, 'out')) e.to.node,
  };
  if (triggers.length > 1) {
    final shared = {
      for (final t in triggers)
        ([
          ...flow.edgesFrom(t.id, 'out').map((e) => e.to.node),
        ]..sort()).join(','),
    };
    if (shared.length != 1) return null;
  }
  for (final n in flow.nodes) {
    final count = incoming[n.id] ?? 0;
    final allowed = firstSteps.contains(n.id) ? triggers.length : 1;
    if (count > allowed) return null;
  }

  late final FlowCard Function(NodeSpec) card;
  List<FlowCard> follow(String nodeId, String port) => [
    for (final e in flow.edgesFrom(nodeId, port)) card(flow.node(e.to.node)!),
  ];

  card = (NodeSpec n) {
    final type = registry[n.type];
    if (type?.category == NodeCategory.condition) {
      return IfCard(n, follow(n.id, 'true'), follow(n.id, 'false'));
    }
    return StepCard(n, [
      for (final p in type?.outputs ?? const <String>[]) ...follow(n.id, p),
    ]);
  };

  return FlowCards(triggers, [
    for (final id in firstSteps) card(flow.node(id)!),
  ]);
}
