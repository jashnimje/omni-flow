import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'android_names.dart';
import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'stored_flows.dart';
import '../devices/adb/adb_channel.dart' show adbTlsGuidPattern;
import '../devices/adb/adb_commands.dart';
import '../devices/adb/adb_sync.dart';
import '../devices/adb/tv_keys.dart';
import '../devices/adb/tv_parsers.dart';
import '../devices/adb/tv_settings.dart';
import '../devices/adb/tv_system.dart';
import '../devices/channels.dart' show CommandFailedException;
import '../devices/device.dart';
import '../devices/board.dart' show manifestFor;
import '../devices/discovery/mdns_discovery.dart'
    show AdbWirelessFind, browseAdbWireless;
import '../manifest/driver_manifest.dart';
import '../storage/database.dart' show DriftDeviceStore;
import '../transports/udp_transport.dart' show TransportTimeoutException;

/// The state keys the hub keeps for a TV, so rules can start on them.
const tvStateKeys = ['power', 'app', 'playing', 'volume'];

/// What the hub keeps for a phone: its screen too, `on` or `off`.
const androidPhoneStateKeys = [...tvStateKeys, 'screen'];

/// An ADB device whose driver is in the phone category, such as
/// `android_phone_adb`, rather than a TV.
bool isAndroidPhone(DriverManifest manifest) =>
    manifest.transport.type == TransportType.adb &&
    manifest.category == 'phone';

/// The remote keys a phone has, by group, with the label a phone uses. A
/// phone answers `invalid` for TV-only keys such as HDMI inputs, channels or
/// the d-pad, and still takes any key code.
const androidPhoneKeyGroups = <({String group, List<(String, String)> keys})>[
  (
    group: 'power',
    keys: [('power', 'Power'), ('sleep', 'Lock'), ('wakeup', 'Wake')],
  ),
  (
    group: 'navigation',
    keys: [
      ('back', 'Back'),
      ('home', 'Home'),
      ('app_switch', 'Recents'),
      ('enter', 'Enter'),
      ('delete', 'Delete'),
      ('tab', 'Tab'),
    ],
  ),
  (
    group: 'volume',
    keys: [
      ('volume_up', 'Volume up'),
      ('volume_down', 'Volume down'),
      ('mute', 'Mute'),
    ],
  ),
  (
    group: 'media',
    keys: [
      ('play_pause', 'Play or pause'),
      ('play', 'Play'),
      ('pause', 'Pause'),
      ('stop', 'Stop'),
      ('next', 'Next'),
      ('previous', 'Previous'),
      ('rewind', 'Rewind'),
      ('fast_forward', 'Fast forward'),
    ],
  ),
  (
    group: 'numbers',
    keys: [
      ('0', '0'),
      ('1', '1'),
      ('2', '2'),
      ('3', '3'),
      ('4', '4'),
      ('5', '5'),
      ('6', '6'),
      ('7', '7'),
      ('8', '8'),
      ('9', '9'),
      ('star', '*'),
      ('pound', '#'),
    ],
  ),
  (
    group: 'system',
    keys: [
      ('notification', 'Notifications'),
      ('search', 'Search'),
      ('assistant', 'Assistant'),
      ('settings', 'Settings'),
      ('brightness_up', 'Brightness up'),
      ('brightness_down', 'Brightness down'),
    ],
  ),
];

final _phoneKeyNames = {
  for (final g in androidPhoneKeyGroups)
    for (final k in g.keys) k.$1,
};

/// The settings categories that only a TV has.
const _tvOnlySettingCategories = {'HDMI-CEC'};

const _maxPath = adbSyncMaxPath;
const _maxShellTimeout = Duration(minutes: 10);
const _installTimeout = Duration(minutes: 5);
const _progressEvery = Duration(milliseconds: 250);

/// How often one TV may be looked for at a new address, so a TV that is
/// off is not searched for on every poll.
const _healEvery = Duration(minutes: 1);

final _serialPattern = RegExp(r'^[A-Za-z0-9]{4,64}$');

/// The `tv.*` commands: remote keys, text and volume, apps, settings, files
/// and the shell on any device whose driver speaks ADB. Every command line
/// is built from validated, quoted values, except `tv.shell`, which runs
/// what the user typed.
class TvCommands {
  TvCommands(this._core, this._stored);

  final EngineCore _core;
  final StoredFlows _stored;
  final _random = Random.secure();
  final _lastHeal = <String, DateTime>{};
  final _askedSerial = <String>{};

  /// The screen size `input` works in, kept on the ADB connection it was
  /// read on, so a TV whose display mode changed is read again after it
  /// reconnects.
  final _screenSizes = Expando<(int, int)>();
  final _recordings = <String, ({String file, DateTime startedAt})>{};

  /// Every command under its `tv.*` name and its `android.*` one.
  Map<String, CommandHandler> get commands => withAndroidNames({
    'tv.state': state,
    'tv.keys': keys,
    'tv.key': key,
    'tv.text': text,
    'tv.volume': volume,
    'tv.apps': apps,
    'tv.app': app,
    'tv.install': install,
    'tv.settings.catalog': settingsCatalog,
    'tv.settings.list': settingsList,
    'tv.settings.get': settingsGet,
    'tv.settings.put': settingsPut,
    'tv.settings.delete': settingsDelete,
    'tv.files.list': filesList,
    'tv.files.stat': filesStat,
    'tv.files.download': filesDownload,
    'tv.files.upload': filesUpload,
    'tv.files.copy': (args) => _copyOrMove(args, move: false),
    'tv.files.move': (args) => _copyOrMove(args, move: true),
    'tv.files.delete': filesDelete,
    'tv.files.mkdir': filesMkdir,
    'tv.files.rename': filesRename,
    'tv.shell': shell,
    'tv.capabilityRisk': capabilityRisk,
    'tv.screenshot': screenshot,
    'tv.input.tap': tap,
    'tv.input.swipe': swipe,
    'tv.record.start': recordStart,
    'tv.record.stop': recordStop,
    'tv.record.status': recordStatus,
    'tv.system': system,
    'tv.processes': processes,
    'tv.app.permissions': appPermissions,
    'tv.app.permission': appPermission,
    'tv.app.backup': appBackup,
    'tv.cache.trim': cacheTrim,
    'tv.power': power,
    'tv.notifications': notifications,
    'android.find': find,
  });

  // Devices ------------------------------------------------------------

  Future<_Tv> _tv(Map<String, Object?> args) async {
    final device = await _core.device(stringArg(args, 'id'));
    final manifest = manifestFor(_core.registry, device);
    if (manifest == null || manifest.transport.type != TransportType.adb) {
      throw ApiError(
        'invalid',
        '${device.id} is not an Android TV or phone over ADB',
      );
    }
    // Only a user at the TV can allow a new key, so an agent or a poll
    // passes allowPairing false and gets needs_user instead of a prompt.
    return _Tv(device, manifest, offerKey: args['allowPairing'] != false);
  }

