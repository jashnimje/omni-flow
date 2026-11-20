import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'api_error.dart';
import 'command_args.dart';
import 'device_commands.dart';
import 'engine_core.dart';
import 'hub_runtime.dart';
import 'organize_commands.dart' show resolveRoom;
import '../devices/device.dart';
import '../devices/discovery.dart';
import '../devices/discovery/thing_finder.dart' show suggestThingId;
import '../devices/wiz_pilot.dart';
import '../manifest/driver_manifest.dart';
import '../storage/database.dart';

/// The built-in WiZ driver the import adds bulbs with.
const wizDriverId = 'philips_wiz_udp';

/// Where the WiZ app's Local integrations export lives: its S3 bucket,
/// `wiz-s3-local-integration-*.amazonaws.com`.
final wizExportHost = RegExp(
  r'^wiz-s3-local-integration-[a-z0-9][a-z0-9.-]*\.amazonaws\.com$',
);

/// The largest export taken, far above a home of a few hundred bulbs.
const wizExportMaxBytes = 512 * 1024;

/// How long the download may take, connecting included.
const wizExportTimeout = Duration(seconds: 15);

/// The most devices one export may list.
const _maxDevices = 500;

/// How to get the export a link points at. Tests pass their own.
typedef WizExportFetch = Future<List<int>> Function(Uri url);

const _howToExport =
    'In the WiZ app: Settings, your home, Integrations, Local integrations, '
    'Export. Copy the link';

/// One device of a [WizExport].
class WizExportDevice {
  const WizExportDevice({
    required this.name,
    required this.type,
    this.mac,
    this.roomId,
    this.traits = const {},
  });

  final String name;
  final String type;

  /// Twelve lower case hex digits, or null when the export had none.
  final String? mac;
  final int? roomId;
  final Map<String, Object?> traits;

  bool get isLight => type == 'light';
}

/// The WiZ app's export of a home for local integration, checked. Its
/// [signingKey] is never shown: it has no `toJson` and no `toString`.
class WizExport {
  const WizExport._(this.homeName, this.signingKey, this.rooms, this.devices);

  final String homeName;
  final String signingKey;

  /// Room names by the WiZ room id.
  final Map<int, String> rooms;
  final List<WizExportDevice> devices;

  @override
  String toString() => 'WizExport($homeName, ${devices.length} devices)';

  /// [json] read as an export, or an `invalid` [ApiError] in plain words.
  /// No message carries a value from the export.
  static WizExport parse(Object? json) {
    if (json is! Map) throw _notExport('it is not a JSON object');
    final devices = json['devices'];
    if (devices is! List) throw _notExport('it has no list of devices');
    if (devices.length > _maxDevices) {
      throw _notExport('it lists more than $_maxDevices devices');
    }
    final key = json['udp_signing_key'];
    if (key is! String || !wizKeyPattern.hasMatch(key.trim())) {
      throw ApiError(
        'invalid',
        'This WiZ export has no usable home key (udp_signing_key). Export '
            'your home again. $_howToExport',
      );
    }
    final rooms = <int, String>{};
    final roomList = json['rooms'] ?? const [];
    if (roomList is! List) throw _notExport('its rooms are not a list');
    for (final r in roomList) {
      if (r case {'room_id': final int id, 'name': final String name}
          when name.trim().isNotEmpty) {
        rooms[id] = name.trim();
      }
    }
    final out = <WizExportDevice>[];
    for (final d in devices) {
      if (d is! Map) throw _notExport('a device in it is not an object');
      final mac = '${d['mac_address'] ?? ''}'
          .replaceAll(RegExp(r'[:\-\s]'), '')
          .toLowerCase();
      final validMac = RegExp(r'^[0-9a-f]{12}$').hasMatch(mac);
      final rawName = d['name'];
      final name = rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim()
          : 'WiZ light${validMac ? ' ${mac.substring(8).toUpperCase()}' : ''}';
      final traits = d['traits'];
      out.add(
        WizExportDevice(
          name: name,
          type: d['type'] is String ? d['type'] as String : 'unknown',
          mac: validMac ? mac : null,
          roomId: d['room_id'] is int ? d['room_id'] as int : null,
          traits: traits is Map
              ? Map<String, Object?>.from(traits)
              : const <String, Object?>{},
        ),
      );
    }
    final home = json['name'];
    return WizExport._(
      home is String && home.trim().isNotEmpty ? home.trim() : 'WiZ home',
      key.trim().toLowerCase(),
      rooms,
      out,
    );
  }

