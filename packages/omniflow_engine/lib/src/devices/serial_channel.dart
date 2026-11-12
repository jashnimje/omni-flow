import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../template/template_renderer.dart';
import '../transports/host_exec.dart';
import '../transports/ndjson.dart';
import '../transports/packet_tap.dart';
import '../transports/udp_transport.dart';
import '../manifest/driver_manifest.dart';
import 'channels.dart';
import 'device.dart';

/// An unsolicited line from a board on a serial port.
class SerialEvent {
  const SerialEvent(this.deviceId, this.json);

  final String deviceId;
  final Map<String, Object?> json;
}

/// Where a port's outgoing bytes go.
abstract interface class SerialSink {
  /// Writes [bytes] and flushes them to the port.
  Future<void> write(List<int> bytes);

  /// Closes the sink. Must not wait on a write that never completes.
  Future<void> close();
}

/// Opens the [SerialSink] for a port path.
typedef SerialSinkOpener = Future<SerialSink> Function(String path);

/// One open serial port the platform provides: bytes in and out, the
/// modem lines and the speed. The phone's USB host ports are these.
abstract interface class SerialLink implements SerialSink {
  Stream<List<int>> get input;

  /// Sets DTR and RTS, which reset a board or put it in its bootloader.
  Future<void> setLines({bool? dtr, bool? rts});

  Future<void> setBaud(int baud);
}

/// Serial ports a platform opens itself, such as USB on a phone, where
/// there is no tty to run stty on. Their paths start with `usb:`.
abstract interface class SerialLinks {
  Future<List<String>> ports();

  Future<SerialLink> open(String path, int baud);
}

/// Whether [path] names a port [SerialLinks] opens.
bool isLinkPort(String path) => path.startsWith('usb:');

/// The OmniFlow MCU protocol over a serial port, for a board on USB.
///
/// The device's host is the port path (`/dev/cu.usbmodem1101`). The port is
/// set to raw mode with `stty` and then read and written as a file, which
/// needs no native library. Each command gets a request id and only the line
/// carrying that id is taken as its reply. Other lines go to [events].
class SerialChannel implements DriverChannel {
  SerialChannel({
    this._renderer = const TemplateRenderer(),
    this._tap,
    this._executor = const LocalExecutor(),
    this._openSink = _FileSink.open,
    this.links,
  });

  /// The platform's own ports (USB on a phone), when it has any.
  final SerialLinks? links;

  final TemplateRenderer _renderer;
  final PacketTap? _tap;
  final HostExecutor _executor;
  final SerialSinkOpener _openSink;
  final _ports = <String, _SerialPort>{};
  final _events = StreamController<SerialEvent>.broadcast();
  var _nextId = 0;

  Stream<SerialEvent> get events => _events.stream;

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    final rendered = _renderer.render(request.command, request.context);
    if (rendered is! Map) {
      throw ArgumentError('a serial command renders to an object');
    }
    final baud = request.manifest.transport.options['baud'] as int? ?? 115200;
    final reliability = request.manifest.reliability;
    final id = ++_nextId;
    final payload = {...rendered.cast<String, Object?>(), 'id': id};
    for (var attempt = 0; attempt <= reliability.retries; attempt++) {
      // A port dropped by a stuck write or a lost reader is opened again.
      final port = await _open(request.device, baud);
      try {
        final reply = await port.request(
          payload,
          id,
          Duration(milliseconds: reliability.timeoutMs),
        );
        if (reply['event'] == 'error') {
          throw CommandFailedException(
            '${request.device.id}: ${reply['message'] ?? 'error'}',
          );
        }
        return ChannelReply(reply);
      } on TimeoutException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    throw TransportTimeoutException(
      'no reply from ${request.device.id} on ${request.device.host}',
    );
  }

  /// Sends `describe` to every USB serial port and returns the boards that
  /// answer. A port that does not answer within [window] is skipped. A port
  /// a device holds is asked through that device's open port and stays open.
  Future<List<Map<String, Object?>>> discover(
    DriverManifest manifest, {
    Duration window = const Duration(milliseconds: 1500),
    Future<List<String>> Function()? ports,
  }) async {
    final found = <Map<String, Object?>>[];
    final paths = ports == null
        ? [...await usbSerialPorts(), ...?await links?.ports()]
        : await ports();
    for (final path in paths) {
      final probe = Device(
        id: '_probe_${path.hashCode}',
        name: path,
        driverId: manifest.id,
        host: path,
      );
      try {
        final reply = await send(
          ChannelRequest(
            device: probe,
            manifest: manifest,
            command: const {'cmd': 'describe'},
            context: const TemplateContext(),
          ),
        ).timeout(window);
        if (reply.json?['event'] == 'describe') {
          found.add({
            'host': path,
            if (reply.json!['node'] != null) 'stableId': reply.json!['node'],
            'reply': reply.json,
          });
        }
      } catch (_) {
        // Not a board speaking the protocol, or busy: skip it.
      } finally {
        await _ports.remove(probe.id)?.close();
      }
    }
    return found;
  }