  /// Runs [op], and when the TV does not answer at its address, looks for
  /// it by its mDNS instance (its stable id) and runs [op] once more there.
  Future<T> _healing<T>(_Tv tv, Future<T> Function() op) async {
    try {
      final result = await op();
      _learnStableId(tv);
      return result;
    } on TransportTimeoutException {
      final stableId = tv.device.stableId;
      final last = _lastHeal[tv.device.id];
      final now = DateTime.now();
      if (stableId == null ||
          (last != null && now.difference(last) < _healEvery)) {
        rethrow;
      }
      _lastHeal[tv.device.id] = now;
      final host = await _core.discovery.locator(tv.manifest, stableId);
      if (host == null || host == tv.device.host) rethrow;
      // Anyone on the network can announce the name, so the host there
      // proves it is this device before anything is sent or saved: a TV
      // by its serial, a phone by the key pinned at its first connection
      // (checked by the ADB channel during TLS).
      final before = tv.device;
      final there = before.copyWith(host: host);
      if (!await _sameTv(tv, there, stableId)) rethrow;
      tv.device = there;
      final T result;
      try {
        result = await op();
      } catch (_) {
        tv.device = before;
        rethrow;
      }
      tv.device = await _core.devices.updateDevice(
        before.id,
        (d) => d.copyWith(host: host),
      );
      _core.emit({
        'event': 'device.moved',
        'deviceId': before.id,
        'from': before.host,
        'to': host,
      });
      return result;
    }
  }

  /// Whether [there] answers as the device [stableId] names. A TV's id is
  /// `adb-<serial>`, read back with getprop. A Wireless Debugging guid is
  /// proved by its pinned key instead.
  Future<bool> _sameTv(_Tv tv, Device there, String stableId) async {
    if (adbTlsGuidPattern.hasMatch(stableId)) return true;
    if (!stableId.startsWith('adb-')) return false;
    try {
      final serial = (await _core.adb.run(
        there,
        tv.manifest,
        'getprop ro.serialno',
        offerKey: tv.offerKey,
      )).trim();
      return 'adb-$serial' == stableId;
    } on Exception {
      return false;
    }
  }

  /// A TV added by address has no stable id to be found by later. Its
  /// `_adb._tcp` instance is `adb-<serial>`, so the serial gives it one.
  void _learnStableId(_Tv tv) {
    if (tv.device.stableId != null || !_askedSerial.add(tv.device.id)) return;
    final advertises = tv.manifest.discovery.any(
      (d) =>
          d.method == 'mdns' &&
          d.config['service'] == '_adb._tcp' &&
          d.config['idInstance'] == true,
    );
    if (!advertises) return;
    _core.track(
      () async {
        final serial = (await _core.adb.run(
          tv.device,
          tv.manifest,
          'getprop ro.serialno',
        )).trim();
        if (!_serialPattern.hasMatch(serial)) return;
        await _core.devices.updateDevice(
          tv.device.id,
          (d) => d.stableId == null ? d.copyWith(stableId: 'adb-$serial') : d,
        );
      }().catchError((Object _) {}),
    );
  }

  Future<String> _run(
    _Tv tv,
    String command, {
    Duration? timeout,
    bool wake = false,
  }) => _healing(
    tv,
    () => _core.adb.run(
      tv.device,
      tv.manifest,
      command,
      timeout: timeout,
      offerKey: tv.offerKey,
      wake: wake,
    ),
  );

  String _marker() =>
      '@@omniflow-exit-${List.generate(8, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}:';

  /// Runs [command] and reports its exit status, read from a marker line
  /// printed after it. Null when the command ended the shell itself.
  Future<({String output, int? exitCode})> _exec(
    _Tv tv,
    String command, {
    Duration? timeout,
  }) async {
    final marker = _marker();
    final raw = await _run(tv, '$command\necho "$marker\$?"', timeout: timeout);
    final at = raw.lastIndexOf(marker);
    if (at < 0) return (output: raw, exitCode: null);
    return (
      output: raw.substring(0, at),
      exitCode: int.tryParse(raw.substring(at + marker.length).trim()),
    );
  }

  /// Like [_exec], failing with the device's message when the command
  /// did not exit 0.
  Future<String> _check(_Tv tv, String command, String what) async {
    final result = await _exec(tv, command);
    if (result.exitCode != 0) {
      final message = result.output.trim();
      throw ApiError(
        'device_error',
        '$what failed${message.isEmpty ? '' : ': ${_firstLines(message)}'}',
      );
    }
    return result.output;
  }

  Future<T> _sync<T>(_Tv tv, Future<T> Function(AdbSync sync) body) async {
    try {
      return await _healing(
        tv,
        () =>
            _core.adb.sync(tv.device, tv.manifest, body, offerKey: tv.offerKey),
      );
    } on AdbSyncException catch (e) {
      throw ApiError('device_error', e.message);
    }
  }

  // State, remote, text, volume ----------------------------------------

  Future<Map<String, Object?>> state(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final result = await _readState(tv);
    await _record(tv.device.id, result);
    return {'id': tv.device.id, ...result};
  }

  /// The TV's power, app, playback and volume. A TV that does not answer
  /// at all is off: Android TVs drop off the network in deep standby.
  Future<Map<String, Object?>> _readState(_Tv tv) async {
    if (tv.isPhone) return _readPhoneState(tv);
    try {
      final output = await _run(tv, tvSections(tvStateCommands));
      return parseTvState(splitTvSections(output));
    } on TransportTimeoutException {
      return {
        'power': 'off',
        'app': null,
        'activity': null,
        'playing': null,
        'volume': null,
        'volumeMax': null,
      };
    }
  }

  /// A phone's state, with its screen `on` or `off`. A phone that does not
  /// answer is not off: Wireless debugging went off, usually on a restart.
  Future<Map<String, Object?>> _readPhoneState(_Tv tv) async {
    try {
      final output = await _run(tv, tvSections(tvStateCommands));
      final state = parseTvState(splitTvSections(output));
      return {
        ...state,
        'kind': 'phone',
        'screen': state['power'] == 'on' ? 'on' : 'off',
        'reachable': true,
      };
    } on TransportTimeoutException {
      return {
        'kind': 'phone',
        'power': null,
        'screen': null,
        'app': null,
        'activity': null,
        'playing': null,
        'volume': null,
        'volumeMax': null,
        'reachable': false,
        'message':
            '${tv.device.id} did not answer. Wireless debugging turns off '
            'when the phone restarts, so turn it on again on that phone',
      };
    }
  }

  /// One hub poll: reads the TV state into the device state, and only
  /// saves it when a key changed, so rules see changes and not heartbeats.
  Future<void> poll(String deviceId) async {
    final tv = await _tv({'id': deviceId, 'allowPairing': false});
    await _record(deviceId, await _readState(tv));
  }

  Future<void> _record(String deviceId, Map<String, Object?> state) async {
    final device = await _core.devices.device(deviceId);
    if (device == null) return;
    final keys = state['kind'] == 'phone' ? androidPhoneStateKeys : tvStateKeys;
    final values = {for (final k in keys) k: state[k]};
    final changed = values.entries.any((e) => device.state[e.key] != e.value);
    if (changed || !keys.every(device.state.containsKey)) {
      await _core.devices.mergeState(deviceId, values);
    }
  }

  Future<Map<String, Object?>> keys(Map<String, Object?> args) async {
    final tv = await _tv(args);
    return {
      'id': tv.device.id,
      'groups': tv.isPhone ? _phoneKeyCatalogJson() : tvKeyCatalogJson(),
    };
  }

  static List<Map<String, Object?>> _phoneKeyCatalogJson() => [
    for (final g in androidPhoneKeyGroups)
      {
        'group': g.group,
        'keys': [
          for (final (key, label) in g.keys)
            {
              'key': key,
              'label': label,
              'keycode': tvKeyCodes[key],
              'group': g.group,
            },
        ],
      },
  ];

  /// Opens or closes the notification shade, as a swipe down from the top
  /// does.
  Future<Map<String, Object?>> notifications(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final action = args['action'] ?? 'expand';
    final command = switch (action) {
      'expand' => 'cmd statusbar expand-notifications',
      'settings' => 'cmd statusbar expand-settings',
      'collapse' => 'cmd statusbar collapse',
      _ => throw ApiError('invalid', 'action is expand, settings or collapse'),
    };
    await _check(tv, command, 'opening the notifications');
    return {'id': tv.device.id, 'action': action};
  }

