import 'dart:convert';
import 'dart:io';

import 'local_client.dart';

/// The app's content provider that hands a command to its engine. It
/// answers only adb's shell user, so only a computer the phone already
/// trusts for USB or wireless debugging reaches it, and nothing listens on
/// the network.
const phoneBridgeUri = 'content://com.jashnm.omniflow_app.agent';

/// Runs a process, as [Process.run] does: injected by tests.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// The engine of the OmniFlow app on a phone, reached through adb: each
/// command is one `adb shell content call` to [phoneBridgeUri], carrying
/// the request and the reply as base64 JSON.
class AdbPhoneConnection implements EngineConnection {
  AdbPhoneConnection({String? adb, this.serial, ProcessRunner? run})
    : adb = adb ?? findAdb(),
      _run = run ?? Process.run;

  /// The adb binary, and the phone's serial when more than one is attached.
  final String adb;
  final String? serial;
  final ProcessRunner _run;

  static final _result = RegExp(r'result=([A-Za-z0-9+/=]+)');

  /// adb from `$ADB`, the Android SDK, Homebrew, or the PATH.
  static String findAdb() {
    final env = Platform.environment;
    final home = env['HOME'] ?? '';
    for (final path in [
      ?env['ADB'],
      if (env['ANDROID_HOME'] case final sdk?) '$sdk/platform-tools/adb',
      '$home/Library/Android/sdk/platform-tools/adb',
      '/opt/homebrew/bin/adb',
      '/usr/local/bin/adb',
    ]) {
      if (File(path).existsSync()) return path;
    }
    return 'adb';
  }

  @override
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> args,
  ) async {
    final request = base64.encode(
      utf8.encode(jsonEncode({'command': command, 'args': args})),
    );
    final ProcessResult result;
    try {
      result = await _run(adb, [
        if (serial != null) ...['-s', serial!],
        'shell',
        'content',
        'call',
        '--uri',
        phoneBridgeUri,
        '--method',
        'handle',
        '--arg',
        request,
      ]);
    } on ProcessException catch (e) {
      return _unreachable('cannot run adb ($adb): ${e.message}');
    }
    final out = '${result.stdout}';
    final match = _result.firstMatch(out);
    // A reply in the output wins over the exit code: adb over wireless
    // debugging can exit non-zero after printing the phone's whole answer.
    if (match == null) {
      final said = '${result.stderr}'.trim().isNotEmpty
          ? '${result.stderr}'.trim()
          : out.trim();
      return _unreachable(
        'the phone did not answer through adb: '
        '${said.isEmpty ? 'no output' : said.split('\n').first}. Check that '
        'the phone shows in adb devices and that OmniFlow is installed',
      );
    }
    try {
      final reply = jsonDecode(utf8.decode(base64.decode(match.group(1)!)));
      if (reply is Map) return Map<String, Object?>.from(reply);
    } on FormatException {
      // Falls through to the error below.
    }
    return _unreachable('the phone sent a reply that is not JSON');
  }

  static Map<String, Object?> _unreachable(String message) => {
    'ok': false,
    'error': {'type': 'unreachable', 'message': message},
  };

  /// Events need a stream adb's content call cannot hold open.
  @override
  Future<Stream<Map<String, Object?>>> events({bool packets = false}) =>
      throw LocalSocketException(
        'live events are not available over adb: run the command on the phone',
      );

  @override
  Future<void> close() async {}
}
