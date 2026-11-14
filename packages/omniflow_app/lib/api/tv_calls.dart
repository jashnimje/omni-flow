import 'dart:ui' show Offset;

import 'engine_calls.dart' show Json;

/// Every `tv.*` call the TV control centre makes, with its argument shapes
/// and the fields read back from its results. When the engine's shape
/// changes, the change is made here and nowhere else.
abstract final class TvCalls {
  static const driver = 'android_tv_adb';

  /// Another Android phone over ADB. It takes every `tv.*` call too, which
  /// the engine also answers under its `android.*` name.
  static const phoneDriver = 'android_phone_adb';

  /// Opens or closes a phone's notification shade.
  static const notifications = 'tv.notifications';

  /// Phones with Wireless debugging on, found on mDNS.
  static const find = 'android.find';

  /// Pairs with a phone's six-digit Wireless debugging code. User only.
  static const pair = 'android.pair';

  static const state = 'tv.state';
  static const keys = 'tv.keys';
  static const key = 'tv.key';
  static const text = 'tv.text';
  static const volume = 'tv.volume';
  static const apps = 'tv.apps';
  static const app = 'tv.app';
  static const install = 'tv.install';
  static const settingsCatalog = 'tv.settings.catalog';
  static const settingsList = 'tv.settings.list';
  static const settingsGet = 'tv.settings.get';
  static const settingsPut = 'tv.settings.put';
  static const settingsDelete = 'tv.settings.delete';
  static const filesList = 'tv.files.list';
  static const filesStat = 'tv.files.stat';
  static const filesDownload = 'tv.files.download';
  static const filesUpload = 'tv.files.upload';
  static const filesCopy = 'tv.files.copy';
  static const filesMove = 'tv.files.move';
  static const filesDelete = 'tv.files.delete';
  static const filesMkdir = 'tv.files.mkdir';
  static const filesRename = 'tv.files.rename';
  static const shell = 'tv.shell';
  static const screenshot = 'tv.screenshot';
  static const tap = 'tv.input.tap';
  static const swipe = 'tv.input.swipe';
  static const recordStart = 'tv.record.start';
  static const recordStop = 'tv.record.stop';
  static const recordStatus = 'tv.record.status';
  static const system = 'tv.system';
  static const processes = 'tv.processes';
  static const appPermissions = 'tv.app.permissions';
  static const appPermission = 'tv.app.permission';
  static const appBackup = 'tv.app.backup';
  static const cacheTrim = 'tv.cache.trim';
  static const power = 'tv.power';

  /// Raised while a transfer or install runs: `{id, op, done, total}`.
  static const progressEvent = 'tv.progress';

  /// Commands that move whole files, which can run far longer than the
  /// service link's usual call timeout.
  static const longRunning = {
    TvPointerCalls.install,
    install,
    filesDownload,
    filesUpload,
    filesCopy,
    filesMove,
    filesDelete,
    shell,
    appBackup,
    recordStop,
  };

  static const maxText = 500;
  static const maxRepeat = 20;

  static bool isTv(Json device) => device['driver'] == driver;

  static bool isPhone(Json device) => device['driver'] == phoneDriver;

  /// Whether [device] gets the Android device page: a TV or a phone.
  static bool isAndroid(Json device) => isTv(device) || isPhone(device);

  static Json notificationsArgs(String id, {String action = 'expand'}) => {
    'id': id,
    'action': action,
  };

  static Json findArgs({int windowMs = 3000}) => {'windowMs': windowMs};

  static List<FoundPhone> phonesOf(Json result) => [
    for (final p in result['phones'] as List? ?? const [])
      if (p is Map) FoundPhone.fromJson(Map<String, Object?>.from(p)),
  ];

  /// The six-digit code only ever travels in this call.
  static Json pairArgs(String host, int port, String code) => {
    'host': host,
    'port': port,
    'code': code,
  };

  /// `thing.add` for a phone at [host] and [port]. A phone paired with a
  /// code carries its [guid] as its stable id, so the engine can follow it
  /// to a new connect port. The engine switches to TLS when the phone asks.
  static Json addPhoneArgs({
    required String host,
    required int port,
    String? guid,
    String? name,
  }) => {
    'driver': phoneDriver,
    'host': host,
    'port': port,
    'name': ?name,
    'stableId': ?guid,
  };

  /// The engine has no such command yet: it needs an update.
  static bool isMissingCommand(Json result) =>
      (result['error'] as Map?)?['type'] == 'unknown_command';

  /// A phone paired with a Wireless debugging code: its stable id is the
  /// guid `android.pair` returned, `adb-<serial>-<six letters>`.
  static bool pairsWithCode(Json device) =>
      isPhone(device) && _tlsGuid.hasMatch('${device['stableId'] ?? ''}');

