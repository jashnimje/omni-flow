import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/engine_calls.dart';
import '../state/providers.dart';
import 'device_sheets.dart';
import 'rule_builder.dart';
import 'theme.dart';

/// Flows: enable, run, review for approval, remove, and open the card view.
class FlowsScreen extends ConsumerWidget {
  const FlowsScreen({super.key});

  Future<void> _run(WidgetRef ref, Json flow) async {
    final result = await callEngine(ref, 'flow.run', {'id': flow['id']});
    if (result['ok'] == true) showMessage(runSummary(flow['name'], result));
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, Json flow) async {
    final flows = ref.read(flowsProvider.notifier);
    final client = ref.read(engineClientProvider);
    final ok = await confirm(
      context,
      title: 'Remove ${flow['name']}?',
      body: 'It stops running and is deleted.',
      action: 'Remove',
    );
    if (!ok) return;
    final result = await callClient(client, 'flow.remove', {'id': flow['id']});
    if (result['ok'] == true) await flows.refresh();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flows = ref.watch(flowsProvider);
    return flows.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) => list.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No automations yet. Make a rule with New rule, or link '
                  'two devices from a device menu on the Devices tab.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              children: [
                for (final f in list)
                  ListTile(
                    key: ValueKey('flow-${f['id']}'),
                    title: Text('${f['name']}'),
                    subtitle: f['approved'] == true
                        ? Text(f['loaded'] == true ? 'running' : 'off')
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: ActionChip(
                              key: ValueKey('review-${f['id']}'),
                              avatar: const Icon(Icons.gpp_maybe, size: 18),
                              label: const Text('Needs approval'),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ApprovalPage(
                                    flowId: f['id'] as String,
                                    name: '${f['name']}',
                                  ),
                                ),
                              ),
                            ),
                          ),
                    onTap: () => EngineCalls.formOf(f) == 'rule'
                        ? openRuleBuilder(context, id: f['id'] as String)
                        : Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => FlowCardsPage(
                                flowId: f['id'] as String,
                                name: '${f['name']}',
                              ),
                            ),
                          ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: ValueKey('run-${f['id']}'),
                          tooltip: 'Run ${f['name']}',
                          icon: const Icon(Icons.play_arrow),
                          onPressed: f['loaded'] == true
                              ? () => _run(ref, f)
                              : null,
                        ),
                        Semantics(
                          label: 'Run ${f['name']} on its own',
                          child: Switch(
                            key: ValueKey('enable-${f['id']}'),
                            value: f['enabled'] == true,
                            onChanged: (v) async {
                              await callEngine(ref, 'flow.enable', {
                                'id': f['id'],
                                'enabled': v,
                              });
                              await ref.read(flowsProvider.notifier).refresh();
                            },
                          ),
                        ),
                        PopupMenuButton<String>(
                          key: ValueKey('flow-menu-${f['id']}'),
                          tooltip: 'More for ${f['name']}',
                          onSelected: (_) => _remove(context, ref, f),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'remove',
                              child: Text('Remove'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// One line per run of a flow.run result: how it ended, and the first
/// node that failed with its error.
String runSummary(Object? name, Json result) {
  final runs = (result['runs'] as List? ?? const []).cast<Map>();
  if (runs.isEmpty) return '$name: nothing ran';
  return [
    for (final r in runs)
      () {
        final failed = (r['nodes'] as List? ?? const [])
            .cast<Map>()
            .where((n) => n['error'] != null)
            .firstOrNull;
        return [
          '$name: ${r['outcome']}',
          if (r['reason'] != null) '(${r['reason']})',
          if (failed != null) 'at ${failed['node']}: ${failed['error']}',
        ].join(' ');
      }(),
  ].join('\n');
}

/// What a flow waiting for approval will do, from the stored flow itself
/// rather than its labels, which whoever wrote the flow chose. Approving
/// sends the revision shown, so the engine can refuse a flow that changed
/// since.
class ApprovalPage extends ConsumerStatefulWidget {
  const ApprovalPage({super.key, required this.flowId, required this.name});

  final String flowId;
  final String name;

  @override
  ConsumerState<ApprovalPage> createState() => _ApprovalPageState();
}

class _ApprovalPageState extends ConsumerState<ApprovalPage> {
  late final Future<Json> _flow = ref.read(engineClientProvider).call(
    'flow.get',
    {'id': widget.flowId},
  );

  static const _effects = {'device_capability', 'device_toggle', 'run_flow'};

  Future<void> _approve(Json data) async {
    final flows = ref.read(flowsProvider.notifier);
    final ok = await confirm(
      context,
      title: 'Approve ${widget.name}?',
      body: 'It can then run on its own and do everything listed.',
      action: 'Approve',
    );
    if (!ok || !mounted) return;
    final result = await callEngine(ref, 'flow.approve', {
      'id': widget.flowId,
      'revision': ?data['revision'],
    });
    if (result['ok'] != true) return;
    await flows.refresh();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final devices = {
      for (final d in ref.watch(devicesProvider).value ?? const <Json>[])
        d['id']: d,
    };
    return Scaffold(
      appBar: AppBar(title: Text('Review ${widget.name}')),
      body: FutureBuilder<Json>(
        future: _flow,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          final data = snap.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (data['ok'] != true) {
            return Center(child: Text(errorMessage(data)));
          }
          final flow = data['flow'] as Map? ?? const {};
          final nodes = [
            for (final n in (flow['nodes'] as List? ?? const []).cast<Map>())
              if (_effects.contains(n['type'])) n,
          ];
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              const Text('When it runs, this flow will:'),
              if (nodes.isEmpty)
                const ListTile(title: Text('Drive no device and run no flow')),
              for (final n in nodes) _effect(n, devices),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('approve'),
                onPressed: () => _approve(data),
                child: const Text('Approve'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _effect(Map node, Map<Object?, Json> devices) {
    final config = node['config'] as Map? ?? const {};
    if (node['type'] == 'run_flow') {
      return ListTile(
        key: ValueKey('effect-${node['id']}'),
        leading: const Icon(Icons.account_tree_outlined),
        title: Text('Run the flow ${config['flowId']}'),
      );
    }
    final device = devices[config['deviceId']];
    final capability = (device?['capabilities'] as List? ?? const [])
        .cast<Map>()
        .where((c) => c['id'] == config['capabilityId'])
        .firstOrNull;
    final highRisk =
        capability?['highRisk'] == true || capability?['type'] == 'exec';
    final params = config['params'] as Map? ?? const {};
    return ListTile(
      key: ValueKey('effect-${node['id']}'),
      leading: Icon(
        highRisk ? Icons.warning_amber : Icons.bolt,
        semanticLabel: highRisk ? 'High risk' : null,
      ),
      title: Text(
        device == null
            ? 'Unknown device ${config['deviceId']}'
            : '${device['name']} (${config['deviceId']})',
      ),
      subtitle: Text(
        [
          if (device != null) 'driver ${device['driver']}',
          node['type'] == 'device_toggle'
              ? 'toggle ${config['capabilityId']}'
              : 'capability ${config['capabilityId']}',
          for (final p in params.entries)
            '${p.key} = ${p.value}${'${p.value}'.contains('{{') ? ' (filled in when it runs)' : ''}',
          if (highRisk) 'runs a command on ${device?['host']}',
        ].join('\n'),
      ),
      isThreeLine: params.isNotEmpty || highRisk,
    );
  }
}

/// The WHEN / IF / THEN view of a flow, read-only. A flow that is not a tree
/// needs the canvas.
class FlowCardsPage extends ConsumerStatefulWidget {
  const FlowCardsPage({super.key, required this.flowId, required this.name});

  final String flowId;
  final String name;

  @override
  ConsumerState<FlowCardsPage> createState() => _FlowCardsPageState();
}

class _FlowCardsPageState extends ConsumerState<FlowCardsPage> {
  late final Future<Json> _result = ref.read(engineClientProvider).call(
    'flow.cards',
    {'id': widget.flowId},
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: FutureBuilder<Json>(
        future: _result,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Text('${snap.error}', key: const ValueKey('cards-error')),
            );
          }
          final data = snap.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (data['ok'] != true) {
            return Center(
              child: Text(
                errorMessage(data),
                key: const ValueKey('cards-error'),
              ),
            );
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

/// The category colour marks the border and a dot only: on the dark card
/// several category colours are too dim for small text.
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
        leading: Icon(Icons.circle, size: 12, color: color),
        title: Text('${node['label']}'),
        subtitle: Text('${node['type']}'),
      ),
    );
  }
}
