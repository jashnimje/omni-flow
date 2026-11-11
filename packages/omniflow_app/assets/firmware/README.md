# Board firmware

The images the app flashes over USB. They are build outputs and git ignores them. Build them with arduino-cli and the four cores before `flutter build apk`:

    dart run tool/firmware_assets.dart
