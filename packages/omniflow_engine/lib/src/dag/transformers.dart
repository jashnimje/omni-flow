import 'package:json_path/json_path.dart';

import 'conditions.dart';
import 'expression.dart';

/// Reads a dotted path (`payload.temp`) out of a message.
Object? readPath(Map<String, Object?> msg, String path) {
  Object? current = msg;
  for (final part in path.split('.')) {
    if (current is Map && current.containsKey(part)) {
      current = current[part];
    } else if (current is List &&
        int.tryParse(part) != null &&
        int.parse(part) < current.length) {
      current = current[int.parse(part)];
    } else {
      return null;
    }
  }
  return current;
}

/// Returns a copy of [msg] with [value] written at the dotted [path].
Map<String, Object?> writePath(
  Map<String, Object?> msg,
  String path,
  Object? value,
) {
  final parts = path.split('.');
  Map<String, Object?> write(Map<String, Object?> node, int i) {
    final copy = Map<String, Object?>.from(node);
    if (i == parts.length - 1) {
      copy[parts[i]] = value;
    } else {
      final child = copy[parts[i]];
      copy[parts[i]] = write(
        child is Map ? Map<String, Object?>.from(child) : <String, Object?>{},
        i + 1,
      );
    }
    return copy;
  }

  return write(msg, 0);
}

/// Runs a transformer node on [msg]. Each reads `msg.<source>` (default
/// `payload`) and writes `msg.<into>` (default `value`).
Map<String, Object?> applyTransformer(
  String type,
  Map<String, Object?> config,
  Map<String, Object?> msg, {
  EvalContext? context,
}) {
  final source = config['source'] as String? ?? 'payload';
  final into = config['into'] as String? ?? 'value';
  final input = readPath(msg, source);
  final Object? output;
  switch (type) {
    case 'jsonpath':
      output = input == null
          ? null
          : JsonPath(config['path'] as String).readValues(input).firstOrNull;
    case 'regex':
      final match = input == null
          ? null
          : RegExp(config['pattern'] as String).firstMatch('$input');
      output = match == null
          ? null
          : (match.groupCount > 0 ? match.group(1) : match.group(0));
    case 'range_map':
      output = input is num ? rangeMap(input, config) : null;
    case 'math':
      output = evaluateExpression(config['expression'] as String, (name) {
        if (name == 'value') return input is num ? input : null;
        if (name.startsWith('msg.')) {
          final v = readPath(msg, name.substring(4));
          return v is num ? v : null;
        }
        final v = context?.variable(name);
        return v is num ? v : null;
      });
    default:
      throw ArgumentError('$type is not a transformer');
  }
  return writePath(msg, into, output);
}

/// Maps [value] linearly from `inMin..inMax` onto `outMin..outMax`, clamped.
num rangeMap(num value, Map<String, Object?> config) {
  final inMin = config['inMin'] as num;
  final inMax = config['inMax'] as num;
  final outMin = config['outMin'] as num;
  final outMax = config['outMax'] as num;
  final t = ((value - inMin) / (inMax - inMin)).clamp(0, 1);
  final mapped = outMin + (outMax - outMin) * t;
  if (config['round'] == true) return mapped.round();
  return mapped == mapped.roundToDouble() ? mapped.round() : mapped;
}
