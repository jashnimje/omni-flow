import 'dart:convert';

import 'api_error.dart';
import 'board_runtime.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'hub_runtime.dart';
import 'stored_flows.dart';
import 'thing_setup.dart';
import 'things_runtime.dart';
import '../devices/board.dart';
import '../devices/device.dart';
import '../devices/device_service.dart';
import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/driver_registry.dart';
import '../storage/database.dart';
import '../storage/secret_store.dart';
import '../template/template_renderer.dart';

/// The driver, device and secret commands: register drivers, add, find,
/// list, invoke and remove devices, and store a device's secrets.
class DeviceCommands {
  DeviceCommands(
    this._core,
    this._boards,
    this._hub,
    this._stored,
    this._things,
  );

  final EngineCore _core;
  final BoardRuntime _boards;
  final HubRuntime _hub;
  final StoredFlows _stored;
  final ThingsRuntime _things;

  OmniDatabase get _db => _core.db;
  DriverRegistry get _registry => _core.registry;
  DeviceService get _devices => _core.devices;

  Future<Map<String, Object?>> driverList(Map<String, Object?> _) async => {
    'drivers': [
      for (final m in _registry.all)
        {
          'id': m.id,
          'name': m.name,
          'category': m.category,
          'transport': m.transport.type.wireName,
          'builtIn': _registry.isBuiltIn(m.id),
          'highRisk': m.isHighRisk,
          'board': isBoardDriver(m),
          if (m.pairingSpec case final p?) 'pairing': p.method.wireName,
          'settings': [
            for (final s in m.settings)
              {'key': s.key, 'label': s.label, if (s.secret) 'secret': true},
          ],
          'capabilities': m.capabilities.map((c) => c.id).toList(),
        },
    ],
    'loadIssues': _core.loadIssues,
  };

  Future<Map<String, Object?>> driverValidate(Map<String, Object?> args) async {
    final m = DriverManifest.parse(objectArg(args, 'manifest'));
    return {'id': m.id, 'highRisk': m.isHighRisk};
  }

  Future<Map<String, Object?>> driverRegister(Map<String, Object?> args) async {
    final json = objectArg(args, 'manifest');
    final m = _registry.register(json);
    await DriftManifestStore(_db)
        .put(m.id, jsonEncode(json), DateTime.now().toUtc());
    await _stored.reloadFlows();
    return {'id': m.id, 'highRisk': m.isHighRisk};
  }

  /// A scan by UID picks one tag, so two tags never share a UID. The UID
  /// is stored the way `tag.save` and a scan normalize it.
  Future<void> _checkTagUid(String id, Map<String, Object?> settings) async {
    if (settings['uid'] == null) return;
    final uid =
        normalizeUid(settings['uid']) ??
        (throw ApiError(
          'invalid',
          'uid must be 4 to 10 bytes of hex, like 04:A2:2B:1C',
        ));
    settings['uid'] = uid;
    final holder = (await DriftDeviceStore(_db).all())
        .where(
          (d) =>
              d.id != id &&
              d.driverId == nfcTagDriverId &&
              normalizeUid(d.settings['uid']) == uid,
        )
        .firstOrNull;
    if (holder != null) {
      throw ApiError('exists', 'the tag ${holder.id} has that uid');
    }
  }

