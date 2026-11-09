import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'adb_connection.dart';

/// The largest DATA chunk in the sync protocol, both ways.
const adbSyncMaxChunk = 64 * 1024;

/// adbd refuses longer paths.
const adbSyncMaxPath = 1024;

const _sIfMt = 0xf000;
const _sIfDir = 0x4000;
const _sIfReg = 0x8000;
const _sIfLnk = 0xa000;

/// Regular file, rw-r--r--, as `adb push` sends a new file.
const adbDefaultFileMode = _sIfReg | 0x1a4;

/// The device refused a sync request, with its reason.
class AdbSyncException implements Exception {
  AdbSyncException(this.message);

  final String message;

  @override
  String toString() => 'AdbSyncException: $message';
}

/// One file as STAT or LIST report it. Legacy sync reports 32-bit sizes and
/// does not follow a symbolic link it is asked about.
class AdbSyncEntry {
  const AdbSyncEntry(this.name, this.mode, this.size, this.mtime);

  final String name;
  final int mode;
  final int size;

  /// Seconds since the epoch.
  final int mtime;

  String get type => switch (mode & _sIfMt) {
    _sIfDir => 'dir',
    _sIfLnk => 'link',
    _sIfReg => 'file',
    _ => 'other',
  };

  bool get isDirectory => mode & _sIfMt == _sIfDir;

  /// The permission bits, as `ls -l` shows them: `rwxr-x---`.
  String get permissions {
    const letters = 'rwxrwxrwx';
    return [
      for (var i = 0; i < 9; i++) mode & (1 << (8 - i)) != 0 ? letters[i] : '-',
    ].join();
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'type': type,
    'size': size,
    'mode': permissions,
    'modified': DateTime.fromMillisecondsSinceEpoch(
      mtime * 1000,
      isUtc: true,
    ).toIso8601String(),
  };
}

/// Bytes moved so far in a transfer, of [total] when it is known.
typedef AdbSyncProgress = void Function(int done, int? total);

/// The ADB sync service (`sync:`) on one stream: STAT, LIST, RECV and SEND,
/// then QUIT. One request runs at a time.
class AdbSync {
  AdbSync(this._stream, {this._timeout = const Duration(seconds: 30)});

  static Future<AdbSync> open(
    AdbConnection connection, {
    Duration timeout = const Duration(seconds: 30),
  }) async => AdbSync(await connection.openStream('sync:'), timeout: timeout);

  final AdbStream _stream;

  /// How long the device may stay silent in the middle of a request.
  final Duration _timeout;

  Future<void> _request(String id, List<int> payload) => _stream.write([
    ...ascii.encode(id),
    ..._le32(payload.length),
    ...payload,
  ], timeout: _timeout);

  Future<Uint8List> _read(int n) => _stream.read(n, timeout: _timeout);

  Future<(String, int)> _header() async {
    final h = await _read(8);
    return (ascii.decode(h.sublist(0, 4), allowInvalid: true), _u32(h, 4));
  }

  static List<int> _pathBytes(String path) {
    final bytes = utf8.encode(path);
    if (bytes.length > adbSyncMaxPath) {
      throw ArgumentError('the path is longer than $adbSyncMaxPath bytes');
    }
    return bytes;
  }

  /// The file at [path], or null when there is none.
  Future<AdbSyncEntry?> stat(String path) async {
    await _request('STAT', _pathBytes(path));
    final reply = await _read(16);
    final id = ascii.decode(reply.sublist(0, 4), allowInvalid: true);
    if (id != 'STAT') throw AdbSyncException('unexpected $id reply to STAT');
    final mode = _u32(reply, 4);
    final size = _u32(reply, 8);
    final mtime = _u32(reply, 12);
    if (mode == 0 && size == 0 && mtime == 0) return null;
    return AdbSyncEntry(_baseName(path), mode, size, mtime);
  }

  /// The entries of the directory [path], without `.` and `..`. A path
  /// that is no directory lists nothing.
  Future<List<AdbSyncEntry>> list(String path) async {
    await _request('LIST', _pathBytes(path));
    final out = <AdbSyncEntry>[];
    while (true) {
      final head = await _read(20);
      final id = ascii.decode(head.sublist(0, 4), allowInvalid: true);
      if (id == 'DONE') return out;
      if (id != 'DENT') throw AdbSyncException('unexpected $id in LIST');
      final name = utf8.decode(
        await _read(_u32(head, 16)),
        allowMalformed: true,
      );
      if (name == '.' || name == '..') continue;
      out.add(AdbSyncEntry(name, _u32(head, 4), _u32(head, 8), _u32(head, 12)));
    }
  }

  /// Copies the device file [path] into [sink] and returns its length.
  Future<int> pull(
    String path,
    Future<void> Function(Uint8List chunk) sink, {
    int? total,
    AdbSyncProgress? onProgress,
  }) async {
    await _request('RECV', _pathBytes(path));
    var done = 0;
    while (true) {
      final (id, length) = await _header();
      switch (id) {
        case 'DATA':
          if (length > adbSyncMaxChunk) {
            throw AdbSyncException('a $length-byte chunk is too large');
          }
          await sink(await _read(length));
          done += length;
          onProgress?.call(done, total);
        case 'DONE':
          return done;
        case 'FAIL':
          throw AdbSyncException(await _failure(length));
        default:
          throw AdbSyncException('unexpected $id in RECV');
      }
    }
  }

  /// Writes [file] to the device as [path] with [mode], keeping its
  /// modification time. adbd creates missing parent directories.
  Future<void> push(
    File file,
    String path, {
    int mode = adbDefaultFileMode,
    AdbSyncProgress? onProgress,
  }) async {
    final total = await file.length();
    final mtime = (await file.lastModified()).millisecondsSinceEpoch ~/ 1000;
    await _request('SEND', [..._pathBytes(path), ...ascii.encode(',$mode')]);
    final raf = await file.open();
    try {
      var done = 0;
      while (true) {
        final chunk = await raf.read(adbSyncMaxChunk);
        if (chunk.isEmpty) break;
        await _stream.write([
          ...ascii.encode('DATA'),
          ..._le32(chunk.length),
          ...chunk,
        ], timeout: _timeout);
        done += chunk.length;
        onProgress?.call(done, total);
      }
    } finally {
      await raf.close();
    }
    await _stream.write([
      ...ascii.encode('DONE'),
      ..._le32(mtime),
    ], timeout: _timeout);
    final (id, length) = await _header();
    if (id == 'OKAY') return;
    if (id == 'FAIL') throw AdbSyncException(await _failure(length));
    throw AdbSyncException('unexpected $id after SEND');
  }

  Future<String> _failure(int length) async =>
      utf8.decode(await _read(length.clamp(0, 4096)), allowMalformed: true);

  /// Ends the session and the stream.
  Future<void> quit() async {
    if (_stream.isDone) return;
    try {
      await _request('QUIT', const []);
    } on Object {
      // The stream closes either way.
    }
    _stream.close();
  }

  /// Closes the stream without QUIT, after a request failed half way.
  void abort() => _stream.close();
}

String _baseName(String path) {
  final trimmed = path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

List<int> _le32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

int _u32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);
