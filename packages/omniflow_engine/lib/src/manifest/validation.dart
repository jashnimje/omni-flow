/// One problem found while validating input, with the JSON path it sits at.
class ValidationIssue {
  const ValidationIssue(this.path, this.message);

  final String path;
  final String message;

  Map<String, String> toJson() => {'path': path, 'message': message};

  @override
  String toString() => '$path: $message';
}

/// Thrown with every issue found, so a caller (CLI, UI, MCP) can show them all.
class ValidationException implements Exception {
  ValidationException(this.subject, this.issues);

  final String subject;
  final List<ValidationIssue> issues;

  @override
  String toString() =>
      'ValidationException: $subject is invalid\n${issues.map((i) => '  $i').join('\n')}';
}

/// Collects issues while reading an untyped JSON map.
class IssueCollector {
  final List<ValidationIssue> issues = [];

  void add(String path, String message) =>
      issues.add(ValidationIssue(path, message));

  bool get hasIssues => issues.isNotEmpty;

  String? requiredString(Map<String, Object?> json, String key, String path) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) return value;
    add(
      '$path.$key',
      value == null ? 'is required' : 'must be a non-empty string',
    );
    return null;
  }

  String? optionalString(Map<String, Object?> json, String key, String path) {
    final value = json[key];
    if (value == null || value is String) return value as String?;
    add('$path.$key', 'must be a string');
    return null;
  }

  int? optionalInt(
    Map<String, Object?> json,
    String key,
    String path, {
    int? min,
    int? max,
  }) {
    final value = json[key];
    if (value == null) return null;
    if (value is! int) {
      add('$path.$key', 'must be an integer');
      return null;
    }
    if ((min != null && value < min) || (max != null && value > max)) {
      add('$path.$key', 'must be between ${min ?? '-inf'} and ${max ?? 'inf'}');
      return null;
    }
    return value;
  }

  Map<String, Object?>? optionalMap(
    Map<String, Object?> json,
    String key,
    String path,
  ) {
    final value = json[key];
    if (value == null) return null;
    if (value is Map) return Map<String, Object?>.from(value);
    add('$path.$key', 'must be an object');
    return null;
  }

  List<Object?> optionalList(
    Map<String, Object?> json,
    String key,
    String path,
  ) {
    final value = json[key];
    if (value == null) return const [];
    if (value is List) return value;
    add('$path.$key', 'must be an array');
    return const [];
  }
}
