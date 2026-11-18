import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'tv_controller.dart';
import 'tv_widgets.dart';

typedef _Run = ({
  String command,
  String output,
  int? exitCode,
  bool failed,
  String? cwd,
});

/// 4.5 Console: a shell on the TV. It runs anything, so it stays behind a
/// warning the user accepts once per session, and the banner stays above
/// the output after.
class TvConsoleTab extends ConsumerStatefulWidget {
  const TvConsoleTab({super.key, required this.tv});

  final TvController tv;

  @override
  ConsumerState<TvConsoleTab> createState() => _TvConsoleTabState();
}

class _TvConsoleTabState extends ConsumerState<TvConsoleTab> {
  final _runs = <_Run>[];
  final _history = <String>[];
  final _command = TextEditingController();
  final _scroll = ScrollController();
  var _running = false;
  String? _cwd;

  TvController get tv => widget.tv;

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
      if (_history.length > 100) _history.removeLast();
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
      // Clear only what was run: the next command may be typed meanwhile.
      if (_command.text.trim() == command) _command.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(consoleAcceptedProvider)) return _warning(context);
    // The terminal well of the mockup: the screen colour, darker than a
    // card, with the prompt in the light accent tint.
    final palette = OmniPalette.of(context);
    final mono = OmniText.mono.copyWith(color: palette.onAccentSoft);
    final out = OmniText.mono.copyWith(color: OmniPalette.of(context).muted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OmniSpace.screen,
        0,
        OmniSpace.screen,
        OmniSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OmniBanner.warning(
            'Commands run directly on the ${tv.noun}. Only you can use this, '
            'never an agent.',
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: palette.background,
                borderRadius: BorderRadius.circular(OmniRadii.button),
                border: Border.all(color: palette.line),
              ),
              child: _runs.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(OmniSpace.md),
                      child: Text(
                        'Commands run with ADB shell rights. Try\n'
                        'getprop ro.build.version.release',
                        style: out,
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey('console-output'),
                      controller: _scroll,
                      padding: const EdgeInsets.all(OmniSpace.md),
                      itemCount: _runs.length,
                      itemBuilder: (context, i) {
                        final r = _runs[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: OmniSpace.sm),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${r.cwd == null ? '' : '${r.cwd} '}\$ ${r.command}',
                                style: mono,
                              ),
                              if (r.output.isNotEmpty)
                                SelectableText(
                                  r.output,
                                  key: ValueKey('console-run-$i'),
                                  style: r.failed
                                      ? out.copyWith(
                                          color: OmniPalette.of(context).bad,
                                        )
                                      : out,
                                ),
                              if (r.exitCode case final code?)
                                Text(
                                  'exit $code',
                                  key: ValueKey('console-exit-$i'),
                                  style: out.copyWith(
                                    color: code == 0
                                        ? OmniPalette.of(context).muted
                                        : OmniPalette.of(context).bad,
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
          if (_running)
            const Padding(
              padding: EdgeInsets.only(top: OmniSpace.xs),
              child: OmniProgressBar(height: 2, semanticLabel: 'Running'),
            ),
          const SizedBox(height: OmniSpace.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('console-command'),
                  controller: _command,
                  style: OmniText.mono.copyWith(fontSize: 14),
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.send,
                  decoration: InputDecoration(
                    labelText: 'Command',
                    prefixText: '${_cwd == null ? '' : '$_cwd '}\$ ',
                    suffixIcon: PopupMenuButton<String>(
                      key: const ValueKey('console-history'),
                      tooltip: 'Earlier commands',
                      enabled: _history.isNotEmpty,
                      icon: const Icon(TvIcons.history),
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
                            child: Text(c, style: OmniText.mono, maxLines: 2),
                          ),
                      ],
                    ),
                  ),
                  onSubmitted: (_) => _run(),
                ),
              ),
              OmniIconAction(
                key: const ValueKey('console-run'),
                icon: TvIcons.run,
                label: 'Run',
                color: palette.accent,
                onPressed: _running ? null : _run,
              ),
              OmniIconAction(
                key: const ValueKey('console-clear'),
                icon: TvIcons.clear,
                label: 'Clear the output',
                onPressed: _runs.isEmpty ? null : () => setState(_runs.clear),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _warning(BuildContext context) => ListView(
    padding: omniBodyPadding(OmniInsets.bottom(context)),
    children: [
      OmniEmptyState(
        key: const ValueKey('console-warning'),
        icon: OmniIcons.warning,
        title: 'The console runs any command on the ${tv.noun}',
        message:
            'OmniFlow does not check what you type. A command can delete '
            'files, remove apps, change settings or make the ${tv.noun} unusable '
            'until it is reset. Only you can use it, never an agent.',
        action: OmniButton.danger(
          key: const ValueKey('console-accept'),
          label: 'I understand, open the console',
          onPressed: () => ref.read(consoleAcceptedProvider.notifier).accept(),
        ),
      ),
    ],
  );
}