  /// `{windowMs?}` -> `{phones}`: the devices on this network with Wireless
  /// debugging on, from mDNS, one per guid. Each has its `guid`, `name`,
  /// `host`, the `pairingPort` while "Pair device with pairing code" is
  /// open, the `connectPort`, and `knownAs` when it is a thing already.
  /// This device is left out.
  Future<Map<String, Object?>> find(Map<String, Object?> args) async {
    final ms = optIntArg(args, 'windowMs') ?? 3000;
    if (ms < 100 || ms > 30000) {
      throw ApiError('invalid', 'windowMs is 100 to 30000');
    }
    final List<AdbWirelessFind> found;
    try {
      found = await browseAdbWireless(
        _core.discovery.mdns,
        window: Duration(milliseconds: ms),
      );
    } on SocketException catch (e) {
      throw ApiError('unavailable', 'mDNS cannot open its socket: $e');
    }
    Set<String> own;
    try {
      own = await _core.discovery.ownAddresses();
    } on SocketException {
      own = const {};
    }
    final known = <String, String>{
      for (final d in await DriftDeviceStore(_core.db).all())
        if (d.stableId case final id?) id.toLowerCase(): d.id,
    };
    final phones = <String, Map<String, Object?>>{};
    for (final f in found) {
      if (own.contains(f.host)) continue;
      final guid = f.guid.toLowerCase();
      final phone = phones.putIfAbsent(
        guid,
        () => {
          'guid': f.guid,
          'name': f.name,
          'host': f.host,
          'knownAs': ?known[guid],
        },
      );
      phone[f.pairing ? 'pairingPort' : 'connectPort'] = f.port;
    }
    return {'phones': phones.values.toList()};
  }

  Future<Map<String, Object?>> key(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final given = args['key'] ?? args['keycode'];
    final keycode = switch (given) {
      int code => AdbAction.keycodeOf(null, code),
      String name when int.tryParse(name) != null => AdbAction.keycodeOf(
        null,
        name,
      ),
      String name => AdbAction.keycodeOf(name, null),
      _ => throw ApiError('invalid', 'key is a key name or a key code'),
    };
    if (tv.isPhone &&
        given is String &&
        int.tryParse(given) == null &&
        !_phoneKeyNames.contains(given)) {
      throw ApiError(
        'invalid',
        '$given is a TV remote key, and ${tv.device.id} is a phone. Its keys '
            'are in android.keys',
      );
    }
    final longPress = AdbAction.flagOf(args['longPress'], r'$.longPress');
    final repeat = AdbAction.repeatOf(args['repeat']);
    // Wake up, and the power key, are how the app turns a TV on: a TV in
    // deep standby gets Wake-on-LAN first. A phone has no Wake-on-LAN.
    await _run(
      tv,
      TvShell.key(keycode, longPress: longPress, repeat: repeat),
      wake: !tv.isPhone && (keycode == 224 || keycode == 26),
    );
    return {
      'id': tv.device.id,
      'keycode': keycode,
      if (given is String && int.tryParse(given) == null) 'key': given,
      'longPress': longPress,
      'repeat': repeat,
    };
  }

  Future<Map<String, Object?>> text(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final value = AdbAction.textOf(args['text']);
    await _run(tv, TvShell.text(value));
    return {'id': tv.device.id, 'typed': value.length};
  }

  static final _volumeLine = RegExp(
    r'volume is (\d+) in range \[(\d+)\.\.(\d+)\]',
  );

  Future<(int, int)?> _volumeNow(_Tv tv) async {
    final m = _volumeLine.firstMatch(await _run(tv, TvShell.volumeGet()));
    return m == null ? null : (int.parse(m.group(1)!), int.parse(m.group(3)!));
  }

  /// Sets the media volume exactly. A TV whose media session service does
  /// not take `--set` gets volume key presses instead.
  Future<Map<String, Object?>> volume(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final before = await _volumeNow(tv);
    final max = before?.$2 ?? 100;
    final level = AdbAction.levelOf(args['level'], max: max);
    await _run(tv, TvShell.volumeSet(level));
    var now = await _volumeNow(tv);
    var method = 'set';
    if (now != null && now.$1 != level) {
      final delta = level - now.$1;
      for (var left = delta.abs(); left > 0; left -= adbMaxRepeat) {
        await _run(
          tv,
          TvShell.key(
            tvKeyCodes[delta > 0 ? 'volume_up' : 'volume_down']!,
            repeat: min(left, adbMaxRepeat),
          ),
        );
      }
      now = await _volumeNow(tv);
      method = 'keys';
    }
    final result = {
      'id': tv.device.id,
      'volume': now?.$1 ?? level,
      'volumeMax': now?.$2 ?? max,
      'method': method,
      // The TV did not say its volume, so the level is what was asked for.
      if (now == null) 'unverified': true,
    };
    final device = await _core.devices.device(tv.device.id);
    if (now != null &&
        device != null &&
        device.state['volume'] != result['volume']) {
      await _core.devices.mergeState(tv.device.id, {
        'volume': result['volume'],
      });
    }
    return result;
  }

  // Apps ---------------------------------------------------------------

  Future<Map<String, Object?>> apps(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final filter = optStringArg(args, 'filter') ?? 'all';
    if (!const ['user', 'system', 'all'].contains(filter)) {
      throw ApiError('invalid', 'filter is user, system or all');
    }
    final launchableOnly = args['launchableOnly'] == true;
    final output = await _run(
      tv,
      tvSections(tvAppsCommands),
      timeout: const Duration(seconds: 30),
    );
    final all = parseTvApps(splitTvSections(output));
    return {
      'id': tv.device.id,
      'apps': [
        for (final a in all)
          if ((filter == 'all' ||
                  (a['system'] == true) == (filter == 'system')) &&
              (!launchableOnly || a['launchable'] == true))
            a,
      ],
    };
  }

  Future<Map<String, Object?>> _appInfo(_Tv tv, String package) async {
    final q = shellQuote(package);
    final output = await _run(
      tv,
      tvSections({
        'dumpsys': 'dumpsys package $q',
        'user': "dumpsys package $q | grep -m 1 -E '^    User 0:'",
        'sizes':
            'for f in \$(pm path $q | sed s/^package://); do '
            'stat -c %s "\$f"; done',
        'leanback':
            'cmd package resolve-activity --brief -a android.intent.action.MAIN '
            '-c android.intent.category.LEANBACK_LAUNCHER $q',
        'launcher':
            'cmd package resolve-activity --brief -a android.intent.action.MAIN '
            '-c android.intent.category.LAUNCHER $q',
      }),
      timeout: const Duration(seconds: 30),
    );
    final sections = splitTvSections(output);
    final parsed = parseTvApps({
      'packages': [
        for (final line in (sections['dumpsys'] ?? '').split('\n'))
          if (RegExp(
            r'^(Hidden system packages|  Package \[|    versionName=|'
            r'    versionCode=|    pkgFlags=|    User 0:)',
          ).hasMatch(line))
            line,
      ].join('\n'),
    }).where((a) => a['package'] == package).firstOrNull;
    if (parsed == null) {
      throw ApiError('not_found', 'no app $package on ${tv.device.id}');
    }
    final sizes = [
      for (final line in (sections['sizes'] ?? '').split('\n'))
        ?int.tryParse(line.trim()),
    ];
    bool resolves(String? s) => (s ?? '').contains('$package/');
    return {
      ...parsed,
      'launchable':
          resolves(sections['leanback']) || resolves(sections['launcher']),
      if (sizes.isNotEmpty) 'sizeBytes': sizes.fold<int>(0, (a, b) => a + b),
      ...parseTvAppInfo(sections['dumpsys'] ?? ''),
    };
  }

