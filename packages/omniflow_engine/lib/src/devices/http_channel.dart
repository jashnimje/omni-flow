import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../manifest/driver_manifest.dart';
import '../manifest/validation.dart';
import '../storage/secret_store.dart';
import '../template/template_renderer.dart';
import '../transports/packet_tap.dart';
import '../transports/udp_transport.dart';
import 'channels.dart';
import 'device.dart';
import 'xml_reply.dart';

/// The secret setting a Hue light keeps its bridge username in.
const hueUsernameSecret = 'username';

/// A device refused the secret it was sent: a wrong or expired token, or a
/// Hue username the bridge no longer knows.
class SecretRejectedException extends CommandFailedException {
  SecretRejectedException(super.message, {required this.secretKey});

  /// The secret setting that was refused, never its value.
  final String secretKey;

  @override
  String toString() => 'SecretRejectedException: $message';
}

/// A Hue bridge refused pairing because its link button was not pressed.
class LinkButtonNotPressedException extends CommandFailedException {
  LinkButtonNotPressedException(super.message);

  @override
  String toString() => 'LinkButtonNotPressedException: $message';
}

final _secretSegment = RegExp(r'^:secret:([A-Za-z][A-Za-z0-9_]*)$');
final _headerName = RegExp(r"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$");
final _authScheme = RegExp(r'^[A-Za-z][A-Za-z0-9._~+-]*$');
final _controlChar = RegExp(r'[\x00-\x1f\x7f]');
final _hueAppName = RegExp(r'^[A-Za-z0-9 _-]{1,19}$');
const _reservedHeaders = {
  'host',
  'content-length',
  'content-type',
  'connection',
  'transfer-encoding',
};
const _hueLinkButtonNotPressed = 101;

/// Why an HTTP manifest's secret options cannot work, or an empty list.
///
/// Checks the `auth` and `authErrorTypes` transport options, `flattenReply`,
/// and every `:secret:<setting>` path segment in the capability and poll
/// commands. A secret named anywhere must be a declared secret setting.
List<ValidationIssue> httpTransportIssues(DriverManifest manifest) {
  if (manifest.transport.type != TransportType.http) return const [];
  final issues = IssueCollector();
  final secretKeys = {
    for (final s in manifest.settings)
      if (s.secret) s.key,
  };
  final options = manifest.transport.options;
  const at = r'$.transport';

  final auth = options['auth'];
  if (auth != null) {
    if (auth is! Map) {
      issues.add('$at.auth', 'must be an object');
    } else {
      final header = auth['header'];
      if (header is! String || !_headerName.hasMatch(header)) {
        issues.add('$at.auth.header', 'must be an HTTP header name');
      } else if (_reservedHeaders.contains(header.toLowerCase())) {
        issues.add('$at.auth.header', '$header is set by the channel');
      }
      final scheme = auth['scheme'];
      if (scheme != null &&
          (scheme is! String || !_authScheme.hasMatch(scheme))) {
        issues.add('$at.auth.scheme', 'must be one word, such as Bearer');
      }
      final secret = auth['secret'];
      if (secret is! String || !secretKeys.contains(secret)) {
        issues.add('$at.auth.secret', 'must name a secret setting');
      }
      for (final key in auth.keys) {
        if (!const {'header', 'scheme', 'secret'}.contains(key)) {
          issues.add('$at.auth.$key', 'is not an auth option');
        }
      }
    }
  }
  final errorTypes = options['authErrorTypes'];
  if (errorTypes != null &&
      (errorTypes is! List || errorTypes.any((t) => t is! int))) {
    issues.add('$at.authErrorTypes', 'must be a list of whole numbers');
  }
  final flatten = options['flattenReply'];
  if (flatten != null && (flatten is! String || flatten.isEmpty)) {
    issues.add('$at.flattenReply', 'must name a key of the reply');
  }
  final reply = options['reply'];
  if (reply != null && reply != 'json' && reply != 'xml') {
    issues.add('$at.reply', 'must be json or xml');
  }

  void checkCommand(Object? command, String path) {
    if (command is! Map) return;
    final rawPath = command['path'];
    if (rawPath is String) {
      for (final segment in rawPath.split('/')) {
        if (!segment.contains(':secret:')) continue;
        final key = _secretSegment.firstMatch(segment)?.group(1);
        if (key == null) {
          issues.add('$path.path', 'a secret is a whole segment, :secret:name');
        } else if (!secretKeys.contains(key)) {
          issues.add('$path.path', '$key is not a secret setting');
        }
      }
    }
    for (final part in ['query', 'body', 'soap']) {
      if (_mentionsSecret(command[part])) {
        issues.add(
          '$path.$part',
          'secrets go only in the path or the auth header',
        );
      }
    }
  }

  for (var i = 0; i < manifest.capabilities.length; i++) {
    checkCommand(
      manifest.capabilities[i].command,
      '\$.capabilities[$i].command',
    );
  }
  checkCommand(manifest.statePoll?['command'], r'$.statePoll.command');
  final also = manifest.statePoll?['also'];
  if (also is List) {
    for (var i = 0; i < also.length; i++) {
      final extra = also[i];
      checkCommand(
        extra is Map ? extra['command'] : null,
        '\$.statePoll.also[$i].command',
      );
    }
  }
  return issues.issues;
}

