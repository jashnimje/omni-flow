import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/src/api/home_commands.dart';
import 'package:omniflow_engine/src/api/mode_commands.dart' show HomeFile;
import 'package:test/test.dart';

void main() {
  test('the mode, the location and the alerts written at once all land, '
      '50 rounds of 50', () async {
    var lost = 0;
    final errors = <Object>[];
    for (var round = 0; round < 50; round++) {
      final dir = await Directory.systemTemp.createTemp('omni_homejson');
      try {
        await Future.wait([
          HomeFile(dir).update({'mode': 'night'}),
          HomeLocationStore(dir).write((latitude: 51.5, longitude: -0.1)),
          HomeFile(dir).update({
            'alerts': {'offline': false, 'battery': true},
          }),
        ]).catchError((Object e) {
          errors.add(e);
          return const <void>[];
        });
        final json =
            jsonDecode(File('${dir.path}/home.json').readAsStringSync()) as Map;
        if (!['mode', 'location', 'alerts'].every(json.containsKey)) lost++;
        expect(dir.listSync().map((e) => e.path.split('/').last), [
          'home.json',
        ], reason: 'no temporary file is left behind');
      } finally {
        await dir.delete(recursive: true);
      }
    }
    expect(errors, isEmpty);
    expect(lost, 0);
  });

  test('clearing the location keeps the other keys', () async {
    final dir = await Directory.systemTemp.createTemp('omni_homejson');
    try {
      final location = HomeLocationStore(dir);
      await location.write((latitude: 10, longitude: 20));
      await HomeFile(dir).update({'mode': 'away'});
      await location.write(null);
      expect(await location.read(), isNull);
      expect(await HomeFile(dir).read(), {'mode': 'away'});
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
