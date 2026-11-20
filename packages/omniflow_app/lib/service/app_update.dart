import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Where OmniFlow's releases are published. The repository is public, so
/// the check needs no sign in.
const updateRepo = 'jashnimje/omni-flow';
final latestReleaseApi = Uri.https(
  'api.github.com',
  '/repos/$updateRepo/releases/latest',
);
final releasesPage = Uri.https('github.com', '/$updateRepo/releases/latest');

/// The Android download every release carries, `omniflow-<v>-android.apk`.
/// Releases before the downloads were sorted named it `-android-arm64.apk`.
final _apkName = RegExp(r'^omniflow-.+-android\.apk$');
final _legacyApkName = RegExp(r'^omniflow-.+-android-arm64\.apk$');
const _sumsName = 'SHA256SUMS';

/// The line the release workflow writes into every release body.
final _releaseLine = RegExp(
  r'omniflow-release:\s*version=([0-9][0-9.]*)\s+build=(\d+)',
);
final _buildInName = RegExp(r'\(build (\d+)\)');
final _versionInTag = RegExp(r'^v?([0-9]+(?:\.[0-9]+)*)');

/// Hosts an update may come from: the release page and the two CDNs
/// GitHub redirects release downloads to.
const updateHosts = {
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
};

/// A release download is only fetched from this repository's releases.
bool isReleaseAssetUrl(Uri url) =>
    url.scheme == 'https' &&
    url.host == 'github.com' &&
    url.path.startsWith('/$updateRepo/releases/download/');

/// A hop of a download (the asset url or a redirect) is followed only
/// over https to [updateHosts].
bool isUpdateHost(Uri url) =>
    url.scheme == 'https' && updateHosts.contains(url.host);

/// The version and build of the app that is running.
class InstalledApp {
  const InstalledApp({required this.version, required this.build});

  final String version;

  /// 0 when it is not known, such as a local build off Android.
  final int build;
}

/// The newest release, as far as the check needs it.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.build,
    required this.page,
    this.apk,
    this.apkName,
    this.apkSize,
    this.sums,
  });

  /// Reads GitHub's latest-release JSON. The version and build come from
  /// the release body's `omniflow-release` line, then from the release
  /// name and the tag.
  factory ReleaseInfo.fromGitHub(Map<String, Object?> json) {
    final body = json['body'] is String ? json['body']! as String : '';
    final name = json['name'] is String ? json['name']! as String : '';
    final tag = json['tag_name'] is String ? json['tag_name']! as String : '';
    final line = _releaseLine.firstMatch(body);
    final version =
        line?.group(1) ?? _versionInTag.firstMatch(tag)?.group(1) ?? '';
    final buildText = line?.group(2) ?? _buildInName.firstMatch(name)?.group(1);
    final page = Uri.tryParse(
      json['html_url'] is String ? json['html_url']! as String : '',
    );

    Map<String, Object?>? asset(bool Function(String) matches) {
      final assets = json['assets'];
      if (assets is! List) return null;
      for (final a in assets) {
        if (a is Map && a['name'] is String && matches(a['name'] as String)) {
          return Map<String, Object?>.from(a);
        }
      }
      return null;
    }

    final apk =
        asset(_apkName.hasMatch) ?? asset(_legacyApkName.hasMatch) ?? const {};
    final sums = asset((n) => n == _sumsName) ?? const {};
    Uri? url(Map<String, Object?> a) => a['browser_download_url'] is String
        ? Uri.tryParse(a['browser_download_url']! as String)
        : null;
    return ReleaseInfo(
      version: version,
      build: buildText == null ? null : int.tryParse(buildText),
      page: page != null && page.scheme == 'https' ? page : releasesPage,
      apk: url(apk),
      apkName: apk['name'] as String?,
      apkSize: apk['size'] is int ? apk['size']! as int : null,
      sums: url(sums),
    );
  }

  final String version;

  /// Null for a release made before builds were numbered.
  final int? build;
  final Uri page;
  final Uri? apk;
  final String? apkName;
  final int? apkSize;
  final Uri? sums;

  /// `1.0.0 (build 45)`.
  String get label => build == null ? version : '$version (build $build)';

  /// Whether this release is newer than [app]: a higher version, or the
  /// same version with a higher build. Without both builds only the
  /// versions count.
  bool isNewerThan(InstalledApp app) {
    final byVersion = compareVersions(version, app.version);
    if (byVersion != 0) return byVersion > 0;
    final build = this.build;
    return build != null && app.build > 0 && build > app.build;
  }
}

