import 'plain_error.dart';
import 'engine_client.dart';

typedef Json = Map<String, Object?>;

/// Every call to the commands the architecture unification adds
/// (automations, NFC, the add pipeline, the phone's inputs), with their
/// argument shapes and the fields read back from their results, so when one
/// changes shape the change is made here and nowhere else.
///
/// Each one follows the engine's handler of the same name.
abstract final class EngineCalls {
  static const automationSave = 'automation.save';
  static const automationGet = 'automation.get';
  static const automationDryRun = 'automation.dry_run';
  static const nfcScanned = 'nfc.scanned';
  static const tagWritePayload = 'tag.write_payload';
  static const thingAdd = 'thing.add';
  static const thingNext = 'thing.next';
  static const thingConfigure = 'thing.configure';
  static const secretSet = 'secret.set';
  static const devicePair = 'device.pair';
  static const phoneWifi = 'phone.wifi';
  static const phoneBattery = 'phone.battery';

  static const automationList = 'automation.list';
  static const automationEnable = 'automation.enable';
  static const automationApprove = 'automation.approve';
  static const automationRun = 'automation.run';
  static const automationLog = 'automation.log';
  static const automationRemove = 'automation.remove';
  static const automationTemplates = 'automation.templates';
  static const roomList = 'room.list';
  static const roomSave = 'room.save';
  static const roomRemove = 'room.remove';
  static const roomOrder = 'room.order';
  static const deviceList = 'device.list';
  static const deviceGet = 'device.get';
  static const deviceInvoke = 'device.invoke';
  static const deviceRemove = 'device.remove';
  static const deviceOrganize = 'device.organize';
  static const deviceHistory = 'device.history';
  static const sceneSave = 'scene.save';
  static const sceneList = 'scene.list';
  static const sceneRun = 'scene.run';
  static const sceneRemove = 'scene.remove';
  static const tagList = 'tag.list';
  static const commandInterpret = 'command.interpret';
  static const deviceRefresh = 'device.refresh';
  static const driverList = 'driver.list';
  static const driverRegister = 'driver.register';
  static const engineStatus = 'engine.status';
  static const hubStart = 'hub.start';
  static const hubStop = 'hub.stop';
  static const zoneList = 'zone.list';
  static const zoneSave = 'zone.save';
  static const presenceSet = 'presence.set';

  /// A device's state changed: `{device: {id, state, online?}}`.
  static const stateChangedEvent = 'device.stateChanged';

  /// Raised by the engine for a scan no tag thing matches.
  static const tagUnknownEvent = 'tag.unknown';

  /// Raised when a rule's Notify step runs: `{title, body?}`.
  static const flowAnnounceEvent = 'flow.announce';

  /// The rule form. [trusted] is for a rule the user built or already
  /// approved, and approves the saved revision. [id] keeps a reopened rule
  /// under its id when its name changes. [replace] saves over the rule
  /// with that id: the reopened one, or one the user chose to replace. A
  /// new rule without it is refused when its id is taken.
  static Json saveRuleArgs(
    Json spec, {
    String? id,
    required bool trusted,
    bool replace = false,
  }) => {
    'form': 'rule',
    'spec': spec,
    'trusted': trusted,
    'id': ?id,
    if (replace) 'replace': true,
  };

  static Json dryRunRuleArgs(Json spec, {String? id}) => {
    'form': 'rule',
    'spec': spec,
    'id': ?id,
  };

  /// The stored automation in an automation.get reply: `source` and `spec`.
  static Json automationOf(Json result) =>
      Map<String, Object?>.from(result['automation'] as Map? ?? result);

  /// The authoring form of a flow.list, automation.list or automation.get
  /// row: `link`, `rule` or `graph`.
  static String? formOf(Json row) => (row['source'] ?? row['form']) as String?;

  /// Each run in a dry-run reply: `{run: trace}`.
  static List<Json> dryRuns(Json result) => [
    for (final r
        in (result['runs'] as List? ??
            [if (result['run'] case final Map run) run]))
      Map<String, Object?>.from(r as Map),
  ];

  static Json nfcScannedArgs({required String uid, required List<Json> ndef}) =>
      {'uid': uid, 'ndef': ndef, 'source': 'phone'};

  static Json tagWritePayloadArgs(String tagId) => {'id': tagId};

  /// What to write on a tag: its `omniflow://tag/` link and the NDEF
  /// records the engine lays out for it.
  static ({String uri, List<Json> records})? tagPayloadOf(Json result) {
    final uri = result['uri'];
    final records = result['records'];
    if (uri is! String || records is! List || records.isEmpty) return null;
    return (
      uri: uri,
      records: [
        for (final r in records)
          if (r is Map) Map<String, Object?>.from(r),
      ],
    );
  }

  /// The thing a tag.unknown event offers to add, ready for thing.add.
  static Json tagCandidateOf(Json event) => Map<String, Object?>.from(
    event['add'] as Map? ??
        {
          'driver': 'nfc_tag',
          'settings': {'uid': event['uid']},
        },
  );

  /// thing.add with no driver or candidate looks on every method at once.
  static const discoverArgs = <String, Object?>{};

  /// Every candidate in a thing.add find, from its driver groups, with the
  /// group's driver name. The candidate goes back to thing.add as it came.
  static List<({String driverName, Json candidate})> candidatesOf(
    Json result,
  ) => [
    for (final g in (result['groups'] as List? ?? const []).cast<Map>())
      for (final c in (g['candidates'] as List? ?? const []))
        (
          driverName: '${g['name'] ?? g['driver'] ?? ''}',
          candidate: Map<String, Object?>.from(c as Map),
        ),
  ];

  static Json addCandidateArgs(Json candidate, {String? name, String? room}) =>
      {'candidate': candidate, 'name': ?name, 'room': ?room};

  /// The drivers a thing.add find lists under `manual`: `{driver, name,
  /// category, virtual?}`. No method finds them, so they are added by
  /// address, or with no address at all when `virtual` (a place, a person).
  static List<Json> manualOf(Json result) => [
    for (final m in (result['manual'] as List? ?? const []))
      if (m is Map) Map<String, Object?>.from(m),
  ];

  static String? thingIdOf(Json result) => result['id'] as String?;

