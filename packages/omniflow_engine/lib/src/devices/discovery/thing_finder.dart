import '../board.dart' show isSerialHost;
import '../device.dart';
import '../discovery.dart';
import '../../manifest/driver_manifest.dart';
import 'board_hellos.dart';
import 'mdns_discovery.dart';
import 'tuya_broadcast.dart';

/// Asks every USB serial port whether it is a device of [driver]. Returns
/// `{host, stableId?, reply}` per answer, as [SerialChannel.discover] does.
typedef SerialProbe = Future<List<Map<String, Object?>>> Function(
  DriverManifest driver,
  Duration window,
);

const serialMethod = 'serial';

/// Every method `thing.add` can run.
const addMethods = {
  'udp_broadcast',
  mdnsMethod,
  tuyaBroadcastMethod,
  serialMethod,
  helloMethod,
};

/// A board opened over USB resets, and takes a moment to answer.
const serialMinimumWindow = Duration(milliseconds: 3000);

/// Runs every discovery method at once for many drivers and turns what is
/// found into candidates to add: grouped by driver, each with a suggested
/// id and name, and marked `knownAs` when it is a device already.
class ThingFinder {
  ThingFinder({
    required this.discovery,
    required this.serial,
    RecentHellos? hellos,
  }) : hellos = hellos ?? RecentHellos();

  final DeviceDiscovery discovery;
  final SerialProbe serial;
  final RecentHellos hellos;

  /// [methods] limits the methods run, all of [addMethods] when null.
  Future<FoundThings> find(
    List<DriverManifest> drivers, {
    required List<Device> devices,
    Duration window = const Duration(seconds: 3),
    Set<String>? methods,
  }) async {
    bool wanted(String method) => methods == null || methods.contains(method);
    final network = discovery.discoverAll(
      drivers,
      window: window,
      methods: methods,
    );
    final serialWindow = window > serialMinimumWindow
        ? window
        : serialMinimumWindow;
    final onUsb = [
      for (final driver in drivers)
        if (wanted(serialMethod) &&
            driver.discovery.any((d) => d.method == serialMethod))
          serial(driver, serialWindow).then(
            (hits) => [
              for (final h in hits)
                if (h['host'] case final String host)
                  (
                    driver.id,
                    DiscoveredDevice(
                      host: host,
                      stableId: h['stableId']?.toString(),
                      name: h['stableId']?.toString(),
                      reply: h['reply'] is Map
                          ? Map<String, Object?>.from(h['reply'] as Map)
                          : const {},
                      method: serialMethod,
                    ),
                  ),
            ],
          ),
    ];
    final sweep = await network;
    final found = <String, List<DiscoveredDevice>>{
      for (final d in drivers) d.id: [...?sweep.found[d.id]],
    };
    if (wanted(helloMethod)) {
      for (final (driver, d) in hellos.recent) {
        found[driver]?.add(d);
      }
    }
    for (final hits in await Future.wait(onUsb)) {
      for (final (driver, d) in hits) {
        found[driver]!.add(d);
      }
    }
    return FoundThings(
      groups: candidateGroups(drivers, found, devices),
      failures: sweep.failures,
      methods: [
        for (final m in addMethods)
          if (wanted(m)) m,
      ],
    );
  }
}

/// The result of [ThingFinder.find].
class FoundThings {
  const FoundThings({
    required this.groups,
    required this.failures,
    required this.methods,
  });

  final List<Map<String, Object?>> groups;
  final List<String> failures;
  final List<String> methods;

  Map<String, Object?> toJson() => {
    'groups': groups,
    'methods': methods,
    if (failures.isNotEmpty) 'failures': failures,
  };
}

/// [found] as candidates grouped by driver, in [drivers] order, leaving out
/// drivers that found nothing. One candidate per device: the same stable id
/// heard by several methods is one candidate listing them all, except that
/// a board on USB and the same board on Wi-Fi are two ways to add it.
List<Map<String, Object?>> candidateGroups(
  List<DriverManifest> drivers,
  Map<String, List<DiscoveredDevice>> found,
  List<Device> devices,
) {
  final taken = {for (final d in devices) d.id};
  final groups = <Map<String, Object?>>[];
  for (final driver in drivers) {
    final merged = <String, (DiscoveredDevice, List<String>)>{};
    for (final d in found[driver.id] ?? const <DiscoveredDevice>[]) {
      final key =
          '${(d.stableId ?? 'host:${d.host}').toLowerCase()}'
          '${isSerialHost(d.host) ? '@usb' : ''}';
      final seen = merged[key];
      if (seen == null) {
        merged[key] = (d, [?d.method]);
      } else if (d.method != null && !seen.$2.contains(d.method)) {
        seen.$2.add(d.method!);
      }
    }
    if (merged.isEmpty) continue;
    final usePort = !driver.discovery.any((s) => s.config['usePort'] == false);
    groups.add({
      'driver': driver.id,
      'name': driver.name,
      'category': driver.category,
      'candidates': [
        for (final (d, methods) in merged.values)
          _candidate(driver, d, methods, devices, taken, usePort: usePort),
      ],
    });
  }
  return groups;
}

