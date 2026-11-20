import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show omniflowBuild;
import 'package:path_provider/path_provider.dart';

import '../service/app_update.dart';
import '../ui/settings/whats_new.dart' show appVersion;

/// Where the update check stands, as the Settings row shows it.
sealed class UpdateStatus {
  const UpdateStatus();

  /// The release this state is about, when there is one.
  ReleaseInfo? get release => null;
}

/// Not checked since the app started.
class UpdateIdle extends UpdateStatus {
  const UpdateIdle();
}

class UpdateChecking extends UpdateStatus {
  const UpdateChecking();
}

/// Nothing newer. [noRelease] when the repository has no release at all.
class UpdateUpToDate extends UpdateStatus {
  const UpdateUpToDate(this.app, {this.noRelease = false});

  final InstalledApp app;
  final bool noRelease;
}

class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable(this.release);

  @override
  final ReleaseInfo release;
}

/// Downloading and checking the APK. [progress] is null until the size is
/// known.
class UpdateDownloading extends UpdateStatus {
  const UpdateDownloading(this.release, [this.progress]);

  @override
  final ReleaseInfo release;
  final double? progress;
}

/// "Install unknown apps" is off for OmniFlow.
class UpdateNeedsPermission extends UpdateStatus {
  const UpdateNeedsPermission(this.release);

  @override
  final ReleaseInfo release;
}

/// Handed to Android's installer, which asks the person to confirm.
class UpdateInstalling extends UpdateStatus {
  const UpdateInstalling(this.release);

  @override
  final ReleaseInfo release;
}

class UpdateFailed extends UpdateStatus {
  const UpdateFailed(this.message, [this.release]);

  final String message;

  @override
  final ReleaseInfo? release;
}

/// The "Check for updates automatically" switch and when the last check
/// ran. On this phone only.
@immutable
class UpdatePrefs {
  const UpdatePrefs({this.auto = true, this.lastCheck});

  factory UpdatePrefs.fromJson(Map<String, Object?> json) => UpdatePrefs(
    auto: json['auto'] != false,
    lastCheck: json['lastCheck'] is String
        ? DateTime.tryParse(json['lastCheck']! as String)
        : null,
  );

  final bool auto;
  final DateTime? lastCheck;

  Map<String, Object?> toJson() => {
    'auto': auto,
    if (lastCheck != null) 'lastCheck': lastCheck!.toIso8601String(),
  };
}

abstract interface class UpdatePrefsStore {
  Future<UpdatePrefs> read();
  Future<void> write(UpdatePrefs prefs);
}

/// A small JSON file next to the app's own data.
class FileUpdatePrefsStore implements UpdatePrefsStore {
  const FileUpdatePrefsStore();

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/updates.json');

  @override
  Future<UpdatePrefs> read() async {
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      return json is Map
          ? UpdatePrefs.fromJson(Map<String, Object?>.from(json))
          : const UpdatePrefs();
    } on Object {
      return const UpdatePrefs();
    }
  }

  @override
  Future<void> write(UpdatePrefs prefs) async {
    try {
      await (await _file()).writeAsString(jsonEncode(prefs.toJson()));
    } on Object {
      return;
    }
  }
}

class MemoryUpdatePrefsStore implements UpdatePrefsStore {
  MemoryUpdatePrefsStore([this.saved = const UpdatePrefs()]);

  UpdatePrefs saved;

  @override
  Future<UpdatePrefs> read() async => saved;

  @override
  Future<void> write(UpdatePrefs prefs) async => saved = prefs;
}

/// Everything the update check reaches outside the app. Tests pass fakes,
/// so they never touch the network.
class UpdateEnv {
  UpdateEnv({
    required this.selfInstall,
    this.fetch = fetchLatestRelease,
    this.open = githubDownload,
    this.installer = const ChannelAppInstaller(),
    UpdatePrefsStore? prefs,
    Future<Directory> Function()? cacheDir,
    DateTime Function()? now,
  }) : prefs = prefs ?? const FileUpdatePrefsStore(),
       cacheDir = cacheDir ?? getTemporaryDirectory,
       now = now ?? DateTime.now;

  /// Android installs updates itself. Elsewhere the check is a link to
  /// the release page.
  final bool selfInstall;
  final FetchLatestRelease fetch;
  final OpenDownload open;
  final AppInstaller installer;
  final UpdatePrefsStore prefs;
  final Future<Directory> Function() cacheDir;
  final DateTime Function() now;
}

final updateEnvProvider = Provider<UpdateEnv>(
  (ref) => UpdateEnv(selfInstall: Platform.isAndroid),
);

