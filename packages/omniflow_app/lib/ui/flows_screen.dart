import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'theme.dart';

/// Flows: enable, run, approve, and open the card view.
class FlowsScreen extends ConsumerWidget {
  const FlowsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flows = ref.watch(flowsProvider);
    return flows.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) => list.isEmpty
          ? const Center(
              child: Text('No flows yet. Save one with omni flow save.'),
            )
          : ListView(
              children: [
                for (final f in list)
                  ListTile(
                    key: ValueKey('flow-${f['id']}'),
                    title: Text('${f['name']}'),
                    subtitle: Text(
                      f['approved'] == true
                          ? (f['loaded'] == true ? 'running' : 'off')
                          : 'waiting for approval',
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FlowCardsPage(
                          flowId: f['id'] as String,
                          name: f['name'] as String,
                        ),
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (f['approved'] != true)
                          TextButton(
                            key: ValueKey('approve-${f['id']}'),
                            onPressed: () async {
                              await callEngine(ref, 'flow.approve', {
                                'id': f['id'],
                              });
                              await ref.read(flowsProvider.notifier).refresh();
                            },
                            child: const Text('Approve'),
                          ),
                        IconButton(
                          key: ValueKey('run-${f['id']}'),
                          icon: const Icon(Icons.play_arrow),
                          onPressed: f['loaded'] == true
                              ? () =>
                                    callEngine(ref, 'flow.run', {'id': f['id']})
                              : null,
                        ),
                        Switch(
                          value: f['enabled'] == true,
                          onChanged: (v) async {
                            await callEngine(ref, 'flow.enable', {
                              'id': f['id'],
                              'enabled': v,
                            });
                            await ref.read(flowsProvider.notifier).refresh();
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// The WHEN / IF / THEN view of a flow, read-only. A flow that is not a tree
/// needs the canvas.
class FlowCardsPage extends ConsumerWidget {
  const FlowCardsPage({super.key, required this.flowId, required this.name});

  final String flowId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: FutureBuilder<Json>(
        future: ref.read(engineClientProvider).call('flow.cards', {
          'id': flowId,
        }),
        builder: (context, snap) {
          final data = snap.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (data['tree'] != true) {
            return const Center(
              child: Text(
                'This flow joins branches, so it only fits the canvas view.',
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              const _Heading('WHEN'),
              for (final t in (data['when'] as List).cast<Map>()) _NodeCard(t),
              ..._cards((data['then'] as List).cast<Map>(), 0),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _cards(List<Map> cards, int depth) => [
    for (final c in cards) ...[
      if (c['kind'] == 'if') ...[
        _Indent(depth, const _Heading('IF')),
        _Indent(depth, _NodeCard(c)),
        _Indent(depth, const _Heading('THEN')),
        ..._cards((c['then'] as List).cast<Map>(), depth + 1),
        if ((c['else'] as List).isNotEmpty) ...[
          _Indent(depth, const _Heading('OTHERWISE')),
          ..._cards((c['else'] as List).cast<Map>(), depth + 1),
        ],
      ] else ...[
        _Indent(depth, _NodeCard(c)),
        ..._cards((c['then'] as List? ?? const []).cast<Map>(), depth),
      ],
    ],
  ];
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2),
    ),
  );
}

class _Indent extends StatelessWidget {
  const _Indent(this.depth, this.child);

  final int depth;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: 16.0 * depth),
    child: child,
  );
}

class _NodeCard extends StatelessWidget {
  const _NodeCard(this.node);

  final Map node;

  @override
  Widget build(BuildContext context) {
    final color = categoryColor(node['type'] as String);
    return Card(
      key: ValueKey('card-${node['node']}'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: color.withValues(alpha: 0.7), width: 1.5),
      ),
      child: ListTile(
        dense: true,
        title: Text('${node['label']}'),
        subtitle: Text('${node['type']}', style: TextStyle(color: color)),
      ),
    );
  }
}
