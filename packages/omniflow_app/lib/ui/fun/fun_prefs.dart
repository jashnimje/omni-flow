import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Whether celebrations show, kept on this phone only: it is how the app
/// looks, not part of the home, so it is not in the backup.
abstract interface class FunPrefsStore {
  Future<bool?> readCelebrations();
  Future<void> writeCelebrations(bool on);
}

class FileFunPrefsStore implements FunPrefsStore {
  const FileFunPrefsStore();

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/fun_prefs.json');

  @override
  Future<bool?> readCelebrations() async {
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      return json is Map && json['celebrations'] is bool
          ? json['celebrations'] as bool
          : null;
    } on Object {
      // Never set, damaged, or no storage here (tests): the default.
      return null;
    }
  }

  @override
  Future<void> writeCelebrations(bool on) async {
    try {
      await (await _file()).writeAsString(jsonEncode({'celebrations': on}));
    } on Object {
      // Kept for this session only: harmless.
    }
  }
}

/// Holds a choice in memory, for tests.
class MemoryFunPrefsStore implements FunPrefsStore {
  MemoryFunPrefsStore([this.celebrations]);

  bool? celebrations;

  @override
  Future<bool?> readCelebrations() async => celebrations;

  @override
  Future<void> writeCelebrations(bool on) async => celebrations = on;
}

final funPrefsStoreProvider = Provider<FunPrefsStore>(
  (ref) => const FileFunPrefsStore(),
);

/// Celebrations are on until the user turns them off.
class CelebrationsNotifier extends Notifier<bool> {
  late Future<void> _loaded;

  @override
  bool build() {
    _loaded = ref.read(funPrefsStoreProvider).readCelebrations().then((on) {
      if (on != null && ref.mounted) state = on;
    });
    return true;
  }

  /// The choice once the stored one is read.
  Future<bool> isOn() async {
    await _loaded;
    return state;
  }

  Future<void> set(bool on) async {
    state = on;
    await ref.read(funPrefsStoreProvider).writeCelebrations(on);
  }
}

final celebrationsProvider = NotifierProvider<CelebrationsNotifier, bool>(
  CelebrationsNotifier.new,
);
