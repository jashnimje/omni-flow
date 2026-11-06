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
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw CommandTimeoutException(argv, timeout);
    }
    return CommandResult(
      exitCode: code,
      stdout: (await out).trimRight(),
      stderr: (await err).trimRight(),
      duration: watch.elapsed,
    );
  }
}