  static const _appSuccess = {
    'clear_cache': 'Success',
    'clear_data': 'Success',
    'disable': 'new state: disabled',
    'enable': 'new state: enabled',
    'uninstall': 'Success',
  };

  Future<Map<String, Object?>> app(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final package = AdbAction.packageOf(args['package']);
    final action = stringArg(args, 'action');
    switch (action) {
      case 'info':
        return {'id': tv.device.id, 'app': await _appInfo(tv, package)};
      case 'open':
        final output = await _run(tv, TvShell.launch(package));
        if (RegExp(
          r'No activities found|monkey aborted|^Error',
          multiLine: true,
        ).hasMatch(output)) {
          throw ApiError('device_error', 'no launchable app $package');
        }
        return {'id': tv.device.id, 'package': package, 'action': action};
      case 'stop':
        await _run(tv, TvShell.forceStop(package));
        return {'id': tv.device.id, 'package': package, 'action': action};
    }
    if (!adbAppActions.contains(action)) {
      throw ApiError(
        'invalid',
        'action is open, stop, info or one of ${adbAppActions.join(', ')}',
      );
    }
    final info = await _appInfo(tv, package);
    final output = await _run(
      tv,
      TvShell.app(package, action, system: info['system'] == true),
      timeout: const Duration(seconds: 60),
    );
    if (!output.contains(_appSuccess[action]!)) {
      throw ApiError(
        'device_error',
        'the ${tv.noun} could not $action $package: ${_firstLines(output.trim())}',
      );
    }
    return {
      'id': tv.device.id,
      'package': package,
      'action': action,
      'output': output.trim(),
    };
  }

  Future<Map<String, Object?>> install(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final file = File(_localPath(args, 'path'));
    if (!await file.exists()) {
      throw ApiError('not_found', 'no file ${file.path} on this computer');
    }
    if (!file.path.toLowerCase().endsWith('.apk')) {
      throw ApiError('invalid', 'path is an .apk file');
    }
    final replace = args['replace'] == true;
    final remote = '/data/local/tmp/omniflow-${_hex(8)}.apk';
    final total = await file.length();
    final progress = _progress(tv.device.id, 'install', total);
    await _sync(
      tv,
      (s) => s.push(file, remote, onProgress: (done, _) => progress(done)),
    );
    try {
      final output = await _run(
        tv,
        'pm install ${replace ? '-r ' : ''}${shellQuote(remote)}',
        timeout: _installTimeout,
      );
      if (!output.contains('Success')) {
        throw ApiError(
          'device_error',
          'the ${tv.noun} did not install ${file.uri.pathSegments.last}: '
              '${_firstLines(output.trim())}',
        );
      }
      return {
        'id': tv.device.id,
        'installed': file.uri.pathSegments.last,
        'bytes': total,
        'replace': replace,
      };
    } finally {
      try {
        await _run(tv, 'rm -f ${shellQuote(remote)}');
      } on Object {
        // The temporary copy is left in /data/local/tmp.
      }
    }
  }

  // Settings -----------------------------------------------------------

  Future<Map<String, Map<String, String>>> _allSettings(_Tv tv) async {
    final output = await _run(
      tv,
      tvSections({
        for (final ns in adbSettingNamespaces) ns: 'settings list $ns',
      }),
    );
    final sections = splitTvSections(output);
    return {
      for (final ns in adbSettingNamespaces)
        ns: parseSettingsList(sections[ns] ?? ''),
    };
  }

  Future<Map<String, Object?>> settingsCatalog(
    Map<String, Object?> args,
  ) async {
    final tv = await _tv(args);
    final all = await _allSettings(tv);
    return {
      'id': tv.device.id,
      'categories': [
        for (final c in tvSettingCatalog)
          if (!tv.isPhone || !_tvOnlySettingCategories.contains(c.category))
            {
              'category': c.category,
              'settings': [
                for (final s in c.settings) s.toJson(all[s.namespace]![s.key]),
              ],
            },
      ],
    };
  }