bool _mentionsSecret(Object? node) => switch (node) {
  String s => s.contains(':secret:'),
  Map m => m.values.any(_mentionsSecret) || m.keys.any(_mentionsSecret),
  List l => l.any(_mentionsSecret),
  _ => false,
};

/// Local HTTP APIs (Shelly, Tasmota, ESPHome, a Hue bridge, Home Assistant).
///
/// The rendered command is `{"method": "GET", "path": "/rpc/Switch.Set",
/// "query": {...}, "body": {...}}`. Query values are sent as text, a body as
/// JSON. A 4xx or 5xx reply fails the command, and so does a JSON list reply
/// holding an `{"error": {...}}` item (the Hue style). A device that does not
/// answer is a transport timeout, so address healing can run.
///
/// Secrets come from the [SecretStore], under `deviceSecretKey(device.id,
/// setting)`, and templates never see them. Two places take one:
///
/// - the transport option `"auth": {"header": "Authorization", "scheme":
///   "Bearer", "secret": "token"}` sends `Authorization: Bearer` and the
///   token.
/// - a whole path segment `:secret:username` in the driver's own path
///   template is replaced by the secret, URL encoded. The same text coming
///   from a param or setting stays literal.
///
/// The packet tap and every error message show `***` in place of a secret,
/// and a reply echoing one gets it replaced the same way. A request carrying
/// a secret does not follow redirects. HTTP 401 or 403, or a list error whose
/// `type` is in the `authErrorTypes` option, is a [SecretRejectedException].
/// The option `"flattenReply": "attributes"` lifts that object's keys to the
/// top of a JSON reply, so a capability reads `$.brightness`.
///
/// For UPnP and Roku: a command part `"soap": {"service", "action", "args"}`
/// is sent as a SOAP envelope with its SOAPACTION header, every argument
/// escaped ([soapRequest]), and the option `"reply": "xml"` reads the reply
/// as XML, its leaf elements becoming keys ([flattenXml]). A UPnP fault is a
/// failed command naming its error code.
class HttpChannel implements DriverChannel {
  HttpChannel({
    this._renderer = const TemplateRenderer(),
    this._tap,
    this._secrets,
  });

  final TemplateRenderer _renderer;
  final PacketTap? _tap;
  final SecretStore? _secrets;
  final _valid = Expando<bool>();
  final _random = Random.secure();

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    final manifest = request.manifest;
    final device = request.device;
    _checkManifest(manifest);
    final options = manifest.transport.options;
    final auth = options['auth'] is Map ? options['auth'] as Map : null;
    final authKey = auth?['secret'] as String?;

    final command = request.command;
    final rawPath = command is Map ? command['path'] : null;
    final pathKeys = [
      if (rawPath is String)
        for (final segment in rawPath.split('/'))
          ?_secretSegment.firstMatch(segment)?.group(1),
    ];
    final secretKeys = {
      for (final s in manifest.settings)
        if (s.secret) s.key,
    };
    for (final key in pathKeys) {
      if (!secretKeys.contains(key)) {
        throw ArgumentError('$key is not a secret setting of ${manifest.id}');
      }
    }
    final secrets = <String, String>{
      for (final key in {...pathKeys, ?authKey})
        key: await _readSecret(device, key),
    };

