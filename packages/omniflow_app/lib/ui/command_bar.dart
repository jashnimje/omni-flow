import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'flows_screen.dart';

/// One input for device commands and running flows. The engine interprets
/// the line (command.interpret), so the CLI and the app read it the same way.
class CommandBar extends ConsumerStatefulWidget {
  const CommandBar({super.key});

  @override
  ConsumerState<CommandBar> createState() => _CommandBarState();
}

class _CommandBarState extends ConsumerState<CommandBar> {
  final _controller = TextEditingController();
  String? _summary;

  Future<void> _submit(String text) async {
    if (text.trim().isEmpty) return;
    final read = await callEngine(ref, 'command.interpret', {'text': text});
    if (read['ok'] != true) return;
    if (!mounted) return;
    if (read['kind'] == 'ask') {
      // The engine explains a line it half understood (a known device, an
      // unknown word). Its generic answer points at the architect, which
      // the app does not have yet.
      final summary = read['summary'];
      setState(
        () => _summary = summary is String && summary != 'Ask the architect'
            ? summary
            : 'Not a device or flow command. The architect is not set up yet.',
      );
      return;
    }
    final result = await callEngine(
      ref,
      read['command'] as String,
      Map<String, Object?>.from(read['args'] as Map),
    );
    if (!mounted) return;
    if (read['command'] == 'flow.run' && result['ok'] == true) {
      showMessage(runSummary(read['summary'], result));
    }
    setState(
      () => _summary = result['ok'] == true ? '${read['summary']}' : null,
    );
    if (result['ok'] == true) _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('command-bar'),
            controller: _controller,
            textInputAction: TextInputAction.go,
            onSubmitted: _submit,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.chevron_right),
              hintText: 'desk lamp 50%, run evening desk',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (_summary != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_summary!, key: const ValueKey('command-summary')),
            ),
        ],
      ),
    );
  }
}
