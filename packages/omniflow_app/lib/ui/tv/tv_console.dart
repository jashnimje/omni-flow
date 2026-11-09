import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import 'tv_controller.dart';

typedef _Run = ({
  String command,
  String output,
  int? exitCode,
  bool failed,
  String? cwd,
});

/// A shell on the TV. It runs anything, so it stays behind a warning the
/// user accepts once per session.
class TvConsoleTab extends ConsumerStatefulWidget {
  const TvConsoleTab({super.key, required this.tv});

  final TvController tv;

  @override
  ConsumerState<TvConsoleTab> createState() => _TvConsoleTabState();
}

class _TvConsoleTabState extends ConsumerState<TvConsoleTab>
    with AutomaticKeepAliveClientMixin {
  final _runs = <_Run>[];
  final _history = <String>[];
  final _command = TextEditingController();
  final _scroll = ScrollController();
  var _running = false;
  String? _cwd;

  TvController get tv => widget.tv;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _command.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final command = _command.text.trim();
    if (command.isEmpty || _running) return;
    setState(() {
      _running = true;
      _history
        ..remove(command)
        ..insert(0, command);
    });
    final result = await tv.client.call(
      TvCalls.shell,
      TvCalls.shellArgs(tv.id, command, cwd: _cwd),
    );
    if (!mounted) return;
    final ok = result['ok'] == true;
    final shell = TvCalls.shellOf(result);
    setState(() {
      _running = false;
      _runs.add((
        command: command,
        output: ok ? shell.output : errorMessage(result),
        exitCode: ok ? shell.exitCode : null,
        failed: !ok,
        cwd: _cwd,
      ));
      if (ok && shell.cwd != null) _cwd = shell.cwd;
      _command.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!ref.watch(consoleAcceptedProvider)) return _warning(context);
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: _runs.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Commands run on the TV with ADB shell rights. Try '
                      'getprop ro.build.version.release',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  key: const ValueKey('console-output'),
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _runs.length,
                  itemBuilder: (context, i) {
                    final r = _runs[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${r.cwd == null ? '' : '${r.cwd} '}\$ ${r.command}',
                            style: mono.copyWith(color: scheme.primary),
                          ),
                          if (r.output.isNotEmpty)
                            SelectableText(
                              r.output,
                              key: ValueKey('console-run-$i'),
                              style: mono.copyWith(
                                color: r.failed ? scheme.error : null,
                              ),
                            ),
                          if (r.exitCode case final code?)
                            Text(
                              'exit $code',
                              key: ValueKey('console-exit-$i'),
                              style: mono.copyWith(
                                color: code == 0
                                    ? scheme.outline
                                    : scheme.error,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        if (_running) const LinearProgressIndicator(minHeight: 2),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 8),
            child: Row(
              children: [
                PopupMenuButton<String>(
                  key: const ValueKey('console-history'),
                  tooltip: 'Earlier commands',
                  enabled: _history.isNotEmpty,
                  icon: const Icon(Icons.history),
                  onSelected: (c) => setState(() {
                    _command.text = c;
                    _command.selection = TextSelection.collapsed(
                      offset: c.length,
                    );
                  }),
                  itemBuilder: (_) => [
                    for (final c in _history.take(30))
                      PopupMenuItem(
                        value: c,
                        child: Text(c, style: mono, maxLines: 2),
                      ),
                  ],
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('console-command'),
                    controller: _command,
                    style: mono,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: 'Shell command',
                      prefixText: '${_cwd == null ? '' : '$_cwd '}\$ ',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _run(),
                  ),
                ),
                IconButton(
                  key: const ValueKey('console-run'),
                  tooltip: 'Run',
                  onPressed: _running ? null : _run,
                  icon: const Icon(Icons.play_arrow),
                ),
                IconButton(
                  key: const ValueKey('console-clear'),
                  tooltip: 'Clear the output',
                  onPressed: _runs.isEmpty ? null : () => setState(_runs.clear),
                  icon: const Icon(Icons.clear_all),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _warning(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.warning_amber,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 12),
          Text(
            'The console runs any command on the TV',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'OmniFlow does not check what you type. A command can delete '
            'files, remove apps, change settings or make the TV unusable '
            'until it is reset. Only run commands you understand.',
            key: ValueKey('console-warning'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('console-accept'),
            onPressed: () =>
                ref.read(consoleAcceptedProvider.notifier).accept(),
            child: const Text('I understand, open the console'),
          ),
        ],
      ),
    ),
  );
}