  /// The `next` of a thing.add, thing.next or thing.configure reply.
  static NextStep nextOf(Json result) => NextStep.fromJson(result['next']);

  /// Where [id]'s setup stands now, which is how a setup left half way
  /// resumes. [paired] reports a `device.pair` that just succeeded.
  static Json nextArgs(String id, {bool paired = false}) => {
    'id': id,
    if (paired) 'paired': true,
  };

  static Json pairArgs(String id) => {'id': id};

  static Json secretArgs(String id, String key, String value) => {
    'deviceId': id,
    'key': key,
    'value': value,
  };

  /// Copies the secret [key] that the thing [from] keeps.
  static Json secretFromArgs(String id, String key, String from) => {
    'deviceId': id,
    'key': key,
    'from': from,
  };

  static Json configureArgs(String id, Json settings) => {
    'id': id,
    'settings': settings,
  };

  static Json wifiArgs({String? ssid, String? bssid}) => {
    'ssid': ?ssid,
    'bssid': ?bssid,
  };

  static Json batteryArgs({int? level, bool? charging}) => {
    'level': ?level,
    'charging': ?charging,
  };
}

enum NextKind { pair, secret, configure, done }

/// One setting or secret a step asks for. [step] is the kind of step it
/// belongs to (`secret` or `configure`), which an optional key on a done
/// step needs to say how it is stored.
typedef StepKey = ({String key, String label, bool optional, String? step});

/// The next step of adding a thing, as the engine says it:
/// `{step: pair | secret | configure | done, instruction, keys?: [{step,
/// key, label, optional?}], command?, optional?}`.
class NextStep {
  const NextStep(
    this.kind, {
    this.instruction,
    this.keys = const [],
    this.optional = const [],
    this.remaining = const [],
    this.method,
    this.help = const {},
    this.sameAs = const {},
  });

  /// A step this app does not know is shown as done, so the user is never
  /// stuck on a screen that cannot finish.
  factory NextStep.fromJson(Object? json) {
    final map = json is Map ? Map<String, Object?>.from(json) : const {};
    final kind = NextKind.values
        .where((k) => k.name == map['step'])
        .firstOrNull;
    List<StepKey> keysOf(Object? list) => [
      for (final k in (list as List? ?? const []).cast<Map>())
        if (k['key'] is String)
          (
            key: k['key'] as String,
            label: '${k['label'] ?? k['key']}',
            optional: k['optional'] == true,
            step: k['step'] as String?,
          ),
    ];
    return NextStep(
      kind ?? NextKind.done,
      instruction: map['instruction'] as String?,
      keys: keysOf(map['keys']),
      optional: keysOf(map['optional']),
      remaining: [
        for (final r in (map['remaining'] as List? ?? const []))
          if (r is String) r,
      ],
      method: map['method'] as String?,
      help: {
        for (final list in [map['keys'], map['optional']])
          for (final k in (list as List? ?? const []).whereType<Map>())
            if (k['key'] is String && k['help'] is String)
              k['key'] as String: k['help'] as String,
      },
      sameAs: {
        for (final k in (map['keys'] as List? ?? const []).whereType<Map>())
          if (k['key'] is String && k['sameAs'] is List)
            k['key'] as String: [
              for (final d in (k['sameAs'] as List).whereType<Map>())
                if (d['id'] is String)
                  (id: d['id'] as String, name: '${d['name'] ?? d['id']}'),
            ],
      },
    );
  }

  /// The steps still open, this one first (`pair`, `secret`, `configure`),
  /// which is how a guided add counts its steps.
  final List<String> remaining;

  /// How a pair step pairs: `adb`, `tv`, `hue_bridge` or `secret`.
  final String? method;

  /// Per secret key, the other things on the same driver that already
  /// have it (one WiZ home key covers every bulb in that home).
  final Map<String, List<({String id, String name})>> sameAs;

  final NextKind kind;
  final String? instruction;
  final List<StepKey> keys;

  /// On a done step, the optional settings and secrets still open.
  final List<StepKey> optional;

  /// What each key is and where to find it, by key, from the driver's
  /// manifest. Keys without help are left out.
  final Map<String, String> help;

  /// A configure step for a board's pins, which the pin sheet sets.
  bool get isPins =>
      kind == NextKind.configure && keys.any((k) => k.key == 'pins');
}

/// A call that failed: the engine's error type, its plain message and, for
/// a validation error, each issue with the rule path it names
/// (`then[2].do`), so an editor can show it on that row.
class ApiFailure {
  const ApiFailure(this.type, this.message, [this.issues = const []]);

  factory ApiFailure.of(Json result) {
    final error = result['error'] is Map
        ? Map<String, Object?>.from(result['error'] as Map)
        : const <String, Object?>{};
    final type = '${error['type'] ?? 'failed'}';
    return ApiFailure(type, plainError(type, error['message'] as String?), [
      for (final issue in (error['issues'] as List? ?? const []))
        if (issue case {'path': final Object path, 'message': final Object m})
          (path: '$path', message: '$m'),
    ]);
  }

  /// The engine could not be reached or threw.
  static const unreachable = ApiFailure(
    'unreachable',
    'OmniFlow did not answer. Try again in a moment.',
  );

  final String type;
  final String message;
  final List<({String path, String message})> issues;

  /// The issues at [path] or under it (`then[2]` covers `then[2].do`).
  List<String> issuesAt(String path) => [
    for (final i in issues)
      if (i.path == path ||
          i.path.startsWith('$path.') ||
          i.path.startsWith('$path['))
        i.message,
  ];
}

/// What a typed call returns: [value] when it worked, [failure] when not.
class Reply<T> {
  const Reply.ok(T this.value) : failure = null;
  const Reply.failed(ApiFailure this.failure) : value = null;

  final T? value;
  final ApiFailure? failure;

  bool get ok => failure == null;

  /// [value], or [fallback] when the call failed.
  T or(T fallback) => ok ? value as T : fallback;
}

/// A room: `room.list` rows.
class Room {
  const Room({
    required this.id,
    required this.name,
    this.order = 0,
    this.deviceCount = 0,
  });

