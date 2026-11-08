import 'flow.dart';
import 'node_types.dart';

/// One card in the card view.
sealed class FlowCard {
  const FlowCard(this.node, this.category, this.port);

  final NodeSpec node;

  /// The node's category (trigger, condition, gate, transformer,
  /// flowControl, action), so a UI can style it without its own table.
  final String? category;

  /// The parent's output this card hangs off, when it is not the plain
  /// next step: `error`, `body`, `done`, `event` or `timeout`.
  final String? port;

  Map<String, Object?> toJson();

  Map<String, Object?> _head(String kind) => {
    'kind': kind,
    'node': node.id,
    'type': node.type,
    'label': node.label,
    'category': ?category,
    'port': ?port,
  };
}

/// An action, transformer, gate or delay: one step.
class StepCard extends FlowCard {
  const StepCard(super.node, super.category, super.port, this.then);

  /// What follows this step, in order. Several cards here run side by side.
  final List<FlowCard> then;

  @override
  Map<String, Object?> toJson() => {
    ..._head('step'),
    if (then.isNotEmpty) 'then': then.map((c) => c.toJson()).toList(),
  };
}

/// A condition: IF, with what happens when it holds and when it does not.
class IfCard extends FlowCard {
  const IfCard(
    super.node,
    super.category,
    super.port,
    this.whenTrue,
    this.whenFalse,
  );

  final List<FlowCard> whenTrue;
  final List<FlowCard> whenFalse;

  @override
  Map<String, Object?> toJson() => {
    ..._head('if'),
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
      for (final n in when)
        {
          'node': n.id,
          'type': n.type,
          'label': n.label,
          'category': NodeCategory.trigger.name,
        },
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

  late final FlowCard Function(NodeSpec, String?) card;
  List<FlowCard> follow(String nodeId, String port, {bool mark = false}) => [
    for (final e in flow.edgesFrom(nodeId, port))
      card(flow.node(e.to.node)!, mark && port != 'out' ? port : null),
  ];

  card = (NodeSpec n, String? port) {
    final type = registry[n.type];
    final category = type?.category.name;
    if (type?.category == NodeCategory.condition) {
      return IfCard(
        n,
        category,
        port,
        follow(n.id, 'true'),
        follow(n.id, 'false'),
      );
    }
    return StepCard(n, category, port, [
      for (final p in type?.outputs ?? const <String>[])
        ...follow(n.id, p, mark: true),
    ]);
  };

  return FlowCards(triggers, [
    for (final id in firstSteps) card(flow.node(id)!, null),
  ]);
}
