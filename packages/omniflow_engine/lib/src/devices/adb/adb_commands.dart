import '../../manifest/param_spec.dart';
import '../../manifest/validation.dart';
import 'tv_keys.dart';

/// Android key codes the `key` op accepts by name.
Map<String, int> get adbKeyCodes => tvKeyCodes;

final adbPackagePattern = RegExp(
  r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$',
);

/// http and https only, and only RFC 3986 unreserved, reserved and percent
/// characters. No quotes, backslashes, spaces or backticks.
final adbUrlPattern = RegExp(
  r"^https?://[A-Za-z0-9\-._~:/?#\[\]@!$&()*+,;=%]+$",
);

/// A settings key as the settings provider names them, dotted and coloned
/// ones included (`dropbox:data_app_anr`, `com.tcl.initSetup.BASICMODEL`).
final adbSettingKeyPattern = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.:\-]{0,199}$');

const adbSettingNamespaces = ['system', 'secure', 'global'];

/// Settings that cut this engine off from the TV when changed. They are
/// changed on the TV itself.
const adbProtectedSettings = {
  'global/adb_enabled',
  'global/adb_wifi_enabled',
  'global/development_settings_enabled',
  'global/wifi_on',
  'global/airplane_mode_on',
};

const adbMaxTextLength = 500;
const adbMaxSettingValueLength = 4096;
const adbMaxRepeat = 20;
const _maxPackageLength = 255;
const _maxUrlLength = 2000;
const _maxKeyCode = 999;
const _maxVolume = 1000;

/// What the `app` op does to a package. `open` and `stop` are their own
/// ops, so every action here changes or removes the app.
const adbAppActions = [
  'clear_cache',
  'clear_data',
  'disable',
  'enable',
  'uninstall',
];

/// The ops that change the TV beyond what a remote does: a raw setting, or
/// an app's data, state or presence. A flow with one of these waits for
/// the user to approve it.
const adbHighRiskOps = {'setting', 'app'};

/// Whether a manifest [command] for an ADB device is high risk. An op the
/// manifest leaves to a template is, since it could render to any op.
bool adbCommandIsHighRisk(Object? command) {
  if (command is! Map) return false;
  final op = command['op'];
  return op is! String || op.contains('{{') || adbHighRiskOps.contains(op);
}

/// The keys an agent may press on another person's phone: power, volume
/// and media. Every other key types, or moves around their screen.
const adbPhoneAgentKeys = {
  'power',
  'sleep',
  'wakeup',
  'volume_up',
  'volume_down',
  'mute',
  'play_pause',
  'play',
  'pause',
  'stop',
  'next',
  'previous',
  'rewind',
  'fast_forward',
};

/// Keys that type into what is on screen, or open the notification shade.
const adbTypingKeys = {
  'enter',
  'delete',
  'tab',
  'escape',
  'search',
  'notification',
  'star',
  'pound',
  '0',
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
};

/// Whether [capability] of an ADB device needs the user's approval in an
/// automation an agent saved. [onPhone] is true for another person's phone.
///
/// On any ADB device: a raw setting or an app's data ([adbCommandIsHighRisk]),
/// typed text, and a key that types or opens the shade (a key left to a
/// param that is not a list of such keys counts too). On a phone, opening
/// an app or a link acts on the person holding it, so those count as well.
bool adbCapabilityIsHighRisk(
  Object? command,
  Map<String, ParamSpec> params, {
  required bool onPhone,
}) {
  if (adbCommandIsHighRisk(command)) return true;
  if (command is! Map) return false;
  final op = command['op'];
  if (op == 'text') return true;
  if (onPhone && (op == 'launch' || op == 'open_url')) return true;
  if (op != 'key') return false;
  final key = command['key'];
  bool risky(String name) =>
      adbTypingKeys.contains(name) ||
      (onPhone && !adbPhoneAgentKeys.contains(name));
  if (key is! String) return true;
  final placeholder = RegExp(r'^\{\{\s*([A-Za-z_][A-Za-z0-9_]*)')
      .firstMatch(key);
  if (placeholder == null) return key.contains('{{') || risky(key);
  final spec = params[placeholder.group(1)];
  if (spec == null || spec.values.isEmpty) return true;
  return spec.values.any(risky);
}

/// Quotes [value] as one POSIX shell word: nothing inside can end the word.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// The shell lines TV commands run, each built from fixed words and
/// validated, quoted values.
abstract final class TvShell {
  /// `input keyevent` for [keycode], [repeat] times in one call.
  static String key(int keycode, {bool longPress = false, int repeat = 1}) => [
    'input keyevent',
    if (longPress) '--longpress',
    for (var i = 0; i < repeat; i++) '$keycode',
  ].join(' ');

