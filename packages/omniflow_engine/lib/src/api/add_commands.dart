import 'api_error.dart';
import 'command_args.dart';
import 'device_commands.dart';
import 'engine_core.dart';
import '../dag/canonical.dart';
import '../devices/device.dart';
import '../devices/discovery/thing_finder.dart';
import '../manifest/driver_manifest.dart';
import '../storage/database.dart';

/// `thing.add`: one way to add anything. With no driver or candidate it
/// runs every discovery method at once and returns what it found, grouped
/// by driver. With one it adds the device and returns the `next` setup
/// step, which `thing.next` recomputes later and `thing.configure` and the
/// pairing and secret commands move along.
class AddCommands {
  AddCommands(this._core, this._devices, {ThingFinder? finder})
    : finder =
          finder ??
          ThingFinder(
            discovery: _core.discovery,
            serial: (driver, window) =>
                _core.serial.discover(driver, window: window),
          );

  final EngineCore _core;
  final DeviceCommands _devices;
  final ThingFinder finder;

  /// Feed every engine event here: the hub's `board.found` hellos become
  /// candidates.
  void observe(Map<String, Object?> event) => finder.hellos.observe(event);

  /// Finds when [args] names no `driver` and no `candidate`, adds otherwise.
  Future<Map<String, Object?>> add(Map<String, Object?> args) =>
      args['driver'] == null && args['candidate'] == null
      ? _find(args)
      : _addOne(args);

  /// `{windowMs?, methods?, drivers?}` -> `{groups, methods, failures?,
  /// manual}`. `manual` lists the drivers no method can find, added by
  /// address with `{driver, host}`.
  Future<Map<String, Object?>> _find(Map<String, Object?> args) async {
    final windowMs = optIntArg(args, 'windowMs') ?? 3000;
    if (windowMs < 100 || windowMs > 60000) {
      throw ApiError('invalid', 'windowMs must be 100 to 60000');
    }
    final methods = _stringSet(args, 'methods');
    final unknown = methods?.difference(addMethods);
    if (unknown != null && unknown.isNotEmpty) {
      throw ApiError(
        'invalid',
        '${unknown.join(', ')} is not a method. Use ${addMethods.join(', ')}',
      );
    }
    final driverIds = _stringSet(args, 'drivers');
    final drivers = <DriverManifest>[];
    for (final m in _core.registry.all) {
      if (driverIds == null || driverIds.contains(m.id)) drivers.add(m);
    }
    final missing = driverIds?.difference({for (final m in drivers) m.id});
    if (missing != null && missing.isNotEmpty) {
      throw ApiError('not_found', 'no driver ${missing.join(', ')}');
    }
    final found = await finder.find(
      [
        for (final d in drivers)
          if (d.discovery.isNotEmpty) d,
      ],
      devices: await DriftDeviceStore(_core.db).all(),
      window: Duration(milliseconds: windowMs),
      methods: methods,
    );
    return {
      ...found.toJson(),
      'manual': [
        for (final d in drivers)
          if (d.discovery.isEmpty)
            {
              'driver': d.id,
              'name': d.name,
              'category': d.category,
              if (d.transport.type == TransportType.virtual) 'virtual': true,
            },
      ],
    };
  }

  static const _candidateKeys = {
    'driver',
    'host',
    'port',
    'stableId',
    'id',
    'name',
    'room',
    'settings',
  };

  /// `{candidate?, driver?, host?, port?, stableId?, id?, name?, room?,
  /// settings?, replace?, provision?}`: the candidate (an entry of `thing.add`
  /// groups, or its `add` object) with the explicit keys over it, then
  /// `device.add`. With no id one is made from the name. A find that is a
  /// device already is refused unless `replace` is true.
  Future<Map<String, Object?>> _addOne(Map<String, Object?> args) async {
    final candidate = args['candidate'] == null
        ? const <String, Object?>{}
        : objectArg(args, 'candidate');
    final base = candidate['add'] is Map
        ? Map<String, Object?>.from(candidate['add'] as Map)
        : candidate;
    final merged = <String, Object?>{
      for (final key in _candidateKeys)
        if (base[key] != null) key: base[key],
      for (final MapEntry(:key, :value) in args.entries)
        if (key != 'candidate' && value != null) key: value,
    };
    final driverId = stringArg(merged, 'driver');
    final manifest =
        _core.registry[driverId] ??
        (throw ApiError('not_found', 'no driver $driverId'));
    final devices = await DriftDeviceStore(_core.db).all();
    final host = optStringArg(merged, 'host');
    final stableId = optStringArg(merged, 'stableId');
    final settings = merged['settings'] is Map
        ? Map<String, Object?>.from(merged['settings'] as Map)
        : const <String, Object?>{};
    final knownAs = candidate['knownAs'];
    // A find's knownAs was worked out with no settings, so an add that names
    // a light or an entity is checked again with them.
    final named = identifyingSettingsOf(manifest)
        .any((k) => settings[k] != null);
    final known = stableId != null || (knownAs is String && named)
        ? knownDeviceFor(
            manifest,
            stableId,
            host ?? '',
            devices,
            settings: settings,
          )
        : knownAs is String
        ? knownAs
        : _sameAddress(manifest, merged, devices);
    if (known != null && merged['replace'] != true) {
      throw ApiError(
        'exists',
        'this is the device $known already. Pass replace: true with id '
            '$known to add it again',
      );
    }
    merged['id'] ??= suggestThingId(
      optStringArg(merged, 'name') ??
          '${driverId}_${(host ?? 'thing').split(RegExp(r'[./]')).last}',
      {for (final d in devices) d.id},
    );
    final result = await _devices.add(merged);
    return {'id': merged['id'], ...result};
  }

  /// The device that is [args] already when the find carries no stable id:
  /// the same driver, host, port and settings. Settings stay in the match
  /// because one host can serve many devices (Home Assistant entities, MQTT
  /// topics), told apart only by a setting.
  static String? _sameAddress(
    DriverManifest manifest,
    Map<String, Object?> args,
    List<Device> devices,
  ) {
    final host = args['host'];
    if (host is! String || manifest.transport.type == TransportType.virtual) {
      return null;
    }
    final settings = canonicalJson(args['settings'] ?? const {});
    return devices
        .where(
          (d) =>
              d.driverId == manifest.id &&
              d.host == host &&
              d.port == args['port'] &&
              canonicalJson(d.settings) == settings,
        )
        .firstOrNull
        ?.id;
  }

  static Set<String>? _stringSet(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is List && value.every((v) => v is String)) {
      return {for (final v in value) v as String};
    }
    throw ApiError('invalid', '$key must be a list of strings');
  }
}
