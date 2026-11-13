import 'dart:async';

import 'api_error.dart';
import 'error_of.dart';
import 'device_history.dart';
import '../dag/canonical.dart';
import '../dag/flow_engine.dart';
import '../devices/adb/adb_channel.dart';
import '../devices/board.dart';
import '../devices/device.dart';
import '../devices/device_service.dart';
import '../devices/discovery.dart';
import '../devices/http_channel.dart';
import '../devices/mqtt_channel.dart';
import '../devices/serial_channel.dart';
import '../devices/tv/tv_channel.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/driver_registry.dart';
import '../manifest/validation.dart';
import '../storage/database.dart';
import '../storage/secret_store.dart';
import '../transports/packet_tap.dart';

/// A stored record that could not be loaded, as a load issue.
Map<String, Object?> loadIssue(String kind, Object? id, Object error) => {
  'kind': kind,
  'id': ?id,
  'error': switch (error) {
    ApiError e => e.message,
    ArgumentError e => '${e.message}',
    ValidationException e =>
      '${e.subject}: ${e.issues.map((i) => i.toJson()).join('; ')}',
    _ => '$error',
  },
};

/// What every part of the engine shares: the stores and channels it opened,
/// the event stream, the background work in flight, and the load issues.
class EngineCore {
  EngineCore({
    required this.db,
    required this.registry,
    required this.devices,
    required this.secrets,
    required this.discovery,
    required this.tap,
    required this.serial,
    required this.mqtt,
    required this.boardChannel,
    required this.http,
    required this.tv,
    required this.adb,
  });

  final OmniDatabase db;
  final DriverRegistry registry;
  final DeviceService devices;
  final SecretStore secrets;
  final DeviceDiscovery discovery;
  final PacketTap? tap;
  final SerialChannel serial;
  final MqttChannel mqtt;
  final BoardChannel boardChannel;
  final HttpChannel http;
  final TvWebSocketChannel tv;
  final AdbChannel adb;
  late final FlowEngine flows;

  /// The user drivers an agent registered and the user has not approved:
  /// everything they drive is high risk.
  final agentDrivers = <String>{};

  final _events = StreamController<Map<String, Object?>>.broadcast();

  /// Everything the engine reports as it happens, as JSON messages.
  Stream<Map<String, Object?>> get events => _events.stream;

  void emit(Map<String, Object?> event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> closeEvents() => _events.close();

  /// The thing [thing] raised the event [key], which `on` triggers with
  /// `event: true` fire on.
  void raiseEvent(String thing, String key, Map<String, Object?> payload) =>
      emit({
        'event': 'thing.event',
        'thing': thing,
        'key': key,
        'payload': payload,
      });

  final _pending = <Future<void>>{};

  /// Runs background work so a failure becomes an event, and so close()
  /// waits for it instead of closing the database under it.
  void track(Future<void> work) {
    final tracked = work.catchError((Object e) {
      emit({'event': 'board.error', ...errorFields(e)});
    });
    _pending.add(tracked);
    tracked.whenComplete(() => _pending.remove(tracked));
  }

  /// Waits until no tracked work is left, including work started meanwhile.
  Future<void> settle() async {
    while (_pending.isNotEmpty) {
      await Future.wait([..._pending]);
    }
  }

  /// Stored records that could not be loaded, by kind (driver, zone, flow).
  /// They stay in the database and are reported, so one bad row never
  /// keeps the engine from opening.
  final issues = <String, List<Map<String, Object?>>>{};

  List<Map<String, Object?>> get loadIssues => [
    for (final list in issues.values) ...list,
  ];

  void setIssues(String kind, List<Map<String, Object?>> issues) {
    final before = {
      for (final i in this.issues[kind] ?? const []) canonicalJson(i),
    };
    this.issues[kind] = issues;
    for (final i in issues) {
      if (!before.contains(canonicalJson(i))) {
        emit({'event': 'engine.loadIssue', ...i});
      }
    }
  }

  Future<Device> device(String id) async {
    final device = await DriftDeviceStore(db).get(id);
    if (device == null) throw ApiError('not_found', 'no device $id');
    return device;
  }

  /// A board says hello every 30 seconds.
  static const _boardOnlineWindow = Duration(seconds: 90);

  /// How long a device may go unseen and still count as online: three state
  /// polls, or three board hellos. Null when nothing reports it regularly.
  Duration? _onlineWindow(DriverManifest? manifest) {
    if (isBoardDriver(manifest)) return _boardOnlineWindow;
    final seconds = manifest?.statePoll?['intervalSeconds'];
    return seconds is int && seconds > 0
        ? Duration(seconds: 3 * seconds)
        : null;
  }

  /// Every device's state changes. The engine feeds it device events.
  late final history = DeviceHistoryLog(this);

  /// Each room's name by id, so device JSON names the room without a read.
  final roomNames = <String, String>{};

  Future<void> loadRooms() async {
    roomNames
      ..clear()
      ..addEntries([
        for (final r in await DriftRoomStore(db).all()) MapEntry(r.id, r.name),
      ]);
  }

  Map<String, Object?> deviceJson(Device d) {
    final manifest = registry[d.driverId];
    final window = _onlineWindow(manifest);
    return {
      'id': d.id,
      'name': d.name,
      'driver': d.driverId,
      if (manifest != null) 'category': manifest.category,
      'icon': ?manifest?.icon,
      'host': d.host,
      if (d.port != null) 'port': d.port,
      if (d.room != null) ...{
        'roomId': d.room,
        'room': roomNames[d.room] ?? d.room,
      },
      'favourite': d.favourite,
      'order': ?d.order,
      if (d.stableId != null) 'stableId': d.stableId,
      'board': isBoardDriver(manifest),
      if (manifest?.pairingSpec case final pairing?)
        'pairing': {
          'method': pairing.method.wireName,
          'prompt': pairingPrompt(pairing, d),
        },
      if (window != null) 'online': d.isOnline(DateTime.now(), window),
      'settings': d.settings,
      'state': d.state,
      if (d.lastSeen != null) 'lastSeen': d.lastSeen!.toIso8601String(),
    };
  }
}

/// What the user does to pair [device], shown before `device.pair` runs.
String pairingPrompt(
  PairingSpec pairing,
  Device device,
) => switch (pairing.method) {
  PairingMethod.adb =>
    'Turn on network or ADB debugging in the TV Developer options. When '
        'the TV asks "Allow USB debugging?", tick "Always allow from this '
        'computer" and choose Allow within 60 seconds',
  PairingMethod.tv =>
    'Keep the TV on. When it asks whether to allow OmniFlow, choose '
        'Allow or Accept within 60 seconds',
  PairingMethod.hueBridge =>
    'Press the round link button on the Hue bridge at ${device.host}, '
        'then start pairing within 30 seconds',
  PairingMethod.secret =>
    '${pairing.instructions ?? 'Get the ${pairing.secret} from the device'}. '
        'Then store it with: omni secret set ${device.id} ${pairing.secret}',
};
