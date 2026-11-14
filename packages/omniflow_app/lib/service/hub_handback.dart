import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/engine_client.dart';

/// The hub's home, exported just before the phone switched back to running
/// it, waiting in the phone's private folder for its engine to open.
File hubHandbackFile(Directory home) => File('${home.path}/hub-handback.json');

/// Keeps [backup] for the phone engine to import when it next opens.
Future<void> saveHubHandback(
  Directory home,
  Map<String, Object?> backup,
) async {
  if (!await home.exists()) await home.create(recursive: true);
  await hubHandbackFile(home).writeAsString(jsonEncode(backup), flush: true);
}

/// Imports the hub's home into the phone engine, replacing what the phone
/// had from before, then deletes the file. A backup that does not import
/// stays, so the next start tries again, and the phone's own home is left
/// as it was.
Future<void> takeBackHubHome(EngineClient engine, Directory home) async {
  final file = hubHandbackFile(home);
  if (!await file.exists()) return;
  try {
    final backup = jsonDecode(await file.readAsString());
    final result = await engine.call('config.import', {
      'backup': backup,
      'mode': 'replace',
    });
    if (result['ok'] == true) {
      await file.delete();
    } else {
      debugPrint('OmniFlow hub home not imported: ${result['error']}');
    }
  } on Object catch (e) {
    debugPrint('OmniFlow hub home not imported: $e');
  }
}

/// The last results the hub gave for read commands, so a restarted service
/// shows the home read-only while the hub is out of reach. They hold what
/// the lists show and no secrets: the engine never returns those.
class HubLastKnown {
  HubLastKnown(Directory home) : _file = File('${home.path}/hub-last.json');

  final File _file;
  var _writing = false;
  Map<String, Map<String, Object?>>? _next;

  Future<Map<String, Map<String, Object?>>> read() async {
    try {
      if (!await _file.exists()) return {};
      final json = jsonDecode(await _file.readAsString());
      if (json is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String && value is Map)
            key: Map<String, Object?>.from(value),
      };
    } on Object {
      return {};
    }
  }

  /// Writes the newest copy, one write at a time.
  void write(Map<String, Map<String, Object?>> lastKnown) {
    _next = Map.of(lastKnown);
    if (_writing) return;
    _writing = true;
    () async {
      try {
        for (var next = _next; next != null; next = _next) {
          _next = null;
          await _file.parent.create(recursive: true);
          await _file.writeAsString(jsonEncode(next));
        }
      } on Object catch (e) {
        debugPrint('OmniFlow hub state not kept: $e');
      } finally {
        _writing = false;
      }
    }();
  }
}
