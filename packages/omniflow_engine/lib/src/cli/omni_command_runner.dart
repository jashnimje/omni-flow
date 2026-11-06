import 'dart:io';

import 'package:args/command_runner.dart';

import '../version.dart';

/// Root of the `omni` CLI. Each subcommand calls the same core API the app
/// uses; commands are added per milestone (driver, device, flow, sniff, mcp, hub).
class OmniCommandRunner extends CommandRunner<int> {
  OmniCommandRunner({StringSink? out})
    : _out = out ?? stdout,
      super('omni', 'OmniFlow local-first automation engine.') {
    argParser.addFlag(
      'version',
      negatable: false,
      help: 'Print the engine version.',
    );
  }

  final StringSink _out;

  @override
  Future<int> run(Iterable<String> args) async {
    final results = parse(args);
    if (results.flag('version')) {
      _out.writeln('omni $omniflowEngineVersion');
      return 0;
    }
    return await runCommand(results) ?? 0;
  }
}
