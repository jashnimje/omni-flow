import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../design/design.dart';
import '../../api/screen_calls.dart';

/// What an AI agent may change through MCP: `read` or `setup`.
final agentAccessProvider = FutureProvider<String?>((ref) async {
  final reply = await ref.watch(engineClientProvider).call(AgentCalls.access);
  return reply['ok'] == true ? reply['access'] as String? : null;
});

const _levels = {
  'read': (
    title: 'Read and suggest',
    detail:
        'Agents see everything and can try rules out. What they save waits '
        'for you where it is high risk, and they cannot add or change things.',
  ),
  'setup': (
    title: 'Set up everything',
    detail:
        'Agents can also find, add and configure things, places, rooms, tags '
        'and scenes, and save, turn on, run and remove automations. A '
        'high-risk automation still waits for you.',
  ),
};

/// The row in Settings, Agents, and its choice sheet.
class AgentAccessRow extends ConsumerWidget {
  const AgentAccessRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(agentAccessProvider).value;
    return OmniListRow(
      key: const ValueKey('settings-agent-access'),
      icon: OmniIcons.agent,
      title: 'What agents can do',
      subtitle: _levels[access]?.title ?? '',
      chevron: true,
      onTap: () => _choose(context, ref, access),
    );
  }

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref,
    String? current,
  ) async {
    final picked = await showOmniSheet<String>(
      context,
      builder: (sheet) => OmniSheet(
        title: 'What agents can do',
        subtitle:
            'Claude and other agents reach OmniFlow through MCP, from a '
            'computer this phone allows for debugging.',
        children: [
          for (final MapEntry(key: level, value: l) in _levels.entries)
            OmniListRow(
              key: ValueKey('agent-access-$level'),
              title: l.title,
              subtitle: l.detail,
              subtitleLines: 4,
              trailing: level == current
                  ? const Icon(OmniIcons.check, color: OmniColors.accent)
                  : null,
              onTap: () => Navigator.of(sheet).pop(level),
            ),
          const SizedBox(height: OmniSpace.sm),
          const Text(
            'Never open to an agent: keys and passwords, pairing, removing '
            'things or places, approving or running high-risk automations, '
            'writing firmware, and the TV shell, installs, raw settings and '
            'file deletes. A computer you allowed for USB debugging can still '
            'do anything you can, so allow only your own.',
            key: ValueKey('agent-access-user-only'),
            style: OmniText.caption,
          ),
        ],
      ),
    );
    if (picked == null || picked == current || !context.mounted) return;
    final reply = await ref.read(engineClientProvider).call(
      AgentCalls.setAccess,
      {'access': picked},
    );
    if (reply['ok'] != true) showMessage(errorMessage(reply));
    ref.invalidate(agentAccessProvider);
  }
}