  static final _tlsGuid = RegExp(r'^adb-[A-Za-z0-9]+-[A-Za-z0-9]{6}$');

  static Json idArgs(String id) => {'id': id};

  /// For a read the app makes on its own (a refresh, a live picture): a TV
  /// that has not let OmniFlow in answers needs_user instead of showing its
  /// Allow prompt, which only the user's own Pair should raise.
  static Json readArgs(String id) => {'id': id, 'allowPairing': false};

  static TvState stateOf(Json result) => TvState.fromJson(result);

  static List<TvKeyGroup> keyGroupsOf(Json result) => [
    for (final g in (result['groups'] as List? ?? const []))
      if (g is Map) TvKeyGroup.fromJson(Map<String, Object?>.from(g)),
  ];

  /// A key by its catalog name when the catalog has one, else by keycode.
  static Json keyArgs(
    String id, {
    String? name,
    int? keycode,
    bool longPress = false,
    int repeat = 1,
  }) => {
    'id': id,
    if (name != null) 'key': name else 'keycode': keycode,
    if (longPress) 'longPress': true,
    if (repeat > 1) 'repeat': repeat.clamp(2, maxRepeat),
  };

  /// A tap at [x], [y] as fractions of the screen, 0 to 1.
  static Json tapArgs(String id, double x, double y) => {
    'id': id,
    'x': x.clamp(0.0, 1.0),
    'y': y.clamp(0.0, 1.0),
  };

  static Json swipeArgs(String id, Offset from, Offset to, {int ms = 300}) => {
    'id': id,
    'x1': from.dx.clamp(0.0, 1.0),
    'y1': from.dy.clamp(0.0, 1.0),
    'x2': to.dx.clamp(0.0, 1.0),
    'y2': to.dy.clamp(0.0, 1.0),
    'ms': ms.clamp(50, 5000),
  };

  static Json recordArgs(String id, int seconds) => {
    'id': id,
    'seconds': seconds.clamp(1, 180),
  };

  static Json permissionArgs(
    String id,
    String package,
    String permission, {
    required bool grant,
  }) => {
    'id': id,
    'package': package,
    'permission': permission,
    'grant': grant,
  };

  static Json backupArgs(String id, String package, String to) => {
    'id': id,
    'package': package,
    'to': to,
  };

  static Json powerArgs(String id, TvPower action) => {
    'id': id,
    'action': action.wire,
  };

  static Json textArgs(String id, String text) => {
    'id': id,
    'text': text.length > maxText ? text.substring(0, maxText) : text,
  };

  static Json volumeArgs(String id, int level) => {'id': id, 'level': level};

  static Json appsArgs(String id, AppFilter filter) => {
    'id': id,
    'filter': filter.name,
  };

  static List<TvApp> appsOf(Json result) => [
    for (final a in (result['apps'] as List? ?? const []))
      if (a is Map && a['package'] is String)
        TvApp.fromJson(Map<String, Object?>.from(a)),
  ];

  static Json appArgs(String id, String package, AppAction action) => {
    'id': id,
    'package': package,
    'action': action.wire,
  };

  static Json installArgs(String id, String path) => {
    'id': id,
    'path': path,
    'replace': true,
  };

  static List<TvSettingCategory> catalogOf(Json result) => [
    for (final c in (result['categories'] as List? ?? const []))
      if (c is Map) TvSettingCategory.fromJson(Map<String, Object?>.from(c)),
  ];

  static Json settingsListArgs(String id, String namespace) => {
    'id': id,
    'namespace': namespace,
  };

  static List<TvRawSetting> settingsOf(Json result) => [
    for (final s in (result['settings'] as List? ?? const []))
      if (s is Map && s['key'] is String)
        (
          namespace: '${s['namespace'] ?? ''}',
          key: s['key'] as String,
          value: s['value'] == null ? null : '${s['value']}',
        ),
  ];

  static Json settingArgs(String id, String namespace, String key) => {
    'id': id,
    'namespace': namespace,
    'key': key,
  };

  static Json settingPutArgs(
    String id,
    String namespace,
    String key,
    Object? value,
  ) => {'id': id, 'namespace': namespace, 'key': key, 'value': value};

  static Json pathArgs(String id, String path) => {'id': id, 'path': path};

  static TvListing listingOf(Json result) => TvListing.fromJson(result);

  /// The engine answers `conflict` for a target that exists unless
  /// [overwrite] is set, so the user is asked before anything is replaced.
  static Json downloadArgs(
    String id,
    String path,
    String to, {
    bool overwrite = false,
  }) => {'id': id, 'path': path, 'to': to, if (overwrite) 'overwrite': true};

