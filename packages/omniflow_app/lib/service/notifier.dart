import 'dart:async';

import 'package:flutter/services.dart';

import '../api/engine_client.dart';
import '../api/plain_error.dart';
import '../ui/shell/links.dart';

/// Posts a notification through the service's omniflow/notify channel.
typedef PostNotification = Future<void> Function({
  required String channel,
  required int id,
  required String title,
  String? body,
  String? link,
});

/// An automation's question as a notification: one action per answer in
/// [actions], a reply box when [reply], or, with more answers than Android
/// shows as actions, a tap that opens the list in [chooser].
class AskNotice {
  const AskNotice({
    required this.id,
    required this.askId,
    required this.title,
    this.body,
    this.actions = const [],
    this.reply = false,
    this.hint,
    this.chooser = const [],
    this.link,
    this.timeoutMs,
  });

  final int id;
  final String askId;
  final String title;
  final String? body;
  final List<String> actions;
  final bool reply;
  final String? hint;
  final List<String> chooser;
  final String? link;

  /// How long until the engine stops waiting, so the notification goes
  /// when the question does.
  final int? timeoutMs;

  /// The heads-up channel every ask posts on.
  String get channel => askChannel;

  /// Each ask stands alone: its own group, so Android never bundles it
  /// with other notifications and its answers stay on screen.
  String get group => 'ask/$askId';

  Map<String, Object?> toJson() => {
    'id': id,
    'askId': askId,
    'channel': channel,
    'group': group,
    'title': title,
    'body': ?body,
    'actions': actions,
    'reply': reply,
    'hint': ?hint,
    'chooser': chooser,
    'link': ?link,
    'timeoutMs': ?timeoutMs,
  };
}

/// Posts or takes down an ask's notification.
typedef PostAsk = Future<void> Function(AskNotice ask);
typedef CancelNotification = Future<void> Function(int id);

/// The high-importance channel "Questions from automations", so an ask
/// shows as a heads-up with its answers. A new id: Android never raises the
/// importance of a channel that already exists.
const askChannel = 'questions';

/// Android shows at most three actions on a notification.
const maxAskActions = 3;

/// The notification id of an ask, stable for the life of the ask.
int askNotificationId(String askId) => 'ask/$askId'.hashCode & 0x7fffffff;

/// The app link a notification opens: the automation, or one of its runs.
String automationLink(String flow, {String? run}) {
  final ShellLink link = run == null
      ? AutomationLink(flow)
      : RunLink(flow, run);
  return 'omniflow://open${link.location}';
}

/// Turns engine events into phone notifications from the service, so they
/// show with the screen off: a rule's notify step, and an automation run
/// that failed, once per automation until it runs well again.
class AutomationNotifier {
  AutomationNotifier(
    this._engine, {
    PostNotification? post,
    PostAsk? postAsk,
    CancelNotification? cancel,
    DateTime Function()? now,
  }) : _post = post ?? _platformPost,
       _postAsk = postAsk ?? _platformAsk,
       _cancel = cancel ?? _platformCancel,
       _now = now ?? DateTime.now;

  static const askPending = 'ask.pending';

  static const channelName = 'omniflow/notify';
  static const _channel = MethodChannel(channelName);

  final EngineClient _engine;
  final PostNotification _post;
  final PostAsk _postAsk;
  final CancelNotification _cancel;
  final DateTime Function() _now;

  /// Asks on screen, so a repeat (ask.pending after the event) is not
  /// posted twice.
  final _asks = <String>{};
  StreamSubscription<Map<String, Object?>>? _sub;
  var _nextId = 1000;

  /// Automations whose failure was already posted, until a run goes well.
  final _failing = <String>{};

  static Future<void> _platformPost({
    required String channel,
    required int id,
    required String title,
    String? body,
    String? link,
  }) async {
    try {
      await _channel.invokeMethod<void>('post', {
        'channel': channel,
        'id': id,
        'title': title,
        'body': ?body,
        'link': ?link,
      });
    } on MissingPluginException {
      // Not on the phone (tests, the desktop): nothing to show.
    }
  }

  static Future<void> _platformAsk(AskNotice ask) async {
    try {
      await _channel.invokeMethod<void>('ask', ask.toJson());
    } on MissingPluginException {
      return;
    }
  }

