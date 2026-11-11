// Builds the OmniFlow board firmware with arduino-cli and puts the images
// the app flashes over USB into assets/firmware/. They are build outputs,
// so git ignores them: run this before `flutter build apk`.
//
//   dart run tool/firmware_assets.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _boards = {
  'esp32': ('esp32:esp32:esp32', 'omniflow_node.ino.merged.bin', 'esp32.bin'),
  'esp8266': (
    'esp8266:esp8266:nodemcuv2',
    'omniflow_node.ino.bin',
    'esp8266.bin',
  ),
  'uno': ('arduino:avr:uno', 'omniflow_node.ino.hex', 'uno.hex'),
  'pico_w': ('rp2040:rp2040:rpipicow', 'omniflow_node.ino.uf2', 'pico_w.uf2'),
};

/// The merged ESP32 image is padded with 0xFF to the whole 4 MiB flash.
/// Writing the padding only erases what is blank already, so it stops at
/// the last 4 KiB sector that holds data.
Uint8List _trimmed(Uint8List image) {
  var end = image.length;
  while (end > 0 && image[end - 1] == 0xFF) {
    end--;
  }
  final sectors = (end + 0xFFF) & ~0xFFF;
  return Uint8List.sublistView(image, 0, sectors.clamp(0, image.length));
}

Future<void> main() async {
  final app = File(Platform.script.toFilePath()).parent.parent;
  final sketch = Directory('${app.path}/../../firmware/omniflow_node');
  final out = Directory('${app.path}/assets/firmware')
    ..createSync(recursive: true);
  final work = Directory.systemTemp.createTempSync('omni_fw');
  final manifest = <String, Object?>{};
  for (final MapEntry(key: chip, value: (fqbn, built, asset))
      in _boards.entries) {
    final dir = '${work.path}/$chip';
    stdout.writeln('== $fqbn');
    final r = await Process.run('arduino-cli', [
      'compile',
      '--fqbn',
      fqbn,
      '--output-dir',
      dir,
      sketch.path,
    ]);
    if (r.exitCode != 0) {
      stderr.writeln(r.stdout);
      stderr.writeln(r.stderr);
      exit(1);
    }
    var bytes = File('$dir/$built').readAsBytesSync();
    if (chip == 'esp32') bytes = _trimmed(bytes);
    File('${out.path}/$asset').writeAsBytesSync(bytes);
    manifest[chip] = {'file': asset, 'bytes': bytes.length};
    stdout.writeln('   ${bytes.length} bytes -> assets/firmware/$asset');
  }
  manifest['built'] = DateTime.now().toUtc().toIso8601String();
  File('${out.path}/firmware.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
  work.deleteSync(recursive: true);
}
