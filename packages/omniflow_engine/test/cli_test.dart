import 'package:args/command_runner.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

void main() {
  test('--version prints the engine version and exits 0', () async {
    final out = StringBuffer();
    final code = await OmniCommandRunner(out: out).run(['--version']);
    expect(code, 0);
    expect(out.toString().trim(), 'omni $omniflowEngineVersion');
  });

  test('an unknown command is a usage error', () {
    expect(
      () => OmniCommandRunner(out: StringBuffer()).run(['nope']),
      throwsA(isA<UsageException>()),
    );
  });
}
