import 'package:omniflow_engine/src/devices/adb/adb_commands.dart';
import 'package:omniflow_engine/src/manifest/validation.dart';
import 'package:test/test.dart';

String shellOf(Map<String, Object?> command) =>
    (AdbAction.parse(command) as AdbShell).command;

Matcher refusedAt(String path) => throwsA(
  isA<ValidationException>().having((e) => e.issues.single.path, 'path', path),
);

void main() {
  test('named keys become input keyevent with the Android code', () {
    expect(shellOf({'op': 'key', 'key': 'wakeup'}), 'input keyevent 224');
    expect(shellOf({'op': 'key', 'key': 'sleep'}), 'input keyevent 223');
    expect(shellOf({'op': 'key', 'key': 'power'}), 'input keyevent 26');
    expect(shellOf({'op': 'key', 'key': 'ok'}), 'input keyevent 23');
    expect(shellOf({'op': 'key', 'key': 'center'}), 'input keyevent 23');
    expect(shellOf({'op': 'key', 'key': 'mute'}), 'input keyevent 164');
    expect(shellOf({'op': 'key', 'key': 'play_pause'}), 'input keyevent 85');
    expect(shellOf({'op': 'key', 'keycode': 66}), 'input keyevent 66');
  });

  test('launch and open_url quote their value', () {
    expect(
      shellOf({'op': 'launch', 'package': 'com.netflix.ninja'}),
      TvShell.launch('com.netflix.ninja'),
    );
    expect(
      TvShell.launch('com.netflix.ninja'),
      allOf(
        contains(
          "-c android.intent.category.LEANBACK_LAUNCHER 'com.netflix.ninja'",
        ),
        contains('am start -n "\$c"'),
        contains(
          "monkey -p 'com.netflix.ninja' -c android.intent.category.LAUNCHER 1",
        ),
      ),
    );
    expect(
      shellOf({
        'op': 'open_url',
        'url': r'https://www.youtube.com/watch?v=abc&t=1;x=$HOME',
      }),
      "am start -a android.intent.action.VIEW -d "
      r"'https://www.youtube.com/watch?v=abc&t=1;x=$HOME'",
    );
  });

  test('shellQuote keeps a quote inside the word', () {
    expect(shellQuote("it's"), r"'it'\''s'");
    expect(shellQuote(r'$(reboot)'), r"'$(reboot)'");
  });

  group('refuses', () {
    test('a package that could break out of the argument', () {
      for (final bad in [
        'com.example;reboot',
        "com.example' ; reboot ; '",
        r'com.example$(reboot)',
        'com.example reboot',
        'com.example\nreboot',
        'example',
        '.com.example',
        'com..example',
        '1com.example',
        '-p.com',
      ]) {
        expect(
          () => AdbAction.parse({'op': 'launch', 'package': bad}),
          refusedAt(r'$.package'),
          reason: bad,
        );
      }
    });

    test('a link that is not plain http or https', () {
      for (final bad in [
        "https://example.com/'; reboot; '",
        'https://example.com/a b',
        'https://example.com/`reboot`',
        'https://example.com/"x"',
        r'https://example.com/\x',
        'javascript:alert(1)',
        'file:///sdcard/x',
        'intent://x#Intent;end',
        '-d https://example.com',
        'https://',
        'https://example.com/${'a' * 2001}',
      ]) {
        expect(
          () => AdbAction.parse({'op': 'open_url', 'url': bad}),
          refusedAt(r'$.url'),
          reason: bad,
        );
      }
    });

    test('an unknown op, key, keycode or extra field', () {
      expect(() => AdbAction.parse({'op': 'shell'}), refusedAt(r'$.op'));
      expect(() => AdbAction.parse('reboot'), refusedAt(r'$'));
      expect(
        () => AdbAction.parse({'op': 'key', 'key': 'reboot'}),
        refusedAt(r'$.key'),
      );
      expect(
        () => AdbAction.parse({'op': 'key', 'keycode': '26; reboot'}),
        refusedAt(r'$.keycode'),
      );
      expect(
        () => AdbAction.parse({'op': 'key', 'keycode': 100000}),
        refusedAt(r'$.keycode'),
      );
      expect(
        () => AdbAction.parse({'op': 'key', 'key': 'up', 'keycode': 19}),
        refusedAt(r'$'),
      );
      expect(
        () => AdbAction.parse({
          'op': 'launch',
          'package': 'com.example.app',
          'shell': 'reboot',
        }),
        refusedAt(r'$.shell'),
      );
    });
  });

  test('a launch fails when monkey finds no activity', () {
    final launch = AdbAction.parse({
      'op': 'launch',
      'package': 'com.missing.app',
    }) as AdbShell;
    expect(
      launch.failureIn('** No activities found to run, monkey aborted.'),
      contains('com.missing.app'),
    );
    expect(launch.failureIn('Events injected: 1'), isNull);
  });
}
