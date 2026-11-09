import 'dart:convert';
import 'dart:io';

import '../manifest/driver_manifest.dart';
import '../template/template_renderer.dart';
import '../storage/secret_store.dart';
import '../transports/host_exec.dart';
import '../transports/ssh_executor.dart';
import '../transports/udp_transport.dart';
import 'device.dart';

/// What a channel needs to deliver one rendered command.
class ChannelRequest {
  const ChannelRequest({
    required this.device,
    required this.manifest,
    required this.command,
    required this.context,
    this.allowPairing = true,
  });

  final Device device;
  final DriverManifest manifest;

  /// Whether the channel may start a pairing (a prompt on a TV) when the
  /// device does not know this engine yet. False for agents: pairing is the
  /// user's step, so the command fails with [PairingRequiredException].
  final bool allowPairing;

  /// The command template. Channels that send structured payloads receive it
  /// rendered. The exec channel renders it as argv itself.
  final Object? command;
  final TemplateContext context;
}

/// The reply a channel got back, as JSON when it has one.
class ChannelReply {
  const ChannelReply(this.json, {this.raw});

  final Map<String, Object?>? json;
  final String? raw;
}

class CommandFailedException implements Exception {
  CommandFailedException(this.message);

  final String message;

  @override
  String toString() => 'CommandFailedException: $message';
}

/// The device is not paired with this engine, and the caller may not start
/// a pairing ([ChannelRequest.allowPairing] is false).
class PairingRequiredException extends CommandFailedException {
  PairingRequiredException(String deviceId)
    : super(
        '$deviceId is not paired with OmniFlow yet. Pair it first: '
        'omni device pair $deviceId, or Pair in the device menu of the app',
      );
}

/// Delivers a command over one transport type.
abstract interface class DriverChannel {
  Future<ChannelReply> send(ChannelRequest request);
}

/// JSON over UDP, expecting a reply from the device (WiZ, the OmniFlow MCU
/// protocol and similar).
///
/// With the transport option `"requestId": true` each command gets a fresh
/// `id` and only the reply carrying that id is accepted, so a late reply to
/// an earlier command is never mistaken for this one. For devices that echo
/// a fixed id (WiZ), `"matchMethod": true` accepts only a reply whose
/// `method` is the command's. A reply with an `error` field, or with
/// `"event": "error"`, fails the command.
class UdpJsonChannel implements DriverChannel {
  UdpJsonChannel(this._udp, {this._renderer = const TemplateRenderer()});

  final UdpTransport _udp;
  final TemplateRenderer _renderer;
  var _nextId = 0;

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    var payload = _renderer.render(request.command, request.context);
    final port = request.device.port ?? request.manifest.transport.port;
    if (port == null) throw ArgumentError('no port for ${request.device.id}');
    final options = request.manifest.transport.options;
    int? id;
    if (options['requestId'] == true) {
      if (payload is! Map) {
        throw ArgumentError('a command with a request id renders to an object');
      }
      id = ++_nextId;
      payload = {...payload, 'id': id};
    }
    final method = options['matchMethod'] == true && payload is Map
        ? payload['method']
        : null;
    final reliability = request.manifest.reliability;
    final reply = await _udp.request(
      InternetAddress(request.device.host),
      port,
      utf8.encode(jsonEncode(payload)),
      timeout: Duration(milliseconds: reliability.timeoutMs),
      retries: reliability.retries,
      accept: id == null && method == null
          ? null
          : (d) {
              final json = _tryJson(d.text);
              return (id == null || json?['id'] == id) &&
                  (method == null || json?['method'] == method);
            },
    );
    final decoded = _tryJson(reply.text);
    if (decoded != null && decoded['error'] != null) {
      throw CommandFailedException(
        '${request.device.id} replied with error ${jsonEncode(decoded['error'])}',
      );
    }
    if (decoded != null && decoded['event'] == 'error') {
      throw CommandFailedException(
        '${request.device.id}: ${decoded['message'] ?? 'error'}',
      );
    }
    return ChannelReply(decoded, raw: reply.text);
  }
}

/// Runs an argv on a host: this machine for `local`, SSH otherwise.
class ExecChannel implements DriverChannel {
  ExecChannel(this._executorFor, {this._renderer = const TemplateRenderer()});

  final HostExecutor Function(Device device) _executorFor;
  final TemplateRenderer _renderer;

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    final argv = renderArgv(
      request.command,
      request.context,
      renderer: _renderer,
    );
    final stdin = request.context.params['stdin'];
    final result = await _executorFor(request.device).run(
      argv,
      stdin: stdin is String ? stdin : null,
      timeout: Duration(milliseconds: request.manifest.reliability.timeoutMs),
    );
    if (!result.succeeded) {
      throw CommandFailedException(
        '${argv.first} exited ${result.exitCode}: ${result.stderr}',
      );
    }
    return ChannelReply({
      'exitCode': result.exitCode,
      'stdout': result.stdout,
      'stderr': result.stderr,
    }, raw: result.stdout);
  }
}

Map<String, Object?>? _tryJson(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is Map ? Map<String, Object?>.from(decoded) : null;
  } on FormatException {
    return null;
  }
}

/// Picks how to run a command for [device]: on this machine when its host is
/// `local`, otherwise over SSH with the device's username and stored key.
HostExecutor Function(Device device) hostExecutors(SecretStore secrets) =>
    (device) {
      if (device.host == 'local') return const LocalExecutor();
      final username = device.settings['username'];
      if (username is! String || username.isEmpty) {
        throw ArgumentError('${device.id} has no username setting for SSH');
      }
      return SshExecutor(
        host: device.host,
        port: device.port ?? 22,
        username: username,
        privateKeySecret: deviceSecretKey(device.id, 'sshPrivateKey'),
        secrets: secrets,
      );
    };
