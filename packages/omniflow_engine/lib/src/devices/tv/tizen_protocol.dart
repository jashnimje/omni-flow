import 'dart:async';
import 'dart:convert';

import '../../manifest/driver_manifest.dart';
import '../channels.dart';
import 'tv_protocol.dart';
import 'tv_socket.dart';

final tizenKey = RegExp(r'^KEY_[A-Z0-9_]{1,32}$');
final tizenAppId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._]{1,127}$');
final _clientName = RegExp(r'^[A-Za-z0-9 ._-]{1,32}$');
const tizenLaunchTypes = {'DEEP_LINK', 'NATIVE_LAUNCH'};
const _defaultClientName = 'OmniFlow';

class TizenKey {
  const TizenKey(this.key);

  final String key;
}

class TizenLaunch {
  const TizenLaunch(this.appId, this.actionType);

  final String appId;
  final String actionType;
}

/// Samsung Tizen remote control over
/// `wss://<tv>:8002/api/v2/channels/samsung.remote.control`.
///
/// The rendered command is `{"key": "KEY_VOLUP"}`, or `{"key": "up",
/// "keyMap": {"up": "KEY_UP", ...}}` for a capability whose param is a word,
/// or `{"launch": "<app id>", "actionType": "DEEP_LINK"}`. The first connect
/// makes the TV prompt; `ms.channel.connect` then carries the token, which
/// later connects pass in the URL so the TV does not prompt again. The TV
/// sends nothing back for a key, so a command succeeds once it is sent.
class TizenProtocol implements TvProtocol {
  const TizenProtocol();

  @override
  String get pairingSecret => 'token';

  @override
  Uri uri(String host, int? port, TransportSpec transport, String? key) {
    final name = transport.options['clientName'] ?? _defaultClientName;
    if (name is! String || !_clientName.hasMatch(name)) {
      throw ArgumentError('a Tizen clientName is 1 to 32 plain characters');
    }
    return Uri(
      scheme: 'wss',
      host: host,
      port: port ?? 8002,
      path: '/api/v2/channels/samsung.remote.control',
      queryParameters: {
        'name': base64.encode(utf8.encode(name)),
        'token': ?key,
      },
    );
  }

  @override
  Object parse(Object? rendered) {
    if (rendered is! Map) {
      throw ArgumentError('a Tizen command renders to an object');
    }
    final launch = rendered['launch'];
    if (launch != null) {
      if (launch is! String || !tizenAppId.hasMatch(launch)) {
        throw ArgumentError('a Tizen app id is letters, digits, dots and _');
      }
      final type = rendered['actionType'] ?? 'DEEP_LINK';
      if (!tizenLaunchTypes.contains(type)) {
        throw ArgumentError(
          'a Tizen actionType is one of ${tizenLaunchTypes.join(', ')}',
        );
      }
      return TizenLaunch(launch, type as String);
    }
    var key = rendered['key'];
    final keyMap = rendered['keyMap'];
    if (keyMap != null) {
      if (keyMap is! Map || !keyMap.containsKey(key)) {
        throw ArgumentError('"$key" is not in the command keyMap');
      }
      key = keyMap[key];
    }
    if (key is! String || !tizenKey.hasMatch(key)) {
      throw ArgumentError('a Tizen key is KEY_ and capitals, digits or _');
    }
    return TizenKey(key);
  }

  @override
  Future<String?> pair(
    TvSocket socket, {
    required String deviceId,
    required TransportSpec transport,
    required String? pairingKey,
    required bool allowPairing,
    required Duration timeout,
  }) async {
    const answers = {
      'ms.channel.connect',
      'ms.channel.unauthorized',
      'ms.channel.timeOut',
    };
    final Map<String, Object?> reply;
    try {
      reply = await socket.next((m) => answers.contains(m['event']), timeout);
    } on TimeoutException {
      // A TV that knows the token connects at once, so silence is its
      // pairing prompt.
      if (!allowPairing) throw PairingRequiredException(deviceId);
      rethrow;
    }
    switch (reply['event']) {
      case 'ms.channel.unauthorized':
        throw TvPairingException('$deviceId refused pairing');
      case 'ms.channel.timeOut':
        throw TvPairingException(
          'nobody accepted the pairing prompt on $deviceId',
        );
    }
    final data = reply['data'];
    final token = data is Map ? data['token'] : null;
    return switch (token) {
      String t when t.isNotEmpty => t,
      num t => '$t',
      _ => null,
    };
  }

  @override
  Future<ChannelReply> deliver(
    TvConnection connection,
    Object command, {
    required String deviceId,
    required Duration timeout,
  }) async {
    switch (command) {
      case TizenKey(:final key):
        connection.socket.send({
          'method': 'ms.remote.control',
          'params': {
            'Cmd': 'Click',
            'DataOfCmd': key,
            'Option': 'false',
            'TypeOfRemote': 'SendRemoteKey',
          },
        });
        return ChannelReply({'sent': key});
      case TizenLaunch(:final appId, :final actionType):
        connection.socket.send({
          'method': 'ms.channel.emit',
          'params': {
            'event': 'ed.apps.launch',
            'to': 'host',
            'data': {'appId': appId, 'action_type': actionType, 'metaTag': ''},
          },
        });
        return ChannelReply({'launched': appId});
    }
    throw ArgumentError('not a Tizen command');
  }
}
