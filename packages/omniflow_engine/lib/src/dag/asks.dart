import 'dart:async';

import 'executor.dart';

/// What a run asks the person: `confirm` (ask before running, with the
/// choices Run and Not now), `choose` (one of [choices]) or `input` (text).
enum AskKind { confirm, choose, input }

/// The two answers of a confirm ask.
const askRun = 'Run';
const askNotNow = 'Not now';

/// How long an ask waits when it does not say.
const askDefaultTimeoutMs = 300000;

/// The questions runs are waiting on, kept in memory only. Each one is an
/// `ask.request` event, and ends with one `ask.closed`: answered, timed out
/// or cancelled (the run ended, or the engine closed).
class AskBroker {
  AskBroker(this._emit);

  final void Function(Map<String, Object?> event) _emit;

  /// The person a run started by a thing is for (a person, or a phone's
  /// person), so its ask reaches that person's phone. The engine sets it.
  Future<String?> Function(String thing)? personOf;
  final _open = <String, _OpenAsk>{};
  var _counter = 0;

  /// The `ask.request` payloads of every open ask, oldest first.
  List<Map<String, Object?>> get pending => [
    for (final a in _open.values) a.request,
  ];

  /// Whether a confirm ask for [flowId] is open.
  bool confirming(String flowId) => _open.values.any(
    (a) => a.request['flow'] == flowId && a.request['kind'] == 'confirm',
  );

  /// Asks the person and waits for the answer: the answer, or null when
  /// [timeout] passes first. Throws [RunCancelled] when [token] is
  /// cancelled first. The ask names [to], or else the person of the
  /// [trigger] thing that started the run, when there is one.
  Future<String?> ask({
    required String flow,
    required AskKind kind,
    required String title,
    String? body,
    List<String>? choices,
    String? fallback,
    required Duration timeout,
    required CancelToken token,
    required FlowClock clock,
    String? to,
    Object? trigger,
  }) async {
    token.check();
    var person = to;
    if (person == null && trigger is String && personOf != null) {
      person = await _personOf(trigger);
      token.check();
    }
    final id = 'ask-${DateTime.now().microsecondsSinceEpoch}-${++_counter}';
    final request = <String, Object?>{
      'askId': id,
      'flow': flow,
      'person': ?person,
      'kind': kind.name,
      'title': title,
      'body': ?body,
      'choices': kind == AskKind.confirm ? const [askRun, askNotNow] : choices,
      'default': ?fallback,
      'expiresAt': clock.now().add(timeout).toUtc().toIso8601String(),
    };
    if (request['choices'] == null) request.remove('choices');
    final open = _OpenAsk(request, kind);
    _open[id] = open;
    _emit({'event': 'ask.request', ...request});
    final waiting = CancelToken();
    token.whenCancelled.then((_) => _close(id, 'cancelled'));
    clock
        .sleep(timeout, waiting)
        .then((_) => _close(id, 'timeout'), onError: (Object _) {});
    try {
      return await open.done.future;
    } finally {
      waiting.cancel();
    }
  }

  Future<String?> _personOf(Object? thing) async {
    final find = personOf;
    if (thing is! String || find == null) return null;
    try {
      return await find(thing);
    } catch (_) {
      // An ask with no person still reaches every phone.
      return null;
    }
  }

  /// Answers the open ask [askId]. Null when it took the answer, else why
  /// not, in a plain sentence.
  String? answer(String askId, Object? answer) {
    final open = _open[askId];
    if (open == null) {
      return 'That question is not waiting for an answer any more';
    }
    final request = open.request;
    if (answer is! String) return 'The answer must be text';
    switch (open.kind) {
      case AskKind.confirm || AskKind.choose:
        final choices = (request['choices'] as List).cast<String>();
        if (!choices.contains(answer)) {
          return 'The answer must be one of ${choices.join(', ')}';
        }
      case AskKind.input:
        break;
    }
    _close(askId, 'answered', answer: answer);
    return null;
  }

  /// Ends every open ask, as the engine closes.
  void cancelAll() {
    for (final id in _open.keys.toList()) {
      _close(id, 'cancelled');
    }
  }

  void _close(String id, String reason, {String? answer}) {
    final open = _open.remove(id);
    if (open == null) return;
    final fallback = open.request['default'] as String?;
    final given = reason == 'answered'
        ? answer
        : reason == 'timeout'
        ? fallback
        : null;
    _emit({
      'event': 'ask.closed',
      'askId': id,
      'answer': ?given,
      'reason': reason,
    });
    if (reason == 'cancelled') {
      open.done.completeError(RunCancelled());
    } else {
      open.done.complete(reason == 'answered' ? answer : null);
    }
  }
}

class _OpenAsk {
  _OpenAsk(this.request, this.kind);

  final Map<String, Object?> request;
  final AskKind kind;
  final done = Completer<String?>();
}