/// The quiet check runs at most once a day.
const autoCheckEvery = Duration(days: 1);

class AppUpdateNotifier extends Notifier<UpdateStatus> {
  @override
  UpdateStatus build() => const UpdateIdle();

  UpdateEnv get _env => ref.read(updateEnvProvider);

  /// The running app's version and build.
  Future<InstalledApp> installedApp() async {
    var build = omniflowBuild;
    if (build <= 0 && _env.selfInstall) {
      try {
        build = buildFromVersionCode(
          (await _env.installer.installed()).versionCode,
        );
      } on Object {
        build = 0;
      }
    }
    return InstalledApp(version: appVersion, build: build);
  }

  /// Asks GitHub for the newest release. A [quiet] check (the daily one)
  /// changes the row only when an update is out, and never shows an
  /// error.
  Future<void> check({bool quiet = false}) async {
    if (state
        case UpdateChecking() || UpdateDownloading() || UpdateInstalling()) {
      return;
    }
    final before = state;
    if (!quiet) state = const UpdateChecking();
    try {
      final json = await _env.fetch();
      final prefs = await _env.prefs.read();
      await _env.prefs.write(
        UpdatePrefs(auto: prefs.auto, lastCheck: _env.now()),
      );
      final app = await installedApp();
      if (json == null) {
        if (!quiet) state = UpdateUpToDate(app, noRelease: true);
        return;
      }
      final release = ReleaseInfo.fromGitHub(json);
      if (release.isNewerThan(app)) {
        state = UpdateAvailable(release);
      } else if (!quiet) {
        state = UpdateUpToDate(app);
      }
    } on UpdateFailure catch (e) {
      state = quiet ? before : UpdateFailed(e.message);
    } on Object {
      state = quiet
          ? before
          : const UpdateFailed('The check failed. Try again later');
    }
  }

  /// The daily check, when the switch is on and a day has passed.
  Future<void> maybeAutoCheck() async {
    if (!_env.selfInstall) return;
    final prefs = await _env.prefs.read();
    if (!prefs.auto) return;
    final last = prefs.lastCheck;
    if (last != null && _env.now().difference(last) < autoCheckEvery) return;
    await check(quiet: true);
  }

  /// Downloads the update, checks it and hands it to Android.
  Future<void> update() async {
    final release = state.release;
    if (release == null || !_env.selfInstall) return;
    if (state is UpdateDownloading || state is UpdateInstalling) return;
    final installer = _env.installer;
    try {
      final abis = (await installer.installed()).abis;
      if (abis.isNotEmpty && !abis.contains('arm64-v8a')) {
        state = UpdateFailed(
          'This phone needs the ${abis.first} build, which is in the '
          'android-extras download on the release page',
          release,
        );
        return;
      }
      if (!await installer.canInstall()) {
        state = UpdateNeedsPermission(release);
        return;
      }
      state = UpdateDownloading(release);
      final dir = Directory('${(await _env.cacheDir()).path}/updates');
      final apk = await downloadVerifiedApk(
        release,
        File('${dir.path}/omniflow-update.apk'),
        open: _env.open,
        onProgress: (p) => state = UpdateDownloading(release, p.clamp(0, 1)),
      );
      state = UpdateInstalling(release);
      final result = await installer.install(apk);
      state = result == InstallResult.started
          ? UpdateInstalling(release)
          : UpdateFailed(installWords(result), release);
    } on UpdateFailure catch (e) {
      state = UpdateFailed(e.message, release);
    } on Object {
      state = UpdateFailed('The update failed. Try again later', release);
    }
  }

  /// Opens OmniFlow's "Install unknown apps" switch.
  Future<void> allowInstalls() => _env.installer.openInstallSettings();

  /// Back from the system settings: carry on when the switch is now on.
  Future<void> recheckPermission() async {
    final status = state;
    if (status is! UpdateNeedsPermission) return;
    if (await _env.installer.canInstall()) {
      state = UpdateAvailable(status.release);
    }
  }
}

final appUpdateProvider = NotifierProvider<AppUpdateNotifier, UpdateStatus>(
  AppUpdateNotifier.new,
);

/// The "Check for updates automatically" switch.
class UpdateAutoNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async =>
      (await ref.watch(updateEnvProvider).prefs.read()).auto;

  Future<void> set(bool on) async {
    state = AsyncData(on);
    final store = ref.read(updateEnvProvider).prefs;
    final prefs = await store.read();
    await store.write(UpdatePrefs(auto: on, lastCheck: prefs.lastCheck));
  }
}

final updateAutoProvider = AsyncNotifierProvider<UpdateAutoNotifier, bool>(
  UpdateAutoNotifier.new,
);
