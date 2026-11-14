# TV pointer helper

The small Android TV app the Mouse tab installs to draw a live pointer on the TV. Its source is `tv_helper/` at the repo root. The APK is a build output and git ignores it. Build it before `flutter build apk`:

    dart run tool/tv_helper_asset.dart
