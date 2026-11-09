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
    );
  }

  final NextKind kind;
  final String? instruction;
  final List<StepKey> keys;

  /// On a done step, the optional settings and secrets still open.
  final List<StepKey> optional;

  /// A configure step for a board's pins, which the pin sheet sets.
  bool get isPins =>
      kind == NextKind.configure && keys.any((k) => k.key == 'pins');
}