  static Json uploadArgs(
    String id,
    String from,
    String path, {
    bool overwrite = false,
  }) => {
    'id': id,
    'from': from,
    'path': path,
    if (overwrite) 'overwrite': true,
  };

  static bool isConflict(Json result) =>
      (result['error'] as Map?)?['type'] == 'conflict';

  static Json fromToArgs(String id, String from, String to) => {
    'id': id,
    'from': from,
    'to': to,
  };

  static Json deleteArgs(String id, List<String> paths, {required bool dirs}) =>
      {'id': id, 'paths': paths, if (dirs) 'recursive': true};

  static Json renameArgs(String id, String path, String name) => {
    'id': id,
    'path': path,
    'name': name,
  };

  /// [cwd] is the folder the previous command ended in, so `cd` carries
  /// over between commands.
  static Json shellArgs(String id, String command, {String? cwd}) => {
    'id': id,
    'command': command,
    'cwd': ?cwd,
  };

  static ({String output, int? exitCode, String? cwd}) shellOf(Json result) => (
    output: '${result['output'] ?? ''}',
    exitCode: (result['exitCode'] as num?)?.toInt(),
    cwd: result['cwd'] as String?,
  );

  /// The details `tv.app` with action info returns under `app`.
  static Json appInfoOf(Json result) => result['app'] is Map
      ? Map<String, Object?>.from(result['app'] as Map)
      : {
          for (final e in result.entries)
            if (e.key != 'ok' && e.key != 'id') e.key: e.value,
        };

  /// The value a `tv.settings.put` stored, typed when the setting is in the
  /// catalog, else as the raw text the TV read back.
  static Object? putValueOf(Json result, Object? sent) {
    final setting = result['setting'];
    if (setting is Map && setting['value'] != null) return setting['value'];
    return result['value'] ?? sent;
  }

  /// The progress in a `tv.progress` event for [id], or null for another
  /// TV or another event.
  static TvProgress? progressOf(Json event, String id) {
    if (event['event'] != progressEvent) return null;
    final body = event['progress'] is Map
        ? Map<String, Object?>.from(event['progress'] as Map)
        : event;
    if ((body['id'] ?? event['id'] ?? event['device']) != id) return null;
    return (
      op: '${body['op'] ?? ''}',
      done: (body['done'] as num? ?? 0).toInt(),
      total: (body['total'] as num?)?.toInt(),
    );
  }
}

enum AppFilter { user, system, all }

enum AppAction {
  open('open'),
  stop('stop'),
  clearCache('clear_cache'),
  clearData('clear_data'),
  disable('disable'),
  enable('enable'),
  uninstall('uninstall'),
  info('info');

  const AppAction(this.wire);

  final String wire;
}

typedef TvProgress = ({String op, int done, int? total});

typedef TvRawSetting = ({String namespace, String key, String? value});

/// What `tv.state` reports. Every field is optional, since a sleeping TV
/// answers only some of them.
class TvState {
  const TvState({
    this.power,
    this.app,
    this.activity,
    this.playing,
    this.volume,
    this.volumeMax = 100,
    this.muted,
  });

  factory TvState.fromJson(Json json) {
    final source = json['state'] is Map
        ? Map<String, Object?>.from(json['state'] as Map)
        : json;
    return TvState(
      power: source['power'] as String?,
      app: source['app'] as String?,
      activity: source['activity'] as String?,
      playing: source['playing'] as String?,
      volume: (source['volume'] as num?)?.toInt(),
      volumeMax: (source['volumeMax'] as num?)?.toInt() ?? 100,
      muted: source['muted'] as bool?,
    );
  }

  /// The hub copies power, app, playing and volume into the device state.
  factory TvState.ofDevice(Json device) => TvState.fromJson(
    Map<String, Object?>.from(device['state'] as Map? ?? {}),
  );

  final String? power;
  final String? app;
  final String? activity;
  final String? playing;
  final int? volume;
  final int volumeMax;
  final bool? muted;

  bool get isOn => power == 'on';
}

class TvKey {
  const TvKey({required this.key, required this.label, this.keycode});

  factory TvKey.fromJson(Json json) => TvKey(
    key: '${json['key']}',
    label: '${json['label'] ?? json['key']}',
    keycode: (json['keycode'] as num?)?.toInt(),
  );

  final String key;
  final String label;
  final int? keycode;
}

class TvKeyGroup {
  const TvKeyGroup(this.group, this.keys);

