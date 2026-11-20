import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/service/app_update.dart';
import 'package:omniflow_app/state/app_update.dart';
import 'package:omniflow_app/ui/settings/update_rows.dart';
import 'package:omniflow_app/ui/settings/whats_new.dart';

import 'fake_engine.dart';
import 'screen_harness.dart';

const _download = 'https://github.com/jashnimje/omni-flow/releases/download';

/// GitHub's latest-release JSON, cut to the fields a release carries, in
/// the shape https://docs.github.com/rest/releases/releases documents.
Map<String, Object?> _release({
  String tag = 'v1.0.0-build.45',
  String version = '1.0.0',
  int? build = 45,
  String apkName = 'omniflow-1.0.0-android.apk',
  String? apkUrl,
  int apkSize = 6,
}) {
  Map<String, Object?> asset(int id, String name, int size, [String? url]) => {
    'url':
        'https://api.github.com/repos/jashnimje/omni-flow/releases/assets/$id',
    'id': id,
    'node_id': 'RA_$id',
    'name': name,
    'label': '',
    'uploader': {'login': 'github-actions[bot]', 'type': 'Bot'},
    'content_type': 'application/octet-stream',
    'state': 'uploaded',
    'size': size,
    'download_count': 3,
    'created_at': '2026-11-20T05:40:00Z',
    'updated_at': '2026-11-20T05:41:00Z',
    'browser_download_url': url ?? '$_download/$tag/$name',
  };
  return {
    'url': 'https://api.github.com/repos/jashnimje/omni-flow/releases/1',
    'html_url': 'https://github.com/jashnimje/omni-flow/releases/tag/$tag',
    'id': 1,
    'author': {'login': 'github-actions[bot]', 'type': 'Bot'},
    'tag_name': tag,
    'target_commitish': 'main',
    'name': build == null ? tag : 'OmniFlow $version (build $build)',
    'draft': false,
    'prerelease': false,
    'created_at': '2026-11-20T05:32:10Z',
    'published_at': '2026-11-20T05:58:54Z',
    'assets': [
      asset(10, apkName, apkSize, apkUrl),
      asset(11, 'omniflow-$version-android-extras.zip', 90),
      asset(12, 'omniflow-$version-macos.zip', 80),
      asset(13, 'SHA256SUMS', 400),
    ],
    'tarball_url':
        'https://api.github.com/repos/jashnimje/omni-flow/tarball/$tag',
    'zipball_url':
        'https://api.github.com/repos/jashnimje/omni-flow/zipball/$tag',
    'body': build == null
        ? '## What\'s Changed\n* Add the MIT licence'
        : 'OmniFlow $version, build $build.\n\n## Which file do I need?\n\n'
              '<!-- omniflow-release: version=$version build=$build -->\n\n'
              '## What\'s Changed\n* Add the MIT licence',
  };
}

final _apkBytes = utf8.encode('apk!!!');
String get _apkSum => sha256.convert(_apkBytes).toString();

class _Installer implements AppInstaller {
  _Installer({
    this.versionCode = 12,
    this.abis = const ['arm64-v8a'],
    this.allowed = true,
    this.result = InstallResult.started,
  });

  int versionCode;
  List<String> abis;
  bool allowed;
  InstallResult result;
  final handedOver = <File>[];
  var openedSettings = 0;

  @override
  Future<({int versionCode, List<String> abis})> installed() async =>
      (versionCode: versionCode, abis: abis);

  @override
  Future<bool> canInstall() async => allowed;

  @override
  Future<void> openInstallSettings() async => openedSettings++;

