import 'validation.dart';

enum ParamType {
  number('number'),
  boolean('boolean'),
  string('string'),
  enumeration('enum');

  const ParamType(this.wireName);

  final String wireName;

  static ParamType? fromWire(Object? name) =>
      values.where((t) => t.wireName == name).firstOrNull;
}

/// The declared shape of one capability parameter.
class ParamSpec {
  const ParamSpec({
    required this.type,
    this.min,
    this.max,
    this.unit,
    this.optional = false,
    this.values = const [],
    this.pattern,
    this.integer = false,
    this.clamp = false,
  });

  final ParamType type;
  final num? min;
  final num? max;
  final String? unit;
  final bool optional;
  final List<String> values;

  /// For a string param, a regular expression the whole value must match.
  final RegExp? pattern;

  /// For a number param, whether it must be a whole number.
  final bool integer;

  /// For a number param, whether a value outside [min] to [max] is brought
  /// inside it (and rounded when [integer]) instead of refused, for a
  /// light, where 5 % on a bulb whose lowest is 10 % should give 10 %.
  final bool clamp;

  /// This spec with another range or set of values, for a device that
  /// takes less than its driver declares.
  ParamSpec copyWith({num? min, num? max, List<String>? values}) => ParamSpec(
    type: type,
    min: min ?? this.min,
    max: max ?? this.max,
    unit: unit,
    optional: optional,
    values: values ?? this.values,
    pattern: pattern,
    integer: integer,
    clamp: clamp,
  );

  /// [value] brought inside the range and rounded, when this param clamps.
  Object? fit(Object? value) {
    if (!clamp || value is! num || !value.isFinite) return value;
    num v = value;
    if (min != null && v < min!) v = min!;
    if (max != null && v > max!) v = max!;
    return integer ? v.round() : v;
  }

  static ParamSpec? parse(Object? json, String path, IssueCollector issues) {
    if (json is! Map) {
      issues.add(path, 'must be an object');
      return null;
    }
    final map = Map<String, Object?>.from(json);
    final type = ParamType.fromWire(map['type']);
    if (type == null) {
      issues.add(
        '$path.type',
        'must be one of ${ParamType.values.map((t) => t.wireName).join(', ')}',
      );
      return null;
    }
    final min = map['min'];
    final max = map['max'];
    if (min != null && min is! num) issues.add('$path.min', 'must be a number');
    if (max != null && max is! num) issues.add('$path.max', 'must be a number');
    if (min is num && max is num && min > max) {
      issues.add(path, 'min must not exceed max');
    }
    final rawValues = map['values'];
    final values = <String>[];
    if (type == ParamType.enumeration) {
      if (rawValues is! List ||
          rawValues.isEmpty ||
          rawValues.any((v) => v is! String)) {
        issues.add('$path.values', 'an enum needs a non-empty list of strings');
      } else {
        values.addAll(rawValues.cast<String>());
      }
    }
    RegExp? pattern;
    final rawPattern = map['pattern'];
    if (rawPattern != null) {
      if (type != ParamType.string || rawPattern is! String) {
        issues.add(
          '$path.pattern',
          'only a string param takes a pattern, as a string',
        );
      } else {
        try {
          pattern = RegExp('^(?:$rawPattern)\$');
        } on FormatException catch (e) {
          issues.add(
            '$path.pattern',
            'is not a valid regular expression: ${e.message}',
          );
        }
      }
    }
    final optional = map['optional'];
    if (optional != null && optional is! bool) {
      issues.add('$path.optional', 'must be a boolean');
    }
    final integer = map['integer'];
    if (integer != null && (integer is! bool || type != ParamType.number)) {
      issues.add('$path.integer', 'is true or false, for a number param');
    }
    final clamp = map['clamp'];
    if (clamp != null && (clamp is! bool || type != ParamType.number)) {
      issues.add('$path.clamp', 'is true or false, for a number param');
    }
    return ParamSpec(
      type: type,
      min: min is num ? min : null,
      max: max is num ? max : null,
      unit: map['unit'] is String ? map['unit'] as String : null,
      optional: optional == true,
      values: values,
      pattern: pattern,
      integer: integer == true,
      clamp: clamp == true,
    );
  }

  /// Returns why [value] does not fit this spec, or null when it fits.
  String? check(Object? value) {
    switch (type) {
      case ParamType.number:
        if (value is! num) return 'must be a number';
        if (clamp) return value.isFinite ? null : 'must be a number';
        if (integer && value != value.roundToDouble()) {
          return 'must be a whole number';
        }
        if (min != null && value < min!) return 'must be at least $min';
        if (max != null && value > max!) return 'must be at most $max';
      case ParamType.boolean:
        if (value is! bool) return 'must be true or false';
      case ParamType.string:
        if (value is! String) return 'must be a string';
        if (pattern != null && !pattern!.hasMatch(value)) {
          return 'does not match the required format';
        }
      case ParamType.enumeration:
        if (value is! String || !values.contains(value)) {
          return 'must be one of ${values.join(', ')}';
        }
    }
    return null;
  }
}