  factory TvKeyGroup.fromJson(Json json) => TvKeyGroup('${json['group']}', [
    for (final k in (json['keys'] as List? ?? const []))
      if (k is Map && k['key'] != null)
        TvKey.fromJson(Map<String, Object?>.from(k)),
  ]);

  final String group;
  final List<TvKey> keys;
}

class TvApp {
  const TvApp({
    required this.package,
    this.label,
    this.versionName,
    this.versionCode,
    this.system = false,
    this.enabled = true,
    this.launchable = false,
    this.sizeBytes,
  });

  factory TvApp.fromJson(Json json) => TvApp(
    package: json['package'] as String,
    label: json['label'] as String?,
    versionName: json['versionName']?.toString(),
    versionCode: json['versionCode']?.toString(),
    system: json['system'] == true,
    enabled: json['enabled'] != false,
    launchable: json['launchable'] == true,
    sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
  );

  final String package;
  final String? label;
  final String? versionName;
  final String? versionCode;
  final bool system;
  final bool enabled;
  final bool launchable;
  final int? sizeBytes;

  String get name => (label == null || label!.isEmpty) ? package : label!;
}

class TvSettingCategory {
  const TvSettingCategory(this.category, this.settings);

  factory TvSettingCategory.fromJson(Json json) =>
      TvSettingCategory('${json['category']}', [
        for (final s in (json['settings'] as List? ?? const []))
          if (s is Map && s['key'] is String)
            TvSetting.fromJson(Map<String, Object?>.from(s)),
      ]);

  final String category;
  final List<TvSetting> settings;
}

typedef TvOption = ({String value, String label});

/// One curated setting. [value] is as the TV stores it, usually a string.
class TvSetting {
  const TvSetting({
    required this.namespace,
    required this.key,
    required this.label,
    required this.type,
    this.min,
    this.max,
    this.step,
    this.options = const [],
    this.unit,
    this.description,
    this.value,
  });

  factory TvSetting.fromJson(Json json) => TvSetting(
    namespace: '${json['namespace']}',
    key: json['key'] as String,
    label: '${json['label'] ?? json['key']}',
    type: '${json['type'] ?? 'string'}',
    min: json['min'] as num?,
    max: json['max'] as num?,
    step: json['step'] as num?,
    options: [
      for (final o in (json['options'] as List? ?? const []))
        if (o is Map)
          (value: '${o['value']}', label: '${o['label'] ?? o['value']}')
        else
          (value: '$o', label: '$o'),
    ],
    unit: json['unit'] as String?,
    description: json['description'] as String?,
    value: json['value'],
  );

  final String namespace;
  final String key;
  final String label;
  final String type;
  final num? min;
  final num? max;
  final num? step;
  final List<TvOption> options;
  final String? unit;
  final String? description;
  final Object? value;

  bool get boolValue => switch (value) {
    final bool b => b,
    final num n => n != 0,
    final String s => s == '1' || s.toLowerCase() == 'true',
    _ => false,
  };

  num? get numValue => switch (value) {
    final num n => n,
    final String s => num.tryParse(s),
    _ => null,
  };

  String get textValue => value == null ? '' : '$value';

  TvSetting withValue(Object? value) => TvSetting(
    namespace: namespace,
    key: key,
    label: label,
    type: type,
    min: min,
    max: max,
    step: step,
    options: options,
    unit: unit,
    description: description,
    value: value,
  );
}

class TvFileEntry {
  const TvFileEntry({
    required this.name,
    required this.type,
    this.size,
    this.mode,
    this.modified,
  });

  factory TvFileEntry.fromJson(Json json) => TvFileEntry(
    name: '${json['name']}',
    type: '${json['type'] ?? 'file'}',
    size: (json['size'] as num?)?.toInt(),
    mode: json['mode']?.toString(),
    modified: _time(json['modified']),
  );

  /// Seconds or milliseconds since the epoch, or an ISO 8601 string.
  static DateTime? _time(Object? value) => switch (value) {
    final num n when n > 100000000000 => DateTime.fromMillisecondsSinceEpoch(
      n.toInt(),
    ),
    final num n => DateTime.fromMillisecondsSinceEpoch(n.toInt() * 1000),
    final String s => DateTime.tryParse(s),
    _ => null,
  };

  final String name;
  final String type;
  final int? size;
  final String? mode;
  final DateTime? modified;

  bool get isDir => type == 'dir';
}

class TvListing {
  const TvListing(this.path, this.entries);

  factory TvListing.fromJson(Json json) => TvListing('${json['path'] ?? ''}', [
    for (final e in (json['entries'] as List? ?? const []))
      if (e is Map && e['name'] != null)
        TvFileEntry.fromJson(Map<String, Object?>.from(e)),
  ]);

