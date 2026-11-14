/// Small XML helpers for the local APIs that answer in XML: Roku's ECP
/// queries and UPnP SOAP (Sonos). Not a general XML parser. It reads
/// elements, attributes, text, CDATA and the five named entities plus
/// numeric ones, which is all those replies use.
library;

final _token = RegExp(
  r'<!\[CDATA\[([\s\S]*?)\]\]>|<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<![^>]*>|<(/?)([A-Za-z_][\w.:-]*)([^>]*?)(/?)>',
);
final _attribute = RegExp(r'''([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');
final _wholeNumber = RegExp(r'^-?\d{1,9}$');
final _name = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');
final _service = RegExp(r'^urn:[A-Za-z0-9:._-]+$');

/// Every leaf element of [xml] (one holding only text) as `name: text`,
/// with each attribute as `name_attribute`. A namespace prefix is dropped
/// and a hyphen becomes an underscore, so `<power-mode>` reads as
/// `power_mode` and `<u:GetVolumeResponse><CurrentVolume>` as
/// `CurrentVolume`. Whole numbers become numbers. The first element of a
/// name wins. Returns null when [xml] has no element at all.
Map<String, Object?>? flattenXml(String xml) {
  final out = <String, Object?>{};
  final stack = <(String, bool)>[];
  var text = StringBuffer();
  var sawElement = false;
  var last = 0;

  void put(String key, String value) {
    out.putIfAbsent(key, () => _typed(value));
  }

  for (final m in _token.allMatches(xml)) {
    text.write(xml.substring(last, m.start));
    last = m.end;
    final cdata = m[1];
    if (cdata != null) {
      text.write(cdata);
      continue;
    }
    final name = m[3];
    if (name == null) continue;
    final key = _key(name);
    if (m[2] == '/') {
      while (stack.isNotEmpty) {
        final (open, hasChild) = stack.removeLast();
        if (open == key) {
          if (!hasChild) put(key, _unescape(text.toString()).trim());
          break;
        }
      }
      text = StringBuffer();
      continue;
    }
    sawElement = true;
    if (stack.isNotEmpty) stack[stack.length - 1] = (stack.last.$1, true);
    for (final a in _attribute.allMatches(m[4] ?? '')) {
      final attr = a[1]!;
      if (attr.startsWith('xmlns') || attr.contains(':')) continue;
      put('${key}_${_key(attr)}', _unescape(a[2] ?? a[3] ?? ''));
    }
    if (m[5] == '/') {
      put(key, '');
    } else {
      stack.add((key, false));
    }
    text = StringBuffer();
  }
  return sawElement ? out : null;
}

String _key(String name) {
  final colon = name.lastIndexOf(':');
  return (colon < 0 ? name : name.substring(colon + 1)).replaceAll('-', '_');
}

Object _typed(String value) =>
    _wholeNumber.hasMatch(value) ? int.parse(value) : value;

String _unescape(String text) => text.replaceAllMapped(
  RegExp(r'&(#x[0-9A-Fa-f]+|#\d+|lt|gt|amp|quot|apos);'),
  (m) {
    final e = m[1]!;
    if (e.startsWith('#x')) {
      return String.fromCharCode(int.parse(e.substring(2), radix: 16));
    }
    if (e.startsWith('#')) {
      return String.fromCharCode(int.parse(e.substring(1)));
    }
    return const {
      'lt': '<',
      'gt': '>',
      'amp': '&',
      'quot': '"',
      'apos': "'",
    }[e]!;
  },
);

/// [text] safe inside an XML element or a double-quoted attribute.
String escapeXml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// A UPnP SOAP request from a rendered `soap` command part:
/// `{"service": "urn:schemas-upnp-org:service:AVTransport:1", "action":
/// "Play", "args": {"InstanceID": 0, "Speed": 1}}`. Returns the envelope
/// and the SOAPACTION value. Every argument value is escaped, so a param
/// cannot add elements, and a boolean goes as 1 or 0. Throws
/// [ArgumentError] for a malformed part.
(String, String) soapRequest(Object? soap) {
  if (soap is! Map) throw ArgumentError('soap must be an object');
  final service = soap['service'];
  final action = soap['action'];
  final args = soap['args'] ?? const {};
  if (service is! String || !_service.hasMatch(service)) {
    throw ArgumentError('soap.service must be a UPnP service urn');
  }
  if (action is! String || !_name.hasMatch(action)) {
    throw ArgumentError('soap.action must be one word');
  }
  if (args is! Map) throw ArgumentError('soap.args must be an object');
  final body = StringBuffer();
  for (final MapEntry(:key, :value) in args.entries) {
    if (key is! String || !_name.hasMatch(key)) {
      throw ArgumentError('soap.args key "$key" must be one word');
    }
    if (value is Map || value is List) {
      throw ArgumentError('soap.args.$key must be a plain value');
    }
    final text = switch (value) {
      true => '1',
      false => '0',
      null => '',
      _ => '$value',
    };
    body.write('<$key>${escapeXml(text)}</$key>');
  }
  final envelope =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:$action xmlns:u="$service">$body</u:$action></s:Body>'
      '</s:Envelope>';
  return (envelope, '$service#$action');
}
