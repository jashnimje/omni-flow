import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'automations_state.dart';
import 'review_page.dart';
import 'rule_editor.dart';
import 'scenes.dart';
import 'test_run.dart';

/// Opens an automation the way it was written: one waiting for approval
/// opens its review, a rule its editor, a scene the scene editor, and a
/// link or a graph its runs. [summary] skips the lookup when the list
/// already has the row.
class AutomationPage extends ConsumerStatefulWidget {
  const AutomationPage({super.key, required this.id, this.summary});

  final String id;
  final AutomationSummary? summary;

  @override
  ConsumerState<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends ConsumerState<AutomationPage> {
  ({String? source, bool approved, String name})? _kind;
  ApiFailure? _failure;

  @override
  void initState() {
    super.initState();
    if (widget.summary case final s?) {
      _kind = (source: s.source, approved: !s.needsApproval, name: s.name);
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _failure = null);
    final reply = await ref.read(engineApiProvider).automation(widget.id);
    if (!mounted) return;
    final a = reply.value;
    setState(() {
      _failure = reply.failure;
      _kind = a == null
          ? null
          : (
              source: EngineCalls.formOf(a),
              approved: a['approved'] != false,
              name: '${a['name'] ?? widget.id}',
            );
    });
  }

  @override
  Widget build(BuildContext context) {
    final kind = _kind;
    if (kind == null) {
      return OmniPage(
        title: widget.id,
        body: _failure == null
            ? const Center(child: CircularProgressIndicator())
            : OmniEmptyState(
                key: const ValueKey('automation-error'),
                icon: OmniIcons.error,
                title: _failure!.type == 'not_found'
                    ? 'This automation is gone'
                    : 'Could not open it',
                message: _failure!.type == 'not_found'
                    ? 'It was removed after the link to it was made.'
                    : _failure!.message,
                action: _failure!.type == 'not_found'
                    ? null
                    : OmniButton.ghost(label: 'Try again', onPressed: _load),
              ),
      );
    }
    if (!kind.approved) return ReviewPage(id: widget.id);
    return switch (kind.source) {
      'rule' => RuleEditorPage(id: widget.id),
      'scene' => SceneEditorPage(id: widget.id),
      _ => _LinkRunsPage(id: widget.id, name: kind.name),
    };
  }
}

/// A link or a graph: its test and runs, and Remove. Links are made again
/// rather than edited.
class _LinkRunsPage extends ConsumerWidget {
  const _LinkRunsPage({required this.id, required this.name});

  final String id;
  final String name;

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Remove $name?',
      body: 'It stops running and is deleted. This cannot be undone.',
      action: 'Remove',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final reply = await ref.read(engineApiProvider).removeAutomation(id);
    if (!reply.ok) return;
    await ref.read(automationsProvider.notifier).refresh();
    showMessage('Removed $name');
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => TestRunPage(
    name: name,
    id: id,
    actions: [
      OmniIconAction(
        key: const ValueKey('automation-remove'),
        icon: OmniIcons.delete,
        label: 'Remove $name',
        onPressed: () => _remove(context, ref),
      ),
    ],
  );
}