/// Compares dotted versions number by number, so 1.10.0 is after 1.9.0.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.split('.')) int.tryParse(p) ?? 0,
  ];
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// The checksums in a `sha256sum` file, by file name.
Map<String, String> parseSha256Sums(String text) => {
  for (final line in const LineSplitter().convert(text))
    if (RegExp(r'^([0-9a-fA-F]{64}) [ *](.+)$').firstMatch(line.trim())
        case final m?)
      m.group(2)!.trim(): m.group(1)!.toLowerCase(),
};

/// Why an update did not go ahead, in words for the person.
class UpdateFailure implements Exception {
  const UpdateFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Opens a download. The real one is [githubDownload]; tests pass bytes.
typedef OpenDownload = Future<Stream<List<int>>> Function(Uri url);

/// Fetches the newest release's JSON. Tests pass a fixture.
typedef FetchLatestRelease = Future<Map<String, Object?>?> Function();

/// The newest release from GitHub's API, or null when the repository has
/// none published.
Future<Map<String, Object?>?> fetchLatestRelease() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(latestReleaseApi);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'OmniFlow-app');
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode == HttpStatus.notFound) return null;
    if (response.statusCode != HttpStatus.ok) {
      throw UpdateFailure(
        response.statusCode == HttpStatus.forbidden ||
                response.statusCode == HttpStatus.tooManyRequests
            ? 'GitHub is limiting checks right now. Try again in an hour'
            : 'GitHub answered ${response.statusCode}. Try again later',
      );
    }
    final json = jsonDecode(text);
    if (json is! Map) throw const UpdateFailure('GitHub sent something odd');
    return Map<String, Object?>.from(json);
  } on SocketException {
    throw const UpdateFailure('No internet connection');
  } on TimeoutException {
    throw const UpdateFailure('GitHub did not answer in time');
  } on HandshakeException {
    throw const UpdateFailure('The secure connection to GitHub failed');
  } finally {
    client.close();
  }
}

/// Downloads [url] over https, following redirects only to [updateHosts].
Future<Stream<List<int>>> githubDownload(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  var at = url;
  try {
    for (var hops = 0; hops < 5; hops++) {
      if (!isUpdateHost(at)) {
        throw const UpdateFailure(
          'The download pointed somewhere other than GitHub, so it was '
          'stopped',
        );
      }
      final request = await client.getUrl(at);
      request
        ..followRedirects = false
        ..headers.set(HttpHeaders.userAgentHeader, 'OmniFlow-app');
      final response = await request.close();
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) break;
        at = at.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw UpdateFailure('The download failed (${response.statusCode})');
      }
      return response.transform<List<int>>(
        StreamTransformer.fromHandlers(
          handleDone: (sink) {
            sink.close();
            client.close();
          },
        ),
      );
    }
    throw const UpdateFailure('The download redirected too many times');
  } on SocketException {
    client.close();
    throw const UpdateFailure('No internet connection');
  } on Object {
    client.close();
    rethrow;
  }
}

