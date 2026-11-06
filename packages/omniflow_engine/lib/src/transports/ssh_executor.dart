import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../storage/secret_store.dart';
import 'host_exec.dart';
import 'udp_transport.dart';

class HostKeyMismatchException implements Exception {
  HostKeyMismatchException(this.host, this.pinned, this.offered);

  final String host;
  final String pinned;
  final String offered;

  @override
  String toString() =>
      'HostKeyMismatchException: $host offered $offered but $pinned is pinned. '
      'If the host was reinstalled, clear the pin and connect again.';
}

/// Pins each host's key on first use, in the secret store.
///
/// dartssh2 accepts any host key when no verifier is given, so every SSH
/// connection goes through [verify].
class HostKeyPins {
  HostKeyPins(this._secrets);

  final SecretStore _secrets;

  static String keyFor(String host, int port) => 'ssh/hostkey/$host:$port';

  /// Returns normally when [fingerprint] is pinned or newly pinned, and
  /// throws [HostKeyMismatchException] when a different key is pinned.
  Future<void> verify(
    String host,
    int port,
    String type,
    String fingerprint,
  ) async {
    final offered = '$type $fingerprint';
    final key = keyFor(host, port);
    final pinned = await _secrets.read(key);
    if (pinned == null) {
      await _secrets.write(key, offered);
      return;
    }
    if (pinned != offered) {
      throw HostKeyMismatchException('$host:$port', pinned, offered);
    }
  }

  Future<void> clear(String host, int port) =>
      _secrets.delete(keyFor(host, port));
}

/// Runs an argv on a remote host over SSH, authenticating with a private key
/// from the secret store. The remote side always runs a shell, so the argv is
/// quoted with [posixShellJoin].
class SshExecutor implements HostExecutor {
  SshExecutor({
    required this.host,
    required this.username,
    required this.privateKeySecret,
    required this._secrets,
    this.port = 22,
    this.connectTimeout = const Duration(seconds: 5),
  }) : _pins = HostKeyPins(_secrets);

  final String host;
  final int port;
  final String username;

  /// The secret store key holding the PEM private key.
  final String privateKeySecret;
  final Duration connectTimeout;
  final SecretStore _secrets;
  final HostKeyPins _pins;

  @override
  Future<CommandResult> run(
    List<String> argv, {
    String? stdin,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (argv.isEmpty) throw ArgumentError('argv is empty');
    final pem = await _secrets.read(privateKeySecret);
    if (pem == null) throw MissingSecretException(privateKeySecret);
    final watch = Stopwatch()..start();

    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host, port, timeout: connectTimeout);
    } on Exception catch (e) {
      throw TransportTimeoutException('cannot reach $host:$port over SSH ($e)');
    }
    HostKeyMismatchException? mismatch;
    final client = SSHClient(
      socket,
      username: username,
      identities: SSHKeyPair.fromPem(pem),
      onVerifyHostKey: (type, fingerprint) async {
        try {
          await _pins.verify(host, port, type, utf8.decode(fingerprint));
          return true;
        } on HostKeyMismatchException catch (e) {
          mismatch = e;
          return false;
        }
      },
    );
    try {
      final session = await client
          .execute(posixShellJoin(argv))
          .timeout(timeout);
      final out = _collect(session.stdout);
      final err = _collect(session.stderr);
      if (stdin != null) session.write(Uint8List.fromList(utf8.encode(stdin)));
      await session.stdin.close();
      await session.done.timeout(timeout);
      return CommandResult(
        exitCode: session.exitCode ?? -1,
        stdout: (await out).trimRight(),
        stderr: (await err).trimRight(),
        duration: watch.elapsed,
      );
    } on TimeoutException {
      throw CommandTimeoutException(argv, timeout);
    } catch (_) {
      if (mismatch != null) throw mismatch!;
      rethrow;
    } finally {
      client.close();
    }
  }

  static Future<String> _collect(Stream<Uint8List> stream) =>
      stream.cast<List<int>>().transform(utf8.decoder).join();
}
