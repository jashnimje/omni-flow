import '../manifest/validation.dart';

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
