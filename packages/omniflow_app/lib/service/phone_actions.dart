import 'dart:async';

import 'package:flutter/services.dart';

import '../api/engine_client.dart';

/// What the phone's Kotlin side does, so tests can stand in for it.
abstract interface class PhoneHands {
  /// Runs one action. The answer is `{ok, error?, errorType?, note?}`.
  Future<Map<String, Object?>> run(String action, Map<String, Object?> params);

  /// Turns the phone's sensors and listeners on or off to match [watch].
  Future<void> watch(Map<String, Object?> watch);

  /// The calendar events of the next 24 hours whose title has one of
  /// [words]: `{words, title, begin, end}` with times in epoch ms. Nothing
  /// else leaves the phone's calendar.
  Future<List<Map<String, Object?>>> calendar(List<String> words);
}

/// PhoneActionsBridge.kt on the `omniflow/phone_actions` channel of the
/// service's engine.
class AndroidPhoneHands implements PhoneHands {
  const AndroidPhoneHands([this._channel = const MethodChannel(channelName)]);

  static const channelName = 'omniflow/phone_actions';

  final MethodChannel _channel;

  @override
  Future<Map<String, Object?>> run(
    String action,
    Map<String, Object?> params,
  ) async {
    try {
      final answer = await _channel.invokeMethod<Map<Object?, Object?>>('run', {
        'action': action,
        'params': params,
      });
      return {
        for (final e in (answer ?? const {}).entries) '${e.key}': e.value,
      };
    } on MissingPluginException {
      return const {
        'ok': false,
        'error': 'This phone cannot do that from OmniFlow',
      };
    } on PlatformException catch (e) {
      return {'ok': false, 'error': e.message ?? 'The phone could not do it'};
    }
  }

