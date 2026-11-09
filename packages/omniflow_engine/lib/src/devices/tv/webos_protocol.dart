import 'dart:async';

import '../../manifest/driver_manifest.dart';
import '../channels.dart';
import 'tv_protocol.dart';
import 'tv_socket.dart';

/// The permissions the open lgtv libraries (aiowebostv) request at
/// registration. A manifest may ask for any of them and no others.
const webOsPublishedPermissions = {
  'APP_TO_APP',
  'CLOSE',
  'CONTROL_AUDIO',
  'CONTROL_DISPLAY',
  'CONTROL_INPUT_JOYSTICK',
  'CONTROL_INPUT_MEDIA_PLAYBACK',
  'CONTROL_INPUT_MEDIA_RECORDING',
  'CONTROL_INPUT_TEXT',
  'CONTROL_INPUT_TV',
  'CONTROL_MOUSE_AND_KEYBOARD',
  'CONTROL_POWER',
  'CONTROL_TV_SCREEN',
  'LAUNCH',
  'LAUNCH_WEBAPP',
  'READ_APP_STATUS',
  'READ_COUNTRY_INFO',
  'READ_CURRENT_CHANNEL',
  'READ_INPUT_DEVICE_LIST',
  'READ_INSTALLED_APPS',
  'READ_LGE_SDX',
  'READ_LGE_TV_INPUT_EVENTS',
  'READ_NETWORK_STATE',
  'READ_NOTIFICATIONS',
  'READ_POWER_STATE',
  'READ_RUNNING_APPS',
  'READ_SETTINGS',
  'READ_TV_CHANNEL_LIST',
  'READ_TV_CURRENT_TIME',
  'READ_UPDATE_INFO',
  'SEARCH',
  'TEST_OPEN',
  'TEST_PROTECTED',
  'TEST_SECURE',
  'UPDATE_FROM_REMOTE_APP',
  'WRITE_NOTIFICATION_ALERT',
  'WRITE_NOTIFICATION_TOAST',
  'WRITE_SETTINGS',
};

/// Audio (volume, mute and reading them), power off, launching an app or
/// input, and a toast.
const webOsDefaultPermissions = [
  'CONTROL_AUDIO',
  'CONTROL_POWER',
  'LAUNCH',
  'WRITE_NOTIFICATION_TOAST',
];

const webOsGetVolume = 'ssap://audio/getVolume';
const webOsCreateToast = 'ssap://system.notifications/createToast';
const webOsLaunch = 'ssap://system.launcher/launch';
const webOsToastMaxLength = 100;

final _ssapUri = RegExp(r'^ssap://[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$');
final webOsAppId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
final _controlChars = RegExp(r'[\x00-\x1f\x7f]');
const _registerId = 'register_0';

class WebOsRequest {
  const WebOsRequest(this.uri, this.payload);

  final String uri;
  final Map<String, Object?>? payload;
}

/// LG webOS SSAP: `wss://<tv>:3001` when the port is 3001 or the transport
/// option `"secure"` is true, otherwise `ws://<tv>:3000`. The built-in
/// driver uses 3001, so the certificate pin applies. Port 3000 is plain
/// text, client key included, and is used only when a device is added with
/// port 3000 for old firmware without wss.
///
/// The rendered command is `{"uri": "ssap://...", "payload": {...}}`.
/// Registration sends the stored client key. Without one the TV shows a
/// prompt and answers `registered` with a new key once the user accepts.
class WebOsProtocol implements TvProtocol {
  const WebOsProtocol();

  @override
  String get pairingSecret => 'clientKey';

  @override
  Uri uri(String host, int? port, TransportSpec transport, String? key) {
    final secure = transport.options['secure'] == true || port == 3001;
    return Uri(
      scheme: secure ? 'wss' : 'ws',
      host: host,
      port: port ?? (secure ? 3001 : 3000),
      path: '/',
    );
  }