  static ApiError _notExport(String why) =>
      ApiError('invalid', 'That is not a WiZ home export: $why. $_howToExport');
}

/// [text] as the link to an export: https only, on the WiZ export bucket,
/// with no user name or other port. An `invalid` [ApiError] otherwise,
/// which never repeats the link (it is a key to the export for 15 minutes).
Uri wizExportUrl(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw ApiError('invalid', 'That is not a link. $_howToExport');
  }
  if (uri.scheme != 'https') {
    throw ApiError(
      'invalid',
      'The WiZ link must start with https://. $_howToExport',
    );
  }
  if (!wizExportHost.hasMatch(uri.host.toLowerCase()) ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    throw ApiError(
      'invalid',
      'That link is not a WiZ export link. $_howToExport',
    );
  }
  return uri;
}

/// The bytes of [body], refusing more than [maxBytes].
Future<List<int>> readCapped(Stream<List<int>> body, int maxBytes) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in body) {
    if (out.length + chunk.length > maxBytes) {
      throw ApiError(
        'invalid',
        'The WiZ link gave more than ${maxBytes ~/ 1024} KB, which is not a '
            'WiZ export',
      );
    }
    out.add(chunk);
  }
  return out.takeBytes();
}

/// Downloads the export at [url] with no redirects, a size cap and a
/// timeout. Errors are plain words and never name the link.
Future<List<int>> fetchWizExport(
  Uri url, {
  Duration timeout = wizExportTimeout,
  int maxBytes = wizExportMaxBytes,
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..userAgent = 'OmniFlow';
  try {
    return await () async {
      final request = await client.getUrl(url);
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode == 403 || response.statusCode == 404) {
        await response.drain<void>();
        throw ApiError(
          'invalid',
          'The WiZ link has run out. It works for about 15 minutes. Export '
              'again in the WiZ app and copy the new link',
        );
      }
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw ApiError(
          'unavailable',
          'The WiZ link did not give the export (HTTP '
              '${response.statusCode}). Try exporting again',
        );
      }
      if (response.contentLength > maxBytes) {
        await response.drain<void>();
        throw ApiError(
          'invalid',
          'The WiZ link gave more than ${maxBytes ~/ 1024} KB, which is not '
              'a WiZ export',
        );
      }
      return readCapped(response, maxBytes);
    }().timeout(timeout);
  } on TimeoutException {
    throw ApiError(
      'unavailable',
      'The WiZ link did not answer within ${timeout.inSeconds} seconds. '
          'Check this phone is online and try again',
    );
  } on IOException {
    throw ApiError(
      'unavailable',
      'Could not reach the WiZ link. Check this phone is online and try '
          'again',
    );
  } finally {
    client.close(force: true);
  }
}

/// `wiz.import {text? | url? | export?, windowMs?, port?}`: adds every
/// light of a WiZ home export that answers on this Wi-Fi.
///
/// `text` is what the user pasted or shared: the export link, or the
/// export itself as JSON. Each light is found by its MAC with the WiZ
/// driver's own broadcast discovery and added with the WiZ name and room
/// (the room is made in the house in view when missing). A bulb added
/// before, by the same MAC, gets its address, name and room updated. The
/// home key is stored as each bulb's `signingKey` secret, as `secret.set`
/// stores it, and never appears in the reply or an error.
class WizImport {
  WizImport(this._core, this._devices, this._hub, {WizExportFetch? fetch})
    : _fetch = fetch ?? fetchWizExport;

  final EngineCore _core;
  final DeviceCommands _devices;
  final HubRuntime _hub;
  final WizExportFetch _fetch;

