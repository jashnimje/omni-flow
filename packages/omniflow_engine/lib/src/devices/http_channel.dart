import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../template/template_renderer.dart';
import '../transports/packet_tap.dart';
import '../transports/udp_transport.dart';
import 'channels.dart';

/// Local HTTP APIs (Shelly, Tasmota, ESPHome and similar).
///
/// The rendered command is `{"method": "GET", "path": "/rpc/Switch.Set",
/// "query": {...}, "body": {...}}`. Query values are sent as text, a body as
/// JSON. A 4xx or 5xx reply fails the command. A device that does not answer
/// is a transport timeout, so address healing can run.
class HttpChannel implements DriverChannel {
  HttpChannel({this._renderer = const TemplateRenderer(), this._tap});

  final TemplateRenderer _renderer;
  final PacketTap? _tap;

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    final rendered = _renderer.render(request.command, request.context);
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
    final query = rendered['query'];
    final uri = Uri(
      scheme: 'http',
      host: request.device.host,
      port: request.device.port ?? request.manifest.transport.port ?? 80,
      path: path,
      queryParameters: query is Map && query.isNotEmpty
          ? {for (final e in query.entries) e.key.toString(): '${e.value}'}
          : null,
    );
    final body = rendered['body'];
    final reliability = request.manifest.reliability;
    final timeout = Duration(milliseconds: reliability.timeoutMs);

    for (var attempt = 0; attempt <= reliability.retries; attempt++) {
      final client = HttpClient()..connectionTimeout = timeout;
      try {
        final req = await client.openUrl(method, uri).timeout(timeout);
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        _record(
          PacketDirection.outgoing,
          uri,
          '$method ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
        );
        final res = await req.close().timeout(timeout);
        final text = await res.transform(utf8.decoder).join().timeout(timeout);
        _record(PacketDirection.incoming, uri, '${res.statusCode} $text');
        if (res.statusCode >= 400) {
          throw CommandFailedException(
            '${request.device.id} answered HTTP ${res.statusCode}: $text',
          );
        }
        Object? decoded;
        try {
          decoded = text.isEmpty ? null : jsonDecode(text);
        } on FormatException {
          decoded = null;
        }
        return ChannelReply(
          decoded is Map ? Map<String, Object?>.from(decoded) : null,
          raw: text,
        );
      } on TimeoutException {
        continue;
      } on SocketException {
        continue;
      } finally {
        client.close(force: true);
      }
    }
    throw TransportTimeoutException(
      'no HTTP reply from ${request.device.id} at ${uri.host}:${uri.port}',
    );
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
