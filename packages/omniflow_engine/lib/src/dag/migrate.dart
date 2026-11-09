/// The trigger and condition types the `on` trigger and `compare`
/// condition replaced. Flows that still use them are rewritten by
/// [migrateFlow] when the engine opens and when one is saved.
const retiredNodeTypes = {
  'device_state',
  'board_event',
  'zone_change',
  'wifi_change',
  'var_equals',
  'var_compare',
  'device_state_is',
};

/// What the old types named differently from the things that replace them.
class FlowMigrationContext {
  const FlowMigrationContext({
    this.places = const {},
    this.boards = const {},
    this.phone = 'phone',
  });

  /// The place thing each zone became, by zone id. A zone not listed kept
  /// its id.
  final Map<String, String> places;

  /// The board thing for each board node name, by the lower-case name.
  final Map<String, String> boards;

  /// The phone thing whose Wi-Fi a `wifi_change` trigger watched.
  final String phone;

  String boardFor(String node) =>
      boards[node.toLowerCase()] ?? node.toLowerCase().replaceAll('-', '_');
}

/// A flow that names something the migration cannot place.
class FlowMigrationException implements Exception {
  FlowMigrationException(this.message);

  final String message;

  @override
  String toString() => 'FlowMigrationException: $message';
}

/// [flow] with every retired trigger and condition rewritten to `on` and
/// `compare`, or [flow] itself when there is nothing to rewrite. Pure: the
/// [context] carries everything it needs from the engine. Throws a
/// [FlowMigrationException] for a `board_event` on any board when there is
/// no board to name.
Map<String, Object?> migrateFlow(
  Map<String, Object?> flow, [
  FlowMigrationContext context = const FlowMigrationContext(),
]) {
  final nodes = flow['nodes'];
  if (nodes is! List || !_usesRetired(nodes)) return flow;
  final out = <Object?>[];
  final edges = [...?(flow['edges'] as List?)];
  final ids = {
    for (final n in nodes)
      if (n is Map) n['id'],
  };
  for (final raw in nodes) {
    if (raw is! Map) {
      out.add(raw);
      continue;
    }
    final node = Map<String, Object?>.from(raw);
    final config = node['config'] is Map
        ? Map<String, Object?>.from(node['config'] as Map)
        : <String, Object?>{};
    switch (node['type']) {
      case 'device_state':
        out.add({
          ...node,
          'type': 'on',
          'config': {'thing': config['deviceId'], 'key': ?config['key']},
        });
      case 'zone_change':
        final zone = config['zoneId'];
        out.add({
          ...node,
          'type': 'on',
          'config': {
            'thing': zone is String ? context.places[zone] ?? zone : zone,
            'key': 'inside',
            'change': {'to': config['transition'] == 'entered'},
          },
        });
      case 'wifi_change':
        out.add({
          ...node,
          'type': 'on',
          'config': {
            'thing': context.phone,
            'key': 'wifi_ssid',
            'change': {if (config['ssid'] != null) 'to': config['ssid']},
          },
        });
      case 'board_event':
        final node0 = config['node'];
        final things = node0 is String
            ? [context.boardFor(node0)]
            : (context.boards.values.toSet().toList()..sort());
        if (things.isEmpty) {
          throw FlowMigrationException(
            'node ${node['id']} waits for ${config['event']} from any '
            'board, and there is no board to name. Add the board, or set '
            'the node it listens to',
          );
        }
        for (var k = 0; k < things.length; k++) {
          final id = k == 0
              ? node['id']
              : _unique('${node['id']}_${things[k]}', ids);
          out.add({
            ...node,
            'id': id,
            'type': 'on',
            'config': {
              'thing': things[k],
              'key': config['event'],
              'event': true,
            },
          });
          if (k == 0) continue;
          for (final e in [...edges]) {
            if (e is Map &&
                e['from'] is Map &&
                e['from']['node'] == node['id']) {
              edges.add({
                ...e,
                'id': _unique('${e['id']}_${things[k]}', ids),
                'from': {...e['from'] as Map, 'node': id},
              });
            }
          }
        }
      default:
        if (_conditionTypes.contains(node['type'])) {
          final rule = _rule({...config, 'type': node['type']});
          out.add({
            ...node,
            'type': rule['type'],
            'config': {...rule}..remove('type'),
          });
        } else {
          out.add(node);
        }
    }
  }
  final renames = {
    for (final n in nodes)
      if (n is Map) ...?_messageKeyRenames[n['type']],
  };
  return {
    ...flow,
    'nodes': renames.isEmpty
        ? out
        : [for (final n in out) _renameMessageKeys(n, renames, context)],
    'edges': edges,
  };
}

/// The message key each retired trigger sent that the `on` trigger sends
/// under another name: a place change names the place as `thing`, a Wi-Fi
/// change carries the SSID as the phone's `wifi_ssid` `value`, and a board
/// event's `node` stays in the board line, the event's `payload`.
const _messageKeyRenames = {
  'zone_change': {'zone': 'thing'},
  'wifi_change': {'ssid': 'value'},
  'board_event': {'node': 'payload.node'},
};

