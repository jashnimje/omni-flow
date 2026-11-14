// Builds OmniFlow's pointer helper for Android TV (tv_helper/ at the repo
// root) and puts its APK where the app bundles it, in assets/tv_helper/.
// It is a build output, so git ignores it: run this before
// `flutter build apk`, as with tool/firmware_assets.dart.
//
//   dart run tool/tv_helper_asset.dart
//
// The Android SDK comes from ANDROID_HOME (or ~/Library/Android/sdk), and
// Gradle runs on the JDK in JAVA_HOME.
import 'dart:io';

const _apk = 'build/outputs/apk/release/omniflow-tv-helper-release.apk';
const _asset = 'omniflow-tv-helper.apk';

Future<void> main(List<String> args) async {
  final app = File(Platform.script.toFilePath()).parent.parent;
  final helper = Directory('${app.path}/../../tv_helper');
  if (!helper.existsSync()) {
    stderr.writeln('no tv_helper project at ${helper.path}');
    exit(1);
  }
  final home = Platform.environment['HOME'] ?? '';
  final sdk =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'] ??
      '$home/Library/Android/sdk';
  final gradlew = Platform.isWindows ? 'gradlew.bat' : './gradlew';
  stdout.writeln('== building the TV pointer helper');
  final r = await Process.run(
    gradlew,
    ['assembleRelease', '-q', ...args],
    workingDirectory: helper.path,
    environment: {'ANDROID_HOME': sdk},
    runInShell: Platform.isWindows,
  );
  if (r.exitCode != 0) {
    stderr.writeln(r.stdout);
    stderr.writeln(r.stderr);
    exit(1);
  }
  final built = File('${helper.path}/$_apk');
  final out = Directory('${app.path}/assets/tv_helper')
    ..createSync(recursive: true);
  final copy = built.copySync('${out.path}/$_asset');
  stdout.writeln('${copy.path} (${copy.lengthSync()} bytes)');
}
