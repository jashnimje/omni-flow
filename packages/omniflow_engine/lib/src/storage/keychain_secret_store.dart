import 'dart:convert';

import '../transports/host_exec.dart';
import 'secret_store.dart';

/// Secrets for the CLI on macOS, kept in the login keychain through the
/// `security` command.
///
/// Values are hex-encoded so a multi-line PEM key fits in one item, and they
/// are written through `security -i` on stdin, so a secret never appears in a
/// process argument list where `ps` could read it.
class KeychainSecretStore implements SecretStore {
  KeychainSecretStore({
    this.service = 'omniflow',
    this._executor = const LocalExecutor(),
  });

  final String service;
  final HostExecutor _executor;
  static final _keyPattern = RegExp(r'^[A-Za-z0-9_./:@-]+$');
  static const _security = '/usr/bin/security';
  static const _notFound = 44;

  @override
  Future<String?> read(String key) async {
    _checkKey(key);
    final result = await _executor.run([
      _security,
      'find-generic-password',
      '-s',
      service,
      '-a',
      key,
      '-w',
    ]);
    if (result.exitCode == _notFound) return null;
    if (!result.succeeded) {
      throw StateError('keychain read failed: ${result.stderr}');
    }
    return utf8.decode(_fromHex(result.stdout.trim()));
  }

  @override
  Future<void> write(String key, String value) async {
    _checkKey(key);
    final hex = utf8
        .encode(value)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final result = await _executor.run([
      _security,
      '-i',
    ], stdin: 'add-generic-password -U -s "$service" -a "$key" -w $hex\n');
    if (!result.succeeded ||
        result.stdout.contains('error') ||
        result.stderr.isNotEmpty) {
      throw StateError(
        'keychain write failed: ${result.stderr}${result.stdout}',
      );
    }
  }

  @override
  Future<void> delete(String key) async {
    _checkKey(key);
    final result = await _executor.run([
      _security,
      'delete-generic-password',
      '-s',
      service,
      '-a',
      key,
    ]);
    if (!result.succeeded && result.exitCode != _notFound) {
      throw StateError('keychain delete failed: ${result.stderr}');
    }
  }

  void _checkKey(String key) {
    if (!_keyPattern.hasMatch(key)) {
      throw ArgumentError.value(
        key,
        'key',
        'has characters a keychain account name cannot hold here',
      );
    }
  }

  static List<int> _fromHex(String hex) {
    if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
      throw FormatException('keychain item is not hex-encoded', hex);
    }
    return [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }
}