  Future<Map<String, Object?>> settingsList(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final namespace = args['namespace'] == null
        ? null
        : AdbAction.namespaceOf(args['namespace']);
    final all = await _allSettings(tv);
    return {
      'id': tv.device.id,
      'settings': [
        for (final ns in adbSettingNamespaces)
          if (namespace == null || ns == namespace)
            for (final e
                in (all[ns]!.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key))))
              {'namespace': ns, 'key': e.key, 'value': e.value},
      ],
    };
  }

  Future<String?> _setting(_Tv tv, String namespace, String key) async {
    final value = (await _run(
      tv,
      TvShell.settingGet(namespace, key),
    )).replaceAll(RegExp(r'\r?\n$'), '');
    return value == 'null' ? null : value;
  }

  (String, String) _settingAddress(Map<String, Object?> args) => (
    AdbAction.namespaceOf(args['namespace']),
    AdbAction.settingKeyOf(args['key']),
  );

  Map<String, Object?> _settingJson(
    String id,
    String namespace,
    String key,
    String? value,
  ) {
    final known = tvSettingsById['$namespace/$key'];
    return {
      'id': id,
      'namespace': namespace,
      'key': key,
      'value': value,
      if (known != null) 'setting': known.toJson(value),
    };
  }

  Future<Map<String, Object?>> settingsGet(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final (namespace, key) = _settingAddress(args);
    return _settingJson(
      tv.device.id,
      namespace,
      key,
      await _setting(tv, namespace, key),
    );
  }

  void _checkWritable(String namespace, String key) {
    if (adbProtectedSettings.contains('$namespace/$key')) {
      throw ApiError(
        'invalid',
        '$namespace $key would cut this engine off from the device. Change it '
            'on the device itself',
      );
    }
  }

  Future<Map<String, Object?>> settingsPut(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final (namespace, key) = _settingAddress(args);
    _checkWritable(namespace, key);
    final known = tvSettingsById['$namespace/$key'];
    final value = known != null
        ? known.encode(args['value'])
        : AdbAction.settingValueOf(args['value']);
    final previous = await _setting(tv, namespace, key);
    if (known?.id == 'global/bluetooth_on') {
      await _check(
        tv,
        'cmd bluetooth_manager ${value == '1' ? 'enable' : 'disable'}',
        'turning Bluetooth ${value == '1' ? 'on' : 'off'}',
      );
    } else {
      await _check(
        tv,
        TvShell.settingPut(namespace, key, value),
        'setting $namespace $key',
      );
    }
    return {
      ..._settingJson(
        tv.device.id,
        namespace,
        key,
        await _setting(tv, namespace, key),
      ),
      'previous': previous,
      'raw': known == null,
    };
  }

  Future<Map<String, Object?>> settingsDelete(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final (namespace, key) = _settingAddress(args);
    _checkWritable(namespace, key);
    final previous = await _setting(tv, namespace, key);
    await _check(
      tv,
      TvShell.settingDelete(namespace, key),
      'deleting $namespace $key',
    );
    return {
      'id': tv.device.id,
      'namespace': namespace,
      'key': key,
      'previous': previous,
    };
  }

  // Files --------------------------------------------------------------

  /// An absolute device path with no NUL or line break, without a
  /// trailing slash.
  static String _remotePath(Map<String, Object?> args, String key) =>
      remotePathOf(args[key], key);

  static String remotePathOf(Object? value, String key) {
    if (value is! String ||
        !value.startsWith('/') ||
        value.length > _maxPath ||
        value.contains(RegExp('[\x00\r\n]'))) {
      throw ApiError(
        'invalid',
        '$key is an absolute path on the device, at most $_maxPath bytes, '
            'on one line',
      );
    }
    final collapsed = value.replaceAll(RegExp('/+'), '/');
    return collapsed.length > 1 && collapsed.endsWith('/')
        ? collapsed.substring(0, collapsed.length - 1)
        : collapsed;
  }

  static String _localPath(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is! String ||
        value.isEmpty ||
        !File(value).isAbsolute ||
        value.contains(RegExp('[\x00\r\n]'))) {
      throw ApiError(
        'invalid',
        '$key is an absolute path on the computer running the engine',
      );
    }
    return value;
  }

  static String _join(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';

  static String _parent(String path) {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }

  static String _baseName(String path) =>
      path.substring(path.lastIndexOf('/') + 1);

  /// Emits `tv.progress` at most every [_progressEvery], and always at the
  /// end.
  void Function(int done) _progress(String id, String op, int? total) {
    var last = DateTime.fromMillisecondsSinceEpoch(0);
    return (done) {
      final now = DateTime.now();
      if (done != total && now.difference(last) < _progressEvery) return;
      last = now;
      _core.emit({
        'event': 'tv.progress',
        'id': id,
        'op': op,
        'done': done,
        'total': total,
      });
    };
  }

  /// Whether [path] is a folder, following a link to one: `/sdcard` is a
  /// link to the storage folder, and STAT does not follow links.
  static Future<bool> _isFolder(AdbSync s, String path) async {
    final entry = await s.stat(path);
    if (entry == null) return false;
    if (entry.isDirectory) return true;
    if (entry.type != 'link') return false;
    return (await s.stat(path.endsWith('/') ? path : '$path/'))?.isDirectory ??
        false;
  }

  Future<AdbSyncEntry> _statOrMissing(AdbSync s, String path, String id) async {
    final entry = await s.stat(path);
    if (entry == null) throw ApiError('not_found', 'no $path on $id');
    return entry;
  }

  Future<Map<String, Object?>> filesList(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final path = _remotePath(args, 'path');
    return _sync(tv, (s) async {
      final entry = path == '/'
          ? null
          : await _statOrMissing(s, path, tv.device.id);
      if (entry != null && entry.type == 'file') {
        throw ApiError('invalid', '$path is a file, not a folder');
      }
      final entries = await s.list(path)
        ..sort((a, b) {
          if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      return {
        'id': tv.device.id,
        'path': path,
        'entries': [for (final e in entries) e.toJson()],
      };
    });
  }

  Future<Map<String, Object?>> filesStat(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final path = _remotePath(args, 'path');
    return _sync(tv, (s) async {
      final entry = await _statOrMissing(s, path, tv.device.id);
      return {'id': tv.device.id, 'path': path, ...entry.toJson()};
    });
  }

  /// Every file under the device folder [root], with the folders to make
  /// first, walked through LIST.
  Future<({List<String> dirs, List<(String, int)> files})> _walkRemote(
    AdbSync s,
    String root,
  ) async {
    final dirs = <String>[root];
    final files = <(String, int)>[];
    for (var i = 0; i < dirs.length; i++) {
      for (final e in await s.list(dirs[i])) {
        final path = _join(dirs[i], e.name);
        if (e.isDirectory) {
          dirs.add(path);
        } else if (e.type == 'file') {
          files.add((path, e.size));
        }
      }
    }
    return (dirs: dirs, files: files);
  }

  Future<void> _pullFile(
    AdbSync s,
    String remote,
    File local,
    void Function(int) progressBy,
  ) async {
    // Into a .part file, renamed over the target only once it is whole, so
    // a failed download never costs the copy the user already had.
    final part = File('${local.path}.part');
    final raf = await part.open(mode: FileMode.write);
    var ok = false;
    try {
      await s.pull(remote, (Uint8List chunk) async {
        await raf.writeFrom(chunk);
        progressBy(chunk.length);
      });
      ok = true;
    } finally {
      await raf.close();
      if (ok) {
        await part.rename(local.path);
      } else if (await part.exists()) {
        await part.delete();
      }
    }
  }

  Future<Map<String, Object?>> filesDownload(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final path = _remotePath(args, 'path');
    final to = _localPath(args, 'to');
    final overwrite = args['overwrite'] == true;
    return _sync(tv, (s) async {
      final entry = await _statOrMissing(s, path, tv.device.id);
      var target = to;
      if (await FileSystemEntity.isDirectory(to)) {
        target = '$to${Platform.pathSeparator}${_baseName(path)}';
      }
      if (!overwrite &&
          await FileSystemEntity.type(target) !=
              FileSystemEntityType.notFound) {
        throw ApiError(
          'conflict',
          '${_baseName(target)} is already there: replace it, or pick another name',
        );
      }
      final isDir =
          entry.isDirectory ||
          (entry.type == 'link' && (await s.list(path)).isNotEmpty);
      if (!isDir) {
        var done = 0;
        final progress = _progress(tv.device.id, 'download', entry.size);
        await _pullFile(s, path, File(target), (n) => progress(done += n));
        return {
          'id': tv.device.id,
          'path': path,
          'to': target,
          'files': 1,
          'bytes': done,
        };
      }
      final walk = await _walkRemote(s, path);
      final total = walk.files.fold<int>(0, (a, f) => a + f.$2);
      final progress = _progress(tv.device.id, 'download', total);
      String localFor(String remote) =>
          pathInside(
            target,
            remote.substring(path.length).split('/').where((p) => p.isNotEmpty),
          ) ??
          (throw ApiError(
            'invalid',
            'the ${tv.noun} listed $remote, which would be saved outside $target, so '
                'the download stopped',
          ));
      for (final d in walk.dirs) {
        await Directory(localFor(d)).create(recursive: true);
      }
      var done = 0;
      for (final (remote, _) in walk.files) {
        await _pullFile(
          s,
          remote,
          File(localFor(remote)),
          (n) => progress(done += n),
        );
      }
      return {
        'id': tv.device.id,
        'path': path,
        'to': target,
        'files': walk.files.length,
        'bytes': done,
      };
    });
  }

  Future<Map<String, Object?>> filesUpload(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final from = _localPath(args, 'from');
    final path = _remotePath(args, 'path');
    final overwrite = args['overwrite'] == true;
    final kind = await FileSystemEntity.type(from, followLinks: false);
    if (kind != FileSystemEntityType.file &&
        kind != FileSystemEntityType.directory) {
      throw ApiError('not_found', 'no file or folder $from on this computer');
    }
    final name = from
        .split(Platform.pathSeparator)
        .lastWhere((p) => p.isNotEmpty);
    final target = await _sync(tv, (s) async {
      final there = await s.stat(path);
      final target = await _isFolder(s, path) ? _join(path, name) : path;
      if (!overwrite && target != path && await s.stat(target) != null ||
          !overwrite && target == path && there != null) {
        throw ApiError(
          'conflict',
          '${_baseName(target)} is already there: replace it, or pick another name',
        );
      }
      return target;
    });
    if (kind == FileSystemEntityType.file) {
      final file = File(from);
      final total = await file.length();
      final progress = _progress(tv.device.id, 'upload', total);
      final mode = _modeOf(await file.stat());
      await _sync(
        tv,
        (s) => s.push(
          file,
          target,
          mode: mode,
          onProgress: (done, _) => progress(done),
        ),
      );
      return {
        'id': tv.device.id,
        'from': from,
        'path': target,
        'files': 1,
        'bytes': total,
      };
    }
    final files = <(File, String)>[];
    final dirs = <String>{target};
    await for (final e in Directory(
      from,
    ).list(recursive: true, followLinks: false)) {
      final relative = e.path
          .substring(from.length)
          .split(Platform.pathSeparator)
          .where((p) => p.isNotEmpty)
          .join('/');
      final remote = remotePathOf(_join(target, relative), 'path');
      if (e is Directory) {
        dirs.add(remote);
      } else if (e is File) {
        files.add((e, remote));
      }
    }
    await _check(
      tv,
      'mkdir -p -- ${(dirs.toList()..sort()).map(shellQuote).join(' ')}',
      'making folders under $target',
    );
    var total = 0;
    for (final (f, _) in files) {
      total += await f.length();
    }
    final progress = _progress(tv.device.id, 'upload', total);
    var done = 0;
    await _sync(tv, (s) async {
      for (final (file, remote) in files) {
        var sent = 0;
        await s.push(
          file,
          remote,
          mode: _modeOf(await file.stat()),
          onProgress: (n, _) {
            done += n - sent;
            sent = n;
            progress(done);
          },
        );
      }
    });
    return {
      'id': tv.device.id,
      'from': from,
      'path': target,
      'files': files.length,
      'bytes': done,
    };
  }

  /// A regular file with the local permission bits.
  static int _modeOf(FileStat stat) => 0x8000 | (stat.mode & 0x1ff);

  Future<Map<String, Object?>> _copyOrMove(
    Map<String, Object?> args, {
    required bool move,
  }) async {
    final tv = await _tv(args);
    final from = _remotePath(args, 'from');
    final to = _remotePath(args, 'to');
    final overwrite = args['overwrite'] == true;
    if (from == '/' || to == from || to.startsWith('$from/')) {
      throw ApiError(
        'invalid',
        'cannot ${move ? 'move' : 'copy'} $from to $to',
      );
    }
    final target = await _sync(tv, (s) async {
      await _statOrMissing(s, from, tv.device.id);
      final target = await _isFolder(s, to) ? _join(to, _baseName(from)) : to;
      if (!overwrite && await s.stat(target) != null) {
        throw ApiError(
          'conflict',
          '${_baseName(target)} is already there: replace it, or pick another name',
        );
      }
      return target;
    });
    final q = '-- ${shellQuote(from)} ${shellQuote(target)}';
    await _check(
      tv,
      move ? 'mv $q' : 'cp -R $q',
      '${move ? 'moving' : 'copying'} $from',
    );
    return {'id': tv.device.id, 'from': from, 'to': target};
  }

  Future<Map<String, Object?>> filesDelete(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final raw = args['paths'];
    if (raw is! List || raw.isEmpty || raw.length > 500) {
      throw ApiError('invalid', 'paths is a list of 1 to 500 paths');
    }
    final paths = [for (final p in raw) remotePathOf(p, 'paths')];
    for (final p in paths) {
      // A top folder holds the system or every user file.
      if (p.split('/').where((s) => s.isNotEmpty).length < 2) {
        throw ApiError('invalid', 'will not delete $p');
      }
    }
    final recursive = args['recursive'] == true;
    await _check(
      tv,
      'rm ${recursive ? '-r ' : ''}-- ${paths.map(shellQuote).join(' ')}',
      'deleting',
    );
    return {'id': tv.device.id, 'deleted': paths};
  }

  Future<Map<String, Object?>> filesMkdir(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final path = _remotePath(args, 'path');
    await _check(tv, 'mkdir -p -- ${shellQuote(path)}', 'making $path');
    return {'id': tv.device.id, 'path': path};
  }

  Future<Map<String, Object?>> filesRename(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final path = _remotePath(args, 'path');
    final name = args['name'];
    if (name is! String ||
        name.isEmpty ||
        name.length > 255 ||
        name == '.' ||
        name == '..' ||
        name.contains(RegExp('[/\x00\r\n]'))) {
      throw ApiError('invalid', 'name is a file name without a slash');
    }
    if (path == '/') throw ApiError('invalid', 'cannot rename /');
    final target = _join(_parent(path), name);
    await _sync(tv, (s) async {
      await _statOrMissing(s, path, tv.device.id);
      if (await s.stat(target) != null) {
        throw ApiError('conflict', '$target exists');
      }
    });
    await _check(
      tv,
      'mv -- ${shellQuote(path)} ${shellQuote(target)}',
      'renaming $path',
    );
    return {'id': tv.device.id, 'from': path, 'to': target};
  }

  // Screen, touch and recording ------------------------------------------

  Future<Uint8List> _execBytes(_Tv tv, String command) => _healing(
    tv,
    () =>
        _core.adb.exec(tv.device, tv.manifest, command, offerKey: tv.offerKey),
  );

  Future<Map<String, Object?>> screenshot(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final png = await _execBytes(tv, 'screencap -p');
    final size = pngSize(png);
    if (size == null) {
      final said = utf8
          .decode(png.take(300).toList(), allowMalformed: true)
          .trim();
      throw ApiError(
        'device_error',
        'the ${tv.noun} did not send a screenshot'
            '${said.isEmpty ? '' : ': ${_firstLines(said)}'}',
      );
    }
    return {
      'id': tv.device.id,
      'png': base64Encode(png),
      'width': size.$1,
      'height': size.$2,
    };
  }

  Future<(int, int)> _screenSize(_Tv tv) async {
    final held = _core.adb.connectionOf(tv.device.id);
    final known = held == null ? null : _screenSizes[held];
    if (known != null) return known;
    final size = parseWmSize(await _run(tv, 'wm size'));
    if (size == null) {
      throw ApiError(
        'device_error',
        '${tv.device.id} did not say its screen size',
      );
    }
    final now = _core.adb.connectionOf(tv.device.id);
    if (now != null) _screenSizes[now] = size;
    return size;
  }

  static double _fraction(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is! num || !value.isFinite || value < 0 || value > 1) {
      throw ApiError('invalid', '$key is a fraction of the screen from 0 to 1');
    }
    return value.toDouble();
  }

  static int _pixel(double fraction, int extent) =>
      min((fraction * extent).floor(), extent - 1);

  static int _intIn(
    Map<String, Object?> args,
    String key, {
    required int low,
    required int high,
    required int fallback,
  }) {
    final value = args[key];
    if (value == null) return fallback;
    if (value is! int || value < low || value > high) {
      throw ApiError('invalid', '$key is a whole number from $low to $high');
    }
    return value;
  }

  Future<Map<String, Object?>> tap(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final x = _fraction(args, 'x');
    final y = _fraction(args, 'y');
    final (width, height) = await _screenSize(tv);
    final (px, py) = (_pixel(x, width), _pixel(y, height));
    await _check(tv, 'input tap $px $py', 'tapping the screen');
    return {'id': tv.device.id, 'x': px, 'y': py};
  }

  Future<Map<String, Object?>> swipe(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final from = (_fraction(args, 'x1'), _fraction(args, 'y1'));
    final to = (_fraction(args, 'x2'), _fraction(args, 'y2'));
    final ms = _intIn(args, 'ms', low: 50, high: 5000, fallback: 300);
    final (width, height) = await _screenSize(tv);
    final points = [
      _pixel(from.$1, width),
      _pixel(from.$2, height),
      _pixel(to.$1, width),
      _pixel(to.$2, height),
    ];
    await _check(
      tv,
      'input swipe ${points.join(' ')} $ms',
      'swiping on the screen',
    );
    return {
      'id': tv.device.id,
      'x1': points[0],
      'y1': points[1],
      'x2': points[2],
      'y2': points[3],
      'ms': ms,
    };
  }

  static const _recordFolder = '/sdcard/Movies/OmniFlow';
  static const _stopWait = Duration(seconds: 5);

  Future<bool> _recording(_Tv tv) async =>
      (await _run(tv, 'pidof screenrecord')).trim().isNotEmpty;

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  Map<String, Object?> _recordingJson(String id) {
    final last = _recordings[id];
    return {
      if (last != null) 'file': last.file,
      if (last != null) 'startedAt': last.startedAt.toIso8601String(),
    };
  }

  Future<Map<String, Object?>> recordStart(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final seconds = _intIn(args, 'seconds', low: 1, high: 180, fallback: 180);
    final mbps = _intIn(args, 'bitRate', low: 1, high: 20, fallback: 6);
    if ((await _exec(tv, 'command -v screenrecord')).exitCode != 0) {
      throw ApiError(
        'device_error',
        '${tv.device.id} has no screenrecord, so it cannot record its screen',
      );
    }
    if (await _recording(tv)) {
      throw ApiError(
        'conflict',
        '${tv.device.id} is already recording its screen: stop that first',
      );
    }
    final startedAt = DateTime.now();
    final file = '$_recordFolder/rec-${_stamp(startedAt)}.mp4';
    // nohup and the background job keep it recording after this shell, and
    // the stream it runs on, end.
    final output = await _run(
      tv,
      [
        'mkdir -p -- ${shellQuote(_recordFolder)}',
        'nohup screenrecord --time-limit $seconds --bit-rate '
            '${mbps * 1000000} ${shellQuote(file)} >/dev/null 2>&1 &',
        'sleep 1',
        'pidof screenrecord',
      ].join('\n'),
      timeout: const Duration(seconds: 15),
    );
    if (int.tryParse(output.trim().split(RegExp(r'\s+')).last) == null) {
      throw ApiError(
        'device_error',
        '${tv.device.id} could not start recording its screen. It may have '
            'no video encoder screenrecord can use',
      );
    }
    _recordings[tv.device.id] = (file: file, startedAt: startedAt.toUtc());
    return {
      'id': tv.device.id,
      ..._recordingJson(tv.device.id),
      'seconds': seconds,
    };
  }

  Future<Map<String, Object?>> recordStop(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final last = _recordings[tv.device.id];
    if (await _recording(tv)) {
      await _run(tv, 'pkill -INT screenrecord');
      final deadline = DateTime.now().add(_stopWait);
      while (await _recording(tv)) {
        if (DateTime.now().isAfter(deadline)) {
          throw ApiError(
            'device_error',
            'the recording on ${tv.device.id} did not stop within '
                '${_stopWait.inSeconds} s',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } else if (last == null) {
      throw ApiError('conflict', '${tv.device.id} is not recording its screen');
    }
    if (last == null) return {'id': tv.device.id, 'file': null, 'bytes': null};
    final entry = await _sync(tv, (s) => s.stat(last.file));
    if (entry == null) {
      throw ApiError(
        'device_error',
        'the recording ${last.file} is not on ${tv.device.id}. The TV may '
            'have no video encoder screenrecord can use',
      );
    }
    return {'id': tv.device.id, 'file': last.file, 'bytes': entry.size};
  }

  Future<Map<String, Object?>> recordStatus(Map<String, Object?> args) async {
    final tv = await _tv(args);
    return {
      'id': tv.device.id,
      'recording': await _recording(tv),
      ..._recordingJson(tv.device.id),
    };
  }

  // System, processes, permissions, backup, power ------------------------

  Future<Map<String, Object?>> system(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final output = await _run(
      tv,
      tvSections({
        'cpu': 'head -n 1 /proc/stat; sleep 0.5; head -n 1 /proc/stat',
        'memory': 'cat /proc/meminfo',
        'data': 'df -k /data',
        'shared': 'df -k /sdcard',
        'network': 'cat /proc/net/dev',
        'uptime': 'cat /proc/uptime',
        'thermal': 'cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null',
      }),
      timeout: const Duration(seconds: 15),
    );
    final sections = splitTvSections(output);
    final cpuLines = [
      for (final line in (sections['cpu'] ?? '').split('\n'))
        if (line.startsWith('cpu ')) line,
    ];
    final memory = parseMeminfo(sections['memory'] ?? '');
    final network = parseNetDev(sections['network'] ?? '');
    final temperature = parseThermal(sections['thermal'] ?? '');
    return {
      'id': tv.device.id,
      'cpu': {
        'percent': cpuLines.length < 2
            ? null
            : cpuPercent(cpuLines[0], cpuLines[1]),
      },
      'memory': {
        'totalKb': memory?.totalKb,
        'availableKb': memory?.availableKb,
      },
      // Named by the folder asked about: TVs mount these under different
      // paths (/data/user/0, /storage/emulated), which mean nothing to a user.
      'storage': [
        for (final (key, path) in const [
          ('data', '/data'),
          ('shared', '/sdcard'),
        ])
          if (parseDf(sections[key] ?? '').firstOrNull case final m?)
            {'mount': path, 'sizeKb': m.sizeKb, 'usedKb': m.usedKb},
      ],
      'network': {'rxBytes': network.rxBytes, 'txBytes': network.txBytes},
      'uptimeSeconds': parseUptime(sections['uptime'] ?? ''),
      'temperatureC': ?temperature,
    };
  }

  Future<Map<String, Object?>> processes(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final output = await _run(
      tv,
      tvSections({
        'ps': 'ps -A -o PID,RSS,NAME',
        'focus': tvStateCommands['focus']!,
      }),
      timeout: const Duration(seconds: 15),
    );
    final sections = splitTvSections(output);
    final foreground = parseTvState({'focus': sections['focus'] ?? ''})['app'];
    return {
      'id': tv.device.id,
      'apps': [
        for (final p in parsePs(sections['ps'] ?? ''))
          {
            'package': p.package,
            'pid': p.pid,
            'memoryKb': p.memoryKb,
            'foreground': p.package == foreground,
          },
      ],
    };
  }

  static final _permissionPattern = RegExp(r'^[A-Za-z0-9_.]{1,255}$');

  Future<Map<String, Object?>> appPermissions(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final package = AdbAction.packageOf(args['package']);
    final output = await _run(
      tv,
      'dumpsys package ${shellQuote(package)}',
      timeout: const Duration(seconds: 30),
    );
    if (!output.contains('Package [$package]')) {
      throw ApiError('not_found', 'no app $package on ${tv.device.id}');
    }
    return {
      'id': tv.device.id,
      'package': package,
      'permissions': [
        for (final p in parsePermissions(output))
          {'name': p.name, 'granted': p.granted, 'runtime': p.runtime},
      ],
    };
  }

  Future<Map<String, Object?>> appPermission(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final package = AdbAction.packageOf(args['package']);
    final permission = args['permission'];
    if (permission is! String || !_permissionPattern.hasMatch(permission)) {
      throw ApiError(
        'invalid',
        'permission is a permission name such as '
            'android.permission.RECORD_AUDIO',
      );
    }
    final grant = args['grant'];
    if (grant is! bool) throw ApiError('invalid', 'grant is true or false');
    final verb = grant ? 'grant' : 'revoke';
    final result = await _exec(
      tv,
      'pm $verb ${shellQuote(package)} ${shellQuote(permission)}',
    );
    final said = result.output.trim();
    if (result.exitCode != 0 || TvShell.failure.hasMatch(said)) {
      throw ApiError(
        'device_error',
        'the ${tv.noun} could not $verb $permission for $package'
            '${said.isEmpty ? '' : ': ${_firstLines(said)}'}',
      );
    }
    return {
      'id': tv.device.id,
      'package': package,
      'permission': permission,
      'granted': grant,
    };
  }

  Future<Map<String, Object?>> appBackup(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final package = AdbAction.packageOf(args['package']);
    final to = _localPath(args, 'to');
    final overwrite = args['overwrite'] == true;
    if (await FileSystemEntity.type(to) == FileSystemEntityType.file) {
      throw ApiError('invalid', 'to is a folder, and $to is a file');
    }
    final listed = parsePmPath(
      await _run(tv, 'pm path ${shellQuote(package)}'),
    );
    if (listed.isEmpty) {
      throw ApiError('not_found', 'no app $package on ${tv.device.id}');
    }
    final plan = <(String, String)>[];
    for (final remote in listed) {
      if (!remote.startsWith('/') ||
          !remote.toLowerCase().endsWith('.apk') ||
          remote.contains(RegExp('[\x00\r\n]'))) {
        throw ApiError(
          'device_error',
          'the ${tv.noun} listed $remote as an APK of $package, which is not an APK '
              'path',
        );
      }
      final name = apkBackupName(package, remote);
      final local =
          pathInside(to, [name]) ??
          (throw ApiError(
            'invalid',
            'the ${tv.noun} listed $remote, which would be saved outside $to, so the '
                'backup stopped',
          ));
      if (!overwrite &&
          await FileSystemEntity.type(local) != FileSystemEntityType.notFound) {
        throw ApiError(
          'conflict',
          '$name is already there: replace it, or pick another folder',
        );
      }
      plan.add((remote, local));
    }
    await Directory(to).create(recursive: true);
    return _sync(tv, (s) async {
      var total = 0;
      for (final (remote, _) in plan) {
        total += (await s.stat(remote))?.size ?? 0;
      }
      final progress = _progress(tv.device.id, 'backup', total);
      var done = 0;
      for (final (remote, local) in plan) {
        await _pullFile(s, remote, File(local), (n) => progress(done += n));
      }
      return {
        'id': tv.device.id,
        'package': package,
        'files': [for (final (_, local) in plan) local],
        'bytes': done,
      };
    });
  }

  Future<Map<String, Object?>> cacheTrim(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final output = await _run(
      tv,
      tvSections({
        'before': 'df -k /data',
        'trim': 'pm trim-caches 999G',
        'after': 'df -k /data',
      }),
      timeout: const Duration(minutes: 2),
    );
    final sections = splitTvSections(output);
    final said = (sections['trim'] ?? '').trim();
    if (TvShell.failure.hasMatch(said)) {
      throw ApiError(
        'device_error',
        'the ${tv.noun} could not trim its caches: ${_firstLines(said)}',
      );
    }
    int? free(String? df) => parseDf(df ?? '').firstOrNull?.availableKb;
    final before = free(sections['before']);
    final after = free(sections['after']);
    return {
      'id': tv.device.id,
      if (before != null && after != null) 'freedKb': max(0, after - before),
    };
  }

  Future<Map<String, Object?>> power(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final action = args['action'];
    if (action != 'reboot' && action != 'shutdown') {
      throw ApiError('invalid', 'action is reboot or shutdown');
    }
    // A TV that cannot be reached or has not allowed this engine fails
    // here. After it, a dropped connection is the TV going down.
    await _run(tv, 'true');
    try {
      final result = await _exec(
        tv,
        action == 'reboot' ? 'reboot' : 'reboot -p',
        timeout: const Duration(seconds: 10),
      );
      if (result.exitCode != null && result.exitCode != 0) {
        final said = result.output.trim();
        throw ApiError(
          'device_error',
          'the ${tv.noun} did not $action'
              '${said.isEmpty ? '' : ': ${_firstLines(said)}'}',
        );
      }
    } on CommandFailedException {
      // The connection dropped as the TV went down.
    } on TransportTimeoutException {
      // The same, seen as a TV that stopped answering.
    }
    _core.adb.forget(tv.device.id);
    return {'id': tv.device.id, 'action': action};
  }

  // Shell ----------------------------------------------------------------

  /// Runs what the user typed. With [cwd] it runs there, and the result
  /// carries the folder the command ended in, so an interactive session
  /// keeps its place between commands.
  Future<Map<String, Object?>> shell(Map<String, Object?> args) async {
    final tv = await _tv(args);
    final command = stringArg(args, 'command');
    if (command.contains('\x00') || command.length > 3500) {
      throw ApiError('invalid', 'command is at most 3500 characters');
    }
    final cwd = args['cwd'] == null ? null : _remotePath(args, 'cwd');
    final ms = optIntArg(args, 'timeoutMs') ?? 30000;
    if (ms < 100 || ms > _maxShellTimeout.inMilliseconds) {
      throw ApiError(
        'invalid',
        'timeoutMs is 100 to ${_maxShellTimeout.inMilliseconds}',
      );
    }
    final marker = _marker();
    final script = [
      // A folder deleted since falls back to /, so the console never sticks.
      if (cwd != null) 'cd ${shellQuote(cwd)} 2>/dev/null || cd /',
      command,
      'echo "$marker\$?:\$PWD"',
    ].join('\n');
    final raw = await _run(tv, script, timeout: Duration(milliseconds: ms));
    final at = raw.lastIndexOf(marker);
    if (at < 0) {
      return {'id': tv.device.id, 'output': raw, 'exitCode': null, 'cwd': cwd};
    }
    final tail = raw.substring(at + marker.length).trim();
    final colon = tail.indexOf(':');
    return {
      'id': tv.device.id,
      'output': raw.substring(0, at),
      'exitCode': int.tryParse(colon < 0 ? tail : tail.substring(0, colon)),
      'cwd': colon < 0 ? cwd : tail.substring(colon + 1),
    };
  }

  /// Whether invoking [capability] on [id] is high risk: what the MCP
  /// server checks before an agent invokes it.
  Future<Map<String, Object?>> capabilityRisk(Map<String, Object?> args) async {
    final device = await _core.device(stringArg(args, 'id'));
    final manifest = manifestFor(_core.registry, device);
    final capability = manifest?.capability(stringArg(args, 'capability'));
    if (manifest == null || capability == null) {
      throw ApiError(
        'not_found',
        'no capability ${args['capability']} on ${device.id}',
      );
    }
    return {
      'id': device.id,
      'capability': capability.id,
      'highRisk': _stored.capabilityIsHighRisk(manifest, capability),
    };
  }

  String _hex(int bytes) => List.generate(
    bytes,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// A TV device resolved for one command. [device] follows a new address
/// when healing moves it.
class _Tv {
  _Tv(this.device, this.manifest, {required this.offerKey})
    : isPhone = isAndroidPhone(manifest);

  Device device;
  final DriverManifest manifest;
  final bool offerKey;
  final bool isPhone;

  /// What messages call the device.
  String get noun => isPhone ? 'phone' : 'TV';
}

String _firstLines(String text) {
  final lines = text.split('\n').take(3).join(' ').trim();
  return lines.length > 300 ? '${lines.substring(0, 300)}...' : lines;
}

/// [segments] joined under [root], or null when the result, with `.` and
/// `..` worked out, is not inside [root].
String? pathInside(String root, Iterable<String> segments) {
  final sep = Platform.pathSeparator;
  final joined = [root, ...segments].join(sep);
  final base = _lexical(File(root).absolute.path);
  final full = _lexical(File(joined).absolute.path);
  return full == base || full.startsWith(base == sep ? sep : '$base$sep')
      ? full
      : null;
}

String _lexical(String path) {
  final sep = Platform.pathSeparator;
  final parts = <String>[];
  for (final p in path.split(sep)) {
    if (p.isEmpty || p == '.') continue;
    if (p == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(p);
    }
  }
  return '$sep${parts.join(sep)}';
}
