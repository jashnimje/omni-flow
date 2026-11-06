import 'built_in_drivers.g.dart';
import 'driver_manifest.dart';
import 'validation.dart';

/// Every driver manifest the engine knows: the built-ins plus the user's own.
class DriverRegistry {
  DriverRegistry._(this._builtIns);

  /// Loads the embedded built-ins. A broken built-in is a build defect, so it
  /// throws instead of being skipped.
  factory DriverRegistry.withBuiltIns({Map<String, String>? sources}) {
    final builtIns = <String, DriverManifest>{};
    for (final entry in (sources ?? builtInDriverSources).entries) {
      final manifest = DriverManifest.parseJson(entry.value);
      if (builtIns.containsKey(manifest.id)) {
        throw StateError('built-in driver id ${manifest.id} is defined twice');
      }
      builtIns[manifest.id] = manifest;
    }
    return DriverRegistry._(builtIns);
  }

  final Map<String, DriverManifest> _builtIns;
  final Map<String, DriverManifest> _user = {};

  List<DriverManifest> get all => [..._builtIns.values, ..._user.values];

  DriverManifest? operator [](String id) => _builtIns[id] ?? _user[id];

  bool isBuiltIn(String id) => _builtIns.containsKey(id);

  /// Adds or replaces a user manifest. A user manifest cannot take a built-in id.
  DriverManifest register(Object? json) {
    final manifest = DriverManifest.parse(json);
    if (_builtIns.containsKey(manifest.id)) {
      throw ValidationException('driver manifest ${manifest.id}', [
        ValidationIssue(
          r'$.id',
          '"${manifest.id}" is a built-in driver. Copy it under a new id to change it',
        ),
      ]);
    }
    _user[manifest.id] = manifest;
    return manifest;
  }

  bool unregister(String id) => _user.remove(id) != null;
}