  Future<Map<String, Object?>> add(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(id)) {
      throw ApiError('invalid', 'device id must be lower snake case');
    }
    final driverId = stringArg(args, 'driver');
    final manifest = _registry[driverId];
    if (manifest == null) throw ApiError('not_found', 'no driver $driverId');
    final replace = args['replace'] == true;
    if (!replace && await DriftDeviceStore(_db).get(id) != null) {
      throw ApiError(
        'exists',
        'a device $id exists. Remove it first, or pass replace: true',
      );
    }
    final settings = args['settings'] == null
        ? <String, Object?>{}
        : objectArg(args, 'settings');
    _checkSettings(manifest, settings);
    if (driverId == nfcTagDriverId) await _checkTagUid(id, settings);
    final port = args['port'];
    if (port != null && (port is! int || port < 1 || port > 65535)) {
      throw ApiError('invalid', 'port must be 1 to 65535');
    }
    final virtual = manifest.transport.type == TransportType.virtual;
    final stableId =
        optStringArg(args, 'stableId') ??
        stableIdFromSettings(manifest, settings);
    final device = Device(
      id: id,
      name: optStringArg(args, 'name') ?? id,
      driverId: driverId,
      host: virtual
          ? optStringArg(args, 'host') ?? virtualHost
          : stringArg(args, 'host'),
      port: port as int?,
      room: optStringArg(args, 'room'),
      stableId: stableId,
      settings: settingsWithStableId(manifest, settings, stableId),
      state: initialThingState(driverId),
    );
    if (driverId == placeDriverId) zoneOfPlace(device);
    if (replace) {
      _hub.stopLive(id);
      _boards.markNotSetUp(id);
      _core.tv.forget(id);
      _core.adb.forget(id);
      _pairedHere.remove(id);
    }
    await DriftDeviceStore(_db).put(device);
    if (virtual) await _things.reload();
    final missingSecrets = [
      for (final s in manifest.settings.where((s) => s.secret))
        if (await _core.secrets.read(deviceSecretKey(id, s.key)) == null) s.key,
    ];
    final missingSettings = missingRequiredSettings(manifest, device.settings);
    if (_hub.running) _hub.startLive(device, provision: false);
    Map<String, Object?>? board;
    String? boardError;
    if (isBoardDriver(manifest) && args['provision'] != false) {
      try {
        board = await _boards.provisionBoard(id);
      } catch (e) {
        boardError = e is ApiError ? e.message : '$e';
      }
    } else if (_hub.running && isBoardDriver(manifest)) {
      _core.track(_boards.provisionQuietly(id));
    }
    await _stored.reloadFlows();
    final added = await _core.device(id);
    return {
      'device': _core.deviceJson(added),
      if (missingSecrets.isNotEmpty) 'missingSecrets': missingSecrets,
      if (missingSettings.isNotEmpty) 'missingSettings': missingSettings,
      'provisioned': ?board,
      'provisionError': ?boardError,
      'next': await _nextFor(added, manifest),
    };
  }

  /// Devices whose pairing stores no secret (ADB) that this engine paired,
  /// as `thing.next {paired: true}` reported after `device.pair`. A restart
  /// forgets them, and the device then counts as paired once it answers.
  final _pairedHere = <String>{};

  Future<Map<String, Object?>> _nextFor(
    Device device,
    DriverManifest manifest,
  ) => nextSetupStep(
    device,
    manifest,
    _core.secrets,
    pairedHere: _pairedHere.contains(device.id),
  );

  /// `thing.next {id, paired?}`: the setup step [id] is on now, so a client
  /// can resume adding it. `paired: true` says `device.pair` just succeeded;
  /// it counts only for a pairing that stores no secret to check (ADB).
  Future<Map<String, Object?>> next(Map<String, Object?> args) async {
    final device = await _core.device(stringArg(args, 'id'));
    final manifest =
        _registry[device.driverId] ??
        (throw ApiError('not_found', 'no driver ${device.driverId}'));
    final paired = args['paired'];
    if (paired != null && paired is! bool) {
      throw ApiError('invalid', 'paired must be true or false');
    }
    if (paired == true &&
        manifest.pairingSpec != null &&
        pairingProofSecret(manifest) == null) {
      _pairedHere.add(device.id);
    }
    return {
      'device': _core.deviceJson(device),
      'next': await _nextFor(device, manifest),
    };
  }

  /// `thing.configure {id, settings, provision?}`: merges plain settings
  /// into a device (null removes one), checked as `device.add` checks them,
  /// and returns the next step. New board pins are sent to the board.
  Future<Map<String, Object?>> configure(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final device = await _core.device(id);
    final manifest =
        _registry[device.driverId] ??
        (throw ApiError('not_found', 'no driver ${device.driverId}'));
    final changes = objectArg(args, 'settings');
    if (changes.isEmpty) throw ApiError('invalid', 'settings is empty');
    final merged = {...device.settings};
    for (final MapEntry(:key, :value) in changes.entries) {
      value == null ? merged.remove(key) : merged[key] = value;
    }
    _checkSettings(manifest, {
      for (final key in changes.keys) key: merged[key],
    }, pins: merged['pins']);
    if (device.driverId == nfcTagDriverId && changes.containsKey('uid')) {
      await _checkTagUid(id, merged);
    }
    final stableId = device.stableId ?? stableIdFromSettings(manifest, merged);
    final proposed = device.copyWith(
      stableId: stableId,
      settings: settingsWithStableId(manifest, merged, stableId),
    );
    if (device.driverId == placeDriverId) zoneOfPlace(proposed);
    final updated = await _devices.updateDevice(
      id,
      (d) => d.copyWith(stableId: stableId, settings: proposed.settings),
    );
    if (manifest.transport.type == TransportType.virtual) {
      await _things.reload();
    }
    if (_hub.running) {
      _hub.stopLive(id);
      _hub.startLive(updated, provision: false);
    }
    Map<String, Object?>? board;
    String? boardError;
    if (isBoardDriver(manifest) && changes.containsKey('pins')) {
      _boards.markNotSetUp(id);
      if (args['provision'] != false) {
        try {
          board = await _boards.provisionBoard(id);
        } catch (e) {
          boardError = e is ApiError ? e.message : '$e';
        }
      } else if (_hub.running) {
        _core.track(_boards.provisionQuietly(id));
      }
    }
    await _stored.reloadFlows();
    final now = await _core.device(id);
    return {
      'device': _core.deviceJson(now),
      'provisioned': ?board,
      'provisionError': ?boardError,
      'next': await _nextFor(now, manifest),
    };
  }

  /// Plain settings of [manifest] only, never a secret. A board's [pins]
  /// (all of them, when only some settings are checked) must parse.
  void _checkSettings(
    DriverManifest manifest,
    Map<String, Object?> settings, {
    Object? pins,
  }) {
    for (final key in settings.keys) {
      final spec = manifest.settings.where((s) => s.key == key).firstOrNull;
      if (spec == null) {
        throw ApiError('invalid', '$key is not a setting of ${manifest.id}');
      }
      if (spec.secret) {
        throw ApiError(
          'invalid',
          '$key is a secret. Store it with omni secret set, never in device settings',
        );
      }
    }
    if (isBoardDriver(manifest)) {
      parseBoardPins(
        pins ?? settings['pins'],
        reserved: {for (final c in manifest.capabilities) c.id},
      );
    }
    if (manifest.id == nfcTagDriverId &&
        settings['uid'] != null &&
        normalizeUid(settings['uid']) == null) {
      throw ApiError('invalid', 'uid must be hex, like 04:A2:2B:1C');
    }
  }

  Future<Map<String, Object?>> discover(Map<String, Object?> args) async {
    final driverId = stringArg(args, 'driver');
    final manifest = _registry[driverId];
    if (manifest == null) throw ApiError('not_found', 'no driver $driverId');
    if (manifest.transport.type == TransportType.serial) {
      return {'found': await _core.serial.discover(manifest)};
    }
    final onUsb = isBoardDriver(manifest) && args['serial'] != false
        ? await _core.serial.discover(
            manifest,
            window: const Duration(milliseconds: 3000),
          )
        : const <Map<String, Object?>>[];
    final found = await _core.discovery.discover(
      manifest,
      window: Duration(milliseconds: optIntArg(args, 'windowMs') ?? 2000),
      portOverride: optIntArg(args, 'port'),
    );
    final known = {
      for (final d in await DriftDeviceStore(_db).all())
        if (d.driverId == driverId && d.stableId != null)
          d.stableId!.toLowerCase(): d.id,
    };
    return {
      'found': [
        for (final f in [...onUsb, for (final f in found) f.toJson()])
          {
            ...f,
            if (known['${f['stableId']}'.toLowerCase()] != null)
              'knownAs': known['${f['stableId']}'.toLowerCase()],
          },
      ],
    };
  }

  Future<Map<String, Object?>> list(Map<String, Object?> args) async => {
    'devices': [
      for (final d in await DriftDeviceStore(_db).all())
        if (args['room'] == null || args['room'] == d.room)
          {
            ..._core.deviceJson(d),
            if (args['withCapabilities'] == true)
              'capabilities': _capabilitiesJson(d),
          },
    ],
  };

  Future<Map<String, Object?>> get(Map<String, Object?> args) async => {
    'device': _core.deviceJson(await _core.device(stringArg(args, 'id'))),
  };

  Future<Map<String, Object?>> remove(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final device = await DriftDeviceStore(_db).get(id);
    _hub.stopLive(id);
    _boards.forget(id);
    // The held TV session and its refusal cooldown would otherwise carry
    // over to a device re-added under the same id, which has no key.
    _core.tv.forget(id);
    _core.adb.forget(id);
    _core.flows.deviceStates.remove(id);
    _pairedHere.remove(id);
    await _core.serial.release(id);
    final removed = await _devices.removeDevice(id);
    for (final s
        in _registry[device?.driverId ?? '']?.settings ??
            const <SettingSpec>[]) {
      if (s.secret) await _core.secrets.delete(deviceSecretKey(id, s.key));
    }
    if (_registry[device?.driverId ?? '']?.transport.type ==
        TransportType.virtual) {
      await _things.reload();
    }
    final disabled = <String>[];
    for (final r in await DriftFlowStore(_db).all()) {
      if (!r.enabled || !StoredFlows.mentionsThing(r.json['nodes'], id)) {
        continue;
      }
      await _stored.put(
        r.json['id'] as String,
        {...StoredFlows.flowJsonOf(r), 'enabled': false},
        enabled: false,
        approved: r.approved,
        trusted: StoredFlows.trustedOf(r),
      );
      disabled.add(r.json['id'] as String);
    }
    await _stored.reloadFlows();
    return {'removed': removed, 'flows': disabled};
  }

  Future<Map<String, Object?>> invoke(Map<String, Object?> args) async {
    final result = await _devices.invoke(
      stringArg(args, 'id'),
      stringArg(args, 'capability'),
      args['params'] == null ? const {} : objectArg(args, 'params'),
      allowPairing: args['allowPairing'] != false,
    );
    return {
      'device': _core.deviceJson(result.device),
      'reply': result.reply.json,
    };
  }

  Future<Map<String, Object?>> refresh(Map<String, Object?> args) async => {
    'device': _core.deviceJson(
      await _devices.refreshState(stringArg(args, 'id')),
    ),
  };

  Future<Map<String, Object?>> secretSet(Map<String, Object?> args) async {
    final device = await _core.device(stringArg(args, 'deviceId'));
    final key = stringArg(args, 'key');
    final manifest = _registry[device.driverId]!;
    if (!manifest.settings.any((s) => s.key == key && s.secret)) {
      throw ApiError(
        'invalid',
        '$key is not a secret setting of ${manifest.id}',
      );
    }
    await _core.secrets.write(
      deviceSecretKey(device.id, key),
      stringArg(args, 'value'),
    );
    // The broker connection read the old password, so it reconnects now.
    if (manifest.transport.type == TransportType.mqtt) {
      await _core.mqtt.resetBroker(device, manifest);
    }
    // A TV connection was opened with the old key or certificate pin.
    if (manifest.transport.type == TransportType.websocket) {
      _core.tv.forget(device.id);
    }
    return {'stored': deviceSecretKey(device.id, key)};
  }

  /// Each capability of a device with the params it accepts, for UIs and agents.
  List<Map<String, Object?>> _capabilitiesJson(Device device) => [
    for (final c
        in manifestFor(_registry, device)?.capabilities ??
            const <CapabilitySpec>[])
      {
        'id': c.id,
        'type': c.type.wireName,
        'label': c.label,
        'highRisk': _registry[device.driverId]!.isHighRisk,
        if (stateKeyOf(c.stateJsonPath) != null)
          'stateKey': stateKeyOf(c.stateJsonPath),
        'params': {
          for (final p in c.params.entries)
            p.key: {
              'type': p.value.type.wireName,
              if (p.value.min != null) 'min': p.value.min,
              if (p.value.max != null) 'max': p.value.max,
              if (p.value.unit != null) 'unit': p.value.unit,
              if (p.value.values.isNotEmpty) 'values': p.value.values,
              if (p.value.optional) 'optional': true,
            },
        },
      },
  ];
}

