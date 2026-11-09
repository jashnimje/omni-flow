import '../../manifest/validation.dart';

/// Android key codes the `key` op accepts by name.
const adbKeyCodes = <String, int>{
  'up': 19,
  'down': 20,
  'left': 21,
  'right': 22,
  'ok': 23,
  'center': 23,
  'back': 4,
  'home': 3,
  'menu': 82,
  'volume_up': 24,
  'volume_down': 25,
  'mute': 164,
  'play_pause': 85,
  'power': 26,
  'sleep': 223,
  'wakeup': 224,
};

final adbPackagePattern = RegExp(
  r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$',
);

/// http and https only, and only RFC 3986 unreserved, reserved and percent
/// characters. No quotes, backslashes, spaces or backticks.
final adbUrlPattern = RegExp(
  r"^https?://[A-Za-z0-9\-._~:/?#\[\]@!$&()*+,;=%]+$",
);

const _maxPackageLength = 255;
const _maxUrlLength = 2000;
const _maxKeyCode = 999;

/// Quotes [value] as one POSIX shell word: nothing inside can end the word.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// One validated thing to do on an ADB device.
///
/// A manifest command renders to a small object naming an `op`. The shell
/// line is built here from fixed words plus quoted, validated values, so no
/// manifest or param can put free text on the device shell.
sealed class AdbAction {
  const AdbAction();

  /// Reads a rendered command. Throws [ValidationException] when it is not
  /// one of the ops, or a value fails its check.
  static AdbAction parse(Object? rendered) {
    if (rendered is! Map) throw _invalid(r'$', 'must be an object with an op');
    final command = Map<String, Object?>.from(rendered);
    final op = command['op'];
    final (allowed, action) = switch (op) {
      'key' => (const {'key', 'keycode'}, _key(command)),
      'launch' => (const {'package'}, _launch(command)),
      'open_url' => (const {'url'}, _openUrl(command)),
      'wake_on_lan' => (const <String>{}, const AdbWakeOnLan()),
      _ => throw _invalid(
        r'$.op',
        'must be one of key, launch, open_url, wake_on_lan',
      ),
    };
    final extra = command.keys.where((k) => k != 'op' && !allowed.contains(k));
    if (extra.isNotEmpty) {
      throw _invalid('\$.${extra.first}', 'is not a field of the $op op');
    }
    return action;
  }

  static AdbShell _key(Map<String, Object?> command) {
    final name = command['key'];
    final code = command['keycode'];
    final int keycode;
    if (name != null && code == null) {
      final known = name is String ? adbKeyCodes[name] : null;
      if (known == null) {
        throw _invalid(
          r'$.key',
          'must be one of ${adbKeyCodes.keys.join(', ')}',
        );
      }
      keycode = known;
    } else if (code != null && name == null) {
      if (code is! int || code < 0 || code > _maxKeyCode) {
        throw _invalid(r'$.keycode', 'must be a whole number 0-$_maxKeyCode');
      }
      keycode = code;
    } else {
      throw _invalid(r'$', 'the key op takes one of key or keycode');
    }
    return AdbShell('input keyevent $keycode');
  }

  static AdbShell _launch(Map<String, Object?> command) {
    final package = command['package'];
    if (package is! String ||
        package.length > _maxPackageLength ||
        !adbPackagePattern.hasMatch(package)) {
      throw _invalid(
        r'$.package',
        'must be an Android package name such as com.example.app',
      );
    }
    return AdbShell(
      'monkey -p ${shellQuote(package)} -c android.intent.category.LAUNCHER 1',
      failsOn: RegExp(r'No activities found|monkey aborted'),
      failure: 'no launchable app $package on the device',
    );
  }

  static AdbShell _openUrl(Map<String, Object?> command) {
    final url = command['url'];
    if (url is! String ||
        url.length > _maxUrlLength ||
        !adbUrlPattern.hasMatch(url)) {
      throw _invalid(
        r'$.url',
        'must be an http or https URL without spaces or quotes',
      );
    }
    return AdbShell(
      'am start -a android.intent.action.VIEW -d ${shellQuote(url)}',
      failsOn: RegExp(r'^Error', multiLine: true),
      failure: 'the device could not open the link',
    );
  }

  static ValidationException _invalid(String path, String message) =>
      ValidationException('adb command', [ValidationIssue(path, message)]);
}

/// A shell line to run, and how to tell from its output that it failed.
final class AdbShell extends AdbAction {
  const AdbShell(this.command, {this.failsOn, this.failure});

  final String command;
  final RegExp? failsOn;
  final String? failure;

  /// Why [output] means the command failed, or null when it did not.
  String? failureIn(String output) =>
      failsOn != null && failsOn!.hasMatch(output) ? failure : null;
}

/// Wake-on-LAN to the device's `mac` setting. Nothing goes over ADB.
final class AdbWakeOnLan extends AdbAction {
  const AdbWakeOnLan();
}