  @override
  Object parse(Object? rendered) {
    if (rendered is! Map) {
      throw ArgumentError('a webOS command renders to an object');
    }
    final uri = rendered['uri'];
    if (uri is! String || !_ssapUri.hasMatch(uri)) {
      throw ArgumentError('a webOS command needs an ssap:// uri');
    }
    final payload = rendered['payload'];
    if (payload != null && payload is! Map) {
      throw ArgumentError('a webOS payload is an object');
    }
    final body = payload == null ? null : Map<String, Object?>.from(payload);
    if (uri == webOsCreateToast) {
      final message = body?['message'];
      if (message is! String ||
          message.isEmpty ||
          message.length > webOsToastMaxLength ||
          _controlChars.hasMatch(message)) {
        throw ArgumentError(
          'a toast is 1 to $webOsToastMaxLength characters on one line',
        );
      }
    }
    if (uri == webOsLaunch) {
      final id = body?['id'];
      if (id is! String || !webOsAppId.hasMatch(id)) {
        throw ArgumentError('a webOS app id is letters, digits and ._-');
      }
    }
    return WebOsRequest(uri, body);
  }

  List<String> _permissions(TransportSpec transport) {
    final raw = transport.options['permissions'];
    if (raw == null) return webOsDefaultPermissions;
    if (raw is! List || raw.isEmpty) {
      throw ArgumentError('webOS permissions is a non-empty list');
    }
    final unknown = raw.where((p) => !webOsPublishedPermissions.contains(p));
    if (unknown.isNotEmpty) {
      throw ArgumentError('unknown webOS permissions: ${unknown.join(', ')}');
    }
    return raw.cast<String>();
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
    socket.send({
      'type': 'register',
      'id': _registerId,
      'payload': {
        'forcePairing': false,
        'pairingType': 'PROMPT',
        'client-key': ?pairingKey,
        'manifest': {
          'manifestVersion': 1,
          'appVersion': '1.1',
          'permissions': _permissions(transport),
        },
      },
    });
    // A `response` with pairingType PROMPT only says the prompt is showing.
    final reply = await socket.next(
      (m) =>
          m['id'] == _registerId &&
          (m['type'] == 'registered' ||
              m['type'] == 'error' ||
              (!allowPairing && _isPrompt(m))),
      timeout,
    );
    if (_isPrompt(reply)) throw PairingRequiredException(deviceId);
    if (reply['type'] == 'error') {
      throw TvPairingException(
        '$deviceId refused pairing: ${reply['error'] ?? 'no reason given'}',
      );
    }
    final payload = reply['payload'];
    final key = payload is Map ? payload['client-key'] : null;
    if (key is! String || key.isEmpty) {
      throw TvPairingException('$deviceId registered without a key');
    }
    return key;
  }

  static bool _isPrompt(Map<String, Object?> message) {
    final payload = message['payload'];
    return message['type'] == 'response' &&
        payload is Map &&
        payload['pairingType'] == 'PROMPT';
  }

  @override
  Future<ChannelReply> deliver(
    TvConnection connection,
    Object command, {
    required String deviceId,
    required Duration timeout,
  }) async {
    final request = command as WebOsRequest;
    final id = connection.nextId();
    final reply = connection.socket.next((m) => m['id'] == id, timeout);
    connection.socket.send({
      'type': 'request',
      'id': id,
      'uri': request.uri,
      'payload': ?request.payload,
    });
    final message = await reply;
    if (message['type'] == 'error') {
      throw CommandFailedException(
        '$deviceId: ${message['error'] ?? 'request failed'}',
      );
    }
    final raw = message['payload'];
    final payload = raw is Map ? Map<String, Object?>.from(raw) : null;
    if (payload != null && payload['returnValue'] == false) {
      throw CommandFailedException(
        '$deviceId: ${payload['errorText'] ?? 'request failed'}',
      );
    }
    if (request.uri == webOsGetVolume && payload != null) {
      return ChannelReply(_flattenVolume(payload));
    }
    return ChannelReply(payload);
  }

  /// webOS 5 and later nest the reading under `volumeStatus` with
  /// `muteStatus`; older firmware puts `volume` and `muted` at the top. One
  /// shape lets the manifest read `$.volume` and `$.muted` on both.
  static Map<String, Object?> _flattenVolume(Map<String, Object?> payload) {
    final nested = payload['volumeStatus'];
    final status = nested is Map ? nested : payload;
    return {
      ...payload,
      'volume': ?status['volume'],
      'muted': ?(status['muteStatus'] ?? status['muted'] ?? status['mute']),
    };
  }
}