/// [node] reading the `on` trigger's keys where it read [renames]: in every
/// template, and on the `{msg}` sides of its conditions.
Object? _renameMessageKeys(
  Object? node,
  Map<String, String> renames,
  FlowMigrationContext context,
) {
  if (node is! Map || node['config'] is! Map) return node;
  final config = node['config'] as Map;
  return {
    ...node,
    'config':
        _conditionTypes.contains(node['type']) || node['type'] == 'compare'
        ? _renameInRule(config, renames, context, type: node['type'])
        : _renameInTemplates(config, renames),
  };
}

Object? _renameInTemplates(Object? value, Map<String, String> renames) =>
    switch (value) {
      String s => s.replaceAllMapped(_placeholder, (m) {
        final terms = [
          for (final raw in m.group(1)!.split('|'))
            raw.replaceFirstMapped(
              _msgTerm,
              (t) => '${t.group(1)}msg.${_renamed(t.group(2)!, renames)}',
            ),
        ];
        return '{{${terms.join('|')}}}';
      }),
      Map m => {
        for (final e in m.entries) e.key: _renameInTemplates(e.value, renames),
      },
      List l => [for (final v in l) _renameInTemplates(v, renames)],
      _ => value,
    };

final _placeholder = RegExp(r'\{\{([^{}]*)\}\}');
final _msgTerm = RegExp(r'^(\s*)msg\.([A-Za-z0-9_.]+)');

/// [path] with its first segment renamed when [renames] names it.
String _renamed(String path, Map<String, String> renames) {
  final dot = path.indexOf('.');
  final head = dot < 0 ? path : path.substring(0, dot);
  final to = renames[head];
  return to == null ? path : '$to${dot < 0 ? '' : path.substring(dot)}';
}

/// [rule] with its `{msg}` sides renamed. [type] is the rule's type when
/// it is a node's config, which carries the type on the node instead.
Object? _renameInRule(
  Object? rule,
  Map<String, String> renames,
  FlowMigrationContext context, {
  Object? type,
}) {
  if (rule is List) {
    return [for (final r in rule) _renameInRule(r, renames, context)];
  }
  if (rule is! Map) return rule;
  final out = {
    for (final e in rule.entries)
      e.key: e.value is Map && _isMsgSide(e.value as Map)
          ? {'msg': _renamed((e.value as Map)['msg'] as String, renames)}
          : _renameInRule(e.value, renames, context),
  };
  // A zone the migration moved to `<id>_place` is that place in msg.thing,
  // so a literal compared with it names the place too.
  if ((type ?? rule['type']) == 'compare' && renames.containsKey('zone')) {
    for (final (side, other) in [('left', 'right'), ('right', 'left')]) {
      final literal = out[other];
      if (rule[side] case {'msg': 'zone'}
          when literal is Map && literal['literal'] is String) {
        final place = context.places[literal['literal']];
        if (place != null) out[other] = {'literal': place};
      }
    }
  }
  return out;
}

bool _isMsgSide(Map side) => side.length == 1 && side['msg'] is String;

const _conditionTypes = {
  'all_of',
  'any_of',
  'xor',
  'not',
  'var_equals',
  'var_compare',
  'device_state_is',
};

bool _usesRetired(Object? value) => switch (value) {
  Map m => retiredNodeTypes.contains(m['type']) || m.values.any(_usesRetired),
  List l => l.any(_usesRetired),
  _ => false,
};

Map<String, Object?> _rule(Map<String, Object?> rule) => switch (rule['type']) {
  'all_of' || 'any_of' || 'xor' when rule['rules'] is List => {
    ...rule,
    'rules': [
      for (final r in rule['rules'] as List)
        r is Map ? _rule(Map<String, Object?>.from(r)) : r,
    ],
  },
  'not' when rule['rule'] is Map => {
    ...rule,
    'rule': _rule(Map<String, Object?>.from(rule['rule'] as Map)),
  },
  'var_equals' => _compare(_side(rule['name']), '==', rule['value']),
  'var_compare' => _numberCompare(
    _side(rule['name']),
    rule['op'],
    rule['value'],
  ),
  'device_state_is' => _compare(
    {'state': '${rule['deviceId']}.${rule['key']}'},
    '==',
    rule['value'],
  ),
  _ => rule,
};

Map<String, Object?> _compare(
  Map<String, Object?> left,
  Object? op,
  Object? value,
) => {
  'type': 'compare',
  'left': left,
  'op': op,
  'right': {'literal': value},
};

/// var_compare held only when the variable was a number, for every
/// operator, while `compare` takes `!=` between any values, so an unset
/// `$Temp` would pass `$Temp != 20`. The any_of is true only for a number.
Map<String, Object?> _numberCompare(
  Map<String, Object?> left,
  Object? op,
  Object? value,
) {
  final compare = _compare(left, op, value);
  if (op != '!=') return compare;
  return {
    'type': 'all_of',
    'rules': [
      compare,
      {
        'type': 'any_of',
        'rules': [_compare(left, '<', 0), _compare(left, '>=', 0)],
      },
    ],
  };
}

/// `msg.value` reads the message, `$Name` and `%name` a variable.
Map<String, Object?> _side(Object? name) =>
    name is String && name.startsWith('msg.')
    ? {'msg': name.substring(4)}
    : {'var': name};

String _unique(String id, Set<Object?> taken) {
  var candidate = id;
  for (var n = 2; taken.contains(candidate); n++) {
    candidate = '${id}_$n';
  }
  taken.add(candidate);
  return candidate;
}
