import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What a web request step got back: the status, the body (as JSON when it
/// parses, else text) and how many bytes of it were read.
typedef WebReply = ({int status, Object? body, int bytes});

/// Sends a rule's web request. Tests stand in for the network.
abstract interface class WebRequester {
  Future<WebReply> send(
    String method,
    Uri url, {
    Map<String, String> headers,
    String? body,
  });
}

/// Reads the web secret [name] (stored under [webSecretKey]), null when none
/// is stored.
typedef WebSecretReader = Future<String?> Function(String name);

/// The key a web request's secret header value is stored under.
String webSecretKey(String name) => 'web/$name';

/// A web secret name: a letter, then letters, digits, `_` or `-`.
final webSecretName = RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$');

/// Why [url] cannot be a web request's address, or null. A `{{...}}` part
/// is filled in when it runs, so it may only sit in the path, query or
/// fragment: the scheme, host, port and user stay as written.
String? webAddressProblem(String url) {
  final trimmed = url.trim();
  final lower = trimmed.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    return 'must be an http:// or https:// address';
  }
  final authority = _authority(trimmed);
  if (authority.contains('{{')) {
    return 'cannot fill the host or port from a placeholder: write the '
        'address out, and use {{...}} only in the path, query or body';
  }
  if (authority.isEmpty) return 'needs a host';
  return null;
}

/// Whether [url] can be a web request's address.
bool webAddressOk(String url) => webAddressProblem(url) == null;

String _authority(String url) {
  final rest = url.substring(url.indexOf('://') + 3);
  final end = rest.indexOf(RegExp(r'[/?#\\]'));
  return end < 0 ? rest : rest.substring(0, end);
}

/// [url] as a step's words: the scheme, host and path, without the user,
/// the query or the fragment, which can carry keys.
String webShownAddress(String url) {
  final trimmed = url.trim();
  final at = trimmed.indexOf('://');
  if (at < 0) return trimmed.split(RegExp(r'[?#]')).first;
  final authority = _authority(trimmed);
  final host = authority.substring(authority.lastIndexOf('@') + 1);
  final rest = trimmed
      .substring(at + 3 + authority.length)
      .split(RegExp(r'[?#]'))
      .first;
  return '${trimmed.substring(0, at + 3)}$host$rest';
}

/// Headers whose value is a credential, so it must come from a secret.
bool webSensitiveHeader(String name) {
  final lower = name.trim().toLowerCase();
  return const {
        'authorization',
        'cookie',
        'proxy-authorization',
        'x-api-key',
      }.contains(lower) ||
      lower.endsWith('-key') ||
      lower.endsWith('-token');
}

/// The secret name of a `{"secret": "name"}` header value, else null.
String? webSecretRef(Object? value) =>
    value is Map &&
        value.length == 1 &&
        value['secret'] is String &&
        webSecretName.hasMatch(value['secret'] as String)
    ? value['secret'] as String
    : null;

/// Why each header of a web request step is wrong, by header name.
Map<String, String> webHeaderProblems(Object? headers) {
  if (headers == null) return const {};
  if (headers is! Map) return const {'': 'must be names to text values'};
  return {
    for (final e in headers.entries)
      if (e.value is! String && webSecretRef(e.value) == null)
        '${e.key}':
            'must be text or {"secret": "name"}, a name of letters, digits, '
            '_ and -'
      else if (e.value is String && webSensitiveHeader('${e.key}'))
        '${e.key}': 'put the token in a secret: {"secret": "name"}',
  };
}

/// The methods a web request step may use.
const webMethods = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'};

/// The most of a reply a step keeps: enough for an API's JSON answer, not
/// a page or a file.
const webReplyLimit = 64 * 1024;

/// Why a web request may not go to [address], or null. The engine's own
/// machine (loopback) and link-local addresses (cloud metadata, a router's
/// fallback) are refused. The private LAN stays open, since reaching the
/// home's own hubs is what the step is for.
String? webAddressRefusal(InternetAddress address) {
  var raw = address.rawAddress;
  if (raw.length == 16 &&
      raw.sublist(0, 10).every((b) => b == 0) &&
      raw[10] == 0xff &&
      raw[11] == 0xff) {
    raw = raw.sublist(12);
  }
  final what = raw.length == 4
      ? raw[0] == 127 || raw.every((b) => b == 0)
            ? 'this machine'
            : raw[0] == 169 && raw[1] == 254
            ? 'a link-local address'
            : null
      : raw.sublist(0, 15).every((b) => b == 0) && raw[15] <= 1
      ? 'this machine'
      : raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80
      ? 'a link-local address'
      : null;
  return what == null
      ? null
      : 'a web request may not go to $what (${address.address})';
}

/// Over dart:io: 15 s to answer, redirects not followed (a 3xx is the
/// answer), a reply cut at [webReplyLimit], and only to an address
/// [refusal] allows, checked on the address it connects to.
class IoWebRequester implements WebRequester {
  const IoWebRequester({
    this.timeout = const Duration(seconds: 15),
    this.refusal = webAddressRefusal,
  });

  final Duration timeout;
  final String? Function(InternetAddress address) refusal;

  @override
  Future<WebReply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final host = url.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost')) {
      throw StateError('a web request may not go to this machine ($host)');
    }
    final client = HttpClient()
      ..connectionTimeout = timeout
      // The address is checked here and connected to as checked, so a name
      // that resolves differently the second time cannot reach this machine.
      ..connectionFactory = (uri, _, _) async {
        final address = await _checkedAddress(uri.host);
        return uri.scheme == 'https'
            ? SecureSocket.startConnect(address, uri.port)
            : Socket.startConnect(address, uri.port);
      };
    try {
      final request = await client.openUrl(method, url).timeout(timeout);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (body != null) request.write(body);
      final response = await request.close().timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length >= webReplyLimit) break;
      }
      final kept = bytes.take(webReplyLimit).toList();
      final text = utf8.decode(kept, allowMalformed: true);
      Object? parsed = text;
      try {
        parsed = jsonDecode(text);
      } on FormatException {
        // Not JSON: the text is the body.
      }
      return (status: response.statusCode, body: parsed, bytes: kept.length);
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

  Future<InternetAddress> _checkedAddress(String host) async {
    final addresses = await InternetAddress.lookup(host).timeout(timeout);
    for (final a in addresses) {
      if (refusal(a) case final why?) throw StateError(why);
    }
    if (addresses.isEmpty) throw StateError('could not find $host');
    return addresses.first;
  }
}
