import 'api_error.dart';
import 'host_key_commands.dart';
import '../dag/error_text.dart';
import '../dag/expression.dart';
import '../devices/adb/adb_channel.dart';
import '../devices/channels.dart';
import '../devices/device_service.dart';
import '../devices/http_channel.dart';
import '../devices/tv/tv_socket.dart';
import '../manifest/validation.dart';
import '../storage/secret_store.dart';
import '../template/template_renderer.dart';
import '../transports/host_exec.dart';
import '../transports/ssh_executor.dart';
import '../transports/udp_transport.dart';

/// The typed error a failure becomes, so a command result and a background
/// event (a poll that failed, a device gone offline) carry the same type and
/// a message without the exception's class name.
ApiError apiErrorOf(Object e) => switch (e) {
  ApiError() => e,
  ValidationException() => ApiError('invalid', e.subject, issues: e.issues),
  DeviceNotFoundException() => ApiError('not_found', e.message),
  TransportTimeoutException() => ApiError('timeout', e.message),
  PairingRequiredException() => ApiError('needs_user', e.message),
  TvCertificateMismatchException() => ApiError(
    'certificate_mismatch',
    e.message,
  ),
  AdbPairingException() => ApiError('pairing_failed', e.message),
  TvPairingException() => ApiError('pairing_failed', e.message),
  LinkButtonNotPressedException() => ApiError('pairing_failed', e.message),
  SecretRejectedException() => ApiError('secret_rejected', e.message),
  HostKeyMismatchException() => hostKeyError(e),
  CommandFailedException() => ApiError('device_error', e.message),
  MissingSecretException() => ApiError(
    'missing_secret',
    'no secret stored for ${e.key}. Set it with omni secret set',
  ),
  CommandTimeoutException() => ApiError(
    'timeout',
    '${e.argv.first} did not finish within ${e.timeout.inSeconds} s',
  ),
  TemplateException() => ApiError('template', e.message),
  ArgumentError() => ApiError('invalid', '${e.message}'),
  StateError() => ApiError('not_ready', e.message),
  ExpressionException() => ApiError('invalid', e.message),
  _ => ApiError('internal', withoutTypeName('$e')),
};

/// The `error` and `errorType` fields of a background failure event.
Map<String, Object?> errorFields(Object e) {
  final error = apiErrorOf(e);
  return {'error': error.message, 'errorType': error.type};
}
