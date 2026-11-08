import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../template/template_renderer.dart';

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;

  bool get succeeded => exitCode == 0;
}

class CommandTimeoutException implements Exception {
  CommandTimeoutException(this.argv, this.timeout);

  final List<String> argv;
  final Duration timeout;

  @override
  String toString() =>
      'CommandTimeoutException: ${argv.first} did not finish within $timeout';
}

/// Runs an argv on a host. Implementations: [LocalExecutor] and, for remote
/// hosts, the SSH executor.
abstract interface class HostExecutor {
  Future<CommandResult> run(
    List<String> argv, {
    String? stdin,
    Duration timeout = const Duration(seconds: 30),
  });
}

/// Renders an argv template element by element. Each element becomes exactly
/// one argument, so a parameter can never add a second command.
List<String> renderArgv(
  Object? template,
  TemplateContext context, {
  TemplateRenderer renderer = const TemplateRenderer(),
}) {
  if (template is! List ||
      template.isEmpty ||
      template.any((e) => e is! String)) {
    throw ArgumentError('an exec command is a non-empty list of strings');
  }
  return [
    for (final element in template.cast<String>())
      renderer.renderText(element, context),
  ];
}

/// Quotes each element for a POSIX shell and joins them, for SSH, where the
/// remote side always runs the command through the login shell.
String posixShellJoin(List<String> argv) => argv.map(_quote).join(' ');

/// Refuses an argv that [posixShellJoin] cannot quote for every login shell.
/// fish reads `\\` and `\'` as escapes even inside single quotes, so a
/// backslash in an argument could end the quoting early there. Throws an
/// [ArgumentError] before anything is sent.
void checkSshArgv(List<String> argv) {
  final bad = argv.where((a) => a.contains(r'\')).firstOrNull;
  if (bad != null) {
    throw ArgumentError.value(
      bad,
      'argv',
      'a backslash cannot be sent safely over SSH',
    );
  }
}

final _safe = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');

String _quote(String arg) {
  if (arg.isNotEmpty && _safe.hasMatch(arg)) return arg;
  return "'${arg.replaceAll("'", r"'\''")}'";
}

/// Runs a command on this machine with no shell in between.
class LocalExecutor implements HostExecutor {
  const LocalExecutor();

  @override
  Future<CommandResult> run(
    List<String> argv, {
    String? stdin,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (argv.isEmpty) throw ArgumentError('argv is empty');
    final watch = Stopwatch()..start();
    final process = await Process.start(
      argv.first,
      argv.sublist(1),
      runInShell: false,
    );
    final out = _Collected(process.stdout);
    final err = _Collected(process.stderr);
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await Future.wait([out.cancel(), err.cancel()]);
      throw CommandTimeoutException(argv, timeout);
    }
    // A child left in the background (`sleep 5 &`) keeps the pipes open after
    // the command exits, so the output is whatever arrived within the timeout.
    final remaining = timeout - watch.elapsed;
    await Future.wait([out.done(remaining), err.done(remaining)]);
    return CommandResult(
      exitCode: code,
      stdout: out.text.trimRight(),
      stderr: err.text.trimRight(),
      duration: watch.elapsed,
    );
  }
}

class _Collected {
  _Collected(Stream<List<int>> stream) {
    _subscription = stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          _text.write,
          onError: (Object _) {},
          onDone: _finished.complete,
        );
  }

  final _text = StringBuffer();
  final _finished = Completer<void>();
  late final StreamSubscription<String> _subscription;

  String get text => _text.toString();

  Future<void> done(Duration within) async {
    if (!within.isNegative) {
      await _finished.future.timeout(within, onTimeout: () {});
    }
    await cancel();
  }

  Future<void> cancel() async {
    if (!_finished.isCompleted) await _subscription.cancel();
  }
}