    final marker = pathKeys.isEmpty ? null : _newMarker();
    final template = marker == null
        ? command
        : {...command as Map, 'path': _markSegments(rawPath as String, marker)};
    final rendered = _renderer.render(template, request.context);
    if (rendered is! Map) {
      throw ArgumentError('an HTTP command renders to an object');
    }
    final method = (rendered['method'] ?? 'GET').toString().toUpperCase();
    if (!const {'GET', 'POST', 'PUT', 'DELETE'}.contains(method)) {
      throw ArgumentError('unsupported HTTP method $method');
    }
    final path = rendered['path'];
    if (path is! String || !path.startsWith('/')) {
      throw ArgumentError('an HTTP command needs a path starting with /');
    }
    final markerPattern = marker == null ? null : RegExp('${marker}_(\\d+)_');
    final sentPath = markerPattern == null
        ? path
        : path.replaceAllMapped(
            markerPattern,
            (m) => Uri.encodeComponent(secrets[pathKeys[int.parse(m[1]!)]]!),
          );
    final shownPath = markerPattern == null
        ? path
        : path.replaceAll(markerPattern, '***');
    _rejectDotSegments(sentPath);

    final query = rendered['query'];
    final uri = Uri(
      scheme: 'http',
      host: device.host,
      port: device.port ?? manifest.transport.port ?? 80,
      path: sentPath,
      queryParameters: query is Map && query.isNotEmpty
          ? {for (final e in query.entries) e.key.toString(): '${e.value}'}
          : null,
    );
    final headers = <String, String>{};
    var shown = '$method $shownPath${uri.hasQuery ? '?${uri.query}' : ''}';
    if (auth != null) {
      final header = auth['header'] as String;
      final scheme = auth['scheme'] as String?;
      final token = secrets[authKey]!;
      if (_controlChar.hasMatch(token)) {
        throw ArgumentError(
          'the $authKey secret of ${device.id} holds a control character',
        );
      }
      headers[header] = scheme == null ? token : '$scheme $token';
      shown += '\n$header: ${scheme == null ? '***' : '$scheme ***'}';
    }
    final soap = rendered['soap'] == null
        ? null
        : soapRequest(rendered['soap']);
    if (soap != null) {
      headers['SOAPACTION'] = '"${soap.$2}"';
      shown += '\nSOAPACTION: "${soap.$2}"';
    }
    final xmlReply = options['reply'] == 'xml';
    final reliability = manifest.reliability;
    final (status, text, _) = await _exchange(
      deviceId: device.id,
      method: method,
      uri: uri,
      headers: headers,
      body: soap == null ? rendered['body'] : null,
      xmlBody: soap?.$1,
      shown: shown,
      secrets: secrets.values,
      timeout: Duration(milliseconds: reliability.timeoutMs),
      retries: reliability.retries,
    );
    final usedKeys = secrets.keys.join(' and ');
    if (secrets.isNotEmpty && status >= 300 && status < 400) {
      throw CommandFailedException(
        '${device.id} answered HTTP $status, a redirect, which a request '
        'carrying a secret does not follow',
      );
    }
    if (secrets.isNotEmpty && (status == 401 || status == 403)) {
      throw SecretRejectedException(
        '${device.id} refused its $usedKeys secret (HTTP $status). It is '
        'wrong or expired: store a new one with omni secret set',
        secretKey: usedKeys,
      );
    }
    if (status >= 400) {
      final upnp = xmlReply ? flattenXml(text) : null;
      final code = upnp?['errorCode'];
      if (code != null) {
        final words = upnp?['errorDescription'];
        throw CommandFailedException(
          '${device.id} refused the command: UPnP error $code'
          '${words is String && words.isNotEmpty ? ' ($words)' : ''}',
        );
      }
      throw CommandFailedException('${device.id} answered HTTP $status: $text');
    }
    if (xmlReply) return ChannelReply(flattenXml(text), raw: text);
    final decoded = _tryDecode(text);
    if (decoded is List) {
      final errors = [
        for (final item in decoded)
          if (item is Map && item['error'] is Map) item['error'] as Map,
      ];
      if (errors.isNotEmpty) {
        final authTypes = options['authErrorTypes'];
        final described = errors
            .map((e) => '${e['description'] ?? jsonEncode(e)}')
            .join('; ');
        if (secrets.isNotEmpty &&
            authTypes is List &&
            errors.any((e) => authTypes.contains(e['type']))) {
          throw SecretRejectedException(
            '${device.id} refused its $usedKeys secret ($described). '
            'Pair again or store a new one with omni secret set',
            secretKey: usedKeys,
          );
        }
        throw CommandFailedException(
          '${device.id} replied with error: $described',
        );
      }
    }
    var json = decoded is Map ? Map<String, Object?>.from(decoded) : null;
    final flatten = options['flattenReply'];
    final nested = flatten is String && json != null ? json[flatten] : null;
    if (json != null && nested is Map) {
      json = {...Map<String, Object?>.from(nested), ...json};
    }
    return ChannelReply(json, raw: text);
  }

  /// Pairs with the Philips Hue bridge at [host] (REST API v1) and stores
  /// the username it issues as the `username` secret of each device in
  /// [deviceIds], the lights on that bridge. The username is never returned,
  /// logged or shown in the packet tap.
  ///
  /// The bridge's link button must be pressed in the 30 seconds before;
  /// otherwise this throws [LinkButtonNotPressedException]. [appName] goes
  /// into the bridge's app list as `omniflow#<appName>`.
  Future<void> pairHueBridge({
    required String host,
    int port = 80,
    required List<String> deviceIds,
    String appName = 'omniflow',
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final store =
        _secrets ?? (throw StateError('the HTTP channel has no secret store'));
    if (deviceIds.isEmpty) {
      throw ArgumentError('pairing needs a device to store the username for');
    }
    if (!_hueAppName.hasMatch(appName)) {
      throw ArgumentError(
        'a Hue app name is 1 to 19 letters, digits, spaces, _ or -',
      );
    }
    final uri = Uri(scheme: 'http', host: host, port: port, path: '/api');
    final (status, text, raw) = await _exchange(
      deviceId: 'Hue bridge',
      method: 'POST',
      uri: uri,
      headers: const {},
      body: {'devicetype': 'omniflow#$appName'},
      shown: 'POST /api',
      secrets: const [],
      revealed: (text) => [?_hueUsername(_tryDecode(text))],
      timeout: timeout,
      retries: 0,
    );
    if (status >= 400) {
      throw CommandFailedException(
        'the Hue bridge at $host answered HTTP $status: $text',
      );
    }
    final decoded = _tryDecode(raw);
    final username = _hueUsername(decoded);
    if (username != null) {
      for (final id in deviceIds) {
        await store.write(deviceSecretKey(id, hueUsernameSecret), username);
      }
      return;
    }
    final error = decoded is List && decoded.isNotEmpty && decoded.first is Map
        ? (decoded.first as Map)['error']
        : null;
    if (error is Map && error['type'] == _hueLinkButtonNotPressed) {
      throw LinkButtonNotPressedException(
        'press the link button on the Hue bridge at $host, then pair again '
        'within 30 seconds',
      );
    }
    if (error is Map) {
      throw CommandFailedException(
        'the Hue bridge at $host refused pairing: '
        '${error['description'] ?? jsonEncode(error)}',
      );
    }
    throw CommandFailedException(
      '$host did not answer like a Hue bridge: $text',
    );
  }

  /// Returns the status, the reply with secrets redacted, and the raw reply
  /// for a caller that must read a secret out of it.
  Future<(int, String, String)> _exchange({
    required String deviceId,
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required Object? body,
    String? xmlBody,
    required String shown,
    required Iterable<String> secrets,
    Iterable<String> Function(String text)? revealed,
    required Duration timeout,
    required int retries,
  }) async {
    final encoded = xmlBody ?? (body == null ? null : jsonEncode(body));
    for (var attempt = 0; attempt <= retries; attempt++) {
      final client = HttpClient()..connectionTimeout = timeout;
      try {
        final req = await client.openUrl(method, uri).timeout(timeout);
        req.followRedirects = secrets.isEmpty;
        headers.forEach(req.headers.set);
        if (encoded != null) {
          req.headers.contentType = xmlBody == null
              ? ContentType.json
              : ContentType('text', 'xml', charset: 'utf-8');
          req.write(encoded);
        }
        _record(
          PacketDirection.outgoing,
          uri,
          _redact(encoded == null ? shown : '$shown\n\n$encoded', secrets),
        );
        final res = await req.close().timeout(timeout);
        final raw = await res
            .transform(const Utf8Decoder(allowMalformed: true))
            .join()
            .timeout(timeout);
        final text = _redact(raw, [...secrets, ...?revealed?.call(raw)]);
        _record(PacketDirection.incoming, uri, '${res.statusCode} $text');
        return (res.statusCode, text, raw);
      } on TimeoutException {
        continue;
      } on SocketException {
        continue;
      } on HttpException catch (e) {
        throw CommandFailedException(
          '$deviceId: the HTTP exchange failed: ${_redact(e.message, secrets)}',
        );
      } finally {
        client.close(force: true);
      }
    }
    throw TransportTimeoutException(
      'no HTTP reply from $deviceId at ${uri.host}:${uri.port}',
    );
  }

  void _checkManifest(DriverManifest manifest) {
    if (_valid[manifest] == true) return;
    final issues = httpTransportIssues(manifest);
    if (issues.isNotEmpty) {
      throw ValidationException('driver manifest ${manifest.id}', issues);
    }
    _valid[manifest] = true;
  }

  Future<String> _readSecret(Device device, String key) async {
    final store =
        _secrets ?? (throw StateError('the HTTP channel has no secret store'));
    final name = deviceSecretKey(device.id, key);
    final value = await store.read(name);
    if (value == null || value.isEmpty) throw MissingSecretException(name);
    return value;
  }

  /// A per-request marker for the secret segments. Rendered params cannot
  /// guess it, so only the driver's own path template reaches a secret.
  String _newMarker() =>
      'omnisecret${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  static String _markSegments(String path, String marker) {
    var index = 0;
    return path
        .split('/')
        .map((s) => _secretSegment.hasMatch(s) ? '${marker}_${index++}_' : s)
        .join('/');
  }

  /// A setting such as an entity id must not climb out of the API path the
  /// driver names, since the request carries the device's token.
  static void _rejectDotSegments(String path) {
    for (final segment in path.split('/')) {
      final String decoded;
      try {
        decoded = Uri.decodeComponent(segment);
      } on ArgumentError {
        throw ArgumentError('an HTTP command path has a bad % escape');
      }
      if (decoded == '.' || decoded == '..') {
        throw ArgumentError('an HTTP command path cannot hold . or ..');
      }
    }
  }

  void _record(PacketDirection direction, Uri uri, String text) => _tap?.record(
    CapturedPacket(
      transport: 'http',
      direction: direction,
      remote: '${uri.host}:${uri.port}',
      bytes: utf8.encode(text),
    ),
  );
}

String? _hueUsername(Object? decoded) {
  if (decoded is! List || decoded.isEmpty) return null;
  final first = decoded.first;
  final success = first is Map ? first['success'] : null;
  final username = success is Map ? success['username'] : null;
  return username is String &&
          username.isNotEmpty &&
          !_controlChar.hasMatch(username)
      ? username
      : null;
}

Object? _tryDecode(String text) {
  if (text.isEmpty) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// [text] with every form of each secret (as is, URL encoded, JSON escaped)
/// replaced by `***`.
String _redact(String text, Iterable<String> secrets) {
  var out = text;
  for (final secret in secrets) {
    if (secret.isEmpty) continue;
    final escaped = jsonEncode(secret);
    for (final form in {
      secret,
      Uri.encodeComponent(secret),
      escaped.substring(1, escaped.length - 1),
    }) {
      out = out.replaceAll(form, '***');
    }
  }
  return out;
}