  @override
  Future<void> watch(Map<String, Object?> watch) async {
    try {
      await _channel.invokeMethod<void>('watch', watch);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<List<Map<String, Object?>>> calendar(List<String> words) async {
    try {
      final found = await _channel.invokeMethod<List<Object?>>('calendar', {
        'words': words,
      });
      return [
        for (final e in found ?? const [])
          if (e is Map) {for (final x in e.entries) '${x.key}': x.value},
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }
}

/// Runs the phone's actions inside the service. The engine asks with a
/// `phone.action {phone, requestId, action, params}` event and waits for
/// `phone.actionDone`. On a hub every connected phone sees the event, so
/// this phone acts only on requests that name its own id, which
/// `phone.ready` gives back.
///
/// Every [readyEvery] it says `phone.ready`, which keeps it counted as
/// connected and says which readings the automations use. Those turn the
/// phone's sensors on, and the calendar is read only for the words of a
/// calendar trigger, once every [calendarEvery].
class PhoneActionRunner {
  PhoneActionRunner(
    this._engine, {
    this._hands = const AndroidPhoneHands(),
    this.readyEvery = const Duration(seconds: 30),
    this.calendarEvery = const Duration(minutes: 15),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const actionEvent = 'phone.action';
  static const actionDone = 'phone.actionDone';
  static const ready = 'phone.ready';
  static const calendarCommand = 'phone.calendar';

  final EngineClient _engine;
  final PhoneHands _hands;
  final Duration readyEvery;
  final Duration calendarEvery;
  final DateTime Function() _now;

  StreamSubscription<Map<String, Object?>>? _events;
  Timer? _ready;
  String? _phone;
  Map<String, Object?>? _watch;
  List<String> _words = const [];
  DateTime? _calendarRead;
  final _calendarTimers = <Timer>[];
  final _reported = <String>{};
  var _stopped = false;

  /// The phone thing the engine knows this phone as, once it said ready.
  String? get phone => _phone;

  void start() {
    _stopped = false;
    _events ??= _engine.events.listen(
      (e) => unawaited(_onEvent(e)),
      onError: (Object _) {},
    );
    unawaited(sayReady());
    _ready ??= Timer.periodic(readyEvery, (_) => unawaited(sayReady()));
  }

  Future<void> stop() async {
    _stopped = true;
    _ready?.cancel();
    _ready = null;
    await _events?.cancel();
    _events = null;
    _cancelCalendar();
    await _hands.watch(const {});
  }

  /// Says ready, and turns on what the automations use.
  Future<void> sayReady() async {
    final Map<String, Object?> reply;
    try {
      reply = await _engine.call(ready);
    } on Object {
      return;
    }
    if (reply['ok'] != true || _stopped) return;
    if (reply['phone'] case final String id) _phone = id;
    final watch = reply['watch'];
    if (watch is! Map) return;
    final next = {for (final e in watch.entries) '${e.key}': e.value};
    if (!_same(next, _watch)) {
      _watch = next;
      await _hands.watch(next);
    }
    final words = [
      for (final w in next['calendarWords'] as List? ?? const [])
        if (w is String) w,
    ];
    final stale =
        _calendarRead == null ||
        _now().difference(_calendarRead!) >= calendarEvery;
    if (!_sameList(words, _words) || (words.isNotEmpty && stale)) {
      _words = words;
      await _readCalendar();
    }
  }

  static bool _same(Map<String, Object?> a, Map<String, Object?>? b) {
    if (b == null || a.length != b.length) return false;
    for (final e in a.entries) {
      final other = b[e.key];
      if (e.value is List && other is List) {
        if (!_sameList(e.value as List, other)) return false;
      } else if (e.value != other) {
        return false;
      }
    }
    return true;
  }

  static bool _sameList(List a, List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _onEvent(Map<String, Object?> e) async {
    if (e['event'] != actionEvent || _stopped) return;
    final requestId = e['requestId'];
    final action = e['action'];
    if (requestId is! String || action is! String) return;
    // Asked of another phone on the same hub.
    if (e['phone'] != (_phone ?? 'phone')) return;
    final params = e['params'] is Map
        ? {for (final p in (e['params'] as Map).entries) '${p.key}': p.value}
        : const <String, Object?>{};
    Map<String, Object?> answer;
    try {
      answer = await _hands.run(action, params);
    } on Object catch (err) {
      answer = {'ok': false, 'error': '$err'};
    }
    final ok = answer['ok'] == true;
    try {
      await _engine.call(actionDone, {
        'requestId': requestId,
        'ok': ok,
        if (!ok) 'error': ?_text(answer['error']),
        if (!ok) 'errorType': ?_text(answer['errorType']),
        'note': ?_text(answer['note']),
      });
    } on Object {
      return;
    }
  }

  static String? _text(Object? v) =>
      v is String && v.trim().isNotEmpty ? v : null;

  /// Times a start and an end report for each matching calendar event.
  Future<void> _readCalendar() async {
    _cancelCalendar();
    _calendarRead = _now();
    if (_words.isEmpty) return;
    final found = await _hands.calendar(_words);
    if (_stopped) return;
    final now = _now();
    for (final event in found) {
      final words = event['words'];
      final begin = event['begin'];
      final end = event['end'];
      if (words is! String || begin is! int || end is! int) continue;
      final title = _text(event['title']);
      for (final (at, kind) in [(begin, 'started'), (end, 'ended')]) {
        final when = DateTime.fromMillisecondsSinceEpoch(at);
        final key = '$words|$at|$kind|$title';
        if (when.isBefore(now) || _reported.contains(key)) continue;
        _calendarTimers.add(
          Timer(when.difference(now), () {
            if (_stopped || !_reported.add(key)) return;
            unawaited(
              _send(calendarCommand, {
                'event': kind,
                'words': words,
                'title': ?title,
              }),
            );
          }),
        );
      }
    }
  }

  void _cancelCalendar() {
    for (final t in _calendarTimers) {
      t.cancel();
    }
    _calendarTimers.clear();
  }

  Future<void> _send(String command, Map<String, Object?> args) async {
    try {
      await _engine.call(command, args);
    } on Object {
      return;
    }
  }
}