  /// `input text` reads `%s` as a space, and a space would end the word.
  static String text(String text) =>
      'input text ${shellQuote(text.replaceAll(' ', '%s'))}';

  static String volumeGet() => 'cmd media_session volume --stream 3 --get';

  static String volumeSet(int level) =>
      'cmd media_session volume --stream 3 --set $level';

  /// Opens the app's TV launcher activity, or its phone launcher activity
  /// when it has no TV one. A TV-only app has no LAUNCHER category, which
  /// is what `monkey` alone would look for.
  static String launch(String package) {
    final p = shellQuote(package);
    return 'c=\$(cmd package resolve-activity --brief -a '
        'android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER '
        '$p | tail -n 1); case "\$c" in */*) am start -n "\$c";; '
        '*) monkey -p $p -c android.intent.category.LAUNCHER 1;; esac';
  }

  static String forceStop(String package) =>
      'am force-stop ${shellQuote(package)}';

  static String settingGet(String namespace, String key) =>
      'settings get $namespace ${shellQuote(key)}';

  static String settingPut(String namespace, String key, String value) =>
      'settings put $namespace ${shellQuote(key)} ${shellQuote(value)}';

  static String settingDelete(String namespace, String key) =>
      'settings delete $namespace ${shellQuote(key)}';

  /// A system app is removed for the current user only, so
  /// `cmd package install-existing` can bring it back.
  static String app(String package, String action, {bool system = false}) {
    final p = shellQuote(package);
    return switch (action) {
      'clear_cache' => 'pm clear --cache-only $p',
      'clear_data' => 'pm clear $p',
      'disable' => 'pm disable-user --user 0 $p',
      'enable' => 'pm enable --user 0 $p',
      'uninstall' => system ? 'pm uninstall --user 0 $p' : 'pm uninstall $p',
      _ => throw ArgumentError.value(action, 'action'),
    };
  }