  final String path;
  final List<TvFileEntry> entries;
}

enum TvPower {
  reboot('reboot'),
  shutdown('shutdown');

  const TvPower(this.wire);

  final String wire;
}

/// `tv.system`: how hard the TV works and how full it is.
class TvSystem {
  const TvSystem({
    this.cpuPercent,
    this.memoryTotalKb,
    this.memoryAvailableKb,
    this.storage = const [],
    this.rxBytes,
    this.txBytes,
    this.uptimeSeconds,
    this.temperatureC,
  });

  factory TvSystem.fromJson(Json json) {
    num? n(Object? v) => v is num ? v : null;
    final cpu = json['cpu'] is Map ? json['cpu'] as Map : const {};
    final memory = json['memory'] is Map ? json['memory'] as Map : const {};
    final network = json['network'] is Map ? json['network'] as Map : const {};
    return TvSystem(
      cpuPercent: n(cpu['percent'])?.toDouble(),
      memoryTotalKb: n(memory['totalKb'])?.toInt(),
      memoryAvailableKb: n(memory['availableKb'])?.toInt(),
      storage: [
        for (final s in (json['storage'] as List? ?? const []))
          if (s is Map)
            (
              mount: '${s['mount']}',
              sizeKb: n(s['sizeKb'])?.toInt() ?? 0,
              usedKb: n(s['usedKb'])?.toInt() ?? 0,
            ),
      ],
      rxBytes: n(network['rxBytes'])?.toInt(),
      txBytes: n(network['txBytes'])?.toInt(),
      uptimeSeconds: n(json['uptimeSeconds'])?.toInt(),
      temperatureC: n(json['temperatureC'])?.toDouble(),
    );
  }

  final double? cpuPercent;
  final int? memoryTotalKb;
  final int? memoryAvailableKb;
  final List<({String mount, int sizeKb, int usedKb})> storage;
  final int? rxBytes;
  final int? txBytes;
  final int? uptimeSeconds;
  final double? temperatureC;
}

/// One running app from `tv.processes`.
typedef TvProcess = ({String package, int pid, int memoryKb, bool foreground});

List<TvProcess> processesOf(Json result) => [
  for (final a in (result['apps'] as List? ?? const []))
    if (a is Map && a['package'] is String)
      (
        package: a['package'] as String,
        pid: (a['pid'] as num?)?.toInt() ?? 0,
        memoryKb: (a['memoryKb'] as num?)?.toInt() ?? 0,
        foreground: a['foreground'] == true,
      ),
];

/// One permission from `tv.app.permissions`.
typedef TvPermission = ({String name, bool granted, bool runtime});

List<TvPermission> permissionsOf(Json result) => [
  for (final p in (result['permissions'] as List? ?? const []))
    if (p is Map && p['name'] is String)
      (
        name: p['name'] as String,
        granted: p['granted'] == true,
        runtime: p['runtime'] == true,
      ),
];

/// The pointer helper's calls, with their argument shapes.
abstract final class TvPointerCalls {
  static const status = 'tv.helper.status';
  static const install = 'tv.helper.install';
  static const pointer = 'tv.pointer';
  static const click = 'tv.pointer.click';

  /// The helper APK the app carries, built by tool/tv_helper_asset.dart.
  static const asset = 'assets/tv_helper/omniflow-tv-helper.apk';

  static Json byArgs(String id, Offset by) => {
    'id': id,
    'by': [by.dx.clamp(-1.0, 1.0), by.dy.clamp(-1.0, 1.0)],
  };

  static Json installArgs(String id, String path) => {'id': id, 'path': path};

  static bool isRunning(Json status) =>
      status['ok'] == true && status['running'] == true;
}

/// A phone `android.find` saw on mDNS. [pairingPort] is there only while
/// "Pair device with pairing code" is open on it.
class FoundPhone {
  const FoundPhone({
    required this.name,
    required this.host,
    this.guid,
    this.pairingPort,
    this.connectPort,
    this.knownAs,
  });

  factory FoundPhone.fromJson(Json json) => FoundPhone(
    name: '${json['name'] ?? json['host']}',
    host: '${json['host']}',
    guid: json['guid'] as String?,
    pairingPort: (json['pairingPort'] as num?)?.toInt(),
    connectPort: (json['connectPort'] as num?)?.toInt(),
    knownAs: json['knownAs'] as String?,
  );

  final String name;
  final String host;
  final String? guid;
  final int? pairingPort;
  final int? connectPort;

  /// The thing it already is, when it was added before.
  final String? knownAs;
}