  Future<Map<String, Object?>> run(Map<String, Object?> args) async {
    final export = await _exportOf(args);
    final windowMs = optIntArg(args, 'windowMs') ?? 3000;
    if (windowMs < 500 || windowMs > 30000) {
      throw ApiError('invalid', 'windowMs must be 500 to 30000');
    }
    final port = optIntArg(args, 'port');
    final manifest =
        _core.registry[wizDriverId] ??
        (throw ApiError('not_found', 'no driver $wizDriverId'));

    final skipped = <Map<String, Object?>>[
      for (final d in export.devices)
        if (!d.isLight)
          {'name': d.name, 'reason': 'It is a WiZ ${d.type}, not a light'}
        else if (d.mac == null)
          {'name': d.name, 'reason': 'The export gives no MAC address for it'},
    ];
    final lights = [
      for (final d in export.devices)
        if (d.isLight && d.mac != null) d,
    ];
    final found = <String, DiscoveredDevice>{};
    if (lights.isNotEmpty) {
      final sweep = await _core.discovery.discoverAll(
        [manifest],
        window: Duration(milliseconds: windowMs),
        methods: const {'udp_broadcast'},
        portOverride: port,
      );
      if (sweep.runs > 0 && sweep.failures.length == sweep.runs) {
        throw ApiError('unavailable', sweep.failures.join('. '));
      }
      for (final hit
          in sweep.found[manifest.id] ?? const <DiscoveredDevice>[]) {
        final mac = hit.stableId?.replaceAll(':', '').toLowerCase();
        if (mac != null) found[mac] = hit;
      }
    }

    final roomsBefore = {
      for (final r in await DriftRoomStore(_core.db).all()) r.id,
    };
    final added = <Map<String, Object?>>[];
    final updated = <Map<String, Object?>>[];
    final notFound = <Map<String, Object?>>[];
    final learn = <(String, DiscoveredDevice, WizExportDevice)>[];
    for (final light in lights) {
      final room = export.rooms[light.roomId];
      final hit = found[light.mac];
      if (hit == null) {
        notFound.add({
          'name': light.name,
          'room': ?room,
          'mac': light.mac,
          'reason':
              'It did not answer on this Wi-Fi. Check it is switched on and '
              'on the same Wi-Fi as this phone, then try again',
        });
        continue;
      }
      final devices = await DriftDeviceStore(_core.db).all();
      final known = devices
          .where(
            (d) =>
                d.driverId == manifest.id &&
                d.stableId?.replaceAll(':', '').toLowerCase() == light.mac,
          )
          .firstOrNull;
      try {
        final Device device;
        if (known != null) {
          device = await _update(known, hit, light.name, room, port);
          updated.add({
            'id': device.id,
            'name': device.name,
            'room': ?room,
            'host': device.host,
            if (known.host != device.host) 'movedFrom': known.host,
          });
        } else {
          final id = suggestThingId(light.name, {
            for (final d in devices) d.id,
          });
          await _devices.add({
            'id': id,
            'driver': manifest.id,
            'host': hit.host,
            if (port != null && port != manifest.transport.port) 'port': port,
            'stableId': light.mac,
            'name': light.name,
            'room': ?room,
          });
          device = await _core.device(id);
          added.add({
            'id': id,
            'name': light.name,
            'room': ?room,
            'host': hit.host,
          });
        }
        await _devices.secretSet({
          'deviceId': device.id,
          'key': wizSigningKey,
          'value': export.signingKey,
        });
        learn.add((device.id, hit, light));
      } on ApiError catch (e) {
        notFound.add({
          'name': light.name,
          'room': ?room,
          'mac': light.mac,
          'reason': 'OmniFlow could not add it: ${e.message}',
        });
      }
    }
    await Future.wait([
      for (final (id, hit, light) in learn) _describe(id, hit, light),
    ]);
    final roomsCreated = [
      for (final r in await DriftRoomStore(_core.db).all())
        if (!roomsBefore.contains(r.id)) r.name,
    ];
    return {
      'home': export.homeName,
      'added': added,
      'updated': updated,
      'notFound': notFound,
      if (skipped.isNotEmpty) 'skipped': skipped,
      'roomsCreated': roomsCreated,
      'message': _summary(added.length, updated.length, notFound.length),
    };
  }

  Future<WizExport> _exportOf(Map<String, Object?> args) async {
    final given = [
      'text',
      'url',
      'export',
    ].where((k) => args[k] != null).toList();
    if (given.length != 1) {
      throw ApiError(
        'invalid',
        'Give the WiZ export link or the exported file. $_howToExport',
      );
    }
    if (args['export'] != null) return WizExport.parse(args['export']);
    final text = (optStringArg(args, given.single) ?? '').trim();
    if (given.single == 'url') return _download(wizExportUrl(text));
    if (text.startsWith('{')) return WizExport.parse(_json(text));
    final link = RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://\S+').firstMatch(text);
    if (link == null) {
      throw ApiError(
        'invalid',
        'Paste the link the WiZ app gave you, or pick the exported file. '
            '$_howToExport',
      );
    }
    return _download(
      wizExportUrl(link.group(0)!.replaceAll(RegExp(r'''[.,)"'>]+$'''), '')),
    );
  }