Map<String, Object?> _candidate(
  DriverManifest driver,
  DiscoveredDevice d,
  List<String> methods,
  List<Device> devices,
  Set<String> taken, {
  required bool usePort,
}) {
  final knownAs = knownDeviceFor(driver, d.stableId, d.host, devices);
  final port = usePort && d.port != driver.transport.port ? d.port : null;
  final name = d.name ?? '${driver.name} ${_tail(d)}';
  final id = suggestThingId(d.name ?? '${driver.id}_${_tail(d)}', taken);
  taken.add(id);
  return {
    'driver': driver.id,
    'method': ?methods.firstOrNull,
    if (methods.length > 1) 'methods': methods,
    'host': d.host,
    'port': ?d.port,
    'stableId': ?d.stableId,
    'name': name,
    'id': id,
    'knownAs': ?knownAs,
    'add': {
      'driver': driver.id,
      'host': d.host,
      'port': ?port,
      'stableId': ?d.stableId,
      'id': id,
      'name': name,
    },
  };
}

/// The settings that tell apart the devices behind one address and one
/// stable id: a Hue bridge's lights, a Home Assistant host's entities, the
/// topics on one MQTT broker.
const identifyingSettingKeys = {
  'lightId',
  'entityId',
  'friendlyName',
  'topic',
  'commandTopic',
  'stateTopic',
};

/// The identifying settings [driver] asks for at setup.
Set<String> identifyingSettingsOf(DriverManifest driver) => {
  for (final step in driver.setup)
    if (step.kind == SetupKind.configure &&
        identifyingSettingKeys.contains(step.key))
      step.key!,
};

/// The id of the device of [driver] that is this find: by stable id, or by
/// address when the find has none, and with the same identifying
/// [settings]. A find and a device with none of them match by address
/// alone, so a second light on a bridge is a device of its own once either
/// names its light.
String? knownDeviceFor(
  DriverManifest driver,
  String? stableId,
  String host,
  List<Device> devices, {
  Map<String, Object?> settings = const {},
}) {
  final keys = identifyingSettingsOf(driver);
  final wanted = _identity(settings, keys);
  for (final d in devices) {
    if (d.driverId != driver.id) continue;
    final sameAddress = stableId != null
        ? d.stableId?.toLowerCase() == stableId.toLowerCase()
        : d.host == host;
    if (!sameAddress) continue;
    final has = _identity(d.settings, keys);
    if (has.length == wanted.length &&
        has.entries.every((e) => wanted[e.key] == e.value)) {
      return d.id;
    }
  }
  return null;
}

Map<String, String> _identity(
  Map<String, Object?> settings,
  Set<String> keys,
) => {
  for (final k in keys)
    if (settings[k] case final Object v when '$v'.isNotEmpty) k: '$v',
};

/// The last part of a find's stable id or address, to tell finds apart.
String _tail(DiscoveredDevice d) {
  final id = d.stableId;
  if (id != null && id.isNotEmpty) {
    return id.length > 6 ? id.substring(id.length - 6) : id;
  }
  return d.host.split(RegExp(r'[./]')).last;
}

/// [raw] as a lower snake case device id not in [taken]: `Philips Hue -
/// 0A0B0C` becomes `philips_hue_0a0b0c`, then `_2`, `_3` on a clash.
String suggestThingId(String raw, Set<String> taken) {
  var base = raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (base.length > 40) {
    base = base.substring(0, 40).replaceAll(RegExp(r'_+$'), '');
  }
  if (base.isEmpty || !RegExp(r'^[a-z]').hasMatch(base)) base = 'thing_$base';
  base = base.replaceAll(RegExp(r'_+$'), '');
  if (!taken.contains(base)) return base;
  for (var n = 2; ; n++) {
    if (!taken.contains('${base}_$n')) return '${base}_$n';
  }
}
