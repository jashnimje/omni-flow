import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../devices/channels.dart';
import '../devices/device.dart';
import '../devices/device_service.dart';
import '../devices/discovery.dart';
import '../devices/http_channel.dart';
import '../devices/serial_channel.dart';
import '../devices/tuya_channel.dart';
import '../devices/wiz_push.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/driver_registry.dart';
import '../manifest/validation.dart';
import '../storage/database.dart';
import '../storage/secret_store.dart';
import '../template/template_renderer.dart';
import '../transports/host_exec.dart';
import '../transports/packet_tap.dart';
import '../transports/udp_transport.dart';

/// A failure the core API reports as a result instead of throwing.
class ApiError implements Exception {
  ApiError(this.type, this.message, {this.issues = const []});

  final String type;
  final String message;
  final List<ValidationIssue> issues;

  Map<String, Object?> toJson() => {
    'type': type,
    'message': message,
    if (issues.isNotEmpty) 'issues': issues.map((i) => i.toJson()).toList(),
  };
}

/// The engine behind one core API. Every caller (the CLI, the app's service,
/// later the MCP tools) sends a command name and a JSON object, and gets a
/// JSON object back: `{"ok": true, ...}` or `{"ok": false, "error": {...}}`.
class OmniEngine {
  OmniEngine._(
    this._db,
    this._lock,
    this.registry,
    this.devices,
    this._secrets,
    this.discovery,
    this._tap,
    this.serial,
    this._closers,
  ) {
    devices.events.listen(
      (e) => _emit({
        'event': 'device.stateChanged',
        'device': _deviceJson(e.device),
      }),
    );
    _tap?.stream.listen(
      (p) => _emit({
        'event': 'packet.captured',
        'transport': p.transport,
        'direction': p.direction.name,
        'remote': p.remote,
        'text': p.text,
        'at': p.timestamp.toUtc().toIso8601String(),
      }),
    );
  }

  /// Opens the engine whose data lives in [home].
  static Future<OmniEngine> open({
    required Directory home,
    required SecretStore secrets,
    PacketTap? tap,
    Future<List<InternetAddress>> Function()? discoveryTargets,
  }) async {
    await home.create(recursive: true);
    final file = File('${home.path}/omniflow.sqlite');
    final lock = await DatabaseLock.acquire(file);
    final db = OmniDatabase.file(file);
    final registry = DriverRegistry.withBuiltIns();
    for (final json in await DriftManifestStore(db).all()) {
      registry.register(jsonDecode(json));
    }
    final udp = await UdpTransport.bind(tap: tap);
    final tuya = TuyaChannel(secrets, tap: tap);
    final serial = SerialChannel(tap: tap);
    final discovery = UdpDiscovery(udp, targets: discoveryTargets);
    final devices = DeviceService(
      registry: registry,
      store: DriftDeviceStore(db),
      locator: discovery.locator,
      channels: {
        TransportType.udp: UdpJsonChannel(udp),
        TransportType.tuya: tuya,
        TransportType.http: HttpChannel(tap: tap),
        TransportType.serial: serial,
        TransportType.exec: ExecChannel(hostExecutors(secrets)),
      },
    );
    return OmniEngine._(
      db,
      lock,
      registry,
      devices,
      secrets,
      discovery,
      tap,
      serial,
      [() async => udp.close(), tuya.close, serial.close, devices.close],
    );
  }

  final OmniDatabase _db;
  final DatabaseLock _lock;
  final DriverRegistry registry;
  final DeviceService devices;
  final SecretStore _secrets;
  final UdpDiscovery discovery;
  final PacketTap? _tap;
  final SerialChannel serial;
  final List<Future<void> Function()> _closers;
  final _events = StreamController<Map<String, Object?>>.broadcast();
  WizPushManager? _wizPush;

  /// Everything the engine reports as it happens, as JSON messages:
  /// `device.stateChanged`, `wiz.firstBeat`, and `packet.captured` when the
  /// engine was opened with a packet tap.
  Stream<Map<String, Object?>> get events => _events.stream;

