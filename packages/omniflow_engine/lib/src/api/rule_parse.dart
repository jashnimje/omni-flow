import 'api_error.dart';
import 'automation_commands.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'home_commands.dart' show houseLocation;
import 'houses.dart';
import 'nfc_tags.dart' show nfcTagDriverId;
import 'things_runtime.dart' show personDriverId, placeDriverId, phoneDriverId;
import '../dag/rules.dart';
import '../dag/sun.dart';
import '../dag/templates.dart' show powerActionsOf;
import '../devices/board.dart' show manifestFor;
import '../devices/device_service.dart' show stateKeyOf;
import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/validation.dart';
import '../storage/database.dart';

/// One thing in the home a sentence can name.
class ParseThing {
  const ParseThing({
    required this.id,
    required this.name,
    required this.driver,
    this.manifest,
    this.room,
    this.state = const {},
  });

  final String id;
  final String name;
  final String driver;
  final DriverManifest? manifest;

  /// The room record's id.
  final String? room;

  /// What it last reported. A generic driver (Zigbee) lists every sensor
  /// a device might have, so a sensor counts only once its key shows here.
  final Map<String, Object?> state;

  String? get category => manifest?.category;
}

/// What a sentence is read against: this home's things, rooms, places,
/// people and automations, the household person (who "I" is), where home
/// is, and now.
class ParseHome {
  ParseHome({
    this.things = const [],
    this.rooms = const {},
    this.automations = const {},
    this.person,
    this.homePlace,
    this.location,
    DateTime? now,
  }) : now = now ?? DateTime.now();

  final List<ParseThing> things;

  /// Room id to name.
  final Map<String, String> rooms;

  /// Automation and scene id to name, for "run Movie time".
  final Map<String, String> automations;

  /// The household person's thing id.
  final String? person;

  /// The place id that counts as the household person's home.
  final String? homePlace;
  final HomeLocation? location;
  final DateTime now;
}

/// What reading a sentence gave: the rule spec the editor makes, or null
/// with [problem] in plain words, the words it could not place, the names
/// it had to choose between, and notes on how it read a phrase.
///
/// Any parser fills this, the grammar today and an AI model later, and
/// `rule.parse` checks the spec the same way whichever wrote it.
class RuleParse {
  const RuleParse({
    this.spec,
    this.unknown = const [],
    this.alternatives = const [],
    this.notes = const [],
    this.problem,
  });

  final Map<String, Object?>? spec;
  final List<String> unknown;

  /// `{text, chosen: {id, name}, options: [{id, name}]}`.
  final List<Map<String, Object?>> alternatives;
  final List<String> notes;
  final String? problem;
}

/// Reads a sentence into a rule. The grammar is the offline one, and an AI
/// model can implement the same interface later.
abstract interface class RuleParser {
  Future<RuleParse> parse(String text, ParseHome home);
}

/// The longest sentence `rule.parse` reads.
const ruleParseMaxLength = 300;

/// `rule.parse {text}`: a sentence as the rule spec the editor makes, with
/// its sentence chips. It never saves: the app opens the spec in the
/// editor for the person to check.
class RuleParseCommands {
  RuleParseCommands(this._core, this._automations, {RuleParser? parser})
    : _parser = parser ?? const GrammarRuleParser();

  final EngineCore _core;
  final AutomationCommands _automations;
  final RuleParser _parser;

  Map<String, CommandHandler> get commands => {'rule.parse': parse};

  Future<Map<String, Object?>> parse(Map<String, Object?> args) async {
    final text = args['text'];
    if (text is! String) throw ApiError('invalid', 'text must be a sentence');
    final result = await _parser.parse(
      text,
      await home(house: _core.houses.resolve(args['house'])),
    );
    final words = await _automations.sentenceContext();
    var spec = result.spec;
    var problem = result.problem;
    List<Map<String, Object?>> sentence = const [];
    if (spec != null) {
      try {
        final normalized = normalizeRule(
          spec,
          context: await _automations.ruleContext(),
        );
        sentence = words.rule(normalized);
      } on ValidationException catch (e) {
        spec = null;
        problem =
            'That does not make a rule yet: '
            '${e.issues.map((i) => '${i.path} ${i.message}').join('; ')}';
      }
    }
    return {
      'spec': spec,
      'sentence': sentence,
      'unknown': result.unknown,
      if (result.alternatives.isNotEmpty) 'alternatives': result.alternatives,
      if (result.notes.isNotEmpty) 'notes': result.notes,
      'problem': ?problem,
    };
  }

  /// This home as the parser reads it: given [house], only its things,
  /// rooms and automations (and the people, whom every house shares), and
  /// where it is.
  Future<ParseHome> home({String? house}) async {
    final houses = _core.houses;
    final devices = [
      for (final d in await DriftDeviceStore(_core.db).all())
        if (house == null || houses.thingIn(d.id, house)) d,
    ];
    final roomHouses = house == null
        ? const <String, String>{}
        : await houses.housesOf(HouseKind.room);
    final context = await _automations.ruleContext();
    return ParseHome(
      things: [
        for (final d in devices)
          ParseThing(
            id: d.id,
            name: d.name,
            driver: d.driverId,
            manifest: manifestFor(_core.registry, d),
            room: d.room,
            state: d.state,
          ),
      ],
      rooms: {
        for (final r in await DriftRoomStore(_core.db).all())
          if (house == null || (roomHouses[r.id] ?? house) == house)
            r.id: r.name,
      },
      automations: {
        for (final f in await DriftFlowStore(_core.db).all())
          if (house == null ||
              (houses.flowHouses['${f.json['id']}'] ?? house) == house)
            '${f.json['id']}': '${f.json['name'] ?? f.json['id']}',
      },
      person: context.person,
      homePlace: context.personHome,
      location: house == null
          ? _core.flows.homeLocation
          : houseLocation(_core, house),
    );
  }
}

/// A word of the sentence: as typed, and lowercased without punctuation.
class _Word {
  _Word(this.raw, this.word);

  final String raw;
  final String word;
}

enum _Kind { thing, room, person, place, tag, automation }

class _Entity {
  _Entity(this.kind, this.id, this.name, {this.thing})
    : words = _nameWords(name);

  final _Kind kind;
  final String id;
  final String name;
  final ParseThing? thing;
  final List<String> words;
}