  Future<WizExport> _download(Uri url) async => WizExport.parse(
    _json(utf8.decode(await _fetch(url), allowMalformed: true)),
  );

  static Object? _json(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      throw ApiError(
        'invalid',
        'That is not a WiZ home export: it is not JSON. $_howToExport',
      );
    }
  }

  /// [known] at the address [hit] answered from, with the WiZ name and
  /// room, keeping its id, settings and automations.
  Future<Device> _update(
    Device known,
    DiscoveredDevice hit,
    String name,
    String? room,
    int? port,
  ) async {
    final roomId = room == null
        ? known.room
        : await resolveRoom(
            _core,
            room,
            house: _core.houses.thingHouses[known.id] ?? _core.houses.defaultId,
          );
    final moved = known.host != hit.host;
    final device = await _core.devices.updateDevice(
      known.id,
      (d) => d
          .copyWith(name: name, host: hit.host, port: port)
          .placed(room: roomId, order: d.order),
    );
    if (moved && _hub.running) {
      _hub.stopLive(device.id);
      _hub.startLive(device, provision: false);
    }
    return device;
  }

  /// Stores what bulb [id] is, from the system config its discovery answer
  /// carried, its `getModelConfig`, and the export's traits, unless it was
  /// learnt before.
  Future<void> _describe(
    String id,
    DiscoveredDevice hit,
    WizExportDevice light,
  ) async {
    final device = await _core.device(id);
    if (device.settings[wizBulbSetting] is Map) return;
    final system = hit.reply['result'];
    Map? model;
    try {
      final reply = await _core.devices.sendCommand(id, {
        'method': 'getModelConfig',
        'params': <String, Object?>{},
      });
      if (reply.json?['result'] case final Map m) model = m;
    } on Exception {
      // Older firmware has no getModelConfig: the traits say the rest.
    }
    final bulb = wizBulbFromTraits(
      WizBulb.from(
        system: system is Map && system['moduleName'] is String ? system : null,
        model: model,
      ),
      light.traits,
    );
    if (bulb.module == null && bulb.kind == null && !bulb.hasWhiteRange) {
      return;
    }
    await _core.devices.updateDevice(
      id,
      (d) =>
          d.copyWith(settings: {...d.settings, wizBulbSetting: bulb.toJson()}),
    );
  }

  static String _summary(int added, int updated, int missing) {
    String lights(int n) => n == 1 ? '1 light' : '$n lights';
    final parts = [
      if (added > 0) 'Added ${lights(added)}',
      if (updated > 0)
        '${added > 0 ? 'updated' : 'Updated'} ${lights(updated)}',
    ];
    final done = parts.isEmpty ? 'No lights were added' : parts.join(' and ');
    if (missing == 0) return '$done.';
    return '$done. ${missing == 1 ? '1 was' : '$missing were'} not found on '
        'this Wi-Fi.';
  }
}

/// [bulb] with what the WiZ app's traits add where the bulb did not say:
/// the kind (colour, tunable white, dimmable white, or power only) and the
/// white range.
WizBulb wizBulbFromTraits(WizBulb bulb, Map<String, Object?> traits) {
  if (traits.isEmpty) return bulb;
  final kind =
      bulb.kind ??
      (traits['is_tunable_color'] == true
          ? 'rgb'
          : traits['is_tunable_white'] == true
          ? 'white'
          : traits['is_dimmable'] == true
          ? 'dimmable'
          : traits['is_dimmable'] == false
          ? 'socket'
          : null);
  var minK = bulb.minK;
  var maxK = bulb.maxK;
  final range = traits['white_range'];
  final white = kind == 'rgb' || kind == 'white';
  if (!bulb.hasWhiteRange &&
      white &&
      range is List &&
      range.length >= 2 &&
      range.every((v) => v is num)) {
    final values = [for (final v in range) (v as num).round()]..sort();
    minK = values.first;
    maxK = values.last;
  }
  return WizBulb(
    module: bulb.module,
    kind: kind,
    minK: minK,
    maxK: maxK,
    minDim: bulb.minDim,
  );
}

/// The driver a manifest-level check uses: whether [m] is the WiZ driver
/// the import adds with.
bool isWizImportDriver(DriverManifest m) =>
    m.id == wizDriverId && isWizPilot(m);