  /// Closes the port held for [deviceId], if any.
  Future<void> release(String deviceId) async =>
      _ports.remove(deviceId)?.close();

  /// Ports a flasher has: nothing else opens them until it is done.
  final _flashing = <String>{};

  /// Closes every port held on [path] and keeps it for [work] alone, so no
  /// poll or command reopens it in the middle of a flash.
  Future<T> exclusive<T>(String path, Future<T> Function() work) async {
    if (!_flashing.add(path)) {
      throw TransportTimeoutException('$path is being flashed already');
    }
    try {
      for (final id in _ports.keys.toList()) {
        if (_ports[id]!.path == path) await _ports.remove(id)!.close();
      }
      return await work();
    } finally {
      _flashing.remove(path);
    }
  }

  /// Two readers on one tty split its bytes between them, so a port that is
  /// already open is shared rather than opened again: by discovery, or by a
  /// second device with the same path.
  Future<_SerialPort> _open(Device device, int baud) async {
    final existing = _ports[device.id];
    if (existing != null && existing.path == device.host && !existing.closed) {
      return existing;
    }
    await existing?.close();
    _ports.remove(device.id);
    final held = _ports.values
        .where((p) => p.path == device.host && !p.closed)
        .firstOrNull;
    if (held != null) return held;
    if (_flashing.contains(device.host)) {
      throw TransportTimeoutException(
        '${device.host} is being flashed: try again when it is done',
      );
    }
    final linked = links;
    if (isLinkPort(device.host)) {
      if (linked == null) {
        throw TransportTimeoutException(
          '${device.host} is a USB port of another device',
        );
      }
      final opening = linked.open(device.host, baud);
      final SerialLink link;
      try {
        link = await opening.timeout(_openTimeout);
      } on TimeoutException {
        // A link that opens after all would hold the port forever.
        unawaited(opening.then((late) => late.close(), onError: (_) {}));
        throw TransportTimeoutException('${device.host} did not open');
      }
      final port = _SerialPort.fromStream(device.host, link, link.input, _tap, (
        json,
      ) {
        if (!_events.isClosed) _events.add(SerialEvent(device.id, json));
      });
      _ports[device.id] = port;
      return port;
    }
    if (!await File(device.host).exists()) {
      throw TransportTimeoutException(
        'serial port ${device.host} is not present',
      );
    }
    // The write descriptor is opened first and held while stty runs. macOS
    // puts a tty back to its defaults when its last descriptor closes, so
    // settings made with nothing open are lost. -hupcl keeps DTR up when the
    // port closes, so the next open does not reset an Uno or a CH340 board.
    final opening = _openSink(device.host);
    final SerialSink sink;
    try {
      sink = await opening.timeout(_openTimeout);
    } on TimeoutException {
      unawaited(opening.then((orphan) => orphan.close(), onError: (_) {}));
      throw TransportTimeoutException(
        'serial port ${device.host} did not open',
      );
    }
    try {
      final configured = await _executor.run(
        sttyArgv(device.host, baud),
        timeout: _openTimeout,
      );
      if (!configured.succeeded) {
        throw CommandFailedException(
          'cannot configure ${device.host}: ${configured.stderr}',
        );
      }
    } catch (_) {
      await sink.close();
      rethrow;
    }
    final port = await _SerialPort.open(device, sink, _tap, (json) {
      if (!_events.isClosed) _events.add(SerialEvent(device.id, json));
    });
    _ports[device.id] = port;
    return port;
  }

  static const _openTimeout = Duration(seconds: 5);

  /// The stty call that sets [path] to [baud], raw, no echo and no hang-up
  /// on close.
  static List<String> sttyArgv(String path, int baud) => [
    '/bin/stty',
    Platform.isMacOS ? '-f' : '-F',
    path,
    '$baud',
    'raw',
    '-echo',
    '-hupcl',
  ];

  Future<void> close() async {
    for (final p in _ports.values) {
      await p.close();
    }
    _ports.clear();
    await _events.close();
  }
}

class _SerialPort {
  _SerialPort._(
    this.path,
    this._writer,
    this._reader,
    this._onEvent,
    this._tap,
  );

  /// A port whose bytes come from a platform stream, not a cat process.
  static _SerialPort fromStream(
    String path,
    SerialSink writer,
    Stream<List<int>> input,
    PacketTap? tap,
    void Function(Map<String, Object?>) onEvent,
  ) {
    final port = _SerialPort._(path, writer, null, onEvent, tap);
    port._subscription = input
        .transform(const NdjsonDecoder())
        .listen(port._onLine, onError: (_) => port.close(), onDone: port.close);
    return port;
  }

