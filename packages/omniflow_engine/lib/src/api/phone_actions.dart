import 'dart:async';
import 'dart:math';

import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'stored_flows.dart';
import 'things_runtime.dart';
import '../dag/conditions.dart' show valuesEqual;
import '../devices/channels.dart';
import '../devices/device.dart';
import '../storage/database.dart';

/// The command key of a phone action in the phone driver: `{"phoneAction":
/// "speak"}`.
const phoneActionKey = 'phoneAction';

/// The event the engine sends to ask a phone to act, and how long it waits
/// for `phone.actionDone`.
const phoneActionEvent = 'phone.action';
const phoneActionTimeout = Duration(seconds: 10);

/// How long after its last `phone.ready` a phone still counts as connected.
/// The app's service says it is ready every 30 seconds.
const phoneReadyFor = Duration(seconds: 75);

/// The phone's own actions and the readings that came with them. A phone
/// action is never sent over a network: the engine emits `phone.action`
/// `{phone, requestId, action, params}` and waits for that phone's service
/// to answer with `phone.actionDone {requestId, ok, error?}`. On a phone
/// engine the app's service is that phone. On a hub the event reaches each
/// connected phone over its hub link, and only the one named acts.
///
/// The readings (`phone.alarm`, `phone.call`, `phone.media`,
/// `phone.calendar`, `phone.shake`, `phone.faceDown`, `phone.headphones`,
/// `phone.boot`, `phone.package`) become events and state on the phone
/// thing, as the earlier `phone.*` inputs do. `phone.ready` says which of
/// them the automations use, so the phone only reads what is needed.
class PhoneActions {
  PhoneActions({
    this.timeout = phoneActionTimeout,
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  final Duration timeout;
  final DateTime Function() _now;
  final Random _random;

  EngineCore? _core;
  ThingsRuntime? _things;
  Future<Map<String, Object?>> Function(String scene)? _runScene;

  final _pending = <String, ({String phone, Completer<_Done> done})>{};
  final _ready = <String, DateTime>{};
  final _alarmTimers = <String, List<Timer>>{};
  final _alarmsFired = <String>{};
  var _closed = false;

  /// Connects the actions to the engine once it is open. [runScene] runs a
  /// scene as the user would, for "shake to run a scene".
  void attach(
    EngineCore core,
    ThingsRuntime things, {
    required Future<Map<String, Object?>> Function(String scene) runScene,
  }) {
    _core = core;
    _things = things;
    _runScene = runScene;
  }

  Map<String, CommandHandler> get commands => {
    'phone.actionDone': actionDone,
    'phone.ready': ready,
    'phone.alarm': alarm,
    'phone.call': call,
    'phone.media': media,
    'phone.calendar': calendar,
    'phone.shake': shake,
    'phone.faceDown': faceDown,
    'phone.headphones': headphones,
    'phone.boot': boot,
    'phone.package': package,
  };

  EngineCore get _engine =>
      _core ?? (throw ApiError('not_ready', 'the engine is still opening'));

  ThingsRuntime get _phones =>
      _things ?? (throw ApiError('not_ready', 'the engine is still opening'));

  /// Asks the phone [request] names to run its action, and waits for the
  /// answer. Called by [PhoneChannel].
  Future<ChannelReply> act(ChannelRequest request, String action) async {
    if (_closed) {
      throw ApiError('unavailable', 'OmniFlow is closing');
    }
    final device = request.device;
    final core = _engine;
    final label =
        request.manifest.capabilities
            .where(
              (c) =>
                  c.command is Map &&
                  (c.command as Map)[phoneActionKey] == action,
            )
            .firstOrNull
            ?.label ??
        action;
    if (!isReady(device.id)) {
      throw ApiError('unavailable', notConnectedText(device, label));
    }
    final requestId = _newId();
    final done = Completer<_Done>();
    _pending[requestId] = (phone: device.id, done: done);
    try {
      core.emit({
        'event': phoneActionEvent,
        'phone': device.id,
        'requestId': requestId,
        'action': action,
        'params': {
          for (final e in request.context.params.entries)
            if (e.value != null) e.key: e.value,
        },
      });
      final _Done answer;
      try {
        answer = await done.future.timeout(timeout);
      } on TimeoutException {
        throw ApiError(
          'timeout',
          '${_nameOf(device)} did not answer within ${timeout.inSeconds} s. '
              'Check that OmniFlow is running on it.',
        );
      }
      if (!answer.ok) {
        throw ApiError(answer.type, answer.error);
      }
      return ChannelReply({'done': true, 'note': ?answer.note});
    } finally {
      _pending.remove(requestId);
    }
  }

  /// Whether [phone] said it is ready recently enough to count as there.
  bool isReady(String phone) {
    final at = _ready[phone];
    return at != null && _now().difference(at) <= phoneReadyFor;
  }

  static String _nameOf(Device device) =>
      device.name.trim().isEmpty ? device.id : device.name;

  /// "Phone is not connected right now, so it cannot say out loud."
  static String notConnectedText(Device device, String label) =>
      '${_nameOf(device)} is not connected right now, so it cannot '
      '${label.toLowerCase()}. Open OmniFlow on that phone, and check it '
      'reaches the hub.';

  String _newId() {
    final bytes = List<int>.generate(12, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// `{requestId, ok, error?, errorType?, note?, phone?}`: the phone's
  /// answer to a `phone.action`. A hub tags it with the phone that sent
  /// it, which must be the phone that was asked.
  Future<Map<String, Object?>> actionDone(Map<String, Object?> args) async {
    final requestId = stringArg(args, 'requestId');
    final ok = args['ok'];
    if (ok is! bool) throw ApiError('invalid', 'ok must be true or false');
    final waiting = _pending[requestId];
    if (waiting == null) {
      throw ApiError(
        'not_found',
        'no phone action is waiting with that id. It may have timed out',
      );
    }
    final from = optStringArg(args, 'phone');
    if (from != null && from != waiting.phone) {
      throw ApiError('invalid', 'that action was asked of another phone');
    }
    final error = _short(optStringArg(args, 'error'));
    final type = optStringArg(args, 'errorType');
    if (!waiting.done.isCompleted) {
      waiting.done.complete(
        _Done(
          ok: ok,
          error: error ?? 'The phone could not do it',
          type: type != null && _errorTypes.contains(type)
              ? type
              : 'device_error',
          note: _short(optStringArg(args, 'note')),
        ),
      );
    }
    return {'accepted': true};
  }

  /// The error types a phone may answer with. Anything else reads as a
  /// device error.
  static const _errorTypes = {
    'device_error',
    'needs_user',
    'unavailable',
    'not_found',
    'invalid',
  };

  static String? _short(String? text) {
    final t = text?.trim();
    if (t == null || t.isEmpty) return null;
    return t.length > 300 ? '${t.substring(0, 300)}…' : t;
  }

  /// `{phone?}` -> `{phone, watch}`: the phone's service is connected and
  /// can act. Sent every 30 seconds. [watch] says which readings the
  /// automations use, so the phone turns on only those sensors.
  Future<Map<String, Object?>> ready(Map<String, Object?> args) async {
    final device = await _phones.phone(optStringArg(args, 'phone'));
    _ready[device.id] = _now();
    final watch = await watchOf(device);
    await _scheduleAlarms(device, watch);
    return {'phone': device.id, 'watch': watch.toJson()};
  }

  /// What the enabled automations read from [phone].
  Future<PhoneWatch> watchOf(Device phone) async {
    final keys = <String>{};
    final words = <String>{};
    final minutes = <int>{};
    void walk(Object? value) {
      switch (value) {
        case Map m:
          final key = m['key'];
          if (m['thing'] == phone.id && key is String) {
            keys.add(key);
            final match = m['match'];
            if (match is Map) {
              if (key.startsWith('calendar_') && match['words'] is String) {
                words.add(match['words'] as String);
              }
              if (key == 'alarm_soon' && match['minutes'] is int) {
                minutes.add(match['minutes'] as int);
              }
            }
          }
          final state = m['state'];
          if (state is String && state.startsWith('${phone.id}.')) {
            keys.add(state.substring(phone.id.length + 1));
          }
          m.values.forEach(walk);
        case List l:
          l.forEach(walk);
      }
    }

    for (final r in await DriftFlowStore(_engine.db).all()) {
      if (r.enabled) walk(StoredFlows.flowJsonOf(r)['nodes']);
    }
    final scene = phone.settings['shake_scene'];
    if (scene is String && scene.trim().isNotEmpty) keys.add('shaken');
    return PhoneWatch(keys, words, minutes);
  }

  /// `{at?, phone?}`: the next alarm on the phone's clock, as an ISO 8601
  /// time, or none. Each "before the next alarm" trigger is timed from it.
  Future<Map<String, Object?>> alarm(Map<String, Object?> args) async {
    final at = optDateArg(args, 'at')?.toUtc();
    final device = await _phones.phone(optStringArg(args, 'phone'));
    await _merge(device, {'next_alarm': at?.toIso8601String()});
    final updated = await _engine.device(device.id);
    await _scheduleAlarms(updated, await watchOf(updated));
    return {'next_alarm': at?.toIso8601String()};
  }

  /// One timer per "before the next alarm by N minutes" trigger. A
  /// trigger whose moment passed less than a minute ago still fires, so a
  /// late reading is not lost. Each fires once per alarm.
  Future<void> _scheduleAlarms(Device phone, PhoneWatch watch) async {
    for (final t in _alarmTimers.remove(phone.id) ?? const <Timer>[]) {
      t.cancel();
    }
    final next = DateTime.tryParse('${phone.state['next_alarm']}');
    _alarmsFired.removeWhere(
      (k) =>
          k.startsWith('${phone.id}|') &&
          (next == null || !k.contains('|${next.toIso8601String()}|')),
    );
    if (next == null || _closed) return;
    final now = _now();
    final timers = <Timer>[];
    for (final minutes in watch.alarmMinutes) {
      final at = next.subtract(Duration(minutes: minutes));
      final key = '${phone.id}|${next.toIso8601String()}|$minutes';
      if (_alarmsFired.contains(key)) continue;
      final wait = at.difference(now);
      if (wait < const Duration(minutes: -1)) continue;
      timers.add(
        Timer(wait.isNegative ? Duration.zero : wait, () {
          if (_closed || !_alarmsFired.add(key)) return;
          _engine.raiseEvent(phone.id, 'alarm_soon', {
            'minutes': minutes,
            'alarm': next.toIso8601String(),
          });
        }),
      );
    }
    if (timers.isNotEmpty) _alarmTimers[phone.id] = timers;
  }

  /// `{state: ringing | answered | ended, phone?}`. Who is calling is never
  /// taken: the phone sends no number, and none is kept.
  Future<Map<String, Object?>> call(Map<String, Object?> args) async {
    final state = args['state'];
    final (event, now) = switch (state) {
      'ringing' => ('call_ringing', 'ringing'),
      'answered' => ('call_answered', 'in_call'),
      'ended' => ('call_ended', 'none'),
      _ => throw ApiError(
        'invalid',
        'state must be ringing, answered or ended',
      ),
    };
    final device = await _phones.phone(optStringArg(args, 'phone'));
    _engine.raiseEvent(device.id, event, const {});
    await _merge(device, {'call': now});
    return {'call': now};
  }

  /// `{playing, package?, label?, title?, phone?}`: media started or
  /// stopped. The title goes into the event only, never the state.
  Future<Map<String, Object?>> media(Map<String, Object?> args) async {
    final playing = _bool(args, 'playing');
    final device = await _phones.phone(optStringArg(args, 'phone'));
    final package = optStringArg(args, 'package');
    // A first reading of nothing playing, or the same state again, is not
    // a start or a stop.
    final before = device.state['media_playing'];
    if (before == playing || (before == null && !playing)) {
      await _merge(device, {'media_playing': playing});
      return {'media_playing': playing};
    }
    _engine.raiseEvent(device.id, playing ? 'media_started' : 'media_stopped', {
      'package': ?package,
      'label': optStringArg(args, 'label') ?? package,
      'title': ?optStringArg(args, 'title'),
    });
    await _merge(device, {'media_playing': playing});
    return {'media_playing': playing};
  }

  /// `{event: started | ended, words, phone?}`: a calendar event whose
  /// title has [words] started or ended. The phone matches the words, and
  /// a title it sends anyway is dropped here: the run log, the events and
  /// a diagram's `seen` say only that an event with those words matched.
  Future<Map<String, Object?>> calendar(Map<String, Object?> args) async {
    final event = args['event'];
    if (event != 'started' && event != 'ended') {
      throw ApiError('invalid', 'event must be started or ended');
    }
    final words = optStringArg(args, 'words')?.trim();
    if (words == null || words.isEmpty) {
      throw ApiError('invalid', 'words are the words the title has');
    }
    final device = await _phones.phone(optStringArg(args, 'phone'));
    _engine.raiseEvent(
      device.id,
      event == 'started' ? 'calendar_started' : 'calendar_ended',
      {'words': words},
    );
    return {'received': true};
  }

  /// `{phone?}`: the phone was shaken. Runs the phone's shake scene when
  /// one is set.
  Future<Map<String, Object?>> shake(Map<String, Object?> args) async {
    final device = await _phones.phone(optStringArg(args, 'phone'));
    _engine.raiseEvent(device.id, 'shaken', const {});
    final scene = device.settings['shake_scene'];
    if (scene is! String || scene.trim().isEmpty) return {'scene': null};
    final run = _runScene;
    if (run == null) return {'scene': scene};
    final result = await run(scene.trim());
    return {
      'scene': scene.trim(),
      'ran': result['ok'] == true,
      if (result['ok'] != true) 'error': result['error'],
    };
  }

  /// `{on, phone?}`: the phone was put face down, or picked up again.
  Future<Map<String, Object?>> faceDown(Map<String, Object?> args) async {
    final on = _bool(args, 'on');
    final device = await _phones.phone(optStringArg(args, 'phone'));
    await _merge(device, {'face_down': on});
    return {'face_down': on};
  }

  /// `{plugged, phone?}`: wired headphones were plugged in or out.
  Future<Map<String, Object?>> headphones(Map<String, Object?> args) async {
    final plugged = _bool(args, 'plugged');
    final device = await _phones.phone(optStringArg(args, 'phone'));
    await _merge(device, {'headphones': plugged});
    return {'headphones': plugged};
  }

  /// `{phone?}`: the phone started up.
  Future<Map<String, Object?>> boot(Map<String, Object?> args) async {
    final device = await _phones.phone(optStringArg(args, 'phone'));
    _engine.raiseEvent(device.id, 'started_up', const {});
    return {'received': true};
  }

  /// `{package, label?, updated, phone?}`: an app was installed, or an
  /// installed one updated.
  Future<Map<String, Object?>> package(Map<String, Object?> args) async {
    final package = optStringArg(args, 'package')?.trim();
    if (package == null || package.isEmpty) {
      throw ApiError('invalid', 'package is the app\'s package name');
    }
    final updated = _bool(args, 'updated');
    final device = await _phones.phone(optStringArg(args, 'phone'));
    _engine.raiseEvent(device.id, updated ? 'app_updated' : 'app_installed', {
      'package': package,
      'label': optStringArg(args, 'label') ?? package,
    });
    return {'received': true};
  }

  static bool _bool(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is! bool) throw ApiError('invalid', '$key must be true or false');
    return value;
  }

  Future<void> _merge(Device device, Map<String, Object?> values) async {
    final current = device.state;
    if (values.entries.every(
      (e) => current.containsKey(e.key) && valuesEqual(current[e.key], e.value),
    )) {
      return;
    }
    await _engine.devices.mergeState(device.id, values);
  }

  /// Ends every wait and timer, so the engine closes at once.
  Future<void> close() async {
    _closed = true;
    for (final timers in _alarmTimers.values) {
      for (final t in timers) {
        t.cancel();
      }
    }
    _alarmTimers.clear();
    for (final p in _pending.values) {
      if (!p.done.isCompleted) {
        p.done.complete(
          const _Done(
            ok: false,
            error: 'OmniFlow closed before the phone answered',
            type: 'unavailable',
          ),
        );
      }
    }
  }
}

class _Done {
  const _Done({
    required this.ok,
    required this.error,
    required this.type,
    this.note,
  });

  final bool ok;
  final String error;
  final String type;
  final String? note;
}

/// The readings the automations use on one phone, and what the phone
/// turns on for them.
class PhoneWatch {
  PhoneWatch(this.keys, this.calendarWords, this.alarmMinutes);

  /// Every key of the phone an enabled automation names.
  final Set<String> keys;

  /// The words of each calendar trigger.
  final Set<String> calendarWords;

  /// The minutes of each "before the next alarm" trigger.
  final Set<int> alarmMinutes;

  bool _any(List<String> of) => of.any(keys.contains);

  Map<String, Object?> toJson() => {
    'shake': _any(const ['shaken']),
    'faceDown': _any(const ['face_down']),
    'calls': _any(const [
      'call',
      'call_ringing',
      'call_answered',
      'call_ended',
    ]),
    'media': _any(const ['media_playing', 'media_started', 'media_stopped']),
    'alarm': _any(const ['next_alarm', 'alarm_soon']),
    'headphones': _any(const ['headphones']),
    'boot': _any(const ['started_up']),
    'packages': _any(const ['app_installed', 'app_updated']),
    // The app on screen is read every few seconds, so only when asked.
    'apps': _any(const ['app_on_screen', 'app_opened', 'app_closed']),
    'calendarWords': calendarWords.toList()..sort(),
    'alarmMinutes': alarmMinutes.toList()..sort(),
  };
}

/// The channel for things with the `virtual` transport. A phone action
/// goes to [PhoneActions]. Anything else is accepted as sent, so the
/// engine's optimistic state becomes the thing's state, as before.
class PhoneChannel implements DriverChannel {
  PhoneChannel(this._phone);

  final PhoneActions _phone;

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    final command = request.command;
    if (request.manifest.id == phoneDriverId &&
        command is Map &&
        command[phoneActionKey] is String) {
      return _phone.act(request, command[phoneActionKey] as String);
    }
    return const ChannelReply({});
  }
}

/// One `omni phone` verb for a reading: the API command it sends, its usage
/// and how its words become args (null for words that do not fit).
typedef PhoneReadingVerb = ({
  String verb,
  String help,
  String command,
  String usage,
  Map<String, Object?>? Function(List<String> rest) args,
});

const _onOff = {'on': true, 'off': false};

/// The CLI verbs of the readings above.
final List<PhoneReadingVerb> phoneReadingVerbs = [
  (
    verb: 'alarm',
    help:
        'The next alarm, none when left out: omni phone alarm 2026-11-13T07:00',
    command: 'phone.alarm',
    usage: '[TIME]',
    args: (rest) =>
        rest.length > 1 ? null : {if (rest.isNotEmpty) 'at': rest.single},
  ),
  (
    verb: 'call',
    help: 'A call rang, was answered or ended: omni phone call ringing',
    command: 'phone.call',
    usage: 'ringing|answered|ended',
    args: (rest) => rest.length == 1 ? {'state': rest.single} : null,
  ),
  (
    verb: 'media',
    help:
        'Media started or stopped: omni phone media playing [PACKAGE] [TITLE]',
    command: 'phone.media',
    usage: 'playing|stopped [PACKAGE] [TITLE]',
    args: (rest) =>
        rest.isEmpty ||
            rest.length > 3 ||
            !const {'playing', 'stopped'}.contains(rest[0])
        ? null
        : {
            'playing': rest[0] == 'playing',
            if (rest.length > 1) 'package': rest[1],
            if (rest.length > 2) 'title': rest[2],
          },
  ),
  (
    verb: 'calendar',
    help:
        'A calendar event with these words started or ended: omni phone '
        'calendar started gym',
    command: 'phone.calendar',
    usage: 'started|ended WORDS',
    args: (rest) =>
        rest.length != 2 ? null : {'event': rest[0], 'words': rest[1]},
  ),
  (
    verb: 'shake',
    help: 'The phone was shaken: omni phone shake',
    command: 'phone.shake',
    usage: '',
    args: (rest) => rest.isEmpty ? {} : null,
  ),
  (
    verb: 'facedown',
    help: 'The phone was put face down or picked up: omni phone facedown on',
    command: 'phone.faceDown',
    usage: 'on|off',
    args: (rest) => rest.length == 1 && _onOff.containsKey(rest.single)
        ? {'on': _onOff[rest.single]}
        : null,
  ),
  (
    verb: 'headphones',
    help: 'Wired headphones went in or out: omni phone headphones on',
    command: 'phone.headphones',
    usage: 'on|off',
    args: (rest) => rest.length == 1 && _onOff.containsKey(rest.single)
        ? {'plugged': _onOff[rest.single]}
        : null,
  ),
  (
    verb: 'boot',
    help: 'The phone started up: omni phone boot',
    command: 'phone.boot',
    usage: '',
    args: (rest) => rest.isEmpty ? {} : null,
  ),
  (
    verb: 'installed',
    help:
        'An app was installed or updated: omni phone installed '
        'com.example.app [updated]',
    command: 'phone.package',
    usage: 'PACKAGE [updated]',
    args: (rest) =>
        rest.isEmpty ||
            rest.length > 2 ||
            (rest.length == 2 && rest[1] != 'updated')
        ? null
        : {'package': rest[0], 'updated': rest.length == 2},
  ),
];
