import 'dart:async';

import 'package:flutter/services.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

import '../api/engine_calls.dart' show Json;

/// One tag the phone read: its UID as upper-case hex and its NDEF records.
class NfcScan {
  const NfcScan(this.uid, this.ndef);

  final String uid;

  /// Each record as `{tnf, type, payload}`, the type name format's number
  /// with the type and payload in hex.
  final List<Json> ndef;
}

/// What to write on a tag, as `tag.write_payload` gives it: the link it
/// carries and the records to write, in order, each `{tnf, type, payload}`
/// with the type name format's number and the type and payload in hex. The
/// engine owns the record layout, and the app writes these bytes as given.
typedef TagPayload = ({String uri, List<Json> records});

/// The phone's NFC reader, while the app is open.
abstract interface class NfcAdapter {
  Future<bool> isAvailable();

  /// Reports every tag held to the phone until [stop].
  Future<void> startReading(void Function(NfcScan scan) onScan);

  /// Writes [payload] to the next tag held to the phone instead of reading
  /// it, and completes with that tag. Throws [NfcWriteError] when the tag
  /// cannot take it.
  Future<NfcScan> writeNext(TagPayload payload);

  /// Gives up a write still waiting for a tag.
  void cancelWrite();

  Future<void> stop();
}

class NfcWriteError implements Exception {
  const NfcWriteError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A phone without NFC, and the default outside the Android app.
class NoNfc implements NfcAdapter {
  const NoNfc();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<void> startReading(void Function(NfcScan scan) onScan) async {}

  @override
  Future<NfcScan> writeNext(TagPayload payload) =>
      Future.error(const NfcWriteError('This phone has no NFC'));

  @override
  void cancelWrite() {}

  @override
  Future<void> stop() async {}
}

/// NFC through the nfc_manager plugin, in Android reader mode. Reader mode
/// also stops Android dispatching the tag as an intent while the app is in
/// front, so a scan reaches the engine once.
class PluginNfcAdapter implements NfcAdapter {
  PluginNfcAdapter([NfcManager? manager]) : _given = manager;

  final NfcManager? _given;
  NfcManager get _manager => _given ?? NfcManager.instance;
  void Function(NfcScan scan)? _onScan;
  ({TagPayload payload, Completer<NfcScan> done})? _write;
  var _running = false;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _manager.checkAvailability() == NfcAvailability.enabled;
    } on Object {
      return false;
    }
  }

  Future<void> _start() async {
    if (_running) return;
    try {
      await _manager.startSession(
        pollingOptions: NfcPollingOption.values.toSet(),
        onDiscovered: _discovered,
      );
      _running = true;
    } on Object {
      _running = false;
    }
  }

  @override
  Future<void> startReading(void Function(NfcScan scan) onScan) async {
    _onScan = onScan;
    if (await isAvailable()) await _start();
  }

  @override
  Future<NfcScan> writeNext(TagPayload payload) async {
    if (!await isAvailable()) {
      throw const NfcWriteError('NFC is off or this phone has none');
    }
    cancelWrite();
    final done = Completer<NfcScan>();
    _write = (payload: payload, done: done);
    await _start();
    return done.future;
  }

  @override
  void cancelWrite() {
    final write = _write;
    _write = null;
    if (write != null && !write.done.isCompleted) {
      write.done.completeError(const NfcWriteError('Cancelled'));
    }
  }

  @override
  Future<void> stop() async {
    _onScan = null;
    cancelWrite();
    if (!_running) return;
    _running = false;
    try {
      await _manager.stopSession();
    } on Object {
      return;
    }
  }

  Future<void> _discovered(NfcTag tag) async {
    final android = NfcTagAndroid.from(tag);
    if (android == null) return;
    final uid = hexOf(android.id);
    final ndef = NdefAndroid.from(tag);
    if (_write case final write?) {
      _write = null;
      try {
        final message = tagMessage(write.payload);
        await _writeTo(tag, ndef, message);
        write.done.complete(NfcScan(uid, recordsJson(message.records)));
      } on Object catch (e) {
        write.done.completeError(
          e is NfcWriteError ? e : NfcWriteError('Writing failed: $e'),
        );
      }
      return;
    }
    final records = ndef?.cachedNdefMessage?.records ?? const <NdefRecord>[];
    _onScan?.call(NfcScan(uid, recordsJson(records)));
  }

  static Future<void> _writeTo(
    NfcTag tag,
    NdefAndroid? ndef,
    NdefMessage message,
  ) async {
    if (ndef != null) {
      if (!ndef.isWritable) throw const NfcWriteError('This tag is locked');
      if (message.byteLength > ndef.maxSize) {
        throw NfcWriteError(
          'This tag holds ${ndef.maxSize} bytes and the link needs '
          '${message.byteLength}',
        );
      }
      await ndef.writeNdefMessage(message);
      return;
    }
    final blank = NdefFormatableAndroid.from(tag);
    if (blank == null) {
      throw const NfcWriteError('This tag cannot hold a link');
    }
    await blank.format(message);
  }
}

