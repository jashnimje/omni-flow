import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What a web request step got back: the status and the body, as JSON
/// when it parses, else text.
typedef WebReply = ({int status, Object? body});

/// Sends a rule's web request. Tests stand in for the network.
abstract interface class WebRequester {
  Future<WebReply> send(
    String method,
    Uri url, {
    Map<String, String> headers,
    String? body,
  });
}

/// An address a web request may go to. A `{{...}}` part is filled in
/// when it runs, so only the start is checked here.
bool webAddressOk(String url) {
  final lower = url.trim().toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

/// The methods a web request step may use.
const webMethods = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'};

/// The most of a reply a step keeps: enough for an API's JSON answer, not
/// a page or a file.
const webReplyLimit = 64 * 1024;

/// Over dart:io: 15 s to answer, redirects followed, a reply cut at
/// [webReplyLimit].
class IoWebRequester implements WebRequester {
  const IoWebRequester({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;

  @override
  Future<WebReply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.openUrl(method, url).timeout(timeout);
      headers.forEach(request.headers.set);
      if (body != null) request.write(body);
      final response = await request.close().timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length >= webReplyLimit) break;
      }
      final text = utf8.decode(
        bytes.take(webReplyLimit).toList(),
        allowMalformed: true,
      );
      Object? parsed = text;
      try {
        parsed = jsonDecode(text);
      } on FormatException {
        // Not JSON: the text is the body.
      }
      return (status: response.statusCode, body: parsed);
    } on TimeoutException {
      throw StateError(
        '${url.host} did not answer within ${timeout.inSeconds} s',
      );
    } on SocketException catch (e) {
      throw StateError('could not reach ${url.host}: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }
}
