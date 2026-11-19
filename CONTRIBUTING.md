# Contributing to OmniFlow

Thanks for helping. Read [ARCHITECTURE.md](ARCHITECTURE.md) first for where things live, and [DESIGN.md](DESIGN.md) before you touch a screen. The rule that matters most: all logic goes in the engine (`packages/omniflow_engine`), and the app, the CLI and the MCP tools stay thin clients of its one core API.

## Setup

You need macOS for the full set. The engine's CLI keeps secrets in the macOS keychain and refuses to start on other systems for now. CI runs the tests on macOS: on Linux, about 20 serial-port, ADB-over-TLS and Tuya timing tests fail today, so Linux is not a supported engine host yet. The app itself builds on Linux.

1. **Flutter 3.47.9 (stable, with Dart 3.13.7).** Install it with mise, which pins the version for this checkout:

   ```sh
   mise use flutter@3.47.9
   flutter --version
   ```

   This is the version CI builds with (`FLUTTER_VERSION` in `.github/workflows/ci.yml` and `release.yml`). Use Flutter's own `dart`, so `dart` and `flutter` agree.

2. **The Android SDK.** Install Android Studio, or the command-line tools, and set `ANDROID_HOME` (the tools also look in `~/Library/Android/sdk`). Accept the licences and check the setup:

   ```sh
   flutter doctor --android-licenses
   flutter doctor
   ```

   The app builds with Java 17 and `minSdk` 26 (`packages/omniflow_app/android/app/build.gradle.kts`). For a device to test on, create an emulator in Android Studio's Device Manager, or attach a phone with USB debugging on.

3. **Build output outside a synced folder.** If the checkout sits in a folder that syncs to the cloud (OneDrive, iCloud, Dropbox), run this once from the repo root:

   ```sh
   tool/link_build_dirs.sh
   ```

   It turns each build output folder (`packages/omniflow_app/build`, the Android `.gradle`, `build` and `.kotlin` folders, `tv_helper`'s and the firmware's) into a link to the same path under `~/.cache/omniflow/`, so Flutter and Gradle find them where they expect and the sync never uploads gigabytes of build files. A folder that already exists for real is left alone and named. Delete it, since it only holds build output, and run the script again. Outside a synced folder you can skip this step.

4. **Packages.** The repo is one pub workspace, so one command at the root resolves both packages:

   ```sh
   dart pub get
   ```

5. **Run the CLI** from `packages/omniflow_engine`:

   ```sh
   dart run omniflow_engine:omni --help
   dart run omniflow_engine:omni device discover
   ```

   Its data goes to `$OMNIFLOW_HOME`, by default `~/.omniflow`. Point it at a scratch folder (`--home /tmp/omni-dev`) while you work, so you do not touch a real home.

6. **Build and install the app** from `packages/omniflow_app`:

   ```sh
   flutter build apk --release
   adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```

   Pick the device with `adb -s <serial>` when more than one is attached. `-r` keeps the app's data. With no `android/key.properties` the release build is signed with the debug key. Two asset sets are build outputs that git ignores: the board firmware the app flashes (`dart run tool/firmware_assets.dart`, which needs `arduino-cli` and the board cores from `firmware/omniflow_node/README.md`) and the TV pointer helper (`dart run tool/tv_helper_asset.dart`). The app builds without them, and then cannot flash a board or install the helper.

## The checks every change passes

Run all of them before you ask for a review. Each must pass with no change and no warning.

In `packages/omniflow_engine`:

```sh
dart analyze
dart format --output=none --set-exit-if-changed lib test tool bin
dart run tool/embed_drivers.dart --check
dart test
```

In `packages/omniflow_app`:

```sh
flutter analyze
dart format --output=none --set-exit-if-changed lib test tool
flutter test
```

Some changes need one more step:

- **A driver in `drivers/`**: run `dart run tool/embed_drivers.dart` in `packages/omniflow_engine` to regenerate `lib/src/manifest/built_in_drivers.g.dart`. The `--check` above and a test in `test/manifest/driver_registry_test.dart` fail until you do.
- **The database schema in `lib/src/storage/database.dart`**: run `dart run build_runner build --delete-conflicting-outputs` in `packages/omniflow_engine`, and add a migration for the new schema version.
- **The hub templates in `packages/omniflow_engine/tool/hub/`**: run `dart run tool/hub/embed_templates.dart`, and check it with `--check`.
- **The firmware**: run `firmware/omniflow_node/check.sh`. It runs the native core tests, the virtual board and `arduino-cli compile` for every board.

To format instead of check, drop `--output=none --set-exit-if-changed`.

## Live hardware tests

Tests that drive real devices on the network are tagged `live` and skipped by default (`packages/omniflow_engine/dart_test.yaml`). Run them only on purpose, against devices you own:

```sh
dart test -t live                                          # every live test
OMNI_KEYCHAIN_TEST=1 dart test -t live test/storage/storage_test.dart
OMNI_SSH_HOST=mac.local OMNI_SSH_USER=me OMNI_SSH_KEY=~/.ssh/id_ed25519 \
  dart test -t live test/devices/host_exec_channel_test.dart
dart test -t live test/devices/adb/tv_live_test.dart
```

- The keychain test writes and deletes one item in the login keychain, and runs only with `OMNI_KEYCHAIN_TEST=1`.
- The SSH test runs one command on the host named by `OMNI_SSH_HOST`, `OMNI_SSH_USER` and `OMNI_SSH_KEY`, and is skipped without them.
- The Android TV test uses the engine home in `OMNI_LIVE_HOME` (default `~/.cache/omniflow/tvhome`) that holds a paired TV, and the device id in `OMNI_LIVE_TV` (default `tv`). It changes only the volume by one step and back, presses Home, sets `animator_duration_scale` to 1 and back, and works in `/sdcard/Download/omniflow_test`, which it removes.
- The weather test in `test/api/smart_home_test.dart` calls Open-Meteo over the internet.

