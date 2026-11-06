import 'dart:convert';

/// Values a template placeholder can resolve against.
///
/// A bare name reads the action params only, so a manifest validator can check
/// it against the declared params. Other roots need a prefix: `state.`,
/// `device.`, `msg.`, `$Name` (global variable) and `%name` (flow variable).
class TemplateContext {
  const TemplateContext({
    this.params = const {},
    this.state = const {},
    this.device = const {},
    this.msg = const {},
    this.globals = const {},
    this.flowVars = const {},
  });

  final Map<String, Object?> params;
  final Map<String, Object?> state;
  final Map<String, Object?> device;
  final Map<String, Object?> msg;
  final Map<String, Object?> globals;
  final Map<String, Object?> flowVars;
}

class TemplateException implements Exception {
  TemplateException(this.message);

  final String message;

  @override
  String toString() => 'TemplateException: $message';
}

/// One `{{...}}` placeholder: alternatives tried left to right.
class Placeholder {
  Placeholder(this.source, this.alternatives);

  final String source;
  final List<PlaceholderTerm> alternatives;

  /// Paths this placeholder can read, for static checks of a manifest.
  Iterable<String> get paths =>
      alternatives.whereType<PathTerm>().map((t) => t.path);
}

sealed class PlaceholderTerm {}

class PathTerm extends PlaceholderTerm {
  PathTerm(this.path);

  final String path;
}

class LiteralTerm extends PlaceholderTerm {
  LiteralTerm(this.value);

  final Object value;
}

final _placeholderPattern = RegExp(r'\{\{([^{}]*)\}\}');
final _pathPattern = RegExp(r'^[$%]?[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*$');
final _numberPattern = RegExp(r'^-?\d+(\.\d+)?$');

/// Renders structured JSON templates.
///
/// A string that is exactly one placeholder becomes the typed value, so
/// `"{{value}}"` with `value: 80` renders the number 80, not the string "80".
/// A placeholder embedded in other text is interpolated as text. Maps and
/// lists are walked recursively.
class TemplateRenderer {
  const TemplateRenderer();

  Object? render(Object? template, TemplateContext context) {
    return switch (template) {
      String s => _renderString(s, context),
      Map m => {
        for (final entry in m.entries)
          entry.key as String: render(entry.value, context),
      },
      List l => [for (final item in l) render(item, context)],
      _ => template,
    };
  }

  /// Renders a template that must produce text (argv elements, text payloads).
  String renderText(String template, TemplateContext context) {
    final rendered = _renderString(template, context);
    return rendered is String ? rendered : _toText(rendered);
  }

  Object? _renderString(String s, TemplateContext context) {
    final matches = _placeholderPattern.allMatches(s).toList();
    if (matches.isEmpty) return s;
    if (matches.length == 1 && matches.first.group(0) == s) {
      return _resolve(parsePlaceholder(matches.first.group(1)!), context);
    }
    return s.replaceAllMapped(_placeholderPattern, (m) {
      return _toText(_resolve(parsePlaceholder(m.group(1)!), context));
    });
  }

  Object? _resolve(Placeholder placeholder, TemplateContext context) {
    for (final term in placeholder.alternatives) {
      switch (term) {
        case LiteralTerm(:final value):
          return value;
        case PathTerm(:final path):
          final (found, value) = _lookup(path, context);
          if (found) return value;
      }
    }
    throw TemplateException('nothing resolved for {{${placeholder.source}}}');
  }

  (bool, Object?) _lookup(String path, TemplateContext context) {
    if (path.startsWith(r'$')) return _walk(context.globals, path.substring(1));
    if (path.startsWith('%')) return _walk(context.flowVars, path.substring(1));
    final dot = path.indexOf('.');
    final head = dot < 0 ? path : path.substring(0, dot);
    final rest = dot < 0 ? '' : path.substring(dot + 1);
    switch (head) {
      case 'state' when rest.isNotEmpty:
        return _walk(context.state, rest);
      case 'device' when rest.isNotEmpty:
        return _walk(context.device, rest);
      case 'msg' when rest.isNotEmpty:
        return _walk(context.msg, rest);
    }
    return _walk(context.params, path);
  }

  (bool, Object?) _walk(Map<String, Object?> root, String dottedPath) {
    Object? current = root;
    for (final segment in dottedPath.split('.')) {
      if (current is Map && current.containsKey(segment)) {
        current = current[segment];
      } else {
        return (false, null);
      }
    }
    return (current != null, current);
  }

  String _toText(Object? value) => switch (value) {
    String s => s,
    num n => n.toString(),
    bool b => b.toString(),
    _ => jsonEncode(value),
  };
}

/// Parses the inside of a placeholder, for example `brightness|state.brightness|100`.
Placeholder parsePlaceholder(String inner) {
  final terms = <PlaceholderTerm>[];
  for (final raw in inner.split('|')) {
    final part = raw.trim();
    if (part.isEmpty) {
      throw TemplateException('empty alternative in {{$inner}}');
    }
    terms.add(_parseTerm(part, inner));
  }
  for (var i = 0; i < terms.length - 1; i++) {
    if (terms[i] is LiteralTerm) {
      throw TemplateException(
        'a literal must be the last alternative in {{$inner}}',
      );
    }
  }
  return Placeholder(inner, terms);
}

PlaceholderTerm _parseTerm(String part, String inner) {
  if (part == 'true') return LiteralTerm(true);
  if (part == 'false') return LiteralTerm(false);
  if (_numberPattern.hasMatch(part)) return LiteralTerm(num.parse(part));
  if (part.length >= 2 &&
      ((part.startsWith("'") && part.endsWith("'")) ||
          (part.startsWith('"') && part.endsWith('"')))) {
    return LiteralTerm(part.substring(1, part.length - 1));
  }
  if (_pathPattern.hasMatch(part)) return PathTerm(part);
  throw TemplateException('invalid term "$part" in {{$inner}}');
}

/// Every placeholder inside a template, for static validation.
List<Placeholder> placeholdersIn(Object? template) {
  final found = <Placeholder>[];
  void visit(Object? node) {
    switch (node) {
      case String s:
        for (final m in _placeholderPattern.allMatches(s)) {
          found.add(parsePlaceholder(m.group(1)!));
        }
      case Map m:
        m.values.forEach(visit);
      case List l:
        l.forEach(visit);
    }
  }

  visit(template);
  return found;
}