  static Future<_SerialPort> open(
    Device device,
    SerialSink writer,
    PacketTap? tap,
    void Function(Map<String, Object?>) onEvent,
  ) async {
    // Reads go through cat so closing the port is a kill. A read on the tty
    // itself blocks until the board sends a line, which would hang shutdown.
    final Process reader;
    try {
      reader = await Process.start('/bin/cat', [device.host]);
    } catch (_) {
      await writer.close();
      rethrow;
    }
    final port = _SerialPort._(device.host, writer, reader, onEvent, tap);
    port._subscription = reader.stdout
        .transform(const NdjsonDecoder())
        .listen(port._onLine, onError: (_) => port.close(), onDone: port.close);
    return port;
  }

  final String path;
  final SerialSink _writer;
  final Process? _reader;
  final void Function(Map<String, Object?>) _onEvent;
  final PacketTap? _tap;
  StreamSubscription<NdjsonLine>? _subscription;
  final _waiting = <int, Completer<Map<String, Object?>>>{};
  var closed = false;

  Future<Map<String, Object?>> request(
    Map<String, Object?> payload,
    int id,
    Duration timeout,
  ) async {
    if (closed) throw const FileSystemException('serial port closed');
    final waiter = _waiting.putIfAbsent(id, Completer.new);
    final bytes = Uint8List.fromList(encodeNdjson(payload));
    // A Wi-Fi password never reaches the packet inspector.
    final shown = payload.containsKey('password')
        ? Uint8List.fromList(encodeNdjson({...payload, 'password': '***'}))
        : bytes;
    _tap?.record(
      CapturedPacket(
        transport: 'serial',
        direction: PacketDirection.outgoing,
        remote: path,
        bytes: shown,
      ),
    );
    final clock = Stopwatch()..start();
    try {
      await _writer.write(bytes).timeout(timeout);
    } on TimeoutException {
      // A port that cannot take one line within the reply timeout is stuck
      // (flow control held, a wedged adapter). Drop it so the next attempt
      // opens it again rather than queueing behind the stuck write.
      _waiting.remove(id);
      unawaited(close());
      rethrow;
    }
    final left = timeout - clock.elapsed;
    try {
      return await waiter.future.timeout(
        left.isNegative ? Duration.zero : left,
      );
    } finally {
      if (waiter.isCompleted) _waiting.remove(id);
    }
  }

  void _onLine(NdjsonLine line) {
    _tap?.record(
      CapturedPacket(
        transport: 'serial',
        direction: PacketDirection.incoming,
        remote: path,
        bytes: utf8.encode(line.raw),
      ),
    );
    final json = line.json;
    if (json == null) return;
    final id = json['id'];
    final waiter = id is int ? _waiting.remove(id) : null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(json);
    } else {
      _onEvent(json);
    }
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    // The line decoder ends only when its input does: the cat process is
    // killed, or a platform link is closed first, which ends its stream.
    final reader = _reader;
    if (reader != null) {
      reader.kill();
      await _subscription?.cancel();
      await _writer.close();
    } else {
      await _writer.close();
      _subscription?.cancel().ignore();
    }
    for (final w in _waiting.values) {
      if (!w.isCompleted) {
        w.completeError(const FileSystemException('serial port closed'));
      }
    }
    _waiting.clear();
  }
}

/// The tty opened for writing.
class _FileSink implements SerialSink {
  _FileSink(this._file);

  static Future<SerialSink> open(String path) async =>
      _FileSink(await File(path).open(mode: FileMode.writeOnly));

  final RandomAccessFile _file;
  Future<void>? _pending;
  var _closed = false;

  @override
  Future<void> write(List<int> bytes) {
    if (_closed) {
      return Future.error(const FileSystemException('serial port closed'));
    }
    final write = () async {
      await _file.writeFrom(bytes);
      await _file.flush();
    }();
    _pending = write;
    return write.whenComplete(() {
      if (identical(_pending, write)) _pending = null;
    });
  }

  /// A RandomAccessFile refuses close while an operation is pending, and a
  /// write blocked in the kernel never returns, so a pending write closes
  /// the file when it finishes instead.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final pending = _pending;
    if (pending != null) {
      unawaited(
        pending.then((_) => _file.close(), onError: (_) => _file.close()),
      );
      return;
    }
    await _file.close();
  }
}

/// USB serial ports a board shows up as: `/dev/cu.usbmodem*` and
/// `/dev/cu.usbserial*` on macOS, `/dev/ttyACM*` and `/dev/ttyUSB*` on Linux.
///
/// An Android app may not list /dev, and USB boards reach the phone through
/// the USB host API instead, so there it finds none.
Future<List<String>> usbSerialPorts() async {
  if (Platform.isAndroid) return const [];
  final patterns = Platform.isMacOS
      ? ['cu.usbmodem', 'cu.usbserial']
      : ['ttyACM', 'ttyUSB'];
  final dev = Directory('/dev');
  if (!await dev.exists()) return const [];
  try {
    return [
      await for (final entry in dev.list())
        if (patterns.any(entry.path.split('/').last.startsWith)) entry.path,
    ]..sort();
  } on FileSystemException {
    return const [];
  }
}