/// Downloads [release]'s APK to [dest] and checks it against the
/// release's SHA256SUMS before anything else may use it. A wrong checksum
/// deletes the file and refuses.
Future<File> downloadVerifiedApk(
  ReleaseInfo release,
  File dest, {
  required OpenDownload open,
  void Function(double progress)? onProgress,
}) async {
  final apk = release.apk;
  final sums = release.sums;
  final name = release.apkName;
  if (apk == null || name == null) {
    throw const UpdateFailure('This release has no Android app to download');
  }
  if (sums == null) {
    throw const UpdateFailure(
      'This release has no checksums, so the download cannot be checked',
    );
  }
  if (!isReleaseAssetUrl(apk) || !isReleaseAssetUrl(sums)) {
    throw const UpdateFailure(
      'The download is not from OmniFlow\'s GitHub releases, so it was '
      'refused',
    );
  }
  final sumsText = await utf8.decodeStream(await open(sums));
  final expected = parseSha256Sums(sumsText)[name];
  if (expected == null) {
    throw const UpdateFailure('The checksums do not list the Android app');
  }

  await dest.parent.create(recursive: true);
  final sink = dest.openWrite();
  final digest = _DigestSink();
  final hasher = sha256.startChunkedConversion(digest);
  var received = 0;
  try {
    await for (final chunk in await open(apk)) {
      sink.add(chunk);
      hasher.add(chunk);
      received += chunk.length;
      final size = release.apkSize;
      if (size != null && size > 0) onProgress?.call(received / size);
    }
  } finally {
    await sink.close();
  }
  hasher.close();
  if (digest.value.toString() != expected) {
    await _delete(dest);
    throw const UpdateFailure(
      'The download did not match its checksum, so it was not installed',
    );
  }
  return dest;
}

Future<void> _delete(File f) async {
  try {
    await f.delete();
  } on FileSystemException {
    return;
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// What Android said about an install.
enum InstallResult {
  /// Android took the APK. OmniFlow restarts as the new version.
  started,

  /// The APK is signed with another key than the installed app.
  otherKey,

  /// The APK is older than the installed app.
  older,

  /// The APK does not run on this phone.
  incompatible,

  /// The person closed Android's install prompt.
  cancelled,

  /// There is not enough storage.
  storage,
  failed,
}

/// The words for an install that did not go through.
String installWords(InstallResult result) => switch (result) {
  InstallResult.started => 'Installing',
  InstallResult.otherKey =>
    'Android refused the update: it is signed with a different key than '
        'the OmniFlow on this phone. Installing it means removing this one '
        'first, which clears your home, so back it up before you do',
  InstallResult.older =>
    'Android refused the update because it is older than the OmniFlow on '
        'this phone',
  InstallResult.incompatible => 'This update does not run on this phone',
  InstallResult.cancelled => 'The install was cancelled',
  InstallResult.storage => 'There is not enough storage to install the update',
  InstallResult.failed => 'Android could not install the update',
};

/// The phone side of updating: what is installed, the "Install unknown
/// apps" permission and Android's package installer.
abstract interface class AppInstaller {
  /// Android's version code of the running app, and the ABIs the phone
  /// runs.
  Future<({int versionCode, List<String> abis})> installed();

  /// Whether Android lets OmniFlow install apps ("Install unknown apps").
  Future<bool> canInstall();

  /// Opens OmniFlow's "Install unknown apps" switch.
  Future<void> openInstallSettings();

  /// Hands [apk] to Android's package installer.
  Future<InstallResult> install(File apk);
}

/// [AppInstaller] over the omniflow/updates channel (AppUpdateBridge.kt).
class ChannelAppInstaller implements AppInstaller {
  const ChannelAppInstaller();

  static const _channel = MethodChannel('omniflow/updates');

  @override
  Future<({int versionCode, List<String> abis})> installed() async {
    final m = await _channel.invokeMapMethod<String, Object?>('installed');
    return (
      versionCode: (m?['versionCode'] as num?)?.toInt() ?? 0,
      abis: [...?(m?['abis'] as List?)?.whereType<String>()],
    );
  }

  @override
  Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  @override
  Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');

  @override
  Future<InstallResult> install(File apk) async {
    final status = await _channel.invokeMethod<String>('install', {
      'path': apk.path,
    });
    return InstallResult.values.asNameMap()[status] ?? InstallResult.failed;
  }
}

/// The running app's build: the release workflow's build number, or on a
/// local Android build the version code. A split APK's version code has
/// its ABI in the thousands (arm64 is 2000 + build), which is dropped.
int buildFromVersionCode(int versionCode) =>
    versionCode >= 1000 ? versionCode % 1000 : versionCode;