  factory Room.fromJson(Json json) => Room(
    id: '${json['id']}',
    name: '${json['name'] ?? json['id']}',
    order: (json['order'] as num?)?.toInt() ?? 0,
    deviceCount: (json['deviceCount'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String name;
  final int order;
  final int deviceCount;
}

/// A `device.list` or `device.get` row read through typed getters. It is
/// the same map the providers hold, so it costs nothing to wrap one.
extension type DeviceView(Json json) {
  String get id => '${json['id']}';
  String get name => '${json['name'] ?? json['id']}';
  String? get driver => json['driver'] as String?;
  String? get host => json['host'] as String?;
  String? get roomId => json['roomId'] as String?;

  /// The room's display name.
  String? get room => json['room'] as String?;
  bool get favourite => json['favourite'] == true;
  int? get order => (json['order'] as num?)?.toInt();

  /// False only when the engine reported it unreachable.
  bool get online => json['online'] != false;
  String? get offlineReason => json['offlineReason'] as String?;
  Json get state => json['state'] is Map
      ? Map<String, Object?>.from(json['state'] as Map)
      : const {};
  List<Json> get capabilities => [
    for (final c in (json['capabilities'] as List? ?? const []))
      if (c is Map) Map<String, Object?>.from(c),
  ];
  DateTime? get lastSeen => DateTime.tryParse('${json['lastSeen']}');

  /// The first capability of [type] (`toggle`, `level`, ...).
  Json? capabilityOf(String type) =>
      capabilities.where((c) => c['type'] == type).firstOrNull;

  /// Whether a tap on its tile can switch it on and off.
  bool get hasPower => capabilityOf('toggle') != null;

  /// The power state, when it has a toggle with a state key.
  bool? get isOn {
    final key = capabilityOf('toggle')?['stateKey'];
    return key is String ? state[key] == true : null;
  }
}

/// One action of a scene: `{do: "thing.action", params?}`.
class SceneAction {
  const SceneAction(this.action, [this.params = const {}]);

  factory SceneAction.fromJson(Json json) => SceneAction(
    '${json['do']}',
    json['params'] is Map
        ? Map<String, Object?>.from(json['params'] as Map)
        : const {},
  );

  /// `thing.action`: the device id and its capability.
  final String action;
  final Json params;

  Json toJson() => {'do': action, if (params.isNotEmpty) 'params': params};
}

/// A named set of device actions run together, stored as an automation.
class Scene {
  const Scene({
    this.id,
    required this.name,
    this.icon,
    this.color,
    this.actions = const [],
  });

  factory Scene.fromJson(Json json) => Scene(
    id: json['id'] as String?,
    name: '${json['name'] ?? json['id']}',
    icon: json['icon'] as String?,
    color: json['color'] as String?,
    actions: [
      for (final a in (json['actions'] as List? ?? const []))
        if (a is Map) SceneAction.fromJson(Map<String, Object?>.from(a)),
    ],
  );

  /// Null for a scene not saved yet.
  final String? id;
  final String name;

  /// A Material Symbols name the user picked.
  final String? icon;

  /// A `#RRGGBB` from the contract's colour list.
  final String? color;
  final List<SceneAction> actions;

  Json toJson() => {
    'id': ?id,
    'name': name,
    'icon': ?icon,
    'color': ?color,
    'actions': [for (final a in actions) a.toJson()],
  };
}

/// One change in a device's state history.
class HistoryEntry {
  const HistoryEntry({
    required this.at,
    required this.key,
    required this.value,
    this.by,
  });

  factory HistoryEntry.fromJson(Json json) => HistoryEntry(
    at: DateTime.tryParse('${json['at']}')?.toLocal() ?? DateTime(0),
    key: '${json['key']}',
    value: json['value'],
    by: json['by'] as String?,
  );

  final DateTime at;
  final String key;
  final Object? value;

  /// The automation id that made the change, `user`, or null when unknown.
  final String? by;

  bool get byUser => by == 'user';
}

enum PresenceSource { wifi, ble, hub, manual, unknown }

/// Where a person is and what decided it, from the person thing's state.
class Presence {
  const Presence({this.home, this.source = PresenceSource.unknown, this.since});

  factory Presence.of(Json person) {
    final state = person['state'] is Map
        ? Map<String, Object?>.from(person['state'] as Map)
        : person;
    return Presence(
      home: state['home'] is bool ? state['home'] as bool : null,
      source:
          PresenceSource.values
              .where((s) => s.name == state['homeSource'])
              .firstOrNull ??
          PresenceSource.unknown,
      since: DateTime.tryParse('${state['homeSince']}')?.toLocal(),
    );
  }

  /// Null until a source has reported.
  final bool? home;
  final PresenceSource source;
  final DateTime? since;
}

enum SentenceKind {
  when,
  onlyIf,
  then,

  /// A branch or a group (pink).
  flow,

  /// Plain words between the parts ("then", "→").
  text;

  static SentenceKind fromWire(Object? kind) => switch (kind) {
    'when' => when,
    'if' => onlyIf,
    'then' => then,
    'flow' => flow,
    _ => text,
  };
}

/// One part of an automation's sentence: `{kind, text}`.
class SentencePart {
  const SentencePart(this.kind, this.text);

  factory SentencePart.fromJson(Json json) =>
      SentencePart(SentenceKind.fromWire(json['kind']), '${json['text']}');

  final SentenceKind kind;
  final String text;
}

/// The last run of an automation: `{at, ok, steps, run?, outcome?, error?}`.
class LastRun {
  const LastRun({
    required this.at,
    required this.ok,
    this.steps = 0,
    this.error,
    this.run,
    this.outcome,
  });

  factory LastRun.fromJson(Json json) => LastRun(
    at: DateTime.tryParse('${json['at']}')?.toLocal() ?? DateTime(0),
    ok: json['ok'] == true,
    steps: (json['steps'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
    run: json['run'] as String?,
    outcome: json['outcome'] as String?,
  );

  final DateTime at;
  final bool ok;
  final int steps;
  final String? error;

  /// The run's id in the run log.
  final String? run;
  final String? outcome;
}

/// An `automation.list` row.
class AutomationSummary {
  const AutomationSummary({
    required this.id,
    required this.name,
    this.source,
    this.enabled = true,
    this.approved = true,
    this.needsApproval = false,
    this.highRisk = false,
    this.sentence = const [],
    this.lastRun,
    this.devices = const [],
    this.controls = const [],
    this.needsYou = false,
    this.icon,
    this.color,
    this.askFirst = false,
    this.notifyOnRun = false,
    this.manualOnly = false,
    this.revision,
    this.conflicts = const [],
    this.nextRun,
  });

  factory AutomationSummary.fromJson(Json json) => AutomationSummary(
    id: '${json['id']}',
    name: '${json['name'] ?? json['id']}',
    source: EngineCalls.formOf(json),
    enabled: json['enabled'] != false,
    approved: json['approved'] != false,
    needsApproval: json['needsApproval'] == true,
    highRisk: json['highRisk'] == true,
    sentence: [
      for (final p in (json['sentence'] as List? ?? const []))
        if (p is Map) SentencePart.fromJson(Map<String, Object?>.from(p)),
    ],
    lastRun: json['lastRun'] is Map
        ? LastRun.fromJson(Map<String, Object?>.from(json['lastRun'] as Map))
        : null,
    devices: [for (final d in (json['devices'] as List? ?? const [])) '$d'],
    controls: [for (final d in (json['controls'] as List? ?? const [])) '$d'],
    needsYou: json['needsYou'] == true,
    icon: json['icon'] as String?,
    color: json['color'] as String?,
    askFirst: json['askFirst'] == true,
    notifyOnRun: json['notifyOnRun'] == true,
    manualOnly: json['manualOnly'] == true,
    revision: json['revision'] as String?,
    conflicts: [for (final c in (json['conflicts'] as List? ?? const [])) '$c'],
    nextRun: json['nextRun'] is String
        ? DateTime.tryParse(json['nextRun'] as String)
        : null,
  );

  final String id;
  final String name;

  /// `rule`, `link`, `graph` or `scene`.
  final String? source;
  final bool enabled;
  final bool approved;
  final bool needsApproval;
  final bool highRisk;
  final List<SentencePart> sentence;
  final LastRun? lastRun;

  /// The ids of the devices it reads or drives.
  final List<String> devices;

  /// The ids of the devices it drives, a subset of [devices].
  final List<String> controls;

  /// Waiting for approval, or on with a failed last run.
  final bool needsYou;

  /// A rule's icon from the contract's icon list, or a scene's Material
  /// Symbols name.
  final String? icon;

  /// A `#RRGGBB` from the contract's colour list.
  final String? color;

  /// Asks the person before a trigger runs it.
  final bool askFirst;

  /// Says so after a run that completes.
  final bool notifyOnRun;

  /// Its only trigger is manual, so it runs by hand (a Home tile).
  final bool manualOnly;
  final String? revision;

  /// Why it clashes with other automations: each sets a device the other
  /// way on the same trigger. Empty when it clashes with none.
  final List<String> conflicts;

  /// When a time, sun or interval trigger runs it next, from the engine's
  /// schedule. Null when it is off or has no such trigger.
  final DateTime? nextRun;

  bool get isLink => source == 'link';
  bool get isScene => source == 'scene';
}

/// One step of a run in the run log or a dry run.
class RunNode {
  const RunNode({
    required this.node,
    required this.type,
    this.label,
    this.error,
    this.duration,
    this.port,
    this.output,
    this.seen,
  });

  factory RunNode.fromJson(Json json) => RunNode(
    node: '${json['node']}',
    type: '${json['type']}',
    label: json['label'] as String?,
    error: json['error'] as String?,
    duration: json['ms'] is num
        ? Duration(milliseconds: (json['ms'] as num).toInt())
        : null,
    port: json['port'] as String?,
    output: json['output'] is Map
        ? Map<String, Object?>.from(json['output'] as Map)
        : null,
    seen: json['seen'],
  );

  final String node;
  final String type;
  final String? label;
  final String? error;
  final Duration? duration;

  /// The port it left by: `true`/`false` for a condition, `out`, `error`,
  /// or null when it stopped the run there.
  final String? port;

  /// What it passed on. In a dry run an action's `result` says what it
  /// would have sent.
  final Json? output;

  /// The value a condition compared, as the engine's trace keeps it.
  final Object? seen;

  bool get ok => error == null;
}

/// One run from `automation.log`, newest first in the reply.
class RunRecord {
  const RunRecord({
    required this.id,
    required this.automationId,
    required this.outcome,
    required this.startedAt,
    this.trigger,
    this.reason,
    this.finishedAt,
    this.dryRun = false,
    this.steps = const [],
  });

  factory RunRecord.fromJson(Json json) => RunRecord(
    id: '${json['run']}',
    automationId: '${json['flow']}',
    outcome: '${json['outcome']}',
    startedAt:
        DateTime.tryParse('${json['startedAt']}')?.toLocal() ?? DateTime(0),
    trigger: json['trigger'] as String?,
    reason: json['reason'] as String?,
    finishedAt: DateTime.tryParse('${json['finishedAt']}')?.toLocal(),
    dryRun: json['dryRun'] == true,
    steps: [
      for (final n in (json['nodes'] as List? ?? const []))
        if (n is Map) RunNode.fromJson(Map<String, Object?>.from(n)),
    ],
  );

  final String id;
  final String automationId;

  /// `completed`, `failed`, `cancelled` or `dropped`.
  final String outcome;
  final DateTime startedAt;
  final String? trigger;
  final String? reason;
  final DateTime? finishedAt;
  final bool dryRun;
  final List<RunNode> steps;

  bool get ok => outcome == 'completed' && steps.every((s) => s.ok);
  Duration? get duration => finishedAt?.difference(startedAt);
}

/// One value a template asks for: `{key, label, kind, default?}`. Kinds:
/// `person`, `tag`, `sensor` (`thing.key`), `toggle` (`thing.action`),
/// `toggles` (a list of those), `time` (`HH:MM`), `duration` (ms).
class TemplatePlaceholder {
  const TemplatePlaceholder({
    required this.key,
    required this.label,
    required this.kind,
    this.fallback,
  });

  factory TemplatePlaceholder.fromJson(Json json) => TemplatePlaceholder(
    key: '${json['key']}',
    label: '${json['label'] ?? json['key']}',
    kind: '${json['kind']}',
    fallback: json['default'],
  );

  final String key;
  final String label;
  final String kind;
  final Object? fallback;
}

/// A starting point for a new automation, with its [placeholders]. The
/// spec carries `"<key>"` placeholders, which `automation.templates` fills
/// when given the template id and the values.
class AutomationTemplate {
  const AutomationTemplate({
    required this.id,
    required this.name,
    this.description = '',
    this.placeholders = const [],
    this.spec = const {},
    this.category,
    this.icon,
    this.color,
  });

  factory AutomationTemplate.fromJson(Json json) => AutomationTemplate(
    id: '${json['id']}',
    name: '${json['name'] ?? json['id']}',
    description: '${json['description'] ?? ''}',
    category: json['category'] as String?,
    icon: json['icon'] as String?,
    color: json['color'] as String?,
    placeholders: [
      for (final p in (json['placeholders'] as List? ?? const []))
        if (p is Map)
          TemplatePlaceholder.fromJson(Map<String, Object?>.from(p)),
    ],
    spec: json['spec'] is Map
        ? Map<String, Object?>.from(json['spec'] as Map)
        : const {},
  );

  final String id;
  final String name;
  final String description;
  final List<TemplatePlaceholder> placeholders;
  final Json spec;

  /// The gallery group, one of [AutomationTemplate.categories].
  final String? category;

  /// From the contract's icon and colour lists.
  final String? icon;
  final String? color;

  /// The gallery's groups, in the order it shows them.
  static const categories = [
    'Arrive and leave',
    'Morning and night',
    'Watch and listen',
    'Away and safety',
    'Buttons and tags',
  ];

  /// Whether a toggle step flips placeholder [key]. A TV turns on and off
  /// with wake and sleep but cannot be flipped, so it is not offered there.
  bool toggles(String key) {
    bool walk(Object? v) => switch (v) {
      Map m => m['toggle'] == '<$key>' || m.values.any(walk),
      List l => l.any(walk),
      _ => false,
    };
    return walk(spec);
  }
}

/// The rule builders the contract adds: the keep step and stop on error.
abstract final class RuleParts {
  /// Holds [target] (`thing.action`) at [value] while every condition in
  /// [whileConditions] holds, and releases it when they stop.
  static Json keep(String target, Object? value, List<Json> whileConditions) =>
      {
        'keep': {'target': target, 'value': value, 'while': whileConditions},
      };

  /// [rule] set to stop at its first failed step. Without it each step
  /// continues on error and the failure goes to the run log.
  static Json stopOnError(Json rule, [bool stop = true]) =>
      {...rule, if (stop) 'stopOnError': true}
        ..removeWhere((k, _) => !stop && k == 'stopOnError');
}

/// Typed calls for every command the redesign codes to (docs/ui/ui-spec.md,
/// Engine additions), plus the device and automation calls its screens
/// share. A failure never throws: it comes back as [Reply.failure], after
/// [onFailure] (the app's snackbar) has seen it.
class EngineApi {
  const EngineApi(this._client, {this.onFailure});

  final EngineClient _client;
  final void Function(ApiFailure failure)? onFailure;

  Future<Reply<T>> _call<T>(
    String command,
    Json args,
    T Function(Json result) read,
  ) async {
    Json result;
    try {
      result = await _client.call(command, args);
    } on Object {
      return _failed(ApiFailure.unreachable);
    }
    if (result['ok'] != true) return _failed(ApiFailure.of(result));
    return Reply.ok(read(result));
  }

  Reply<T> _failed<T>(ApiFailure failure) {
    onFailure?.call(failure);
    return Reply.failed(failure);
  }

  static List<Json> _rows(Object? list) => [
    for (final r in (list as List? ?? const []))
      if (r is Map) Map<String, Object?>.from(r),
  ];

  static String? _idOf(Json result) =>
      (result['id'] ??
              (result['room'] is Map ? (result['room'] as Map)['id'] : null) ??
              (result['scene'] is Map ? (result['scene'] as Map)['id'] : null))
          as String?;

  // Rooms.

  Future<Reply<List<Room>>> rooms() => _call(
    EngineCalls.roomList,
    const {},
    (r) =>
        [for (final j in _rows(r['rooms'])) Room.fromJson(j)]
          ..sort((a, b) => a.order.compareTo(b.order)),
  );

  /// Creates a room, or renames and moves the one with [id]. Returns its id.
  Future<Reply<String?>> saveRoom({
    String? id,
    required String name,
    int? order,
  }) => _call(EngineCalls.roomSave, {
    'id': ?id,
    'name': name,
    'order': ?order,
  }, _idOf);

  Future<Reply<void>> removeRoom(String id) =>
      _call(EngineCalls.roomRemove, {'id': id}, (_) {});

  /// Puts the rooms in the order of [ids].
  Future<Reply<void>> orderRooms(List<String> ids) =>
      _call(EngineCalls.roomOrder, {'ids': ids}, (_) {});

  // Devices.

  Future<Reply<List<DeviceView>>> devices() => _call(
    EngineCalls.deviceList,
    const {'withCapabilities': true},
    (r) => [for (final j in _rows(r['devices'])) DeviceView(j)],
  );

  Future<Reply<DeviceView>> device(String id) => _call(EngineCalls.deviceGet, {
    'id': id,
  }, (r) => DeviceView(Map<String, Object?>.from(r['device'] as Map? ?? r)));

  /// Runs a capability. The reply is the driver's, as the engine gives it.
  Future<Reply<Json>> invoke(
    String id,
    String capability, [
    Json params = const {},
  ]) => _call(EngineCalls.deviceInvoke, {
    'id': id,
    'capability': capability,
    'params': params,
  }, (r) => r);

  /// Sets the fields given: a new [name], a [room] id (an empty string takes
  /// it out of its room), whether it is a [favourite], and its [order].
  Future<Reply<void>> organizeDevice(
    String id, {
    String? name,
    String? room,
    bool? favourite,
    int? order,
  }) => _call(EngineCalls.deviceOrganize, {
    'id': id,
    'name': ?name,
    'room': ?room,
    'favourite': ?favourite,
    'order': ?order,
  }, (_) {});

  Future<Reply<void>> removeDevice(String id) =>
      _call(EngineCalls.deviceRemove, {'id': id}, (_) {});

  /// Reads the device's state again now, as "Try again" does.
  Future<Reply<DeviceView>> refreshDevice(String id) => _call(
    EngineCalls.deviceRefresh,
    {'id': id},
    (r) => DeviceView(Map<String, Object?>.from(r['device'] as Map? ?? r)),
  );

  /// Adds a driver from its manifest JSON. Returns its id.
  Future<Reply<String?>> registerDriver(Json manifest) =>
      _call(EngineCalls.driverRegister, {'manifest': manifest}, _idOf);

  // The engine and its hub.

  /// `{hubRunning, flows: [ids loaded], loadIssues: [{kind, id, error}]}`.
  Future<Reply<Json>> engineStatus() =>
      _call(EngineCalls.engineStatus, const {}, (r) => r);

  Future<Reply<void>> startHub() =>
      _call(EngineCalls.hubStart, const {}, (_) {});

  Future<Reply<void>> stopHub() => _call(EngineCalls.hubStop, const {}, (_) {});

  // Places and presence.

  /// The places that have inputs: `{id, name, place, inside, wifi?: {ssids,
  /// bssids, required}, ble?: {matchName, ...}}`.
  Future<Reply<List<Json>>> zones() =>
      _call(EngineCalls.zoneList, const {}, (r) => _rows(r['zones']));

  /// Saves [zone] (`{id, name, wifi?, ble?}`) as its place.
  Future<Reply<void>> saveZone(Json zone) =>
      _call(EngineCalls.zoneSave, {'zone': zone}, (_) {});

  /// Says the person is home or away until the next reading decides.
  Future<Reply<void>> setPresence(bool home, {String? person}) =>
      _call(EngineCalls.presenceSet, {'home': home, 'person': ?person}, (_) {});

  /// The newest state changes of [id], newest first: only [key] when given,
  /// at most [limit] (the engine defaults to 100), none before [since].
  Future<Reply<List<HistoryEntry>>> history(
    String id, {
    String? key,
    int? limit,
    DateTime? since,
  }) => _call(EngineCalls.deviceHistory, {
    'id': id,
    'key': ?key,
    'limit': ?limit,
    'since': ?since?.toUtc().toIso8601String(),
  }, (r) => [for (final j in _rows(r['entries'])) HistoryEntry.fromJson(j)]);

  // Scenes.

  Future<Reply<List<Scene>>> scenes() => _call(
    EngineCalls.sceneList,
    const {},
    (r) => [for (final j in _rows(r['scenes'])) Scene.fromJson(j)],
  );

  /// Saves [scene] and returns its id. The app's user wrote it, so it is
  /// trusted: an untrusted save over a trusted scene would unapprove it.
  Future<Reply<String?>> saveScene(Scene scene) =>
      _call(EngineCalls.sceneSave, {...scene.toJson(), 'trusted': true}, _idOf);

  Future<Reply<List<RunRecord>>> runScene(String id) => _call(
    EngineCalls.sceneRun,
    {'id': id},
    (r) => [for (final j in _rows(r['runs'])) RunRecord.fromJson(j)],
  );

  Future<Reply<void>> removeScene(String id) =>
      _call(EngineCalls.sceneRemove, {'id': id}, (_) {});

  // Automations.

  /// Every automation, or those using [device], those a [tag] triggers, or
  /// only those that need the user ([needsYou]: waiting for approval or
  /// failing).
  Future<Reply<List<AutomationSummary>>> automations({
    String? device,
    String? tag,
    bool needsYou = false,
  }) => _call(
    EngineCalls.automationList,
    {'device': ?device, 'tag': ?tag, if (needsYou) 'needsYou': true},
    (r) => [
      for (final j in _rows(r['automations'])) AutomationSummary.fromJson(j),
    ],
  );

  /// `automation.get`: `{id, name, source, spec, flow, enabled, approved,
  /// highRisk, revision}`.
  Future<Reply<Json>> automation(String id) =>
      _call(EngineCalls.automationGet, {'id': id}, (r) => r);

  Future<Reply<void>> enableAutomation(String id, bool enabled) => _call(
    EngineCalls.automationEnable,
    {'id': id, 'enabled': enabled},
    (_) {},
  );

  /// Approves exactly [revision], the one the user reviewed.
  Future<Reply<void>> approveAutomation(String id, String revision) => _call(
    EngineCalls.automationApprove,
    {'id': id, 'revision': revision},
    (_) {},
  );

  /// Runs it now, as Retry does. Returns the runs it started.
  Future<Reply<List<RunRecord>>> runAutomation(String id) => _call(
    EngineCalls.automationRun,
    {'id': id},
    (r) => [for (final j in _rows(r['runs'])) RunRecord.fromJson(j)],
  );

  /// The newest runs of [id] (of every automation without it).
  Future<Reply<List<RunRecord>>> runLog({String? id, int? limit}) => _call(
    EngineCalls.automationLog,
    {'id': ?id, 'limit': ?limit},
    (r) => [for (final j in _rows(r['runs'])) RunRecord.fromJson(j)],
  );

  Future<Reply<void>> removeAutomation(String id) =>
      _call(EngineCalls.automationRemove, {'id': id}, (_) {});

  Future<Reply<List<AutomationTemplate>>> templates() => _call(
    EngineCalls.automationTemplates,
    const {},
    (r) => [
      for (final j in _rows(r['templates'])) AutomationTemplate.fromJson(j),
    ],
  );

  /// The rule template [id] with its placeholders filled from [values].
  Future<Reply<Json>> fillTemplate(String id, Json values) => _call(
    EngineCalls.automationTemplates,
    {'id': id, 'values': values},
    (r) => Map<String, Object?>.from(
      (_rows(r['templates']).firstOrNull?['spec'] as Map?) ?? const {},
    ),
  );

  /// Saves a rule: `{id, approved, highRisk, revision, name}`. See
  /// [EngineCalls.saveRuleArgs] for [trusted] and [replace].
  Future<Reply<Json>> saveRule(
    Json spec, {
    String? id,
    required bool trusted,
    bool replace = false,
  }) => _call(
    EngineCalls.automationSave,
    EngineCalls.saveRuleArgs(spec, id: id, trusted: trusted, replace: replace),
    (r) => r,
  );

  /// A dry run of a rule not saved yet, or of the stored automation [id]
  /// when [rule] is null. Nothing is sent to any device.
  Future<Reply<List<RunRecord>>> dryRun({Json? rule, String? id}) => _call(
    EngineCalls.automationDryRun,
    rule == null ? {'id': id} : EngineCalls.dryRunRuleArgs(rule, id: id),
    (r) => [for (final j in EngineCalls.dryRuns(r)) RunRecord.fromJson(j)],
  );

  /// What a link from the state key [from] (`thing.key`) can do:
  /// `{modes: [...], targets: [{to, modes}]}`.
  Future<Reply<Json>> linkOptions(String from) =>
      _call('link.options', {'from': from}, (r) => r);

  /// Creates a link the user made: `{from, to, mode, above?|below?, set?}`.
  /// Returns `{id, name}`.
  Future<Reply<Json>> createLink(Json link) =>
      _call('link.create', {...link, 'trusted': true}, (r) => r);

  // Tags and commands.

  Future<Reply<List<Json>>> tags() =>
      _call(EngineCalls.tagList, const {}, (r) => _rows(r['tags']));

  /// What the engine makes of a typed line: `{kind: call | ask, command?,
  /// args?, summary}`.
  Future<Reply<Json>> interpret(String text) =>
      _call(EngineCalls.commandInterpret, {'text': text}, (r) => r);

  /// `{id, name, uid?}`: adds the tag or renames it. Returns the tag row.
  /// [forgetCard] unpins the card, so the next card scanned with the
  /// tag's link becomes it.
  Future<Reply<Json>> saveTag(
    String id,
    String name, {
    String? uid,
    bool forgetCard = false,
  }) => _call('tag.save', {
    'id': id,
    'name': name,
    if (forgetCard) 'uid': null else 'uid': ?uid,
  }, (r) => Map<String, Object?>.from(r['tag'] as Map? ?? const {}));

  Future<Reply<void>> removeTag(String id) =>
      _call('tag.remove', {'id': id}, (_) {});

  /// The link and NDEF records to write on a tag for the tag thing [id].
  Future<Reply<({String uri, List<Json> records})?>> tagPayload(String id) =>
      _call(
        EngineCalls.tagWritePayload,
        EngineCalls.tagWritePayloadArgs(id),
        EngineCalls.tagPayloadOf,
      );

  // Boards.

  /// What board [id] offers: its pins, extras and warnings. An offline
  /// board answers with the last describe the engine saw.
  Future<Reply<BoardInfo>> boardDescribe(String id) =>
      _call('board.describe', {'id': id}, BoardInfo.fromJson);

  /// Sets every named pin of board [id] (name to `{pin, mode, invert?}`)
  /// and sets the board up to them.
  Future<Reply<PinsSaved>> saveBoardPins(String id, Json pins) => _call(
    'board.pins',
    {'id': id, 'pins': pins},
    (r) => (
      warnings: BoardInfo.warningsOf(r['warnings']),
      provisionError: r['provisionError'] as String?,
    ),
  );

  /// Binds the extra [type] (`ir`, `rf`, `nfc_rc522`, `nfc_pn532`) to
  /// [pins] on board [id], or takes it off with [clear]. The firmware takes
  /// this over USB only.
  Future<Reply<Json>> setBoardPeriph(
    String id,
    String type, {
    Map<String, int> pins = const {},
    bool clear = false,
    String? port,
  }) => _call('board.periph', {
    if (port != null) 'port': port else 'id': id,
    'type': type,
    if (clear) 'clear': true else 'pins': pins,
  }, (r) => r);

  // Adding things.

  /// Runs every discovery method at once: what was found, by driver, and
  /// the drivers added by hand.
  Future<Reply<AddFind>> discover() =>
      _call(EngineCalls.thingAdd, EngineCalls.discoverArgs, AddFind.fromJson);

  /// Adds a found [candidate] and says what step comes next.
  Future<Reply<Added>> addCandidate(
    Json candidate, {
    String? name,
    String? room,
  }) => _call(
    EngineCalls.thingAdd,
    EngineCalls.addCandidateArgs(candidate, name: name, room: room),
    Added.fromJson,
  );

  /// Adds a device by hand (`device.add`): `{id, name, driver, host?,
  /// room?, settings?}`.
  Future<Reply<Added>> addDevice(Json device) => _call(
    'device.add',
    device,
    (r) => Added.fromJson({'id': device['id'], ...r}),
  );

  /// Where [id]'s setup stands. [paired] reports a pairing that just worked.
  Future<Reply<NextStep>> nextStep(String id, {bool paired = false}) => _call(
    EngineCalls.thingNext,
    EngineCalls.nextArgs(id, paired: paired),
    EngineCalls.nextOf,
  );

  Future<Reply<NextStep>> configureThing(String id, Json settings) => _call(
    EngineCalls.thingConfigure,
    EngineCalls.configureArgs(id, settings),
    EngineCalls.nextOf,
  );

  /// Runs the pairing [id]'s driver needs. `message` says what happened.
  Future<Reply<({bool paired, String? message})>> pairDevice(String id) =>
      _call(
        EngineCalls.devicePair,
        EngineCalls.pairArgs(id),
        (r) => (paired: r['paired'] == true, message: r['message'] as String?),
      );

  Future<Reply<void>> setSecret(String id, String key, String value) => _call(
    EngineCalls.secretSet,
    EngineCalls.secretArgs(id, key, value),
    (_) {},
  );

  /// Stores for [id] the same secret [key] the thing [from] has.
  Future<Reply<void>> copySecret(String id, String key, String from) => _call(
    EngineCalls.secretSet,
    EngineCalls.secretFromArgs(id, key, from),
    (_) {},
  );

  /// What [driver]'s own discovery finds on the network: `{host, port?,
  /// stableId?, knownAs?}` each.
  Future<Reply<List<Json>>> discoverDriver(String driver) =>
      _call('device.discover', {'driver': driver}, (r) => _rows(r['found']));

  /// Every driver: `{id, name, category, transport, board, pairing?,
  /// settings: [{key, label, secret?}]}`.
  Future<Reply<List<Json>>> drivers() =>
      _call('driver.list', const {}, (r) => _rows(r['drivers']));

  /// Stores [value] as the web secret [name], which a web request header
  /// names with `{"secret": name}`. It stays in the secret store.
  Future<Reply<void>> setWebSecret(String name, String value) =>
      _call('web.secret.set', {'name': name, 'value': value}, (_) {});

  /// The automations removed lately that can be put back: `{id, name,
  /// form, removedAt, keptUntil, versions}`, newest first.
  Future<Reply<List<Json>>> removedAutomations() =>
      _call('automation.removed', const {}, (r) => _rows(r['removed']));

  /// Puts the removed automation [id] back, switched off.
  Future<Reply<void>> unremoveAutomation(String id) =>
      _call('automation.unremove', {'id': id}, (_) {});
}

/// One GPIO a board offers and what it can do: `in`, `pullup`, `out`,
/// `pwm`, `servo`, `adc`.
typedef BoardGpio = ({int pin, Set<String> caps});

/// An extra set on a board and the GPIO each of its lines takes (`tx`, or
/// `ss`, `rst`, `sck`, `miso`, `mosi` for an RC522).
typedef BoardPeriph = ({String type, Map<String, int> pins});

/// What a `board.pins` save reports: boot pin warnings, and why the board
/// could not be set up now when it is offline.
typedef PinsSaved = ({List<String> warnings, String? provisionError});

/// A `board.describe` reply.
class BoardInfo {
  const BoardInfo({
    this.live = true,
    this.seenAt,
    this.board,
    this.firmware,
    this.node,
    this.gpios = const [],
    this.periph = const [],
    this.periphTypes = const [],
    this.warnings = const [],
    this.bootPins = const {},
  });

  factory BoardInfo.fromJson(Json r) {
    final d = r['describe'] is Map
        ? Map<String, Object?>.from(r['describe'] as Map)
        : const <String, Object?>{};
    final gpios = <BoardGpio>[];
    final boot = <int>{
      for (final p in [
        ...(r['bootPins'] as List? ?? const []),
        ...(d['bootPins'] as List? ?? const []),
      ])
        if (p is int) p,
    };
    for (final p in (d['pins'] as List? ?? const [])) {
      if (p case {'pin': final int pin, 'caps': final List caps}) {
        gpios.add((pin: pin, caps: {for (final c in caps) '$c'}));
        if (p['boot'] == true || p['strapping'] == true) boot.add(pin);
      }
    }
    return BoardInfo(
      live: r['live'] != false,
      seenAt: DateTime.tryParse('${r['seenAt']}')?.toLocal(),
      board: d['board'] as String?,
      firmware: d['fw']?.toString(),
      node: d['node'] as String?,
      gpios: gpios,
      periph: [
        for (final p in (d['periph'] as List? ?? const []))
          if (p case {'type': final String type, 'pins': final Map pins})
            (
              type: type,
              pins: {
                for (final e in pins.entries)
                  if (e.value is int) '${e.key}': e.value as int,
              },
            ),
      ],
      periphTypes: [
        for (final t in (d['periphTypes'] as List? ?? const []))
          if (t is String) t,
      ],
      warnings: warningsOf(r['warnings']),
      bootPins: boot,
    );
  }

  /// False when the board did not answer and this is the last describe the
  /// engine saw, at [seenAt].
  final bool live;
  final DateTime? seenAt;

  /// The board type as the firmware names it (`esp32`, `esp8266`).
  final String? board;
  final String? firmware;

  /// The node name the board announces itself by.
  final String? node;
  final List<BoardGpio> gpios;
  final List<BoardPeriph> periph;

  /// The extras this firmware build knows.
  final List<String> periphTypes;
  final List<String> warnings;

  /// GPIOs that decide how the board starts. Only an engine that reports
  /// them (`bootPins`, or `boot` on a pin) fills this.
  final Set<int> bootPins;

  static List<String> warningsOf(Object? list) => [
    for (final w in (list as List? ?? const []))
      switch (w) {
        {'pin': final pin, 'message': final message} => 'GPIO $pin: $message',
        {'message': final message} => '$message',
        _ => '$w',
      },
  ];
}

/// One thing a discovery found: its driver's name and category, and the
/// candidate to hand back to `thing.add` as it came.
typedef FoundThing = ({String driverName, String? category, Json candidate});

/// A `thing.add` find.
class AddFind {
  const AddFind({
    this.found = const [],
    this.manual = const [],
    this.methods = const [],
  });

  factory AddFind.fromJson(Json r) => AddFind(
    found: [
      for (final g in (r['groups'] as List? ?? const []))
        if (g is Map)
          for (final c in (g['candidates'] as List? ?? const []))
            if (c is Map)
              (
                driverName: '${g['name'] ?? g['driver'] ?? ''}',
                category: g['category'] as String?,
                candidate: Map<String, Object?>.from(c),
              ),
    ],
    manual: EngineCalls.manualOf(r),
    methods: [
      for (final m in (r['methods'] as List? ?? const []))
        if (m is String) m,
    ],
  );

  final List<FoundThing> found;

  /// Drivers no method finds, `{driver, name, category, virtual?}`.
  final List<Json> manual;

  /// The methods that ran.
  final List<String> methods;
}

/// What adding a thing returned: its id and the step that comes next.
class Added {
  const Added({
    this.id,
    this.next = const NextStep(NextKind.done),
    this.provisionError,
  });

  factory Added.fromJson(Json r) => Added(
    id: EngineCalls.thingIdOf(r),
    next: EngineCalls.nextOf(r),
    provisionError: r['provisionError'] as String?,
  );

  final String? id;
  final NextStep next;

  /// Why a board could not be set up now (it is offline).
  final String? provisionError;
}

/// The `home.stats` command and the events that move its numbers.
abstract final class HomeStatsCalls {
  static const homeStats = 'home.stats';
  static const achievementEarnedEvent = 'home.achievementEarned';

  /// Ends a run, so the numbers move.
  static const runFinishedEvent = 'run.finished';
}
