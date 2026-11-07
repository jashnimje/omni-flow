import 'dart:math' as math;

class ExpressionException implements Exception {
  ExpressionException(this.message);

  final String message;

  @override
  String toString() => 'ExpressionException: $message';
}

/// A small arithmetic language for the math node: numbers, names, `+ - * /
/// %`, parentheses, unary minus, and `min`, `max`, `abs`, `round`, `floor`,
/// `ceil`, `clamp`. Names are resolved by the caller (`value`, `msg.temp`,
/// `$Brightness`, `%count`). Nothing else can be called, so an expression
/// cannot reach the host.
num evaluateExpression(String source, num? Function(String name) resolve) {
  final parser = _Parser(_tokenize(source), resolve);
  final result = parser.expression();
  if (!parser.atEnd) {
    throw ExpressionException('unexpected "${parser.peek}" in $source');
  }
  return result;
}

final _token = RegExp(
  r'\s*(?:(\d+(?:\.\d+)?)|([$%]?[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*)|(\S))',
);

List<String> _tokenize(String source) {
  final tokens = <String>[];
  var pos = 0;
  while (pos < source.length) {
    final m = _token.matchAsPrefix(source, pos);
    if (m == null) break;
    final t = m.group(1) ?? m.group(2) ?? m.group(3);
    if (t != null) tokens.add(t);
    pos = m.end;
  }
  return tokens;
}

class _Parser {
  _Parser(this._tokens, this._resolve);

  final List<String> _tokens;
  final num? Function(String) _resolve;
  var _i = 0;

  bool get atEnd => _i >= _tokens.length;
  String? get peek => atEnd ? null : _tokens[_i];

  String _take() {
    if (atEnd) throw ExpressionException('the expression ends too early');
    return _tokens[_i++];
  }

  void _expect(String t) {
    final got = _take();
    if (got != t) throw ExpressionException('expected "$t", got "$got"');
  }

  num expression() {
    var left = _term();
    while (peek == '+' || peek == '-') {
      final op = _take();
      final right = _term();
      left = op == '+' ? left + right : left - right;
    }
    return left;
  }

  num _term() {
    var left = _unary();
    while (peek == '*' || peek == '/' || peek == '%') {
      final op = _take();
      final right = _unary();
      if ((op == '/' || op == '%') && right == 0) {
        throw ExpressionException('division by zero');
      }
      left = switch (op) {
        '*' => left * right,
        '/' => left / right,
        _ => left % right,
      };
    }
    return left;
  }

  num _unary() {
    if (peek == '-') {
      _take();
      return -_unary();
    }
    if (peek == '+') {
      _take();
      return _unary();
    }
    return _primary();
  }

  num _primary() {
    final t = _take();
    if (t == '(') {
      final v = expression();
      _expect(')');
      return v;
    }
    final number = num.tryParse(t);
    if (number != null) return number;
    if (!RegExp(r'^[$%]?[A-Za-z_]').hasMatch(t)) {
      throw ExpressionException('unexpected "$t"');
    }
    if (peek == '(') return _call(t);
    final value = _resolve(t);
    if (value == null) throw ExpressionException('$t has no numeric value');
    return value;
  }

  num _call(String name) {
    _expect('(');
    final args = <num>[];
    if (peek != ')') {
      args.add(expression());
      while (peek == ',') {
        _take();
        args.add(expression());
      }
    }
    _expect(')');
    void arity(int n) {
      if (args.length != n) {
        throw ExpressionException('$name takes $n arguments');
      }
    }

    switch (name) {
      case 'abs':
        arity(1);
        return args[0].abs();
      case 'round':
        arity(1);
        return args[0].round();
      case 'floor':
        arity(1);
        return args[0].floor();
      case 'ceil':
        arity(1);
        return args[0].ceil();
      case 'min':
        if (args.isEmpty) throw ExpressionException('min needs arguments');
        return args.reduce(math.min);
      case 'max':
        if (args.isEmpty) throw ExpressionException('max needs arguments');
        return args.reduce(math.max);
      case 'clamp':
        arity(3);
        return args[0].clamp(args[1], args[2]);
    }
    throw ExpressionException('unknown function $name');
  }
}
