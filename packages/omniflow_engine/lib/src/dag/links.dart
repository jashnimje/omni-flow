import '../manifest/capability.dart';
import '../manifest/param_spec.dart';
import 'canonical.dart';

/// How a link connects its two ends.
enum LinkMode {
  /// Each time the source turns on (a button press), flip the target.
  toggle,

  /// The target copies the source, scaled to the target's range.
  follow,

  /// When the source crosses a threshold, set the target to a value.
  threshold,
}

/// One end of a link: `device.key`, where the key is a state key on the
/// source side and a capability on the target side.
class LinkEnd {
  const LinkEnd(this.deviceId, this.key);

  final String deviceId;
  final String key;

  static final _pattern = RegExp(r'^([a-z][a-z0-9_]*)\.([a-z][a-z0-9_]*)$');

  static LinkEnd parse(String text, String role) {
    final m = _pattern.firstMatch(text);
    if (m == null) {
      throw ArgumentError('$role must be device.key, like desk_board.button');
    }
    return LinkEnd(m.group(1)!, m.group(2)!);
  }

  @override
  String toString() => '$deviceId.$key';
}

/// A link, written as the flow that runs it. It is validated and stored like
/// any other flow, so it shows in the flow list, the cards and the run log.
class LinkRequest {
  const LinkRequest({
    required this.from,
    required this.to,
    required this.mode,
    required this.target,
    this.above,
    this.below,
    this.set,
    this.fromMin = 0,
    this.fromMax = 100,
    this.onValue = true,
  });

  final LinkEnd from;
  final LinkEnd to;
  final LinkMode mode;

  /// The target's capability, to check the mode fits and to scale into.
  final CapabilitySpec target;
  final num? above;
  final num? below;
  final Object? set;

  /// The source's range, for scaling a follow into the target's range.
  final num fromMin;
  final num fromMax;

  /// The source value that counts as a press for a toggle.
  final Object? onValue;

  /// A hash of everything that makes two links different, so a hysteresis
  /// pair (below 30 on, above 60 off) is two links, and `desk.button_a`
  /// never collides with `desk_button.a`.
  String get id =>
      'link_${sha256Hex(canonicalJson({'from': '$from', 'to': '$to', 'mode': mode.name, 'above': above, 'below': below, 'set': set})).substring(0, 12)}';

  String get name => switch (mode) {
    LinkMode.toggle => '$from toggles $to',
    LinkMode.follow => '$to follows $from',
    LinkMode.threshold =>
      '$to set to $set when $from goes ${above != null ? 'above $above' : 'below $below'}',
  };

  /// The flow JSON. Throws an [ArgumentError] when the mode does not fit
  /// the target capability.
  Map<String, Object?> toFlow() {
    final trigger = {
      'id': 'source',
      'type': 'device_state',
      'label': '$from changes',
      'config': {'deviceId': from.deviceId, 'key': from.key},
      'position': {'x': 0, 'y': 0},
    };
    final nodes = <Map<String, Object?>>[trigger];
    final edges = <Map<String, Object?>>[];
    var last = ('source', 'out');
    void add(Map<String, Object?> node, String outPort) {
      nodes.add({
        ...node,
        'position': {'x': 220 * (nodes.length), 'y': 0},
      });
      edges.add({
        'id': 'e${edges.length + 1}',
        'from': {'node': last.$1, 'port': last.$2},
        'to': {'node': node['id'], 'port': 'in'},
      });
      last = (node['id'] as String, outPort);
    }

    final String mode;
    switch (this.mode) {
      case LinkMode.toggle:
        if (target.type != CapabilityType.toggle) {
          throw ArgumentError(
            '$to is a ${target.type.wireName}, and only an on/off toggle can be toggled',
          );
        }
        mode = 'queued';
        add({
          'id': 'pressed',
          'type': 'var_equals',
          'label': '$from is $onValue',
          'config': {'name': 'msg.value', 'value': onValue},
        }, 'true');
        add({
          'id': 'flip',
          'type': 'device_toggle',
          'label': 'toggle $to',
          'config': {'deviceId': to.deviceId, 'capabilityId': to.key},
        }, 'out');
      case LinkMode.follow:
        final value = target.params['value'];
        if (value == null ||
            (target.type != CapabilityType.toggle &&
                value.type != ParamType.number)) {
          throw ArgumentError('$to takes no single value to follow with');
        }
        mode = 'restart';
        if (value.type == ParamType.number &&
            value.min != null &&
            value.max != null &&
            (value.min != fromMin || value.max != fromMax)) {
          add({
            'id': 'scale',
            'type': 'range_map',
            'label': 'scale $fromMin..$fromMax to ${value.min}..${value.max}',
            'config': {
              'source': 'value',
              'into': 'value',
              'inMin': fromMin,
              'inMax': fromMax,
              'outMin': value.min,
              'outMax': value.max,
              // A whole-number target (WiZ brightness, Tasmota dimmer)
              // refuses 63.5.
              if (value.integer) 'round': true,
            },
          }, 'out');
        }
        add({
          'id': 'apply',
          'type': 'device_capability',
          'label': 'set $to',
          'config': {
            'deviceId': to.deviceId,
            'capabilityId': to.key,
            'params': {'value': '{{msg.value}}'},
          },
        }, 'out');
      case LinkMode.threshold:
        if ((above == null) == (below == null)) {
          throw ArgumentError(
            'a threshold link needs exactly one of above or below',
          );
        }
        if (set == null) {
          throw ArgumentError('a threshold link needs the value to set');
        }
        mode = 'queued';
        final op = above != null ? '>' : '<';
        final limit = above ?? below;
        add({
          'id': 'crossed',
          'type': 'all_of',
          'label': '$from crosses $op $limit',
          'config': {
            'rules': [
              {
                'type': 'var_compare',
                'name': 'msg.value',
                'op': op,
                'value': limit,
              },
              {
                'type': 'not',
                'rule': {
                  'type': 'var_compare',
                  'name': 'msg.previous',
                  'op': op,
                  'value': limit,
                },
              },
            ],
          },
        }, 'true');
        add({
          'id': 'apply',
          'type': 'device_capability',
          'label': 'set $to to $set',
          'config': {
            'deviceId': to.deviceId,
            'capabilityId': to.key,
            'params': {'value': set},
          },
        }, 'out');
    }
    return {
      'schemaVersion': 1,
      'id': id,
      'name': name,
      'enabled': true,
      'mode': mode,
      'cooldownSeconds': 0,
      'nodes': nodes,
      'edges': edges,
    };
  }
}
