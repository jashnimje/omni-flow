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
  AutomationNotifier(this._engine, {PostNotification? post})
    : _post = post ?? _platformPost;

  static const channelName = 'omniflow/notify';
  static const _channel = MethodChannel(channelName);

  final EngineClient _engine;
  final PostNotification _post;
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

  void start() => _sub ??= _engine.events.listen(_onEvent);

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> _onEvent(Map<String, Object?> e) async {
    switch (e['event']) {
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