A few other tests skip themselves where the machine cannot run them: the virtual board needs a C++ compiler, the loopback `sshd` test needs macOS with OpenSSH, and three loopback address tests run on macOS only. The skip reason says which.

## Tests come with the change

- A bug fix comes with a test that fails without the fix.
- A new command gets an engine test in `packages/omniflow_engine/test/api/`, and a CLI verb a test in `test/cli/`.
- A new driver or channel gets a test against a loopback fake of the device, as the WiZ, Tuya, HTTP and ADB tests do. Tests stay on loopback: fake TVs, a fake adbd, a fake mDNS client (`test/devices/fake_mdns.dart`) and `InMemorySecretStore`. Pass `mdns:` to `OmniEngine.open` in a test that discovers devices or heals an address.
- A screen change gets a widget test with `FakeEngine` (`packages/omniflow_app/test/fake_engine.dart`) that covers its states and the accessibility checks in [DESIGN.md](DESIGN.md#accessibility-checks).
- A rule shape the app writes is checked against the engine in `packages/omniflow_app/test/real_rules_test.dart`.

## Secrets never go in logs or tests

A Tuya local key, an SSH or ADB key, a TV pairing key, a Hue username, a Home Assistant token or a Wi-Fi password never goes in a manifest, a flow, a test, a fixture, a log line, a commit or an issue. In code, secrets go through `SecretStore` and are read by key. In tests, use `InMemorySecretStore` with made-up values. The same goes for anything that identifies a real home: use made-up addresses, device ids, MAC addresses, serials and network names in fixtures, docs and screenshots. Grep your diff for key-shaped strings before you commit.

## Releases

Two workflows run on GitHub Actions. `ci.yml` runs the checks above on every push to `main` and every pull request. `release.yml` builds every target on a `v*` tag, or by hand from Actions, Release, Run workflow:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

Each build is uploaded as `omniflow-<version>-<platform>-<arch>.<ext>`, with `dev` as the version on a run by hand. A tag build also makes a GitHub release with every file and a `SHA256SUMS`. The tests run once, in the `test` job, and the release waits for them.

| Target | File | Built on |
| --- | --- | --- |
| Android app | `android-arm64.apk`, `android-arm32.apk`, `android-x86_64.apk`, `android-universal.aab` | Ubuntu |
| Android TV pointer helper | `androidtv-helper.apk` | Ubuntu |
| Board firmware | `firmware-esp32.bin`, `firmware-esp8266.bin`, `firmware-uno.hex`, `firmware-pico_w.uf2` | Ubuntu |
| iOS app, unsigned | `ios-arm64-unsigned.ipa` | macOS |
| macOS app | `macos-universal.zip` | macOS |
| Windows app | `windows-x64.zip` | Windows Server 2022 |
| Linux app | `linux-x64.tar.gz` | Ubuntu |
| `omni` CLI and hub | `cli-macos-arm64.tar.gz`, `cli-macos-x64.tar.gz` (Linux and Windows are built in CI but not released, see above) | each macOS runner |

The Android app bundles the firmware and the TV helper that the same run built. It is signed with the release key from the `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_ALIAS` secrets. A tag build fails without them, since an APK signed with another key cannot update an installed one. A run by hand without them is signed with the debug key. Everything else is unsigned.

Off Android the app runs the engine inside itself while it is open, with its data in the app's support folder rather than `~/.omniflow`. `DeviceFeatures` (`lib/state/device_features.dart`) says what the device has, and the screens hide the rest: the background service and Phone setup, the phone's own triggers and actions, NFC tags, USB boards, hub mode and shake to run a scene. The iOS and macOS bundle id is `com.jashnm.omniflowApp`, since Apple ids cannot hold an underscore. Android keeps `com.jashnm.omniflow_app`.

There is no web build. The engine reaches devices over UDP, TCP and mDNS with `dart:io` and keeps its data in SQLite through FFI, and a browser has neither.

To build them on a Mac, from `packages/omniflow_app`:

```sh
flutter build apk --release --split-per-abi
flutter build appbundle --release
flutter build ios --release --no-codesign
flutter build macos --release
```

and the CLI, from `packages/omniflow_engine`. It needs `dart build cli`, not `dart compile exe`, because the sqlite3 package has build hooks. A Mac can cross-build the Linux bundles, not the macOS x64 or Windows ones:

```sh
dart build cli -o build/omni
dart build cli --target-os linux --target-arch arm64 -o build/omni-linux-arm64
```

The Windows and Linux apps build only on their own systems, so only CI proves them.

## Commits

- One logical change per commit. A fix and the refactor that made it possible are two commits.
- The subject is a plain sentence, imperative or descriptive, under about 60 characters, with no prefix such as `feat:` or `fix(ui):`. For example: "Keep the light page's sections closed on first open".
- The body says why, in a few short lines. The diff already says what.
- Each commit passes the checks above on its own.

## Reporting a security issue

Do not open a public issue for a security problem. Report it privately to the maintainer through the repository's private vulnerability reporting (Security, Report a vulnerability), with the steps to reproduce it and what it lets someone do. Leave out real keys and addresses. The security model, and the risks the design already accepts, are in [ARCHITECTURE.md](ARCHITECTURE.md#security-model) and [docs/engine-design.md](docs/engine-design.md), Security.