/// The stable id a driver's discovery reads from a device setting
/// (`idSetting`), so a device added by hand still heals by it: a Tuya plug's
/// `devId` is the `gwId` it announces.
String? stableIdFromSettings(
  DriverManifest manifest,
  Map<String, Object?> settings,
) {
  for (final spec in manifest.discovery) {
    final value = settings[spec.config['idSetting']];
    if (value is String && value.isNotEmpty) return value;
  }
  return null;
}

/// [settings] with each empty `idSetting` filled from [stableId], so a Tuya
/// plug picked from a scan gets the `devId` it announced as its `gwId`.
Map<String, Object?> settingsWithStableId(
  DriverManifest manifest,
  Map<String, Object?> settings,
  String? stableId,
) {
  if (stableId == null || stableId.isEmpty) return settings;
  final filled = {...settings};
  for (final spec in manifest.discovery) {
    final key = spec.config['idSetting'];
    if (key is! String) continue;
    final value = filled[key];
    if (value == null || (value is String && value.isEmpty)) {
      filled[key] = stableId;
    }
  }
  return filled;
}

/// The plain settings a device of [manifest] cannot work without and does
/// not have: those its templates read with no fallback, and its discovery
/// `idSetting`, which the channel addresses the device by.
List<String> missingRequiredSettings(
  DriverManifest manifest,
  Map<String, Object?> settings,
) {
  bool present(String key) {
    final value = settings[key];
    return value != null && !(value is String && value.isEmpty);
  }

  final declared = {
    for (final s in manifest.settings)
      if (!s.secret) s.key,
  };
  final required = <String>{
    for (final spec in manifest.discovery)
      if (spec.config['idSetting'] case final String key) key,
  };
  final templates = [
    for (final c in manifest.capabilities) c.command,
    manifest.statePoll,
    manifest.statePush,
  ];
  for (final placeholder in templates.expand(placeholdersIn)) {
    if (placeholder.alternatives.any((t) => t is LiteralTerm)) continue;
    final keys = [
      for (final path in placeholder.paths)
        if (path.startsWith('device.')) path.substring(7).split('.').first,
    ];
    if (keys.length != placeholder.alternatives.length) continue;
    if (!keys.any(present)) required.add(keys.first);
  }
  return [
    for (final key in required)
      if (declared.contains(key) && !present(key)) key,
  ];
}
