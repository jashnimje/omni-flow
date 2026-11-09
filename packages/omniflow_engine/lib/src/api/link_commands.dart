import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'flow_commands.dart';
import '../dag/links.dart';
import '../devices/board.dart';
import '../devices/device.dart';
import '../devices/device_service.dart';
import '../manifest/capability.dart';
import '../manifest/param_spec.dart';
import '../storage/database.dart';

/// The link commands: a link is a small flow from one device's state to
/// another device's capability, saved and removed as a flow.
class LinkCommands {
  LinkCommands(this._core, this._flowCommands);

  final EngineCore _core;
  final FlowCommands _flowCommands;

  /// What a link from [source] can be, for the app to offer only links
  /// that can fire.
  static ({bool onOff, bool number}) _sourceKind(
    CapabilitySpec? capability,
    Object? current,
  ) => (
    onOff: capability?.type == CapabilityType.toggle || current is bool,
    number:
        const {
          CapabilityType.level,
          CapabilityType.colorTemp,
        }.contains(capability?.type) ||
        current is num,
  );

  Future<(Device, LinkEnd, CapabilitySpec?, Set<String>)> _linkSource(
    String text,
  ) async {
    final from = LinkEnd.parse(text, 'from');
    final source = await _core.device(from.deviceId);
    final manifest = manifestFor(_core.registry, source);
    final capability = manifest?.capabilities
        .where((c) => stateKeyOf(c.stateJsonPath) == from.key)
        .firstOrNull;
    final knownKeys = {
      ...source.state.keys,
      for (final c in manifest?.capabilities ?? const <CapabilitySpec>[])
        ?stateKeyOf(c.stateJsonPath),
    };
    return (source, from, capability, knownKeys);
  }

  Future<Map<String, Object?>> create(Map<String, Object?> args) async {
    final (source, from, sourceCapability, knownKeys) = await _linkSource(
      stringArg(args, 'from'),
    );
    final to = LinkEnd.parse(stringArg(args, 'to'), 'to');
    final mode = LinkMode.values
        .where((m) => m.name == args['mode'])
        .firstOrNull;
    if (mode == null) {
      throw ApiError('invalid', 'mode must be toggle, follow or threshold');
    }
    if (!knownKeys.contains(from.key)) {
      throw ApiError(
        'not_found',
        '${from.deviceId} has no state ${from.key} (it has ${(knownKeys.toList()..sort()).join(', ')})',
      );
    }
    final target = manifestFor(
      _core.registry,
      await _core.device(to.deviceId),
    )?.capability(to.key);
    if (target == null) {
      throw ApiError('not_found', '${to.deviceId} has no capability ${to.key}');
    }
    // Each mode reads the source differently: a threshold compares a
    // number, a toggle waits for one value (on, unless onValue says),
    // and a follow copies the value, so both ends must be on/off, or
    // both numbers.
    final kind = _sourceKind(sourceCapability, source.state[from.key]);
    switch (mode) {
      case LinkMode.follow:
        final targetIsOnOff = target.type == CapabilityType.toggle;
        if ((kind.onOff && !targetIsOnOff) || (kind.number && targetIsOnOff)) {
          throw ApiError(
            'invalid',
            '$to cannot follow $from: one is on/off and the other a number. Use a threshold link',
          );
        }
      case LinkMode.threshold:
        if (kind.onOff) {
          throw ApiError(
            'invalid',
            '$from is on/off, so it never crosses a number. Use a toggle or follow link',
          );
        }
      case LinkMode.toggle:
        if (kind.number && !args.containsKey('onValue')) {
          throw ApiError(
            'invalid',
            '$from is a number, so it is never on. Use a threshold link, or give onValue',
          );
        }
    }
    final range = sourceCapability?.params['value'];
    num bound(String key, num? fromCapability, num fallback) =>
        optNumArg(args, key) ?? fromCapability ?? fallback;
    final request = LinkRequest(
      from: from,
      to: to,
      mode: mode,
      target: target,
      above: optNumArg(args, 'above'),
      below: optNumArg(args, 'below'),
      set: args['set'],
      fromMin: bound('fromMin', range?.min, 0),
      fromMax: bound('fromMax', range?.max, 100),
      onValue: args.containsKey('onValue') ? args['onValue'] : true,
    );
    final Map<String, Object?> flow;
    try {
      flow = request.toFlow();
    } on ArgumentError catch (e) {
      throw ApiError('invalid', '${e.message}');
    }
    if (args['replace'] != true &&
        await DriftFlowStore(_core.db).get(request.id) != null) {
      throw ApiError(
        'exists',
        'this link exists as ${request.id}. Pass replace: true to save it again',
      );
    }
    final saved = await _flowCommands.save({
      'flow': flow,
      'trusted': args['trusted'] == true,
    });
    return {...saved, 'name': request.name};
  }

  Future<Map<String, Object?>> options(Map<String, Object?> args) async {
    final (source, from, sourceCapability, knownKeys) = await _linkSource(
      stringArg(args, 'from'),
    );
    if (!knownKeys.contains(from.key)) {
      throw ApiError('not_found', '${from.deviceId} has no state ${from.key}');
    }
    final kind = _sourceKind(sourceCapability, source.state[from.key]);
    final modes = [
      if (!kind.number) 'toggle',
      'follow',
      if (!kind.onOff) 'threshold',
    ];
    return {
      'from': '$from',
      'modes': modes,
      'targets': [
        for (final d in await DriftDeviceStore(_core.db).all())
          for (final c
              in manifestFor(_core.registry, d)?.capabilities ??
                  const <CapabilitySpec>[])
            if (_targetModes(c, kind).isNotEmpty)
              {
                'to': '${d.id}.${c.id}',
                'type': c.type.wireName,
                'modes': _targetModes(c, kind),
              },
      ],
    };
  }

  Future<Map<String, Object?>> list(Map<String, Object?> _) async => {
    'links': [
      for (final r in await DriftFlowStore(_core.db).all())
        if ((r.json['id'] as String).startsWith('link_'))
          {
            'id': r.json['id'],
            'name': r.json['name'],
            'enabled': r.enabled,
            'approved': r.approved,
          },
    ],
  };

  Future<Map<String, Object?>> remove(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    if (!id.startsWith('link_')) {
      throw ApiError('invalid', '$id is not a link');
    }
    return _flowCommands.remove({'id': id});
  }

  /// The link modes that can drive capability [c] from a source of [kind],
  /// the same checks link.create and LinkRequest.toFlow make.
  static List<String> _targetModes(
    CapabilitySpec c,
    ({bool onOff, bool number}) kind,
  ) {
    final value = c.params['value'];
    final isToggle = c.type == CapabilityType.toggle;
    final takesNumber = value?.type == ParamType.number;
    return [
      if (isToggle && !kind.number) 'toggle',
      if (value != null &&
          (isToggle || takesNumber) &&
          !(kind.onOff && !isToggle) &&
          !(kind.number && isToggle))
        'follow',
      if (value != null && !kind.onOff) 'threshold',
    ];
  }
}
