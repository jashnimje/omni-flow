import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

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

  /// Off Android: the user's Downloads folder on the desktop, and the
  /// app's own documents on iOS, which the Files app shows.
  @override
  Future<String?> downloadsDir() async {
    try {
      final path = Platform.isAndroid
          ? downloads
          : Platform.isIOS
          ? '${(await getApplicationDocumentsDirectory()).path}/OmniFlow'
          : switch (await getDownloadsDirectory()) {
              final dir? => '${dir.path}/OmniFlow',
              null => null,
            };
      if (path == null) return null;
      await Directory(path).create(recursive: true);
      return path;
    } on FileSystemException {
      return null;
    } on UnsupportedError {
      return null;
    }
  }

  @override
  Future<void> cleanup() => FilePicker.clearTemporaryFiles();
}