  void _emit(Map<String, Object?> event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Starts live state from every WiZ device that has a stable id (its MAC).
  Future<int> startWizPush({int listenPort = 38900}) async {
    final bulbs = [
      for (final d in await DriftDeviceStore(_db).all())
        if (d.driverId == 'philips_wiz_udp' && d.stableId != null) d,
    ];
    final push = _wizPush ??= await WizPushManager.start(
      devices: devices,
      listenPort: listenPort,
      tap: _tap,
    );
    push.firstBeats.listen(
      (b) => _emit({
        'event': 'wiz.firstBeat',
        'host': b.host,
        if (b.mac != null) 'mac': b.mac,
      }),
    );
    await push.watch(bulbs);
    return bulbs.length;
  }

  late final Map<
    String,
    Future<Map<String, Object?>> Function(Map<String, Object?> args)
  >
  _commands = {
    'driver.list': (_) async => {
      'drivers': [
        for (final m in registry.all)
          {
            'id': m.id,
            'name': m.name,
            'category': m.category,
            'transport': m.transport.type.wireName,
            'builtIn': registry.isBuiltIn(m.id),
            'capabilities': m.capabilities.map((c) => c.id).toList(),
          },
      ],
    },
    'driver.validate': (args) async {
      final m = DriverManifest.parse(_object(args, 'manifest'));
      return {'id': m.id, 'highRisk': m.isHighRisk};
    },
    'driver.register': (args) async {
      final json = _object(args, 'manifest');
      final m = registry.register(json);
      await DriftManifestStore(_db)
          .put(m.id, jsonEncode(json), DateTime.now().toUtc());
      return {'id': m.id, 'highRisk': m.isHighRisk};
    },
    'device.add': _addDevice,
    'device.discover': (args) async {
      final driverId = _string(args, 'driver');
      final manifest = registry[driverId];
      if (manifest == null) throw ApiError('not_found', 'no driver $driverId');
      final windowMs = args['windowMs'];
      if (manifest.transport.type == TransportType.serial) {
        return {'found': await serial.discover(manifest)};
      }
      final found = await discovery.discover(
        manifest,
        window: Duration(milliseconds: windowMs is int ? windowMs : 2000),
        portOverride: args['port'] as int?,
      );
      final known = {
        for (final d in await DriftDeviceStore(_db).all())
          if (d.driverId == driverId && d.stableId != null)
            d.stableId!.toLowerCase(): d.id,
      };
      return {
        'found': [
          for (final f in found)
            {
              ...f.toJson(),
              if (known[f.stableId?.toLowerCase()] != null)
                'knownAs': known[f.stableId?.toLowerCase()],
            },
        ],
      };
    },
    'device.list': (_) async => {
      'devices': [
        for (final d in await DriftDeviceStore(_db).all()) _deviceJson(d),
      ],
    },
    'device.get': (args) async => {
      'device': _deviceJson(await _device(_string(args, 'id'))),
    },
    'device.remove': (args) async => {
      'removed': await DriftDeviceStore(_db).remove(_string(args, 'id')),
    },
    'device.invoke': (args) async {
      final result = await devices.invoke(
        _string(args, 'id'),
        _string(args, 'capability'),
        args['params'] == null ? const {} : _object(args, 'params'),
      );
      return {'device': _deviceJson(result.device), 'reply': result.reply.json};
    },
    'device.refresh': (args) async => {
      'device': _deviceJson(await devices.refreshState(_string(args, 'id'))),
    },
    'secret.set': (args) async {
      final device = await _device(_string(args, 'deviceId'));
      final key = _string(args, 'key');
      final manifest = registry[device.driverId]!;
      if (!manifest.settings.any((s) => s.key == key && s.secret)) {
        throw ApiError(
          'invalid',
          '$key is not a secret setting of ${manifest.id}',
        );
      }
      await _secrets.write(
        deviceSecretKey(device.id, key),
        _string(args, 'value'),
      );
      return {'stored': deviceSecretKey(device.id, key)};
    },
  };

  Iterable<String> get commandNames => _commands.keys;

  /// Runs [command] with [args]. Never throws: every failure becomes an error result.
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> args,
  ) async {
    final handler = _commands[command];
    if (handler == null) {
      return _failure(ApiError('unknown_command', 'no command $command'));
    }
    try {
      return {'ok': true, ...await handler(args)};
    } on ApiError catch (e) {
      return _failure(e);
    } on ValidationException catch (e) {
      return _failure(ApiError('invalid', e.subject, issues: e.issues));
    } on DeviceNotFoundException catch (e) {
      return _failure(ApiError('not_found', e.message));
    } on TransportTimeoutException catch (e) {
      return _failure(ApiError('timeout', e.message));
    } on CommandFailedException catch (e) {
      return _failure(ApiError('device_error', e.message));
    } on MissingSecretException catch (e) {
      return _failure(
        ApiError(
          'missing_secret',
          'no secret stored for ${e.key}. Set it with omni secret set',
        ),
      );
    } on CommandTimeoutException catch (e) {
      return _failure(ApiError('timeout', e.toString()));
    } on TemplateException catch (e) {
      return _failure(ApiError('template', e.message));
    } on ArgumentError catch (e) {
      return _failure(ApiError('invalid', '${e.message}'));
    }
  }