List<String> _nameWords(String name) => [
  for (final w in name.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
    if (w.isNotEmpty) w,
];

/// A name found in the sentence: the best [entity], where its words end,
/// and the others it could also be.
class _Match {
  _Match(this.entity, this.end, this.score, this.others, this.text);

  final _Entity entity;
  final int end;
  final int score;
  final List<_Entity> others;
  final String text;
}

/// Thrown inside the grammar when the sentence cannot make a rule.
class _Refusal implements Exception {
  _Refusal(this.message, [this.words = const []]);

  final String message;
  final List<String> words;
}

const _fillers = {
  'the',
  'a',
  'an',
  'my',
  'our',
  'please',
  'also',
  'just',
  'then',
  'and',
  'ok',
  'okay',
  'automatically',
};

const _actionVerbs = {
  'turn',
  'switch',
  'set',
  'dim',
  'toggle',
  'run',
  'start',
  'notify',
  'alert',
  'tell',
  'send',
  'remind',
  'wait',
};

const _dayNames = {
  'monday': 'mon',
  'mondays': 'mon',
  'mon': 'mon',
  'tuesday': 'tue',
  'tuesdays': 'tue',
  'tue': 'tue',
  'tues': 'tue',
  'wednesday': 'wed',
  'wednesdays': 'wed',
  'wed': 'wed',
  'thursday': 'thu',
  'thursdays': 'thu',
  'thu': 'thu',
  'thurs': 'thu',
  'friday': 'fri',
  'fridays': 'fri',
  'fri': 'fri',
  'saturday': 'sat',
  'saturdays': 'sat',
  'sat': 'sat',
  'sunday': 'sun',
  'sundays': 'sun',
  'sun': 'sun',
};

const _weekdays = ['mon', 'tue', 'wed', 'thu', 'fri'];
const _weekend = ['sat', 'sun'];

final _clock = RegExp(r'^(\d{1,2})(?:[:.](\d{2}))?(am|pm)?$');
final _number = RegExp(r'^-?\d+(?:\.\d+)?$');

/// The offline grammar over this home's names and the rule shapes the
/// editor writes. No AI and no network.
class GrammarRuleParser implements RuleParser {
  const GrammarRuleParser();

  @override
  Future<RuleParse> parse(String text, ParseHome home) async =>
      _Reading(text, home).read();
}

/// One reading of one sentence.
class _Reading {
  _Reading(this.text, this.home);

  final String text;
  final ParseHome home;

  late final List<_Word> _words = _split(text);
  late final List<_Entity> _entities = _entitiesOf(home);
  final _unknown = <String>[];
  final _alternatives = <Map<String, Object?>>[];
  final _notes = <String>[];

  final _triggers = <Map<String, Object?>>[];
  final _conditions = <Map<String, Object?>>[];
  final _steps = <Map<String, Object?>>[];

  /// A days phrase not yet tied to a time or sun trigger.
  List<String>? _days;

  /// Time windows and sun windows read before the triggers are known:
  /// each becomes a condition, or a trigger when nothing else says when.
  final _windows = <_Window>[];

  RuleParse read() {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const RuleParse(
        problem: 'Type what you want, like "turn off the lights when I leave"',
      );
    }
    if (trimmed.length > ruleParseMaxLength) {
      return const RuleParse(
        problem: 'That is too long to read. Say one automation in one sentence',
      );
    }
    try {
      for (final segment in _segments()) {
        _segment(segment);
      }
      _assemble();
    } on _Refusal catch (r) {
      return RuleParse(
        unknown: _dedupe([..._unknown, ...r.words]),
        alternatives: _alternatives,
        notes: _notes,
        problem: r.message,
      );
    }
    return RuleParse(
      spec: {
        'name': _nameOf(trimmed),
        'when': _triggers,
        if (_conditions.isNotEmpty) 'onlyIf': _conditions,
        'then': _steps,
      },
      unknown: _dedupe(_unknown),
      alternatives: _alternatives,
      notes: _notes,
    );
  }

  static List<String> _dedupe(List<String> words) => [
    ...{...words},
  ];

  static String _nameOf(String text) {
    var t = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[.!?]+$'), '');
    if (t.length > 60) {
      final cut = t.lastIndexOf(' ', 60);
      t = t.substring(0, cut > 20 ? cut : 60);
    }
    return t[0].toUpperCase() + t.substring(1);
  }

  // Words.

  static List<_Word> _split(String text) {
    final out = <_Word>[];
    final normalized = text
        .replaceAll('’', "'")
        .replaceAll(',', ' , ')
        .replaceAll(';', ' , ');
    for (final raw in normalized.split(RegExp(r'\s+'))) {
      if (raw.isEmpty) continue;
      if (raw == ',') {
        out.add(_Word(raw, ','));
        continue;
      }
      var w = raw.toLowerCase().replaceAll(
        RegExp(r'''^["'(]+|["')!?.]+$'''),
        '',
      );
      w = w.replaceAll('°', '');
      if (w.isEmpty) continue;
      switch (w) {
        case "i'm":
          out
            ..add(_Word('I', 'i'))
            ..add(_Word('am', 'am'));
        case "it's":
          out
            ..add(_Word('it', 'it'))
            ..add(_Word('is', 'is'));
        case "there's":
          out
            ..add(_Word('there', 'there'))
            ..add(_Word('is', 'is'));
        default:
          if (RegExp(r'^\d+(?:\.\d+)?%$').hasMatch(w)) {
            out.add(_Word(raw, w.substring(0, w.length - 1)));
          } else {
            out.add(_Word(raw, w));
          }
      }
    }
    return out;
  }

  static List<_Entity> _entitiesOf(ParseHome home) {
    final out = <_Entity>[];
    for (final t in home.things) {
      final kind = switch (t.driver) {
        personDriverId => _Kind.person,
        placeDriverId => _Kind.place,
        nfcTagDriverId => _Kind.tag,
        _ => _Kind.thing,
      };
      out.add(_Entity(kind, t.id, t.name, thing: t));
    }
    for (final MapEntry(:key, :value) in home.rooms.entries) {
      out.add(_Entity(_Kind.room, key, value));
    }
    for (final MapEntry(:key, :value) in home.automations.entries) {
      out.add(_Entity(_Kind.automation, key, value));
    }
    return out;
  }

  // Splitting the sentence into its parts: when, only if, and do.

  bool _isTime(int i) => _looksLikeTime([for (final w in _words) w.word], i);

  /// A clock time at [i], and not a number of minutes or degrees.
  static bool _looksLikeTime(List<String> words, int i) {
    if (i >= words.length) return false;
    if (const {'noon', 'midday', 'midnight'}.contains(words[i])) return true;
    if (!_clock.hasMatch(words[i])) return false;
    final next = i + 1 < words.length ? words[i + 1] : null;
    return next == null ||
        (_unitMs(next) == null &&
            !const {'degrees', 'degree', 'percent', 'c'}.contains(next));
  }

  bool _isSun(int i) =>
      i < _words.length &&
      const {'sunset', 'sunrise', 'dusk', 'dawn'}.contains(_words[i].word);

  bool _isDay(int i) =>
      i < _words.length &&
      (_dayNames.containsKey(_words[i].word) ||
          const {
            'day',
            'days',
            'weekday',
            'weekdays',
            'weekend',
            'weekends',
            'morning',
            'evening',
            'night',
          }.contains(_words[i].word));

  bool _isDurationStart(int i) =>
      i + 1 < _words.length &&
      (_number.hasMatch(_words[i].word) ||
          const {'a', 'an', 'half'}.contains(_words[i].word)) &&
      _unitMs(_words[i + 1].word) != null;

  /// Whether a new part of the sentence starts at word [i].
  bool _startsPart(int i) {
    final w = _words[i].word;
    final prev = i > 0 ? _words[i - 1].word : null;
    if (_actionVerbs.contains(w)) {
      // "when I turn on the TV" is a trigger, not a step.
      return prev != 'i' && prev != 'you';
    }
    switch (w) {
      case 'when' || 'whenever' || 'once' || 'if' || 'only' || 'while':
        return true;
      case 'unless':
        return true;
      case 'as':
        return i + 2 < _words.length &&
            _words[i + 1].word == 'soon' &&
            _words[i + 2].word == 'as';
      case 'at':
        return _isTime(i + 1) ||
            _isSun(i + 1) ||
            (i + 1 < _words.length && _words[i + 1].word == 'night');
      case 'every' || 'each':
        return _isDay(i + 1) ||
            _isDurationStart(i + 1) ||
            (i + 1 < _words.length && _unitMs(_words[i + 1].word) != null);
      case 'daily' || 'everyday' || 'weekdays' || 'weekends':
        return true;
      case 'on':
        return _isDay(i + 1);
      case 'after' || 'before':
        return !(i >= 2 && _isDurationStart(i - 2)) &&
            (_isTime(i + 1) || _isSun(i + 1) || _isDark(i + 1));
      case 'between':
        return _isTime(i + 1);
      case 'and' || ',' || 'then':
        return i + 1 < _words.length &&
            (_startsPart(i + 1) || _conditionAfterAnd(i + 1));
    }
    if (_isDurationStart(i) &&
        i + 2 < _words.length &&
        const {'before', 'after'}.contains(_words[i + 2].word) &&
        _isSun(i + 3)) {
      return true;
    }
    return false;
  }

  bool _isDark(int i) => i < _words.length && _words[i].word == 'dark';

  /// "and it is after 18:00", "and I am home", "and Jade is away".
  bool _conditionAfterAnd(int i) {
    final w = _words[i].word;
    if (w == 'it' || w == 'i') return true;
    final m = _match(_words.map((w) => w.word).toList(), i, {_Kind.person});
    return m != null &&
        m.end < _words.length &&
        const {'is', 'isnt'}.contains(_words[m.end].word);
  }

  List<List<_Word>> _segments() {
    final out = <List<_Word>>[];
    var current = <_Word>[];
    for (var i = 0; i < _words.length; i++) {
      if (current.isNotEmpty && _startsPart(i)) {
        out.add(current);
        current = <_Word>[];
      }
      current.add(_words[i]);
    }
    if (current.isNotEmpty) out.add(current);
    return out;
  }

  // Reading each part.

  void _segment(List<_Word> segment) {
    final words = [for (final w in segment) w.word];
    final raws = [for (final w in segment) w.raw];
    // "an hour after sunset" starts with a filler word.
    if (_durationAt(words, 0) != null && _schedule(words, 0)) return;
    var i = 0;
    while (i < words.length &&
        (_fillers.contains(words[i]) || words[i] == ',')) {
      i++;
    }
    if (i >= words.length) return;
    final first = words[i];
    if (first == 'unless') {
      throw _Refusal(
        'I cannot read "unless" yet. Say "only if" with what must be true',
      );
    }
    if (_actionVerbs.contains(first)) {
      _action(words, raws, i);
      return;
    }
    if (first == 'as') {
      _when(words, i + 3, preferCondition: false);
      return;
    }
    if (const {'when', 'whenever', 'once'}.contains(first)) {
      _when(words, i + 1, preferCondition: false);
      return;
    }
    if (first == 'if') {
      _when(words, i + 1, preferCondition: _triggers.isNotEmpty);
      return;
    }
    if (first == 'only' || first == 'while') {
      var j = i + 1;
      if (j < words.length && (words[j] == 'if' || words[j] == 'when')) j++;
      _when(words, j, preferCondition: true);
      return;
    }
    if (first == 'it' || first == 'i' || _conditionAfterAndIn(words, i)) {
      _when(words, i, preferCondition: true);
      return;
    }
    if (_schedule(words, i)) return;
    _unplaced(words, i);
  }

  bool _conditionAfterAndIn(List<String> words, int i) {
    final m = _match(words, i, {_Kind.person});
    return m != null && m.end < words.length && words[m.end] == 'is';
  }

  void _unplaced(List<String> words, int from) {
    for (var j = from; j < words.length; j++) {
      if (!_fillers.contains(words[j]) && words[j] != ',') {
        _unknown.add(words[j]);
      }
    }
  }

  /// A time, days, sun or every-so-often part. False when [words] at [i]
  /// is none of them.
  bool _schedule(List<String> words, int i) {
    var j = i;
    var read = false;
    while (j < words.length) {
      final w = words[j];
      if ((_fillers.contains(w) || w == ',' || w == 'it' || w == 'is') &&
          _durationAt(words, j) == null) {
        j++;
        continue;
      }
      final everyDays = w == 'every' || w == 'each' ? _daysAt(words, j) : null;
      if (everyDays != null) {
        final (list, end) = everyDays;
        if (list != null) _days = list;
        j = end;
        read = true;
        continue;
      }
      if ((w == 'every' || w == 'each') && j + 1 < words.length) {
        final interval = _durationAt(words, j + 1);
        if (interval != null) {
          final (ms, end) = interval;
          _addInterval(ms);
          j = end;
          read = true;
          continue;
        }
        final unit = _unitMs(words[j + 1]);
        if (unit != null) {
          _addInterval(unit);
          j += 2;
          read = true;
          continue;
        }
        j++;
        continue;
      }
      if (w == 'on' && j + 1 < words.length && _isDayWord(words[j + 1])) {
        j++;
        continue;
      }
      final days = _daysAt(words, j);
      if (days != null) {
        final (list, end) = days;
        if (list != null) _days = list;
        j = end;
        read = true;
        continue;
      }
      if (w == 'at' && j + 1 < words.length && words[j + 1] == 'night') {
        _windows.add(_Window.dark(_darkWindow()));
        j += 2;
        read = true;
        continue;
      }
      if (w == 'at' || w == 'around') {
        final time = _timeAt(words, j + 1);
        if (time != null) {
          final (hhmm, end) = time;
          _addTime(hhmm);
          j = end;
          read = true;
          continue;
        }
        final sun = _sunAt(words, j + 1, 0);
        if (sun != null) {
          j = sun;
          read = true;
          continue;
        }
        j++;
        continue;
      }
      if (_isDurationStart2(words, j)) {
        final (ms, end) = _durationAt(words, j)!;
        if (end < words.length &&
            const {'before', 'after'}.contains(words[end])) {
          final minutes = ms ~/ 60000;
          final sign = words[end] == 'before' ? -1 : 1;
          final sun = _sunAt(words, end + 1, sign * minutes);
          if (sun != null) {
            j = sun;
            read = true;
            continue;
          }
        }
      }
      if (w == 'after' || w == 'before') {
        final time = _timeAt(words, j + 1);
        if (time != null) {
          final (hhmm, end) = time;
          _windows.add(
            w == 'after'
                ? _Window.time(hhmm, '00:00', hhmm)
                : _Window.time('00:00', hhmm, null),
          );
          j = end;
          read = true;
          continue;
        }
        if (j + 1 < words.length && _isSun2(words[j + 1]) ||
            j + 1 < words.length && words[j + 1] == 'dark') {
          final sun = _sunWord(words[j + 1]) ?? 'sunset';
          final after = w == 'after';
          _windows.add(
            _Window.dark(
              after == (sun == 'sunset') ? _darkWindow() : _lightWindow(),
              sun: after ? sun : null,
              label: '$w $sun',
            ),
          );
          j += 2;
          read = true;
          continue;
        }
      }
      if (w == 'between') {
        final start = _timeAt(words, j + 1);
        if (start != null &&
            start.$2 < words.length &&
            words[start.$2] == 'and') {
          final end = _timeAt(words, start.$2 + 1);
          if (end != null) {
            _windows.add(_Window.time(start.$1, end.$1, null));
            j = end.$2;
            read = true;
            continue;
          }
        }
      }
      if (_isSun2(w)) {
        final sun = _sunAt(words, j, 0);
        if (sun != null) {
          j = sun;
          read = true;
          continue;
        }
      }
      break;
    }
    if (!read) return false;
    _unplaced(words, j);
    return true;
  }

  bool _isSun2(String w) =>
      const {'sunset', 'sunrise', 'dusk', 'dawn'}.contains(w);

  bool _isDurationStart2(List<String> words, int j) =>
      _durationAt(words, j) != null;

  bool _isDayWord(String w) =>
      _dayNames.containsKey(w) ||
      const {
        'weekday',
        'weekdays',
        'weekend',
        'weekends',
        'day',
        'days',
      }.contains(w);

  static String? _sunWord(String w) => switch (w) {
    'sunset' || 'dusk' => 'sunset',
    'sunrise' || 'dawn' => 'sunrise',
    _ => null,
  };

  /// A sun trigger at [words][j], moved by [offset] minutes. The index
  /// after it, or null.
  int? _sunAt(List<String> words, int j, int offset) {
    if (j >= words.length) return null;
    final sun = _sunWord(words[j]);
    if (sun == null) return null;
    var end = j + 1;
    var by = offset;
    // "sunset minus 30 minutes", "sunrise plus an hour".
    if (offset == 0 &&
        end < words.length &&
        const {'minus', 'plus'}.contains(words[end])) {
      final d = _durationAt(words, end + 1);
      if (d != null) {
        by = (words[end] == 'minus' ? -1 : 1) * (d.$1 ~/ 60000);
        end = d.$2;
      }
    }
    if (by.abs() > sunOffsetLimit) {
      throw _Refusal('A sun time can move at most 12 hours from $sun');
    }
    _triggers.add({'sun': sun, if (by != 0) 'offset': by});
    return end;
  }

  void _addTime(String hhmm) => _triggers.add({'time': hhmm});

  void _addInterval(int ms) {
    if (ms < 1000) throw _Refusal('Every needs at least a second');
    _triggers.add({'interval': ms ~/ 1000});
  }

  /// A days phrase at [j]: `(days or null for every day, end)`.
  (List<String>?, int)? _daysAt(List<String> words, int j) {
    final w = words[j];
    if (const {'daily', 'everyday'}.contains(w)) return (null, j + 1);
    if (w == 'every' || w == 'each') {
      if (j + 1 < words.length) {
        final next = words[j + 1];
        if (next == 'day' || next == 'morning' || next == 'evening') {
          return (null, j + 2);
        }
        if (next == 'night') return (null, j + 2);
        final inner = _daysAt(words, j + 1);
        if (inner != null) return inner;
      }
      return null;
    }
    if (w == 'weekday' || w == 'weekdays') return (_weekdays, j + 1);
    if (w == 'weekend' || w == 'weekends') return (_weekend, j + 1);
    if (_dayNames.containsKey(w)) {
      final days = <String>[];
      var k = j;
      while (k < words.length) {
        final d = _dayNames[words[k]];
        if (d != null) {
          if (k + 2 < words.length &&
              (words[k + 1] == 'to' || words[k + 1] == 'through') &&
              _dayNames.containsKey(words[k + 2])) {
            days.addAll(_range(d, _dayNames[words[k + 2]]!));
            k += 3;
            continue;
          }
          days.add(d);
          k++;
          continue;
        }
        if ((words[k] == 'and' || words[k] == ',' || words[k] == 'or') &&
            k + 1 < words.length &&
            _dayNames.containsKey(words[k + 1])) {
          k++;
          continue;
        }
        break;
      }
      const order = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
      final sorted = order.where(days.contains).toList();
      return (sorted, k);
    }
    return null;
  }

  static List<String> _range(String from, String to) {
    const order = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    final a = order.indexOf(from);
    final b = order.indexOf(to);
    return [for (var k = a; k != (b + 1) % 7; k = (k + 1) % 7) order[k]];
  }

  /// A clock time at [j]: `("HH:MM", end)`, or null when there is none.
  (String, int)? _timeAt(List<String> words, int j) {
    if (!_looksLikeTime(words, j)) return null;
    final w = words[j];
    if (w == 'noon' || w == 'midday') return ('12:00', j + 1);
    if (w == 'midnight') return ('00:00', j + 1);
    final m = _clock.firstMatch(w);
    if (m == null) return null;
    var end = j + 1;
    var suffix = m.group(3);
    if (suffix == null && end < words.length) {
      final next = words[end].replaceAll('.', '');
      if (next == 'am' || next == 'pm') {
        suffix = next;
        end++;
      } else if (next == "o'clock" || next == 'oclock') {
        end++;
      }
    }
    var hour = int.parse(m.group(1)!);
    final minute = int.parse(m.group(2) ?? '0');
    if (minute > 59 ||
        hour > 23 ||
        (suffix != null && (hour < 1 || hour > 12))) {
      throw _Refusal('${words[j]} is not a time of day', [words[j]]);
    }
    if (suffix == 'pm' && hour < 12) hour += 12;
    if (suffix == 'am' && hour == 12) hour = 0;
    return (
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
      end,
    );
  }

  static int? _unitMs(String w) => switch (w) {
    'second' || 'seconds' || 'sec' || 'secs' || 's' => 1000,
    'minute' || 'minutes' || 'min' || 'mins' || 'm' => 60000,
    'hour' || 'hours' || 'hr' || 'hrs' || 'h' => 3600000,
    _ => null,
  };

  /// A length of time at [j]: `(ms, end)`. "5 minutes", "an hour",
  /// "half an hour", "90s".
  (int, int)? _durationAt(List<String> words, int j) {
    if (j >= words.length) return null;
    final w = words[j];
    if (w == 'half' &&
        j + 2 < words.length &&
        (words[j + 1] == 'an' || words[j + 1] == 'a') &&
        words[j + 2] == 'hour') {
      return (1800000, j + 3);
    }
    final glued = RegExp(r'^(\d+)(s|sec|secs|m|min|mins|h|hr|hrs)$')
        .firstMatch(w);
    if (glued != null) {
      return (int.parse(glued.group(1)!) * _unitMs(glued.group(2)!)!, j + 1);
    }
    if (j + 1 >= words.length) return null;
    final unit = _unitMs(words[j + 1]);
    if (unit == null) return null;
    if (w == 'a' || w == 'an' || w == 'one') return (unit, j + 2);
    if (!RegExp(r'^\d+$').hasMatch(w)) return null;
    return (int.parse(w) * unit, j + 2);
  }

  // The when part: a trigger, or with [preferCondition] what must be true.

  void _when(List<String> words, int i, {required bool preferCondition}) {
    var j = _skipFillers(words, i);
    if (words
        .skip(j)
        .every(
          (w) => _fillers.contains(w) || w == 'it' || w == 'is' || w == ',',
        )) {
      return;
    }
    // "when it is 7", "if it is after 18:00".
    if (words[j] == 'it' &&
        j + 1 < words.length &&
        words[j + 1] == 'is' &&
        j + 2 < words.length &&
        (_timeAt(words, j + 2) != null ||
            const {'after', 'before', 'between'}.contains(words[j + 2]))) {
      if (!_schedule(words, j + 2)) _unplaced(words, j + 2);
      return;
    }
    if (words[j] == 'it' &&
        j + 1 < words.length &&
        (words[j + 1] == 'is' || words[j + 1] == 'gets') &&
        j + 2 < words.length &&
        words[j + 2] == 'dark') {
      _windows.add(_Window.dark(_darkWindow(), sun: 'sunset', label: 'dark'));
      _unplaced(words, j + 3);
      return;
    }
    if (_schedule(words, j)) return;
    final end =
        _me(words, j, preferCondition) ??
        _personPart(words, j, preferCondition) ??
        _temperaturePart(words, j, preferCondition) ??
        _thingPart(words, j, preferCondition);
    if (end == null) {
      final rest = [
        for (final w in words.skip(j))
          if (!_fillers.contains(w)) w,
      ];
      throw _Refusal(
        rest.isEmpty
            ? 'I could not tell when it should happen'
            : 'I could not tell what "${rest.join(' ')}" means as a trigger. '
                  'Name a device, a person, a place or a time',
        rest,
      );
    }
    _unplaced(words, end);
  }

  int _skipFillers(List<String> words, int i) {
    var j = i;
    while (j < words.length &&
        (_fillers.contains(words[j]) || words[j] == ',')) {
      j++;
    }
    return j;
  }

  String _myId() {
    final person = home.person;
    if (person == null) {
      throw _Refusal(
        'I do not know who "I" is. Add yourself as a person first, in '
        'Settings, People',
        ['i'],
      );
    }
    return person;
  }

  static const _arrive = [
    ['get', 'home'],
    ['gets', 'home'],
    ['arrive', 'home'],
    ['arrives', 'home'],
    ['come', 'home'],
    ['comes', 'home'],
    ['get', 'back'],
    ['gets', 'back'],
    ['come', 'back'],
    ['comes', 'back'],
    ['return', 'home'],
    ['returns', 'home'],
    ['reach', 'home'],
    ['reaches', 'home'],
    ['arrive'],
    ['arrives'],
  ];

  static const _leave = [
    ['leave', 'home'],
    ['leaves', 'home'],
    ['leave', 'the', 'house'],
    ['leaves', 'the', 'house'],
    ['go', 'out'],
    ['goes', 'out'],
    ['head', 'out'],
    ['heads', 'out'],
    ['leave'],
    ['leaves'],
  ];

  static int? _phrase(List<String> words, int j, List<List<String>> options) {
    for (final p in options) {
      if (j + p.length > words.length) continue;
      var ok = true;
      for (var k = 0; k < p.length; k++) {
        if (words[j + k] != p[k]) ok = false;
      }
      if (ok) return j + p.length;
    }
    return null;
  }

  /// "I get home", "I leave", "I arrive at the office", "I am home",
  /// "I scan the front door tag", "I turn on the TV".
  int? _me(List<String> words, int j, bool preferCondition) {
    if (words[j] != 'i' && words[j] != 'me') return null;
    final k = j + 1;
    if (k >= words.length) throw _Refusal('What should happen to you?', []);
    // A place by name: "I arrive at the office", "I leave work".
    for (final (verbs, entered) in [
      (const ['arrive', 'get', 'reach', 'am'], true),
      (const ['leave'], false),
    ]) {
      if (!verbs.contains(words[k])) continue;
      var p = k + 1;
      if (p < words.length &&
          (words[p] == 'at' || words[p] == 'to' || words[p] == 'in')) {
        p++;
      }
      p = _skipFillers(words, p);
      final place = _match(words, p, {_Kind.place});
      if (place != null && !(words[k] == 'am' && !preferCondition)) {
        _choose(place);
        _place(place.entity.id, entered, condition: words[k] == 'am');
        return place.end;
      }
    }
    final person = _myId();
    if (words[k] == 'am' || words[k] == 'not') {
      final away = _phrase(words, k, const [
        ['am', 'away'],
        ['am', 'out'],
        ['am', 'not', 'home'],
        ['am', 'not', 'at', 'home'],
      ]);
      final here = _phrase(words, k, const [
        ['am', 'home'],
        ['am', 'at', 'home'],
        ['am', 'in'],
      ]);
      if (away != null || here != null) {
        _conditions.add({
          'state': '$person.home',
          'op': '==',
          'value': here != null,
        });
        return away ?? here;
      }
    }
    final arrive = _phrase(words, k, _arrive);
    if (arrive != null) {
      _triggers.add({
        'on': '$person.home',
        'change': {'to': true},
      });
      return arrive;
    }
    final leave = _phrase(words, k, _leave);
    if (leave != null) {
      _triggers.add({
        'on': '$person.home',
        'change': {'to': false},
      });
      return leave;
    }
    if (words[k] == 'scan' || words[k] == 'tap') {
      final p = _skipFillers(words, k + 1);
      final tag = _match(words, p, {_Kind.tag});
      if (tag == null) {
        throw _Refusal('I do not know that NFC tag', [
          for (final w in words.skip(p))
            if (!_fillers.contains(w)) w,
        ]);
      }
      _choose(tag);
      _triggers.add({'on': '${tag.entity.id}.scanned', 'event': true});
      var end = tag.end;
      if (end < words.length && words[end] == 'tag') end++;
      return end;
    }
    if (words[k] == 'turn' || words[k] == 'switch') {
      var p = k + 1;
      bool? on;
      if (p < words.length && (words[p] == 'on' || words[p] == 'off')) {
        on = words[p] == 'on';
        p++;
      }
      p = _skipFillers(words, p);
      final thing = _match(words, p, {_Kind.thing});
      if (thing == null) return null;
      _choose(thing);
      var end = thing.end;
      if (on == null &&
          end < words.length &&
          (words[end] == 'on' || words[end] == 'off')) {
        on = words[end] == 'on';
        end++;
      }
      if (on == null) return null;
      _thingTurns(thing.entity.thing!, on, condition: preferCondition);
      return end;
    }
    return null;
  }

  void _place(String placeId, bool inside, {required bool condition}) {
    final person = home.person;
    final ref = person != null && home.homePlace == placeId
        ? '$person.home'
        : '$placeId.inside';
    if (condition) {
      _conditions.add({'state': ref, 'op': '==', 'value': inside});
    } else {
      _triggers.add({
        'on': ref,
        'change': {'to': inside},
      });
    }
  }

  /// "Jade gets home", "Jade leaves", "Jade is home", "Jade is away".
  int? _personPart(List<String> words, int j, bool preferCondition) {
    if (const {
      'someone',
      'anyone',
      'everyone',
      'everybody',
      'nobody',
      'somebody',
    }.contains(words[j])) {
      throw _Refusal(
        'I cannot read "${words[j]}" yet. Name one person, like '
        '"when Jade gets home"',
        [words[j]],
      );
    }
    final m = _match(words, j, {_Kind.person});
    if (m == null) return null;
    _choose(m);
    final id = m.entity.id;
    final k = m.end;
    final cond = _phrase(words, k, const [
      ['is', 'home'],
      ['is', 'at', 'home'],
      ['is', 'away'],
      ['is', 'out'],
      ['is', 'not', 'home'],
    ]);
    if (cond != null) {
      _conditions.add({
        'state': '$id.home',
        'op': '==',
        'value': words[k + 1] == 'home' || words[k + 1] == 'at',
      });
      return cond;
    }
    final arrive = _phrase(words, k, _arrive);
    final leave = arrive == null ? _phrase(words, k, _leave) : null;
    if (arrive == null && leave == null) return null;
    _triggers.add({
      'on': '$id.home',
      'change': {'to': arrive != null},
    });
    return arrive ?? leave;
  }

  static const _above = [
    ['gets', 'above'],
    ['goes', 'above'],
    ['rises', 'above'],
    ['is', 'above'],
    ['is', 'over'],
    ['goes', 'over'],
    ['gets', 'over'],
    ['gets', 'hotter', 'than'],
    ['gets', 'warmer', 'than'],
    ['is', 'higher', 'than'],
    ['is', 'more', 'than'],
    ['above'],
    ['over'],
  ];

  static const _below = [
    ['gets', 'below'],
    ['goes', 'below'],
    ['drops', 'below'],
    ['falls', 'below'],
    ['is', 'below'],
    ['is', 'under'],
    ['goes', 'under'],
    ['drops', 'under'],
    ['gets', 'colder', 'than'],
    ['gets', 'cooler', 'than'],
    ['is', 'lower', 'than'],
    ['is', 'less', 'than'],
    ['below'],
    ['under'],
  ];

  /// "it gets above 28", "the temperature drops below 18": the home's
  /// temperature.
  int? _temperaturePart(List<String> words, int j, bool preferCondition) {
    if (words[j] != 'it' && words[j] != 'temperature') return null;
    var k = j + 1;
    if (words[j] == 'it' && k < words.length && words[k] == 'temperature') k++;
    if (_phrase(words, k, _above) == null &&
        _phrase(words, k, _below) == null) {
      return null;
    }
    final (thing, key) = _temperature(words[j]);
    return _threshold(words, k, thing, key, preferCondition);
  }

  /// "goes above 28" at [k] on `thing.key`. The index after it, or null.
  int? _threshold(
    List<String> words,
    int k,
    String thing,
    String key,
    bool preferCondition,
  ) {
    final above = _phrase(words, k, _above);
    final below = above == null ? _phrase(words, k, _below) : null;
    final at = above ?? below;
    if (at == null || at >= words.length) return null;
    final n = num.tryParse(words[at].replaceAll(RegExp(r'[a-z]+$'), ''));
    if (n == null || !n.isFinite) {
      throw _Refusal('${words[at]} is not a number', [words[at]]);
    }
    var end = at + 1;
    if (end < words.length &&
        const {
          'degrees',
          'degree',
          'c',
          'celsius',
          'percent',
        }.contains(words[end])) {
      end++;
    }
    final isState =
        words[k] == 'is' || words[k] == 'above' || words[k] == 'below';
    if (preferCondition || (isState && _triggers.isNotEmpty)) {
      _conditions.add({
        'state': '$thing.$key',
        'op': above != null ? '>' : '<',
        'value': n,
      });
    } else {
      // "above 28 for 10 minutes": the crossing has to hold that long.
      final held = end < words.length && words[end] == 'for'
          ? _durationAt(words, end + 1)
          : null;
      _triggers.add({
        'on': '$thing.$key',
        'crosses': {above != null ? 'above' : 'below': n},
        'for': ?held?.$1,
      });
      if (held != null) end = held.$2;
    }
    return end;
  }

  /// The thing that reports the home's temperature. With more than one,
  /// the first, and the others as alternatives.
  (String, String) _temperature(String said) {
    final found = <(ParseThing, String)>[];
    for (final t in home.things) {
      final key = _temperatureKey(t);
      if (key != null) found.add((t, key));
    }
    if (found.isEmpty) {
      throw _Refusal('Nothing in your home reports a temperature yet', [said]);
    }
    if (found.length > 1) {
      _alternatives.add({
        'text': said,
        'chosen': {'id': found.first.$1.id, 'name': found.first.$1.name},
        'options': [
          for (final (t, _) in found.skip(1)) {'id': t.id, 'name': t.name},
        ],
      });
    }
    return (found.first.$1.id, found.first.$2);
  }

  static String? _temperatureKey(ParseThing t) {
    for (final c in t.manifest?.capabilities ?? const <CapabilitySpec>[]) {
      if (c.type != CapabilityType.sensor || !_reports(t, c)) continue;
      final words = '${c.id} ${c.label}'.toLowerCase();
      if (words.contains('temp') && !words.contains('color')) return c.id;
    }
    return null;
  }

  /// "the front door opens", "the TV turns on", "motion is detected in the
  /// hall", "the hall sensor goes above 25", "the lamp changes".
  int? _thingPart(List<String> words, int j, bool preferCondition) {
    if (words[j] == 'motion' ||
        (words[j] == 'there' && words.contains('motion'))) {
      var p = words.indexOf('motion', j) + 1;
      p =
          _phrase(words, p, const [
            ['is', 'detected'],
            ['detected'],
          ]) ??
          p;
      String? room;
      if (p < words.length && words[p] == 'in') {
        final r = _match(words, _skipFillers(words, p + 1), {_Kind.room});
        if (r != null) {
          room = r.entity.id;
          p = r.end;
        }
      }
      final sensor = _withCapability('occupancy', room: room);
      if (sensor == null) {
        throw _Refusal('Nothing in your home reports motion yet', ['motion']);
      }
      _onState(sensor, 'occupancy', true, condition: preferCondition);
      return p;
    }
    final m = _match(words, j, {_Kind.thing, _Kind.tag, _Kind.room});
    if (m == null) return null;
    _choose(m);
    var k = m.end;
    if (m.entity.kind == _Kind.room) {
      // "the living room temperature goes above 25".
      if (k < words.length && words[k] == 'temperature') {
        final sensor = home.things
            .where((t) => t.room == m.entity.id && _temperatureKey(t) != null)
            .firstOrNull;
        if (sensor == null) {
          throw _Refusal('Nothing in ${m.entity.name} reports a temperature');
        }
        return _threshold(
          words,
          k + 1,
          sensor.id,
          _temperatureKey(sensor)!,
          preferCondition,
        );
      }
      return null;
    }
    if (m.entity.kind == _Kind.tag) {
      final scanned = _phrase(words, k, const [
        ['is', 'scanned'],
        ['gets', 'scanned'],
        ['is', 'tapped'],
        ['scanned'],
      ]);
      if (scanned == null) return null;
      _triggers.add({'on': '${m.entity.id}.scanned', 'event': true});
      return scanned;
    }
    final thing = m.entity.thing!;
    if (k < words.length && words[k] == 'temperature') {
      final key = _temperatureKey(thing);
      if (key != null) {
        return _threshold(words, k + 1, thing.id, key, preferCondition);
      }
    }
    final threshold = _numericKey(thing);
    if (threshold != null) {
      final end = _threshold(words, k, thing.id, threshold, preferCondition);
      if (end != null) return end;
    }
    final opens = _phrase(words, k, const [
      ['opens'],
      ['is', 'opened'],
      ['is', 'open'],
      ['gets', 'opened'],
      ['open'],
    ]);
    final closes = opens == null
        ? _phrase(words, k, const [
            ['closes'],
            ['is', 'closed'],
            ['gets', 'closed'],
            ['shuts'],
          ])
        : null;
    if (opens != null || closes != null) {
      if (_capability(thing, 'contact') == null) {
        throw _Refusal('${thing.name} does not report open or closed');
      }
      // A contact sensor reports true when it is closed.
      _onState(thing.id, 'contact', closes != null, condition: preferCondition);
      return opens ?? closes;
    }
    final motion = _phrase(words, k, const [
      ['detects', 'motion'],
      ['sees', 'motion'],
      ['senses', 'motion'],
    ]);
    if (motion != null) {
      if (_capability(thing, 'occupancy') == null) {
        throw _Refusal('${thing.name} does not report motion');
      }
      _onState(thing.id, 'occupancy', true, condition: preferCondition);
      return motion;
    }
    final turns = _phrase(words, k, const [
      ['turns', 'on'],
      ['is', 'turned', 'on'],
      ['switches', 'on'],
      ['comes', 'on'],
      ['goes', 'on'],
      ['is', 'on'],
      ['turns', 'off'],
      ['is', 'turned', 'off'],
      ['switches', 'off'],
      ['goes', 'off'],
      ['is', 'off'],
    ]);
    if (turns != null) {
      _thingTurns(
        thing,
        words[turns - 1] == 'on',
        condition:
            preferCondition ||
            (words[k] == 'is' &&
                words[k + 1] != 'turned' &&
                _triggers.isNotEmpty),
      );
      return turns;
    }
    final changes = _phrase(words, k, const [
      ['changes'],
      ['is', 'changed'],
    ]);
    if (changes != null) {
      final key = _onOffKey(thing)?.$1 ?? _numericKey(thing);
      if (key == null) return null;
      _triggers.add({'on': '${thing.id}.$key', 'change': <String, Object?>{}});
      return changes;
    }
    return null;
  }

  /// A thing with [capability], in [room] when given.
  String? _withCapability(String capability, {String? room}) => home.things
      .where(
        (t) =>
            (room == null || t.room == room) &&
            _capability(t, capability) != null,
      )
      .firstOrNull
      ?.id;

  static CapabilitySpec? _capability(ParseThing t, String id) {
    final c = t.manifest?.capability(id);
    return c != null && _reports(t, c) ? c : null;
  }

  /// Whether [t] has [c]: an action always, and a state once it has
  /// reported its key, or while it has reported nothing yet.
  static bool _reports(ParseThing t, CapabilitySpec c) {
    if (t.state.isEmpty) return true;
    final key = stateKeyOf(c.stateJsonPath);
    return key == null || t.state.containsKey(key);
  }

  void _onState(
    String thing,
    String key,
    Object value, {
    required bool condition,
  }) {
    if (condition) {
      _conditions.add({'state': '$thing.$key', 'op': '==', 'value': value});
    } else {
      _triggers.add({
        'on': '$thing.$key',
        'change': {'to': value},
      });
    }
  }

  /// The key that says [t] is on or off, and the values for on and off:
  /// a toggle's true and false, or a TV power sensor's words.
  static (String, Object, Object)? _onOffKey(ParseThing t) {
    final caps = t.manifest?.capabilities ?? const <CapabilitySpec>[];
    final toggle =
        caps
            .where(
              (c) =>
                  c.id == 'power' &&
                  c.type == CapabilityType.toggle &&
                  stateKeyOf(c.stateJsonPath) != null &&
                  _reports(t, c),
            )
            .firstOrNull ??
        caps
            .where(
              (c) =>
                  c.type == CapabilityType.toggle &&
                  stateKeyOf(c.stateJsonPath) != null &&
                  _reports(t, c),
            )
            .firstOrNull;
    if (toggle != null) return (toggle.id, true, false);
    final sensor = caps
        .where(
          (c) =>
              c.type == CapabilityType.sensor &&
              c.values.contains('on') &&
              c.values.contains('off') &&
              _reports(t, c),
        )
        .firstOrNull;
    if (sensor != null) return (sensor.id, 'on', 'off');
    return null;
  }

  static String? _numericKey(ParseThing t) {
    for (final c in t.manifest?.capabilities ?? const <CapabilitySpec>[]) {
      if (c.type == CapabilityType.sensor &&
          stateKeyOf(c.stateJsonPath) != null &&
          c.values.isEmpty &&
          _reports(t, c) &&
          !const {
            'home',
            'place',
            'inside',
            'people',
            'contact',
            'occupancy',
          }.contains(c.id)) {
        final label = c.label.toLowerCase();
        if (label.contains('app') ||
            label.contains('since') ||
            label.contains('what')) {
          continue;
        }
        return c.id;
      }
    }
    return null;
  }

  void _thingTurns(ParseThing thing, bool on, {required bool condition}) {
    final key = _onOffKey(thing);
    if (key == null) {
      throw _Refusal('${thing.name} does not report on or off');
    }
    _onState(thing.id, key.$1, on ? key.$2 : key.$3, condition: condition);
  }

  // The do part.

  void _action(List<String> words, List<String> raws, int i) {
    final verb = words[i];
    var j = i + 1;
    switch (verb) {
      case 'turn' || 'switch':
        bool? on;
        if (j < words.length && (words[j] == 'on' || words[j] == 'off')) {
          on = words[j] == 'on';
          j++;
        }
        final targets = _targets(words, j, stopAtOnOff: on == null);
        j = targets.end;
        if (on == null &&
            j < words.length &&
            (words[j] == 'on' || words[j] == 'off')) {
          on = words[j] == 'on';
          j++;
        }
        if (on == null) {
          throw _Refusal('Say turn on or turn off', [verb]);
        }
        final isOn = on;
        _steps.addAll([for (final t in targets.things) _power(t, isOn)]);
        j = _forDuration(
          words,
          j,
          () => [for (final t in targets.things) _power(t, !isOn)],
        );
      case 'toggle':
        final targets = _targets(words, j);
        j = targets.end;
        for (final t in targets.things) {
          final key = _onOffKey(t);
          if (key == null || key.$2 != true) {
            throw _Refusal('${t.name} cannot be toggled');
          }
          _steps.add({'toggle': '${t.id}.${key.$1}'});
        }
      case 'dim' || 'set':
        final targets = _targets(words, j);
        j = targets.end;
        num? value;
        while (j < words.length &&
            const {
              'brightness',
              'to',
              'at',
              'the',
              'level',
            }.contains(words[j])) {
          j++;
        }
        if (j < words.length && _number.hasMatch(words[j])) {
          value = num.parse(words[j]);
          j++;
          if (j < words.length && (words[j] == 'percent' || words[j] == '%')) {
            j++;
          }
        } else if (j < words.length &&
            (words[j] == 'on' || words[j] == 'off') &&
            verb == 'set') {
          final on = words[j] == 'on';
          j++;
          for (final t in targets.things) {
            _steps.add(_power(t, on));
          }
          break;
        }
        if (value == null && verb == 'dim') value = 30;
        if (value == null) {
          throw _Refusal('Set it to what? Say a number, like 40%');
        }
        for (final t in targets.things) {
          final level = _levelOf(t);
          if (level == null) {
            throw _Refusal('${t.name} has no brightness to set');
          }
          _steps.add({
            'do': '${t.id}.$level',
            'params': {'value': value},
          });
        }
        j = _forDuration(
          words,
          j,
          () => [for (final t in targets.things) _power(t, false)],
        );
      case 'run' || 'start':
        j = _skipFillers(words, j);
        final m = _match(words, j, {_Kind.automation});
        if (m == null) {
          final rest = [
            for (final w in words.skip(j))
              if (!_fillers.contains(w)) w,
          ];
          throw _Refusal(
            rest.isEmpty
                ? 'Run what? Name a scene or an automation'
                : 'I do not know a scene or automation called "${rest.join(' ')}"',
            rest,
          );
        }
        _choose(m);
        _steps.add({'run': m.entity.id});
        j = m.end;
        if (j < words.length &&
            (words[j] == 'scene' || words[j] == 'automation')) {
          j++;
        }
      case 'notify' || 'alert' || 'tell' || 'send' || 'remind':
        while (j < words.length &&
            const {
              'me',
              'us',
              'a',
              'notification',
              'message',
              'saying',
              'that',
              'with',
              ':',
            }.contains(words[j])) {
          j++;
        }
        final message = raws.skip(j).join(' ').trim();
        if (message.isEmpty) throw _Refusal('Notify with what words?');
        _steps.add({
          'notify': {'title': message},
        });
        return;
      case 'wait':
        if (j < words.length && words[j] == 'for') j++;
        final d = _durationAt(words, j);
        if (d == null) {
          throw _Refusal('Wait how long? Say 5 minutes or 30 seconds');
        }
        _steps.add({'wait': d.$1});
        j = d.$2;
    }
    _unplaced(words, j);
  }

  /// "for 5 minutes" at [j]: a wait, then the [undo] steps.
  int _forDuration(
    List<String> words,
    int j,
    List<Map<String, Object?>> Function() undo,
  ) {
    if (j >= words.length || words[j] != 'for') return j;
    final d = _durationAt(words, j + 1);
    if (d == null) return j;
    _steps
      ..add({'wait': d.$1})
      ..addAll(undo());
    return d.$2;
  }

  static String? _levelOf(ParseThing t) {
    final caps = t.manifest?.capabilities ?? const <CapabilitySpec>[];
    for (final id in const ['brightness', 'dimmer']) {
      if (caps.any((c) => c.id == id && c.type == CapabilityType.level)) {
        return id;
      }
    }
    return caps
        .where((c) => c.type == CapabilityType.level && c.id != 'volume')
        .firstOrNull
        ?.id;
  }

  /// The step that turns [t] on or off.
  Map<String, Object?> _power(ParseThing t, bool on) {
    final key = _onOffKey(t);
    if (key != null && key.$2 == true) {
      return {
        'do': '${t.id}.${key.$1}',
        'params': {'value': on},
      };
    }
    final actions = powerActionsOf(t.manifest, 'power');
    if (actions != null) {
      return {'do': '${t.id}.${on ? actions.on : actions.off}'};
    }
    final named = on ? 'power_on' : 'power_off';
    if (_capability(t, named)?.type == CapabilityType.action) {
      return {'do': '${t.id}.$named'};
    }
    throw _Refusal('${t.name} cannot be turned ${on ? 'on' : 'off'}');
  }

  static bool _switchable(ParseThing t) {
    if (const {
      personDriverId,
      placeDriverId,
      nfcTagDriverId,
      phoneDriverId,
    }.contains(t.driver)) {
      return false;
    }
    if (_onOffKey(t)?.$2 == true) return true;
    if (powerActionsOf(t.manifest, 'power') != null) return true;
    return t.manifest?.capability('power_off') != null;
  }

  static bool _isLight(ParseThing t) =>
      _switchable(t) &&
      (t.category == 'lighting' ||
          _nameWords(
            t.name,
          ).any((w) => const {'light', 'lights', 'lamp', 'bulb'}.contains(w)));

  /// The things a step acts on: "the lights", "the living room lights",
  /// "the lights in the kitchen", "the living room", "the desk lamp and the
  /// fan".
  ({List<ParseThing> things, int end}) _targets(
    List<String> words,
    int i, {
    bool stopAtOnOff = false,
  }) {
    final things = <ParseThing>[];
    var j = i;
    while (true) {
      j = _skipFillers(words, j);
      if (j < words.length && words[j] == 'all') j = _skipFillers(words, j + 1);
      if (j >= words.length) break;
      final w = words[j];
      if (w == 'lights' || w == 'light' || w == 'everything') {
        var end = j + 1;
        String? room;
        if (end + 1 < words.length && words[end] == 'in') {
          final r = _match(words, _skipFillers(words, end + 1), {_Kind.room});
          if (r != null) {
            room = r.entity.id;
            end = r.end;
          }
        }
        final found = [
          for (final t in home.things)
            if ((room == null || t.room == room) &&
                (w == 'everything' ? _switchable(t) : _isLight(t)))
              t,
        ];
        if (found.isEmpty) {
          throw _Refusal(
            room == null
                ? 'There are no lights in your home yet'
                : 'There are no lights in ${home.rooms[room]}',
            [w],
          );
        }
        things.addAll(found);
        j = end;
      } else {
        final m = _match(words, j, {_Kind.thing, _Kind.room});
        if (m == null) {
          final rest = <String>[];
          for (var k = j; k < words.length; k++) {
            if (_startsPartIn(words, k) ||
                (stopAtOnOff && (words[k] == 'on' || words[k] == 'off'))) {
              break;
            }
            if (!_fillers.contains(words[k])) rest.add(words[k]);
          }
          throw _Refusal(
            rest.isEmpty
                ? 'Turn what? Name a device, a room or the lights'
                : 'I do not know a device or room called "${rest.join(' ')}"',
            rest,
          );
        }
        _choose(m);
        var end = m.end;
        if (m.entity.kind == _Kind.room) {
          final lightsOnly =
              end < words.length &&
              (words[end] == 'lights' || words[end] == 'light');
          if (lightsOnly) end++;
          final found = [
            for (final t in home.things)
              if (t.room == m.entity.id &&
                  (lightsOnly ? _isLight(t) : _switchable(t)))
                t,
          ];
          if (found.isEmpty) {
            throw _Refusal(
              'Nothing in ${m.entity.name} can be turned on or off',
              [for (final w in m.entity.words) w],
            );
          }
          things.addAll(found);
        } else {
          things.add(m.entity.thing!);
        }
        j = end;
      }
      final next = _skipFillers(words, j);
      if (next < words.length &&
          j < words.length &&
          (words[j] == 'and' || words[j] == ',')) {
        if (_startsPartIn(words, j)) break;
        j = next;
        continue;
      }
      break;
    }
    if (things.isEmpty) {
      throw _Refusal('Turn what? Name a device, a room or the lights');
    }
    return (things: things, end: j);
  }

  /// A step keyword inside an action's words: "and turn", "and notify".
  static bool _startsPartIn(List<String> words, int k) =>
      _actionVerbs.contains(words[k]) ||
      ((words[k] == 'and' || words[k] == ',') &&
          k + 1 < words.length &&
          _actionVerbs.contains(words[k + 1]));

  // Names.

  void _choose(_Match m) {
    if (m.others.isEmpty) return;
    _alternatives.add({
      'text': m.text,
      'chosen': {'id': m.entity.id, 'name': m.entity.name},
      'options': [
        for (final o in m.others) {'id': o.id, 'name': o.name},
      ],
    });
  }

  /// The best name of [kinds] that starts at [words][i]: the longest run of
  /// words that reads as a name, exactly, then nearly (one letter off, a
  /// plural), then as part of a longer name.
  _Match? _match(List<String> words, int i, Set<_Kind> kinds) {
    if (i >= words.length) return null;
    final candidates = [
      for (final e in _entities)
        if (kinds.contains(e.kind) && e.words.isNotEmpty) e,
    ];
    for (var len = 6; len >= 1; len--) {
      if (i + len > words.length) continue;
      final said = words.sublist(i, i + len);
      if (said.any((w) => w == ',' || w == 'and')) continue;
      final best = <(_Entity, int)>[];
      for (final e in candidates) {
        final score = _score(said, e.words);
        if (score > 0) best.add((e, score));
      }
      if (best.isEmpty) continue;
      final top = best.map((b) => b.$2).reduce((a, b) => a > b ? a : b);
      final winners = [
        for (final b in best)
          if (b.$2 == top) b.$1,
      ];
      // A thing beats a room of the same name: "the desk" names the
      // device called Desk rather than a room called Desk.
      winners.sort((a, b) => a.kind.index.compareTo(b.kind.index));
      return _Match(
        winners.first,
        i + len,
        top,
        top >= 3 ? const [] : winners.skip(1).toList(),
        said.join(' '),
      );
    }
    return null;
  }

  /// 3 for the same words, 2 for nearly the same, 1 for a part of a
  /// longer name, 0 for no match.
  static int _score(List<String> said, List<String> name) {
    if (_same(said, name, exact: true)) return 3;
    if (said.length == name.length && _same(said, name, exact: false)) return 2;
    if (said.length < name.length) {
      for (var start = 0; start + said.length <= name.length; start++) {
        if (_same(
              said,
              name.sublist(start, start + said.length),
              exact: false,
            ) &&
            !said.every(_generic.contains)) {
          return 1;
        }
      }
    }
    return 0;
  }

  /// Words that are part of many names, so they never name a thing alone.
  static const _generic = {
    'room',
    'light',
    'lights',
    'the',
    'plug',
    'sensor',
    'tv',
  };

  static bool _same(List<String> a, List<String> b, {required bool exact}) {
    if (a.length != b.length) return false;
    for (var k = 0; k < a.length; k++) {
      if (exact ? a[k] != b[k] : !_near(a[k], b[k])) return false;
    }
    return true;
  }

  static bool _near(String a, String b) {
    if (a == b) return true;
    String one(String w) =>
        w.length > 3 && w.endsWith('s') ? w.substring(0, w.length - 1) : w;
    if (one(a) == one(b)) return true;
    final shorter = a.length < b.length ? a.length : b.length;
    if (shorter < 4) return false;
    return _distance(a, b) <= (shorter >= 8 ? 2 : 1);
  }

  static int _distance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (k) => k);
    for (var x = 1; x <= a.length; x++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = x;
      for (var y = 1; y <= b.length; y++) {
        final cost = a[x - 1] == b[y - 1] ? 0 : 1;
        current[y] = [
          previous[y] + 1,
          current[y - 1] + 1,
          previous[y - 1] + cost,
        ].reduce((p, q) => p < q ? p : q);
      }
      previous = current;
    }
    return previous[b.length];
  }

  // Putting it together.

  /// Today's dark hours, sunset to sunrise, as clock times.
  (String, String)? _darkWindow() {
    final sunset = _sunTime(SunEvent.sunset);
    final sunrise = _sunTime(SunEvent.sunrise);
    return sunset == null || sunrise == null ? null : (sunset, sunrise);
  }

  (String, String)? _lightWindow() {
    final sunset = _sunTime(SunEvent.sunset);
    final sunrise = _sunTime(SunEvent.sunrise);
    return sunset == null || sunrise == null ? null : (sunrise, sunset);
  }

  String? _sunTime(SunEvent event) {
    final location = home.location;
    if (location == null) return null;
    final at = sunEventOn(home.now, event, location);
    if (at == null) return null;
    return '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  }

  void _assemble() {
    final timed = _triggers.where(
      (t) => t.containsKey('time') || t.containsKey('sun'),
    );
    if (_days != null) {
      if (timed.isNotEmpty) {
        for (final t in timed) {
          t['days'] = _days;
        }
      } else if (_triggers.isNotEmpty || _windows.isNotEmpty) {
        _conditions.add({'days': _days});
      }
    }
    for (final w in _windows) {
      if (_triggers.isEmpty && w.trigger != null) {
        // "after sunset turn on the porch light", "after 18:00 ...": the
        // start of the window is when it runs.
        _triggers.add({...w.trigger!, if (_days != null) 'days': _days});
        continue;
      }
      final window = w.window;
      if (window == null) {
        throw _Refusal(
          'After sunset needs the home location. Set it in Settings, Home '
          'location',
          ['sunset'],
        );
      }
      _conditions.add({
        'between': [window.$1, window.$2],
      });
      if (w.sunBased) {
        _notes.add(
          'Reads "${w.label}" as ${window.$1} to ${window.$2}, from today\'s '
          'sunrise and sunset. It does not move with the seasons',
        );
      }
    }
    if (_steps.isEmpty) {
      throw _Refusal(
        'I could not find what to do. Start with turn on, turn off, set, '
        'run or notify',
      );
    }
    if (_triggers.isEmpty) {
      throw _Refusal(
        'That is something to do now, not an automation. Say when it should '
        'happen, like "at 7" or "when I get home"',
      );
    }
  }
}

/// A time or sun window read from the sentence.
class _Window {
  _Window.time(String start, String end, String? at)
    : window = (start, end),
      trigger = at == null ? null : {'time': at},
      sunBased = false,
      label = '';

  _Window.dark(this.window, {String? sun, this.label = 'at night'})
    : trigger = sun == null ? null : {'sun': sun},
      sunBased = true;

  final (String, String)? window;

  /// What runs it when nothing else says when.
  final Map<String, Object?>? trigger;
  final bool sunBased;

  /// The words it was read from, for the note.
  final String label;
}