  @override
  Future<InstallResult> install(File apk) async {
    handedOver.add(apk);
    return result;
  }
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('omni_update_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('the latest-release JSON', () {
    test('reads the version and build from the release line', () {
      final r = ReleaseInfo.fromGitHub(_release());
      expect(r.version, '1.0.0');
      expect(r.build, 45);
      expect(r.label, '1.0.0 (build 45)');
      expect(r.apkName, 'omniflow-1.0.0-android.apk');
      expect(r.apk.toString(), '$_download/v1.0.0-build.45/${r.apkName}');
      expect(r.sums.toString(), '$_download/v1.0.0-build.45/SHA256SUMS');
      expect(
        r.page.toString(),
        'https://github.com/jashnimje/omni-flow/releases/tag/v1.0.0-build.45',
      );
    });

    test('a release from before build numbers has the tag version and no '
        'build, and its arm64 APK still counts', () {
      final r = ReleaseInfo.fromGitHub(
        _release(
          tag: 'v1.0.0',
          build: null,
          apkName: 'omniflow-1.0.0-android-arm64.apk',
        ),
      );
      expect(r.version, '1.0.0');
      expect(r.build, isNull);
      expect(r.apkName, 'omniflow-1.0.0-android-arm64.apk');
    });

    test('the extras zip is never taken for the APK', () {
      final json = _release();
      (json['assets']! as List).removeAt(0);
      expect(ReleaseInfo.fromGitHub(json).apk, isNull);
    });

    test('SHA256SUMS lines by file name', () {
      final sums = parseSha256Sums(
        '${'a' * 64}  omniflow-1.0.0-android.apk\n'
        '${'B' * 64} *omniflow-1.0.0-macos.zip\n'
        'not a line\n',
      );
      expect(sums, {
        'omniflow-1.0.0-android.apk': 'a' * 64,
        'omniflow-1.0.0-macos.zip': 'b' * 64,
      });
    });
  });

  group('version and build', () {
    const app = InstalledApp(version: '1.0.0', build: 12);
    ReleaseInfo r(String v, int? b) =>
        ReleaseInfo(version: v, build: b, page: releasesPage);

    test('a higher build of the same version is newer', () {
      expect(r('1.0.0', 45).isNewerThan(app), isTrue);
      expect(r('1.0.0', 12).isNewerThan(app), isFalse);
      expect(r('1.0.0', 11).isNewerThan(app), isFalse);
    });

    test('the version counts before the build', () {
      expect(r('1.1.0', 1).isNewerThan(app), isTrue);
      expect(r('0.11.0', 99).isNewerThan(app), isFalse);
      expect(compareVersions('1.10.0', '1.9.0'), 1);
      expect(compareVersions('1.0', '1.0.0'), 0);
    });

    test('without a build on either side only the version counts', () {
      expect(r('1.0.0', null).isNewerThan(app), isFalse);
      expect(
        r(
          '1.0.0',
          45,
        ).isNewerThan(const InstalledApp(version: '1.0.0', build: 0)),
        isFalse,
      );
    });

    test('a split APK version code drops its ABI', () {
      expect(buildFromVersionCode(2045), 45);
      expect(buildFromVersionCode(12), 12);
    });
  });

  group('downloads', () {
    OpenDownload files(Map<String, List<int>> byUrl) =>
        (url) async => Stream.value(byUrl[url.toString()]!);

    test('a download that matches SHA256SUMS is kept', () async {
      final r = ReleaseInfo.fromGitHub(_release());
      final progress = <double>[];
      final apk = await downloadVerifiedApk(
        r,
        File('${tmp.path}/u.apk'),
        open: files({
          '${r.sums}': utf8.encode('$_apkSum  ${r.apkName}\n'),
          '${r.apk}': _apkBytes,
        }),
        onProgress: progress.add,
      );
      expect(apk.readAsBytesSync(), _apkBytes);
      expect(progress.last, 1);
    });

    test('a checksum mismatch is refused and the file deleted', () async {
      final r = ReleaseInfo.fromGitHub(_release());
      final dest = File('${tmp.path}/u.apk');
      await expectLater(
        downloadVerifiedApk(
          r,
          dest,
          open: files({
            '${r.sums}': utf8.encode('${'0' * 64}  ${r.apkName}\n'),
            '${r.apk}': _apkBytes,
          }),
        ),
        throwsA(
          isA<UpdateFailure>().having(
            (e) => e.message,
            'message',
            contains('did not match its checksum'),
          ),
        ),
      );
      expect(dest.existsSync(), isFalse);
    });

    test('an APK the checksums do not list is refused', () async {
      final r = ReleaseInfo.fromGitHub(_release());
      await expectLater(
        downloadVerifiedApk(
          r,
          File('${tmp.path}/u.apk'),
          open: files({'${r.sums}': utf8.encode('$_apkSum  other.apk\n')}),
        ),
        throwsA(isA<UpdateFailure>()),
      );
    });

    test(
      'a non-GitHub asset url is refused before anything downloads',
      () async {
        final r = ReleaseInfo.fromGitHub(
          _release(apkUrl: 'https://example.com/omniflow-1.0.0-android.apk'),
        );
        var opened = 0;
        await expectLater(
          downloadVerifiedApk(
            r,
            File('${tmp.path}/u.apk'),
            open: (url) async {
              opened++;
              return Stream.value(_apkBytes);
            },
          ),
          throwsA(
            isA<UpdateFailure>().having(
              (e) => e.message,
              'message',
              contains('not from OmniFlow'),
            ),
          ),
        );
        expect(opened, 0);
      },
    );

    test('only https GitHub hosts and this repository count', () {
      expect(isReleaseAssetUrl(Uri.parse('$_download/v1/x.apk')), isTrue);
      expect(
        isReleaseAssetUrl(
          Uri.parse(
            'http://github.com/jashnimje/omni-flow/releases/download/v1/x',
          ),
        ),
        isFalse,
      );
      expect(
        isReleaseAssetUrl(
          Uri.parse('https://github.com/someone/else/releases/download/v1/x'),
        ),
        isFalse,
      );
      expect(
        isUpdateHost(Uri.parse('https://objects.githubusercontent.com/a')),
        isTrue,
      );
      expect(
        isUpdateHost(
          Uri.parse('https://release-assets.githubusercontent.com/a'),
        ),
        isTrue,
      );
      expect(
        isUpdateHost(Uri.parse('https://githubusercontent.com.evil/a')),
        isFalse,
      );
      expect(isUpdateHost(Uri.parse('http://github.com/a')), isFalse);
    });

    test('a signing key that does not match reads in plain words', () {
      expect(installWords(InstallResult.otherKey), contains('different key'));
    });
  });

  group('the update states', () {
    ({ProviderContainer c, _Installer installer, MemoryUpdatePrefsStore prefs})
    make({
      Map<String, Object?>? json,
      bool noRelease = false,
      Object? fetchError,
      _Installer? installer,
      OpenDownload? open,
      UpdatePrefs prefs = const UpdatePrefs(),
      DateTime? now,
    }) {
      final i = installer ?? _Installer();
      final store = MemoryUpdatePrefsStore(prefs);
      final c = ProviderContainer(
        overrides: [
          updateEnvProvider.overrideWithValue(
            UpdateEnv(
              selfInstall: true,
              fetch: () async {
                if (fetchError != null) throw fetchError;
                return noRelease ? null : json ?? _release();
              },
              open:
                  open ??
                  (url) async => Stream.value(
                    url.path.endsWith('SHA256SUMS')
                        ? utf8.encode('$_apkSum  omniflow-1.0.0-android.apk\n')
                        : _apkBytes,
                  ),
              installer: i,
              prefs: store,
              cacheDir: () async => tmp,
              now: () => now ?? DateTime(2026, 11, 20, 9),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      return (c: c, installer: i, prefs: store);
    }

    test('a newer build is available, an equal one up to date', () async {
      var s = make();
      await s.c.read(appUpdateProvider.notifier).check();
      expect(s.c.read(appUpdateProvider), isA<UpdateAvailable>());
      expect(s.prefs.saved.lastCheck, DateTime(2026, 11, 20, 9));

      s = make(json: _release(build: 12));
      await s.c.read(appUpdateProvider.notifier).check();
      final up = s.c.read(appUpdateProvider) as UpdateUpToDate;
      expect(up.app.build, 12);

      // A split release APK reports 2000 + build as its version code.
      s = make(installer: _Installer(versionCode: 2045));
      await s.c.read(appUpdateProvider.notifier).check();
      expect(s.c.read(appUpdateProvider), isA<UpdateUpToDate>());
    });

    test('no release yet, and a failed check, read as such', () async {
      var s = make(noRelease: true);
      await s.c.read(appUpdateProvider.notifier).check();
      expect((s.c.read(appUpdateProvider) as UpdateUpToDate).noRelease, isTrue);

      s = make(fetchError: const UpdateFailure('No internet connection'));
      await s.c.read(appUpdateProvider.notifier).check();
      expect(
        (s.c.read(appUpdateProvider) as UpdateFailed).message,
        'No internet connection',
      );
    });

    test(
      'the quiet daily check shows only an update, never an error',
      () async {
        var s = make(fetchError: const UpdateFailure('No internet connection'));
        await s.c.read(appUpdateProvider.notifier).maybeAutoCheck();
        expect(s.c.read(appUpdateProvider), isA<UpdateIdle>());

        s = make(json: _release(build: 12));
        await s.c.read(appUpdateProvider.notifier).maybeAutoCheck();
        expect(s.c.read(appUpdateProvider), isA<UpdateIdle>());

        s = make();
        await s.c.read(appUpdateProvider.notifier).maybeAutoCheck();
        expect(s.c.read(appUpdateProvider), isA<UpdateAvailable>());
      },
    );

    test(
      'the daily check waits a day and stays off when switched off',
      () async {
        final now = DateTime(2026, 11, 20, 9);
        var s = make(
          prefs: UpdatePrefs(lastCheck: now.subtract(const Duration(hours: 3))),
          now: now,
        );
        await s.c.read(appUpdateProvider.notifier).maybeAutoCheck();
        expect(s.c.read(appUpdateProvider), isA<UpdateIdle>());

        s = make(prefs: const UpdatePrefs(auto: false));
        await s.c.read(appUpdateProvider.notifier).maybeAutoCheck();
        expect(s.c.read(appUpdateProvider), isA<UpdateIdle>());
        await s.c.read(updateAutoProvider.future);
        await s.c.read(updateAutoProvider.notifier).set(true);
        expect(s.prefs.saved.auto, isTrue);
      },
    );

    test('an update downloads, checks out and goes to the installer', () async {
      final s = make();
      final n = s.c.read(appUpdateProvider.notifier);
      final seen = <UpdateStatus>[];
      s.c.listen(appUpdateProvider, (_, next) => seen.add(next));
      await n.check();
      await n.update();
      expect(seen.whereType<UpdateDownloading>(), isNotEmpty);
      expect(s.c.read(appUpdateProvider), isA<UpdateInstalling>());
      expect(
        s.installer.handedOver.single.path,
        endsWith('omniflow-update.apk'),
      );
    });

    test('without "Install unknown apps" it asks, then carries on', () async {
      final s = make(installer: _Installer(allowed: false));
      final n = s.c.read(appUpdateProvider.notifier);
      await n.check();
      await n.update();
      expect(s.c.read(appUpdateProvider), isA<UpdateNeedsPermission>());
      await n.allowInstalls();
      expect(s.installer.openedSettings, 1);
      s.installer.allowed = true;
      await n.recheckPermission();
      expect(s.c.read(appUpdateProvider), isA<UpdateAvailable>());
    });

    test('a checksum mismatch never reaches the installer', () async {
      final s = make(
        open: (url) async => Stream.value(
          url.path.endsWith('SHA256SUMS')
              ? utf8.encode('${'0' * 64}  omniflow-1.0.0-android.apk\n')
              : _apkBytes,
        ),
      );
      final n = s.c.read(appUpdateProvider.notifier);
      await n.check();
      await n.update();
      expect(
        (s.c.read(appUpdateProvider) as UpdateFailed).message,
        contains('checksum'),
      );
      expect(s.installer.handedOver, isEmpty);
    });

    test('another signing key and another ABI fail in plain words', () async {
      var s = make(installer: _Installer(result: InstallResult.otherKey));
      var n = s.c.read(appUpdateProvider.notifier);
      await n.check();
      await n.update();
      expect(
        (s.c.read(appUpdateProvider) as UpdateFailed).message,
        contains('different key'),
      );

      s = make(installer: _Installer(abis: const ['x86_64']));
      n = s.c.read(appUpdateProvider.notifier);
      await n.check();
      await n.update();
      expect(
        (s.c.read(appUpdateProvider) as UpdateFailed).message,
        contains('x86_64'),
      );
    });
  });

  group('the About rows', () {
    final available = UpdateAvailable(ReleaseInfo.fromGitHub(_release()));
    final cases = <String, (UpdateStatus, String)>{
      'idle': (const UpdateIdle(), 'Check for updates'),
      'checking': (const UpdateChecking(), 'Checking for updates'),
      'up to date': (
        const UpdateUpToDate(InstalledApp(version: '1.0.0', build: 12)),
        'Up to date',
      ),
      'available': (available, 'Update available: 1.0.0 (build 45)'),
      'downloading': (
        UpdateDownloading(available.release, 0.5),
        'Downloading 1.0.0 (build 45)',
      ),
      'needs permission': (
        UpdateNeedsPermission(available.release),
        'Allow OmniFlow to install updates',
      ),
      'installing': (
        UpdateInstalling(available.release),
        'Installing 1.0.0 (build 45)',
      ),
      'failed': (const UpdateFailed('No internet connection'), 'Update failed'),
    };

    for (final MapEntry(key: name, value: (status, title)) in cases.entries) {
      testWidgets(name, (tester) async {
        await pumpScreen(
          tester,
          FakeEngine(),
          const AboutPage(),
          settle: false,
          overrides: [
            updateEnvProvider.overrideWithValue(
              UpdateEnv(
                selfInstall: true,
                prefs: MemoryUpdatePrefsStore(),
                installer: _Installer(),
              ),
            ),
            appUpdateProvider.overrideWith(() => _Fixed(status)),
          ],
        );
        await tester.pump();
        expect(find.text(title), findsOneWidget);
        expect(find.byKey(const ValueKey('about-update-auto')), findsOneWidget);
        if (status is UpdateDownloading) {
          expect(find.textContaining('50%'), findsOneWidget);
        }
        if (status is UpdateNeedsPermission) {
          expect(find.textContaining('Allow from this source'), findsOneWidget);
        }
      });
    }

    testWidgets('Settings shows a row only while an update is out', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        FakeEngine(),
        Scaffold(
          body: Column(children: [UpdateAvailableRow(onTap: () {})]),
        ),
        overrides: [appUpdateProvider.overrideWith(() => _Fixed(available))],
      );
      expect(find.text('Update available: 1.0.0 (build 45)'), findsOneWidget);
    });

    testWidgets('off Android it is a link to the release page', (tester) async {
      await pumpScreen(
        tester,
        FakeEngine(),
        const AboutPage(),
        overrides: [
          updateEnvProvider.overrideWithValue(
            UpdateEnv(selfInstall: false, prefs: MemoryUpdatePrefsStore()),
          ),
        ],
      );
      expect(find.text('Check for updates'), findsOneWidget);
      expect(find.text('Opens the releases page on GitHub'), findsOneWidget);
      expect(find.byKey(const ValueKey('about-update-auto')), findsNothing);
    });
  });
}

class _Fixed extends AppUpdateNotifier {
  _Fixed(this.fixed);

  final UpdateStatus fixed;

  @override
  UpdateStatus build() => fixed;
}
