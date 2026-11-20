import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import 'omni_command_runner.dart';
import 'one_shot.dart';

/// `omni wiz`: WiZ helpers.
class WizCommand extends Command<int> {
  WizCommand() {
    addSubcommand(_WizImport());
  }

  @override
  final name = 'wiz';

  @override
  final description = 'Philips WiZ lights.';
}

/// `omni wiz import FILE|URL`: adds every light of a WiZ home export.
class _WizImport extends Command<int> {
  _WizImport() {
    argParser.addOption(
      'window-ms',
      defaultsTo: '3000',
      help: 'How long to listen for the bulbs on the Wi-Fi.',
    );
  }

  @override
  final name = 'import';

  @override
  final description =
      'Add the lights of your WiZ home, with their names, rooms and home '
      'key. In the WiZ app: Settings, your home, Integrations, Local '
      'integrations, Export. Pass the link it gives (valid for about 15 '
      'minutes) or the saved file.';

  @override
  String get invocation => 'omni wiz import FILE|URL';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) {
      throw UsageException('needs one FILE or URL', invocation);
    }
    final source = rest.single;
    final windowMs = int.tryParse(argResults!.option('window-ms')!);
    if (windowMs == null) throw UsageException('--window-ms is a number', '');
    final Map<String, Object?> args;
    if (source.contains('://')) {
      args = {'url': source};
    } else {
      final file = File(source);
      if (!await file.exists()) {
        throw UsageException('no file $source', invocation);
      }
      args = {'text': await file.readAsString()};
    }
    final omni = runner! as OmniCommandRunner;
    final engine = await omni.connect();
    try {
      final result = await engine.handle('wiz.import', {
        ...args,
        'windowMs': windowMs,
      });
      omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
      return result['ok'] == true ? 0 : 1;
    } finally {
      await closeOneShot(engine);
    }
  }
}
