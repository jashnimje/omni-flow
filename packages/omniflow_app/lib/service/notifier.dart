import 'dart:async';

import 'package:flutter/services.dart';

import '../api/engine_client.dart';
import '../api/engine_client_hub.dart';
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

/// A notification whose tap can open one of Android's settings pages
/// ([AutomationNotifier.platformPost]'s `open`).
typedef PostSettingsNotice = Future<void> Function({
  required String channel,
  required int id,
  required String title,
  String? body,
  String? link,
  String? open,
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

/// Device alerts (offline, back online, low battery) post here, apart from
/// what automations say.
const alertsChannel = 'alerts';

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
    this._shows,
  }) : _post = post ?? platformPost,
       _postAsk = postAsk ?? _platformAsk,
       _cancel = cancel ?? _platformCancel,
       _now = now ?? DateTime.now;

  /// Whether an ask or a notify step is for this phone. In hub mode only
  /// those for this phone's person, or for no one in particular, show.
  final bool Function(Map<String, Object?> event)? _shows;

  bool _forHere(Map<String, Object?> e) => _shows?.call(e) ?? true;

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

  /// Automations whose failure was already posted, until a run goes well.
  final _failing = <String>{};

  /// Posts on the phone. [open] names a settings page a tap opens
  /// (`location`, `alarms`) instead of the app.
  static Future<void> platformPost({
    required String channel,
    required int id,
    required String title,
    String? body,
    String? link,
    String? open,
  }) async {
    try {
      await _channel.invokeMethod<void>('post', {
        'channel': channel,
        'id': id,
        'title': title,
        'body': ?body,
        'link': ?link,
        'open': ?open,
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
    await _showPending();
  }

  Future<void> _showPending() async {
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
    if (!_forHere(e)) return;
    final notice = noticeFor(e);
    if (notice == null || !_asks.add(notice.askId)) return;
    await _postAsk(
      notice.body != null ? notice : await _withBody(notice, e['flow']),
    );
  }

  /// An ask with no text of its own says which automation waits, and for
  /// a plain Run or Not now, what each does, so its buttons have context.
  Future<AskNotice> _withBody(AskNotice notice, Object? flow) async {
    final name = flow == null ? null : await _nameOf('$flow');
    final runOrNot =
        notice.actions.length == 2 &&
        notice.actions.first == 'Run' &&
        notice.actions.last == 'Not now';
    final body = switch ((name, runOrNot)) {
      (final n?, true) => 'Tap Run to let $n go ahead, or Not now to skip it',
      (final n?, false) => '$n is waiting for your answer',
      (null, true) => 'Tap Run to let it go ahead, or Not now to skip it',
      (null, false) => 'An automation is waiting for your answer',
    };
    return AskNotice(
      id: notice.id,
      askId: notice.askId,
      title: notice.title,
      body: body,
      actions: notice.actions,
      reply: notice.reply,
      hint: notice.hint,
      chooser: notice.chooser,
      link: notice.link,
      timeoutMs: notice.timeoutMs,
    );
  }

  Future<String?> _nameOf(String flow) async {
    try {
      final got = await _engine.call('automation.get', {'id': flow});
      return got['ok'] == true ? got['name'] as String? : null;
    } on Object {
      return null;
    }
  }

  /// A device alert, on its own channel so it mutes apart from what
  /// automations say: one per device and kind, so "back online" replaces
  /// "offline". The engine's words already say how long since it was last
  /// heard from, so they are shown as sent.
  Future<void> _alert(
    String alert,
    Map<String, Object?> e,
    String title,
  ) async {
    final thing = '${e['thing'] ?? ''}';
    final family = alert == 'battery' ? 'battery' : 'online';
    await _post(
      channel: alertsChannel,
      id: 'alert/$thing/$family'.hashCode & 0x7fffffff,
      title: title,
      body: e['body'] as String?,
    );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> _onEvent(Map<String, Object?> e) async {
    switch (e['event']) {
      case HubLink.event when e['state'] == 'connected':
        // Asks made while the hub was out of reach.
        await _showPending();
      case 'ask.request':
        await _ask(e);
      case 'ask.closed':
        final askId = e['askId'];
        if (askId is! String) return;
        _asks.remove(askId);
        await _cancel(askNotificationId(askId));
      case 'flow.announce':
        final title = '${e['title'] ?? ''}'.trim();
        if (title.isEmpty || !_forHere(e)) return;
        if (e['alert'] case final String alert) return _alert(alert, e, title);
        // One notification per automation and title, updated in place, so
        // a rule that fires often, or a notice with no automation, does not
        // stack up to Android's limit.
        final flow = e['flow'];
        await _post(
          channel: 'automations',
          id: '${flow ?? ''}/$title'.hashCode & 0x7fffffff,
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