  /// Output that means a `pm` or `am` command failed.
  static final failure = RegExp(
    r'^(Error|Failure|Failed|Exception)|java\.lang\.|Unknown package|'
    r'No activities found|monkey aborted|Security exception',
    multiLine: true,
  );
}

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
      'key' => (const {'key', 'keycode', 'longPress', 'repeat'}, _key(command)),
      'text' => (const {'text'}, _text(command)),
      'volume' => (const {'level'}, _volume(command)),
      'launch' => (const {'package'}, _launch(command)),
      'stop' => (const {'package'}, _stop(command)),
      'open_url' => (const {'url'}, _openUrl(command)),
      'setting' => (const {'namespace', 'key', 'value'}, _setting(command)),
      'app' => (const {'package', 'action'}, _app(command)),
      'wake_on_lan' => (const <String>{}, const AdbWakeOnLan()),
      _ => throw _invalid(
        r'$.op',
        'must be one of key, text, volume, launch, stop, open_url, setting, '
            'app, wake_on_lan',
      ),
    };
    final extra = command.keys.where((k) => k != 'op' && !allowed.contains(k));
    if (extra.isNotEmpty) {
      throw _invalid('\$.${extra.first}', 'is not a field of the $op op');
    }
    return action;
  }

  /// The key code for a catalog name, or a code given as a number.
  static int keycodeOf(Object? name, Object? code, {String path = r'$'}) {
    if (name != null && code == null) {
      final known = name is String ? adbKeyCodes[name] : null;
      if (known != null) return known;
      throw _invalid(
        '$path.key',
        'must be a key from tv.keys, such as ok, home or volume_up',
      );
    }
    if (code != null && name == null) {
      final number = code is String ? int.tryParse(code) : code;
      if (number is! int || number < 0 || number > _maxKeyCode) {
        throw _invalid(
          '$path.keycode',
          'must be a whole number 0-$_maxKeyCode',
        );
      }
      return number;
    }
    throw _invalid(path, 'the key op takes one of key or keycode');
  }

  static int repeatOf(Object? repeat, {String path = r'$.repeat'}) {
    if (repeat == null) return 1;
    final n = repeat is String ? int.tryParse(repeat) : repeat;
    if (n is! int || n < 1 || n > adbMaxRepeat) {
      throw _invalid(path, 'must be a whole number 1-$adbMaxRepeat');
    }
    return n;
  }

  static bool flagOf(Object? value, String path) => switch (value) {
    null || false || 'false' => false,
    true || 'true' => true,
    _ => throw _invalid(path, 'must be true or false'),
  };

  static AdbShell _key(Map<String, Object?> command) => AdbShell(
    TvShell.key(
      keycodeOf(command['key'], command['keycode']),
      longPress: flagOf(command['longPress'], r'$.longPress'),
      repeat: repeatOf(command['repeat']),
    ),
  );

  /// Printable ASCII only: `input text` has no key for anything else.
  static String textOf(Object? text, {String path = r'$.text'}) {
    if (text is! String ||
        text.isEmpty ||
        text.length > adbMaxTextLength ||
        text.codeUnits.any((c) => c < 0x20 || c > 0x7e)) {
      throw _invalid(
        path,
        'must be 1-$adbMaxTextLength printable ASCII characters',
      );
    }
    return text;
  }

  static AdbShell _text(Map<String, Object?> command) =>
      AdbShell(TvShell.text(textOf(command['text'])));

  static int levelOf(Object? level, {int max = _maxVolume}) {
    final n = level is String
        ? (int.tryParse(level) ?? double.tryParse(level))
        : level;
    if (n is! num || n.isNaN || n < 0 || n > max) {
      throw _invalid(r'$.level', 'must be a number 0-$max');
    }
    return n.round();
  }

  static AdbShell _volume(Map<String, Object?> command) => AdbShell(
    TvShell.volumeSet(levelOf(command['level'])),
    failsOn: RegExp(r'^Error|Exception', multiLine: true),
    failure: 'the TV did not take the volume',
  );

  static String packageOf(Object? package, {String path = r'$.package'}) {
    if (package is! String ||
        package.length > _maxPackageLength ||
        !adbPackagePattern.hasMatch(package)) {
      throw _invalid(
        path,
        'must be an Android package name such as com.example.app',
      );
    }
    return package;
  }

  static AdbShell _launch(Map<String, Object?> command) {
    final package = packageOf(command['package']);
    return AdbShell(
      TvShell.launch(package),
      failsOn: RegExp(
        r'No activities found|monkey aborted|^Error',
        multiLine: true,
      ),
      failure: 'no launchable app $package on the device',
    );
  }

  static AdbShell _stop(Map<String, Object?> command) =>
      AdbShell(TvShell.forceStop(packageOf(command['package'])));

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

  static String namespaceOf(Object? namespace, {String path = r'$.namespace'}) {
    if (namespace is String && adbSettingNamespaces.contains(namespace)) {
      return namespace;
    }
    throw _invalid(path, 'must be system, secure or global');
  }

  static String settingKeyOf(Object? key, {String path = r'$.key'}) {
    if (key is String && adbSettingKeyPattern.hasMatch(key)) return key;
    throw _invalid(path, 'must be a settings key such as screen_off_timeout');
  }

  /// A settings value: any text without NUL or line breaks.
  static String settingValueOf(Object? value, {String path = r'$.value'}) {
    final text = switch (value) {
      String s => s,
      bool b => b ? '1' : '0',
      num n => '$n',
      _ => throw _invalid(path, 'must be text, a number or true or false'),
    };
    if (text.length > adbMaxSettingValueLength ||
        text.contains(RegExp('[\x00\r\n]'))) {
      throw _invalid(
        path,
        'must be at most $adbMaxSettingValueLength characters on one line',
      );
    }
    return text;
  }

  static AdbShell _setting(Map<String, Object?> command) {
    final namespace = namespaceOf(command['namespace']);
    final key = settingKeyOf(command['key']);
    if (adbProtectedSettings.contains('$namespace/$key')) {
      throw _invalid(
        r'$.key',
        '$namespace $key would cut this engine off from the TV, so it is '
            'changed on the TV',
      );
    }
    return AdbShell(
      TvShell.settingPut(namespace, key, settingValueOf(command['value'])),
      failsOn: RegExp(r'^(Error|Exception|java\.)', multiLine: true),
      failure: 'the TV refused the setting',
    );
  }

  static AdbShell _app(Map<String, Object?> command) {
    final package = packageOf(command['package']);
    final action = command['action'];
    if (action is! String || !adbAppActions.contains(action)) {
      throw _invalid(r'$.action', 'must be one of ${adbAppActions.join(', ')}');
    }
    return AdbShell(
      TvShell.app(package, action),
      failsOn: TvShell.failure,
      failure: 'the TV could not $action $package',
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