/// [payload]'s records as an NDEF message. Throws [NfcWriteError] when a
/// record is not a type name format number with hex type and payload.
NdefMessage tagMessage(TagPayload payload) {
  if (payload.records.isEmpty) {
    throw const NfcWriteError('OmniFlow sent no records to write');
  }
  return NdefMessage(
    records: [
      for (final r in payload.records)
        if (r
            case {
              'tnf': final int tnf,
              'type': final String type,
              'payload': final String body,
            }
            when tnf >= 0 && tnf < TypeNameFormat.values.length)
          NdefRecord(
            typeNameFormat: TypeNameFormat.values[tnf],
            type: _bytesOf(type),
            identifier: Uint8List(0),
            payload: _bytesOf(body),
          )
        else
          throw NfcWriteError(
            'OmniFlow sent a record this app cannot write: $r',
          ),
    ],
  );
}

Uint8List _bytesOf(String hex) {
  if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
    throw NfcWriteError('$hex is not hex');
  }
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

String hexOf(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')]
        .join()
        .toUpperCase();

List<Json> recordsJson(List<NdefRecord> records) => [
  for (final r in records)
    recordJson(r.typeNameFormat.index, r.type, r.payload),
];

/// One record as the engine takes it: [tnf] is the type name format's
/// number, which Android's `NdefRecord.TNF_*` and [TypeNameFormat] share,
/// and the type and payload go as hex. The engine decodes URI and text
/// records itself.
Json recordJson(int tnf, List<int> type, List<int> payload) => {
  'tnf': tnf,
  'type': hexOf(type),
  'payload': hexOf(payload),
};

/// Tags Android hands to the app as an intent: the `omniflow://tag/`
/// filter opens the app for one even when it was closed.
abstract interface class NfcIntents {
  /// The scan that opened the app, once, or null.
  Future<NfcScan?> takeLaunchScan();

  /// Scans Android delivers while the app runs but is not reading.
  Stream<NfcScan> get scans;
}

class NoNfcIntents implements NfcIntents {
  const NoNfcIntents();

  @override
  Future<NfcScan?> takeLaunchScan() async => null;

  @override
  Stream<NfcScan> get scans => const Stream.empty();
}

/// MainActivity's `omniflow/nfc_intent` channel. Each scan is
/// `{uid: bytes, live: true, records: [{tnf: int, type: bytes, payload:
/// bytes}]}`.
class PlatformNfcIntents implements NfcIntents {
  PlatformNfcIntents([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'scanned') return;
      final scan = scanFromPlatform(call.arguments);
      if (scan == null) return;
      _scans.hasListener ? _scans.add(scan) : _waiting.add(scan);
    });
  }

  static const channelName = 'omniflow/nfc_intent';

  final MethodChannel _channel;

  /// Scans that arrived while the app was still connecting to the engine,
  /// before anything listened.
  final _waiting = <NfcScan>[];
  late final StreamController<NfcScan> _scans = StreamController.broadcast(
    onListen: () {
      final waiting = [..._waiting];
      _waiting.clear();
      waiting.forEach(_scans.add);
    },
  );

  @override
  Future<NfcScan?> takeLaunchScan() async {
    try {
      return scanFromPlatform(await _channel.invokeMethod<Object?>('take'));
    } on Object {
      return null;
    }
  }

  @override
  Stream<NfcScan> get scans => _scans.stream;
}

/// Any app can start MainActivity with an NDEF intent and made-up extras,
/// so only a scan MainActivity read again from the tag itself (`live`) is
/// taken.
NfcScan? scanFromPlatform(Object? data) {
  if (data is! Map || data['live'] != true) return null;
  final uid = data['uid'];
  if (uid is! List<int> || uid.isEmpty) return null;
  return NfcScan(hexOf(uid), [
    for (final r in (data['records'] as List? ?? const []))
      if (r case {
        'tnf': final int tnf,
        'type': final List<int> type,
        'payload': final List<int> payload,
      })
        recordJson(tnf, type, payload),
  ]);
}
