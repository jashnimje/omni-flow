import 'engine_core.dart' show pairingPrompt;
import '../devices/board.dart' show isBoardDriver;
import '../devices/device.dart';
import '../devices/device_service.dart' show setupNeedsSetting;
import '../devices/http_channel.dart' show hueUsernameSecret;
import '../devices/tv/tizen_protocol.dart';
import '../devices/tv/webos_protocol.dart';
import '../manifest/driver_manifest.dart';
import '../storage/secret_store.dart';

/// Whether [settings] holds a value for [key]. An empty object or list
/// counts, so a board set up with no pins is configured.
bool settingPresent(Map<String, Object?> settings, String key) {
  final value = settings[key];
  return value != null && !(value is String && value.isEmpty);
}

/// The secret a successful pairing stores, which proves it happened. Null
/// for ADB, where the TV keeps the trust and the engine stores nothing.
String? pairingProofSecret(DriverManifest manifest) {
  final spec = manifest.pairingSpec;
  return switch (spec?.method) {
    PairingMethod.secret => spec!.secret,
    PairingMethod.hueBridge => hueUsernameSecret,
    PairingMethod.tv => switch (manifest.transport.options['protocol']) {
      'webos' => const WebOsProtocol().pairingSecret,
      'tizen' => const TizenProtocol().pairingSecret,
      _ => null,
    },
    PairingMethod.adb || null => null,
  };
}

/// The next setup step of [device], from its driver's `setup`, as the
/// `next` object `thing.add`, `thing.next` and `device.add` return:
/// `{step: pair | secret | configure | done, instruction, ...}`.
///
/// A pair step is done when the secret pairing stores is there. A driver
/// whose pairing stores none (ADB) counts as paired once the device has
/// answered, or when [pairedHere] says this engine paired it.
///
/// An optional step whose key the device's `setupNeeds` setting lists is
/// required: the device refused commands without it (a WiZ bulb whose
/// firmware wants the home key). A secret key that one of [siblings] (the
/// other devices on the same driver) already has carries `sameAs`, its
/// `{id, name}` list, for `secret.set {from}`.
Future<Map<String, Object?>> nextSetupStep(
  Device device,
  DriverManifest manifest,
  SecretStore secrets, {
  bool pairedHere = false,
  List<Device> siblings = const [],
}) async {
  Future<bool> secretOf(String deviceId, String key) async {
    final value = await secrets.read(deviceSecretKey(deviceId, key));
    return value != null && value.isNotEmpty;
  }

  Future<bool> hasSecret(String key) => secretOf(device.id, key);
  final needs = device.settings[setupNeedsSetting];
  final sameAs = <String, List<Map<String, Object?>>>{};
  for (final s in manifest.setup) {
    if (s.kind != SetupKind.secret || siblings.isEmpty) continue;
    sameAs[s.key!] = [
      for (final d in siblings)
        if (await secretOf(d.id, s.key!)) {'id': d.id, 'name': d.name},
    ];
  }

  Future<bool> done(SetupStep step) async => switch (step.kind) {
    SetupKind.pair => switch (pairingProofSecret(manifest)) {
      final String key => hasSecret(key),
      null => pairedHere || device.lastSeen != null,
    },
    SetupKind.secret => hasSecret(step.key!),
    SetupKind.configure => settingPresent(device.settings, step.key!),
  };

  final steps = [
    for (final s in manifest.setup)
      s.optional && needs is List && needs.contains(s.key)
          ? SetupStep(s.kind, key: s.key)
          : s,
  ];
  Map<String, Object?> keyJson(SetupStep s) => {
    ..._keyJson(manifest, s),
    if (sameAs[s.key] case final list? when list.isNotEmpty) 'sameAs': list,
  };
  final open = [for (final s in steps) !await done(s)];
  final remaining = [
    for (var i = 0; i < steps.length; i++)
      if (open[i]) steps[i].wireName,
  ];
  final first = [
    for (var i = 0; i < steps.length; i++)
      if (open[i] && !steps[i].optional) i,
  ].firstOrNull;

  if (first == null) {
    final optional = [
      for (var i = 0; i < steps.length; i++)
        if (open[i]) keyJson(steps[i]),
    ];
    return {
      'step': 'done',
      'instruction': '${device.name} is ready',
      if (optional.isNotEmpty) 'optional': optional,
    };
  }

  final step = steps[first];
  if (step.kind == SetupKind.pair) {
    final spec = manifest.pairingSpec!;
    return {
      'step': 'pair',
      'method': spec.method.wireName,
      'instruction': pairingPrompt(spec, device),
      'command': 'device.pair',
      'remaining': remaining,
    };
  }

  // The open steps of the same kind next to the first one go together, so a
  // client asks for an MQTT topic and its optional broker user at once.
  var from = first;
  while (from > 0 && steps[from - 1].kind == step.kind) {
    from--;
  }
  var to = first;
  while (to + 1 < steps.length && steps[to + 1].kind == step.kind) {
    to++;
  }
  final keys = [
    for (var i = from; i <= to; i++)
      if (open[i]) keyJson(steps[i]),
  ];
  final secret = step.kind == SetupKind.secret;
  return {
    'step': step.kind.wireName,
    'keys': keys,
    'instruction': secret
        ? _secretInstruction(device, manifest, keys)
        : _configureInstruction(device, manifest, keys),
    'command': secret ? 'secret.set' : 'thing.configure',
    'remaining': remaining,
  };
}

Map<String, Object?> _keyJson(DriverManifest manifest, SetupStep step) => {
  'step': step.kind.wireName,
  'key': ?step.key,
  if (step.key != null)
    'label': manifest.settings.firstWhere((s) => s.key == step.key).label,
  if (step.key != null)
    'help': ?manifest.settings.firstWhere((s) => s.key == step.key).help,
  if (step.optional) 'optional': true,
};

String _labels(List<Map<String, Object?>> keys) =>
    keys.map((k) => k['label']).join(', ');

String _secretInstruction(
  Device device,
  DriverManifest manifest,
  List<Map<String, Object?>> keys,
) {
  final pairing = manifest.pairing;
  final how =
      pairing?.method == PairingMethod.secret &&
          pairing?.instructions != null &&
          keys.any((k) => k['key'] == pairing!.secret)
      ? '${pairing!.instructions}. '
      : '';
  return '${how}Enter the ${_labels(keys)} for ${device.id}. Secrets go to '
      'the secret store only, never into settings';
}

String _configureInstruction(
  Device device,
  DriverManifest manifest,
  List<Map<String, Object?>> keys,
) {
  if (isBoardDriver(manifest) && keys.any((k) => k['key'] == 'pins')) {
    return 'Name the pins you use on ${device.id}, as name: {pin, mode, '
        'watch}, for example {"relay": {"pin": 4, "mode": "out"}}. '
        'board.describe lists what the board offers. {} means no pins';
  }
  return 'Set the ${_labels(keys)} for ${device.id}';
}