  static Future<void> _platformCancel(int id) async {
    try {
      await _channel.invokeMethod<void>('cancel', {'id': id});
    } on MissingPluginException {
      return;
    }
  }

  /// Listens for events, then shows the asks still waiting from before the
  /// service started (or while it could not post).
  Future<void> start() async {
    if (_sub != null) return;
    _sub = _engine.events.listen(_onEvent);
    final Map<String, Object?> pending;
    try {
      pending = await _engine.call(askPending);
    } on Object {
      return;
    }
    if (pending['ok'] != true) return;
    for (final ask in (pending['asks'] as List? ?? const [])) {
      if (ask is Map) await _ask(Map<String, Object?>.from(ask));
    }
  }

  /// The notification for an `ask.request` payload, or null for one that
  /// cannot be answered from the phone.
  AskNotice? noticeFor(Map<String, Object?> e) {
    final askId = e['askId'];
    if (askId is! String || askId.isEmpty) return null;
    final title = '${e['title'] ?? ''}'.trim();
    final choices = [for (final c in (e['choices'] as List? ?? const [])) '$c'];
    final flow = e['flow'];
    final base = (
      id: askNotificationId(askId),
      title: title.isEmpty ? 'OmniFlow has a question' : title,
      body: e['body'] as String?,
      link: flow == null ? null : automationLink('$flow'),
      timeoutMs: _timeoutOf(e['expiresAt']),
    );
    AskNotice notice({
      List<String> actions = const [],
      bool reply = false,
      String? hint,
      List<String> chooser = const [],
    }) => AskNotice(
      id: base.id,
      askId: askId,
      title: base.title,
      body: base.body,
      link: base.link,
      timeoutMs: base.timeoutMs,
      actions: actions,
      reply: reply,
      hint: hint,
      chooser: chooser,
    );
    switch (e['kind']) {
      case 'confirm':
        return notice(
          actions: choices.isEmpty ? const ['Run', 'Not now'] : choices,
        );
      case 'choose':
        if (choices.isEmpty) return null;
        return choices.length <= maxAskActions
            ? notice(actions: choices)
            : notice(chooser: choices);
      case 'input':
        final fallback = e['default'];
        return notice(
          reply: true,
          hint: fallback == null ? null : 'Or leave it for $fallback',
        );
    }
    return null;
  }

  /// [expiresAt] as milliseconds from now: epoch milliseconds or an ISO
  /// time. Null when unknown, or already past.
  int? _timeoutOf(Object? expiresAt) {
    final at = switch (expiresAt) {
      int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      num ms => DateTime.fromMillisecondsSinceEpoch(ms.round()),
      String iso => DateTime.tryParse(iso),
      _ => null,
    };
    if (at == null) return null;
    final left = at.difference(_now()).inMilliseconds;
    return left > 0 ? left : null;
  }

  Future<void> _ask(Map<String, Object?> e) async {
    final notice = noticeFor(e);
    if (notice == null || !_asks.add(notice.askId)) return;
    await _postAsk(notice);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> _onEvent(Map<String, Object?> e) async {
    switch (e['event']) {
      case 'ask.request':
        await _ask(e);
      case 'ask.closed':
        final askId = e['askId'];
        if (askId is! String) return;
        _asks.remove(askId);
        await _cancel(askNotificationId(askId));
      case 'flow.announce':
        final title = '${e['title'] ?? ''}'.trim();
        if (title.isEmpty) return;
        // One notification per automation and title, updated in place, so
        // a rule that fires often does not stack up to Android's limit.
        final flow = e['flow'];
        await _post(
          channel: 'automations',
          id: flow == null ? _nextId++ : '$flow/$title'.hashCode & 0x7fffffff,
          title: title,
          body: e['body'] as String?,
          link: flow == null ? null : automationLink('$flow'),
        );
      case 'run.finished':
        final flow = '${e['flow']}';
        if (e['outcome'] != 'failed') {
          if (e['outcome'] == 'completed') _failing.remove(flow);
          return;
        }
        if (!_failing.add(flow)) return;
        final got = await _engine.call('automation.get', {'id': flow});
        final name = got['ok'] == true ? '${got['name'] ?? flow}' : flow;
        await _post(
          channel: 'problems',
          id: flow.hashCode & 0x7fffffff,
          title: '$name did not finish',
          body: plainError('device_error', e['reason'] as String?),
          link: automationLink(flow, run: e['run'] as String?),
        );
    }
  }
}
