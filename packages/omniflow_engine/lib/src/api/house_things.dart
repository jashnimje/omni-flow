import '../manifest/driver_manifest.dart';

/// The thing the house mode lives on. Rules read it like any thing:
/// `{"on": "house_mode.changed", "event": true, "match": {"mode": "night"}}`
/// starts on a change to Night, `{"state": "house_mode.mode", "op": "==",
/// "value": "away"}` checks it, and `{"do": "house_mode.set", "params":
/// {"mode": "night"}}` sets it.
const houseModeThing = 'house_mode';

/// The thing named timers live on: `timers.start {name, ms}`, `timers.cancel
/// {name}`, `timers.pause {name}`, `timers.resume {name}`, and the event
/// `timers.ended` with `{timer, name}`, matched on `timer`.
const timersThing = 'timers';

/// The modes every home has, in the order the picker shows them.
const builtInModes = ['home', 'away', 'night', 'vacation'];

/// The longest a timer runs: a day.
const timerMaxMs = 86400000;

final _modeManifest = DriverManifest.parse({
  'schemaVersion': 1,
  'id': houseModeThing,
  'name': 'House mode',
  'category': 'home',
  'icon': 'home',
  'transport': {'type': 'virtual'},
  'capabilities': [
    {
      'id': 'mode',
      'type': 'sensor',
      'label': 'Mode',
      'stateJsonPath': r'$.mode',
    },
    {
      'id': 'set',
      'type': 'action',
      'label': 'Set the mode',
      'params': {
        'mode': {'type': 'string', 'pattern': '[a-z][a-z0-9_]{0,39}'},
      },
      'command': {'mode': '{{mode}}'},
    },
    {'id': 'changed', 'type': 'event', 'label': 'The mode changes'},
  ],
});

Map<String, Object?> _timerAction(String id, String label, {bool ms = false}) =>
    {
      'id': id,
      'type': 'action',
      'label': label,
      'params': {
        'name': {'type': 'string', 'pattern': '.{1,40}'},
        if (ms)
          'ms': {
            'type': 'number',
            'integer': true,
            'min': 1000,
            'max': timerMaxMs,
            'unit': 'ms',
          },
      },
      'command': {'name': '{{name}}', if (ms) 'ms': '{{ms}}'},
    };

final _timersManifest = DriverManifest.parse({
  'schemaVersion': 1,
  'id': timersThing,
  'name': 'Timers',
  'category': 'home',
  'icon': 'timer',
  'transport': {'type': 'virtual'},
  'capabilities': [
    _timerAction('start', 'Start a timer', ms: true),
    _timerAction('cancel', 'Cancel a timer'),
    _timerAction('pause', 'Pause a timer'),
    _timerAction('resume', 'Resume a timer'),
    {'id': 'ended', 'type': 'event', 'label': 'A timer ends'},
  ],
});

/// The things the engine itself is, by id, which a flow may name though no
/// device row holds them. A device the user added under one of these ids
/// keeps it, and the built-in one is then not offered.
final builtInThings = <String, DriverManifest>{
  houseModeThing: _modeManifest,
  timersThing: _timersManifest,
};

/// [name] as an id: lower case, with every run of other characters one
/// `_`. Null when nothing is left.
String? houseIdOf(String name) {
  final slug = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (slug.isEmpty) return null;
  return RegExp('^[a-z]').hasMatch(slug) ? slug : 'n_$slug';
}

/// An id read as a name: `movie_night` is "Movie night".
String houseNameOf(String id) {
  final words = id.replaceAll('_', ' ').trim();
  return words.isEmpty ? id : '${words[0].toUpperCase()}${words.substring(1)}';
}

String _ms(Object? ms) {
  if (ms is! int) return '$ms ms';
  if (ms > 0 && ms % 3600000 == 0) return '${ms ~/ 3600000} h';
  if (ms > 0 && ms % 60000 == 0) return '${ms ~/ 60000} min';
  if (ms % 1000 == 0) return '${ms ~/ 1000} s';
  return '$ms ms';
}

/// What an `on` trigger or a waitFor on a built-in thing waits for, after
/// "when", or null for any other trigger.
String? houseTriggerWords(Map<Object?, Object?> t) {
  final match = t['match'];
  switch (t['on']) {
    case '$houseModeThing.changed':
      final mode = match is Map ? match['mode'] : null;
      return mode is String
          ? 'the mode changes to ${houseNameOf(mode)}'
          : 'the mode changes';
    case '$timersThing.ended':
      final timer = match is Map ? match['timer'] : null;
      return timer is String
          ? 'timer ${houseNameOf(timer)} ends'
          : 'a timer ends';
  }
  return null;
}

/// A check on the house mode in words, or null for any other check.
String? houseConditionWords(Map<Object?, Object?> c) {
  if (c['state'] != '$houseModeThing.mode') return null;
  final value = c['value'];
  if (value is! String) return null;
  return switch (c['op']) {
    '==' => 'the mode is ${houseNameOf(value)}',
    '!=' => 'the mode is not ${houseNameOf(value)}',
    _ => null,
  };
}

/// A step on a built-in thing in words, or null for any other step.
String? houseStepWords(Map<Object?, Object?> s) {
  final params = s['params'] is Map ? s['params'] as Map : const {};
  final name = params['name'];
  switch (s['do']) {
    case '$houseModeThing.set':
      final mode = params['mode'];
      return mode is String
          ? 'set the mode to ${houseNameOf(mode)}'
          : 'set the mode';
    case '$timersThing.start':
      return 'start a ${_ms(params['ms'])} timer called $name';
    case '$timersThing.cancel':
      return 'cancel timer $name';
    case '$timersThing.pause':
      return 'pause timer $name';
    case '$timersThing.resume':
      return 'resume timer $name';
  }
  return null;
}

/// Runs a capability of a built-in thing from a flow. Returns the reply,
/// and throws an ApiError the run reports.
typedef BuiltInInvoke = Future<Map<String, Object?>?> Function(
  String capability,
  Map<String, Object?> params, {
  String? by,
});
