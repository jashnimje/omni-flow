import 'dart:io';

import 'package:file_picker/file_picker.dart';

typedef PickedFile = ({String name, String path});

/// Files on the phone for the TV control centre: picking what to upload or
/// install, and where downloads go. The engine reads and writes these paths
/// itself, since it runs in the same app process.
abstract interface class PhoneFiles {
  /// Files the user picks, copied where the engine can read them. Empty
  /// when the user cancels.
  Future<List<PickedFile>> pick({List<String>? extensions});

  /// The folder downloads from the TV land in, or null when there is none.
  Future<String?> downloadsDir();

  /// Drops the copies [pick] made, once the engine has sent them.
  Future<void> cleanup();
}

/// For tests and platforms without a picker.
class NoPhoneFiles implements PhoneFiles {
  const NoPhoneFiles();

  @override
  Future<List<PickedFile>> pick({List<String>? extensions}) async => const [];

  @override
  Future<String?> downloadsDir() async => null;

  @override
  Future<void> cleanup() async {}
}

class PluginPhoneFiles implements PhoneFiles {
  const PluginPhoneFiles();

  /// Android 11 and later let an app create files in the shared Download
  /// folder by path without a storage permission, and they show in the
  /// Files app.
  static const downloads = '/storage/emulated/0/Download/OmniFlow';

  @override
  Future<List<PickedFile>> pick({List<String>? extensions}) async {
    final files = await FilePicker.pickFiles(
      type: extensions == null ? FileType.any : FileType.custom,
      allowedExtensions: extensions,
    );
    return [
      for (final f in files)
        if (f.path case final path?) (name: f.name, path: path),
    ];
  }

  @override
  Future<String?> downloadsDir() async {
    try {
      await Directory(downloads).create(recursive: true);
      return downloads;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> cleanup() => FilePicker.clearTemporaryFiles();
}
