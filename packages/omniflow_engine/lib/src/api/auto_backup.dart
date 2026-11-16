import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'mode_commands.dart' show HomeFile;

/// How many automatic backups are kept.
const autoBackupKeep = 14;

/// How long after one automatic backup the next is due.
const autoBackupEvery = Duration(days: 1);

final _backupName = RegExp(r'omniflow-\d{4}-\d{2}-\d{2}\.json$');

/// A daily `config.export` into the engine home's `backups/` folder, while
/// the hub runs, so a lost or reset phone does not lose the home. The
/// folder is 0700 and each file 0600, since a backup holds every place,
/// person and automation. The newest [autoBackupKeep] are kept, and the
/// app shows and shares the last one.
///
/// - `backup.auto.get`: whether it is on, the folder, the last backup and
///   the ones kept.
/// - `backup.auto.set {on?, now?}`: turns it on or off, and with
///   `now: true` writes one now.
class AutoBackup {
  AutoBackup(
    this._core,
    Directory home,
    this._file, {
    required this.export,
    bool Function()? hubRunning,
    this.every = const Duration(hours: 1),
  }) : folder = Directory('${home.absolute.path}/backups'),
       _hubRunning = hubRunning ?? (() => true);

  final EngineCore _core;
  final HomeFile _file;

  /// What `config.export` replies.
  final Future<Map<String, Object?>> Function() export;
  final bool Function() _hubRunning;

  /// Where the backups go.
  final Directory folder;

  /// How often it looks whether one is due.
  final Duration every;

  static const _key = 'autoBackup';

  var on = true;
  DateTime? lastAt;
  String? lastFile;
  String? lastError;
  Timer? _timer;
  Future<Map<String, Object?>>? _running;

  Map<String, CommandHandler> get commands => {
    'backup.auto.get': get,
    'backup.auto.set': set,
  };

  Future<void> open() async {
    final saved = (await _file.read())[_key];
    if (saved is Map) {
      on = saved['on'] != false;
      lastAt = DateTime.tryParse('${saved['lastAt']}');
      lastFile = saved['lastFile'] is String
          ? saved['lastFile'] as String
          : null;
      lastError = saved['lastError'] is String
          ? saved['lastError'] as String
          : null;
    }
    _timer = Timer.periodic(every, (_) => _core.track(tick(DateTime.now())));
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await _running;
  }

  /// Writes a backup when one is due at [now] and the hub runs.
  Future<void> tick(DateTime now) async {
    if (!on || !_hubRunning()) return;
    final last = lastAt;
    if (last != null && now.difference(last) < autoBackupEvery) return;
    try {
      await backup(now);
    } catch (_) {
      // backup kept the reason in lastError.
    }
  }

  /// One backup now, named by [now]'s date. A second call while one is
  /// being written waits for it.
  Future<Map<String, Object?>> backup(DateTime now) =>
      _running ??= _backup(now).whenComplete(() => _running = null);

  Future<Map<String, Object?>> _backup(DateTime now) async {
    try {
      final result = await export();
      final backup = result['backup'];
      if (backup is! Map) throw StateError('the export held no backup');
      await _privateFolder();
      final date = now.toIso8601String().substring(0, 10);
      final file = File('${folder.path}/omniflow-$date.json');
      final temp = File('${file.path}.$pid.tmp');
      await temp.writeAsString('');
      await _chmod('600', temp.path);
      await temp.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(backup)}\n',
        flush: true,
      );
      await temp.rename(file.path);
      final removed = <String>[];
      for (final old in _kept().skip(autoBackupKeep)) {
        await old.delete();
        removed.add(old.path);
      }
      lastAt = now;
      lastFile = file.path;
      lastError = null;
      await _save();
      _core.emit({'event': 'backup.done', 'file': file.path});
      return {'file': file.path, 'at': _iso(now), 'removed': removed};
    } catch (e) {
      lastError = e is ApiError ? e.message : '$e';
      await _save();
      _core.emit({'event': 'backup.failed', 'error': lastError});
      rethrow;
    }
  }

  /// The kept backups, newest first.
  List<File> _kept() {
    if (!folder.existsSync()) return const [];
    return [
      for (final f in folder.listSync().whereType<File>())
        if (_backupName.hasMatch(f.path)) f,
    ]..sort((a, b) => b.path.compareTo(a.path));
  }

  Future<void> _privateFolder() async {
    if (!await folder.exists()) await folder.create(recursive: true);
    if ((await folder.stat()).mode & 0x3f != 0) {
      await _chmod('700', folder.path);
    }
  }

  Future<void> _save() => _file.update({
    _key: {
      'on': on,
      'lastAt': ?lastAt?.toUtc().toIso8601String(),
      'lastFile': ?lastFile,
      'lastError': ?lastError,
    },
  });

  static String _iso(DateTime t) => t.toUtc().toIso8601String();

  /// What `engine.status` says of it.
  Map<String, Object?> statusJson() => {
    'autoBackup': on,
    'lastBackup': ?lastAt?.toUtc().toIso8601String(),
  };

  Future<Map<String, Object?>> get(Map<String, Object?> _) async => {
    'on': on,
    'keep': autoBackupKeep,
    'everyHours': autoBackupEvery.inHours,
    'folder': folder.path,
    'lastAt': ?lastAt?.toUtc().toIso8601String(),
    'lastFile': ?lastFile,
    'lastError': ?lastError,
    'backups': [
      for (final f in _kept()) {'file': f.path, 'bytes': f.lengthSync()},
    ],
  };

  /// `{on?, now?}`.
  Future<Map<String, Object?>> set(Map<String, Object?> args) async {
    for (final key in const ['on', 'now']) {
      if (args[key] != null && args[key] is! bool) {
        throw ApiError('invalid', '$key must be true or false');
      }
    }
    if (args['on'] case final bool value) {
      on = value;
      await _save();
    }
    Map<String, Object?>? written;
    if (args['now'] == true) {
      try {
        written = await backup(DateTime.now());
      } catch (_) {
        throw ApiError('unavailable', 'Could not write the backup: $lastError');
      }
    }
    return {...await get(const {}), 'written': ?written};
  }
}

Future<void> _chmod(String mode, String path) async {
  // Android keeps chmod in /system/bin.
  final chmod = File('/bin/chmod').existsSync()
      ? '/bin/chmod'
      : '/system/bin/chmod';
  final result = await Process.run(chmod, [mode, path]);
  if (result.exitCode != 0) {
    throw FileSystemException('cannot set mode $mode', path);
  }
}
