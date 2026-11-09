import 'api_error.dart';

/// One entry in the engine's command table: JSON args in, JSON result out.
typedef CommandHandler = Future<Map<String, Object?>> Function(
  Map<String, Object?> args,
);

String stringArg(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value is String && value.isNotEmpty) return value;
  throw ApiError('invalid', '$key is required');
}

String? optStringArg(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null || value is String) return value as String?;
  throw ApiError('invalid', '$key must be a string');
}

int? optIntArg(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null || value is int) return value as int?;
  throw ApiError('invalid', '$key must be a whole number');
}

num? optNumArg(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null || value is num) return value as num?;
  throw ApiError('invalid', '$key must be a number');
}

DateTime? optDateArg(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null) return null;
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed != null) return parsed;
  throw ApiError('invalid', '$key must be an ISO 8601 time');
}

Map<String, Object?> objectArg(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value is Map) return Map<String, Object?>.from(value);
  throw ApiError('invalid', '$key must be an object');
}