  Future<Map<String, Object?>> _addDevice(Map<String, Object?> args) async {
    final id = _string(args, 'id');
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(id)) {
      throw ApiError('invalid', 'device id must be lower snake case');
    }
    final driverId = _string(args, 'driver');
    final manifest = registry[driverId];
    if (manifest == null) throw ApiError('not_found', 'no driver $driverId');
    final settings = args['settings'] == null
        ? <String, Object?>{}
        : _object(args, 'settings');
    for (final key in settings.keys) {
      final spec = manifest.settings.where((s) => s.key == key).firstOrNull;
      if (spec == null) {
        throw ApiError('invalid', '$key is not a setting of $driverId');
      }
      if (spec.secret) {
        throw ApiError(
          'invalid',
          '$key is a secret. Store it with omni secret set, never in device settings',
        );
      }
    }
    final port = args['port'];
    if (port != null && (port is! int || port < 1 || port > 65535)) {
      throw ApiError('invalid', 'port must be 1 to 65535');
    }
    final device = Device(
      id: id,
      name: args['name'] is String ? args['name'] as String : id,
      driverId: driverId,
      host: _string(args, 'host'),
      port: port as int?,
      room: args['room'] as String?,
      stableId: args['stableId'] as String?,
      settings: settings,
    );
    await DriftDeviceStore(_db).put(device);
    final missingSecrets = [
      for (final s in manifest.settings.where((s) => s.secret))
        if (await _secrets.read(deviceSecretKey(id, s.key)) == null) s.key,
    ];
    return {
      'device': _deviceJson(device),
      if (missingSecrets.isNotEmpty) 'missingSecrets': missingSecrets,
    };
  }

  Future<Device> _device(String id) async {
    final device = await DriftDeviceStore(_db).get(id);
    if (device == null) throw ApiError('not_found', 'no device $id');
    return device;
  }

  static Map<String, Object?> _deviceJson(Device d) => {
    'id': d.id,
    'name': d.name,
    'driver': d.driverId,
    'host': d.host,
    if (d.port != null) 'port': d.port,
    if (d.room != null) 'room': d.room,
    if (d.stableId != null) 'stableId': d.stableId,
    'settings': d.settings,
    'state': d.state,
    if (d.lastSeen != null) 'lastSeen': d.lastSeen!.toIso8601String(),
  };

  static String _string(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is String && value.isNotEmpty) return value;
    throw ApiError('invalid', '$key is required');
  }

  static Map<String, Object?> _object(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is Map) return Map<String, Object?>.from(value);
    throw ApiError('invalid', '$key must be an object');
  }

  static Map<String, Object?> _failure(ApiError e) => {
    'ok': false,
    'error': e.toJson(),
  };

  Future<void> close() async {
    await _wizPush?.stop();
    for (final close in _closers) {
      await close();
    }
    await _db.close();
    await _lock.release();
    await _events.close();
  }
}
