@TestOn('mac-os || linux')
library;

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// Prints each argument it receives inside brackets, one per line.
const printArgs = ['/usr/bin/printf', r'[%s]\n'];

void main() {
  const local = LocalExecutor();
  const hostile = r'; rm -rf ~ && echo pwned $(id) `id` "q" \n';

  test('a hostile param reaches the command as one literal argument', () async {
    final argv = renderArgv([
      ...printArgs,
      'volume {{value}}',
    ], const TemplateContext(params: {'value': hostile}));
    final result = await local.run(argv);
    expect(result.succeeded, isTrue);
    expect(result.stdout, '[volume $hostile]');
  });

  test('stdin is passed as data', () async {
    final result = await local.run([
      '/bin/cat',
    ], stdin: 'shortcut input; not a command');
    expect(result.stdout, 'shortcut input; not a command');
  });

  test('a non-zero exit is reported, not thrown', () async {
    final result = await local.run(['/bin/sh', '-c', 'echo oops >&2; exit 3']);
    expect(result.exitCode, 3);
    expect(result.stderr, 'oops');
    expect(result.succeeded, isFalse);
  });

  test('a command past its timeout is killed', () async {
    await expectLater(
      local.run([
        '/bin/sleep',
        '5',
      ], timeout: const Duration(milliseconds: 200)),
      throwsA(isA<CommandTimeoutException>()),
    );
  });

  test('a child left holding stdout does not outlast the timeout', () async {
    final watch = Stopwatch()..start();
    final result = await local.run([
      '/bin/sh',
      '-c',
      'sleep 5 & echo hi',
    ], timeout: const Duration(seconds: 1));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(result.exitCode, 0);
    expect(result.stdout, 'hi');
  });

  test('a backslash is refused for SSH and passed through locally', () async {
    const argv = ['/usr/bin/printf', '%s', r"\';touch /tmp/pwn;echo \"];
    expect(() => checkSshArgv(argv), throwsArgumentError);
    final ssh = SshExecutor(
      host: '127.0.0.1',
      port: 9,
      username: 'nobody',
      privateKeySecret: 'ssh/none',
      secrets: InMemorySecretStore(),
    );
    await expectLater(ssh.run(argv), throwsArgumentError);
    final result = await local.run(argv);
    expect(result.stdout, r"\';touch /tmp/pwn;echo \");
  });

  test('renderArgv rejects a template that is not a list of strings', () {
    expect(
      () => renderArgv('osascript -e x', const TemplateContext()),
      throwsArgumentError,
    );
    expect(() => renderArgv([], const TemplateContext()), throwsArgumentError);
    expect(
      () => renderArgv(['ok', 3], const TemplateContext()),
      throwsArgumentError,
    );
  });

  group('posixShellJoin', () {
    test('leaves safe words bare and quotes the rest', () {
      expect(
        posixShellJoin(['osascript', '-e', 'set volume output volume 45']),
        "osascript -e 'set volume output volume 45'",
      );
      expect(posixShellJoin(['echo', "it's"]), r"echo 'it'\''s'");
      expect(posixShellJoin(['echo', '']), "echo ''");
    });

    test(
      'a POSIX shell parses the joined line back into the same arguments',
      () async {
        final args = [hostile, "it's", '', 'two words', r'$HOME', '*'];
        final line = posixShellJoin([...printArgs, ...args]);
        final result = await local.run(['/bin/sh', '-c', line]);
        expect(result.stdout, args.map((a) => '[$a]').join('\n'));
      },
    );
  });
}
