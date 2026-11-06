import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

Future<void> main(List<String> args) async {
  try {
    exitCode = await OmniCommandRunner().run(args);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  }
}
