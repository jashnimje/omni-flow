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
  });

  final TemplateRenderer _renderer;
  final PacketTap? _tap;
  final HostExecutor _executor;
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
    final port = await _open(
      request.device,
      request.manifest.transport.options['baud'] as int? ?? 115200,
    );
    final reliability = request.manifest.reliability;
    final id = ++_nextId;
    final payload = {...rendered.cast<String, Object?>(), 'id': id};
    for (var attempt = 0; attempt <= reliability.retries; attempt++) {
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
    for (final path in await (ports ?? usbSerialPorts)()) {
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
    if (!await File(device.host).exists()) {
      throw TransportTimeoutException(
        'serial port ${device.host} is not present',
      );
    }
    final stty = Platform.isMacOS
        ? ['/bin/stty', '-f', device.host, '$baud', 'raw', '-echo']
        : ['/bin/stty', '-F', device.host, '$baud', 'raw', '-echo'];
    final configured = await _executor.run(
      stty,
      timeout: const Duration(seconds: 5),
    );
    if (!configured.succeeded) {
      throw CommandFailedException(
        'cannot configure ${device.host}: ${configured.stderr}',
      );
    }
    final port = await _SerialPort.open(device, _tap, (json) {
      if (!_events.isClosed) _events.add(SerialEvent(device.id, json));
    });
    _ports[device.id] = port;
    return port;
  }

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

  static Future<_SerialPort> open(
    Device device,
    PacketTap? tap,
    void Function(Map<String, Object?>) onEvent,
  ) async {
    final writer = await File(device.host).open(mode: FileMode.writeOnly);
    // Reads go through cat so closing the port is a kill. A read on the tty
    // itself blocks until the board sends a line, which would hang shutdown.
    final reader = await Process.start('/bin/cat', [device.host]);
    final port = _SerialPort._(device.host, writer, reader, onEvent, tap);
    port._subscription = reader.stdout
        .transform(const NdjsonDecoder())
        .listen(port._onLine, onError: (_) => port.close(), onDone: port.close);
    return port;
  }

  final String path;
  final RandomAccessFile _writer;
  final Process _reader;
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
    await _writer.writeFrom(bytes);
    await _writer.flush();
    try {
      return await waiter.future.timeout(timeout);
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
    _reader.kill();
    await _subscription?.cancel();
    await _writer.close();
    for (final w in _waiting.values) {
      if (!w.isCompleted) {
        w.completeError(const FileSystemException('serial port closed'));
      }
    }
    _waiting.clear();
  }
}

/// USB serial ports a board shows up as: `/dev/cu.usbmodem*` and
/// `/dev/cu.usbserial*` on macOS, `/dev/ttyACM*` and `/dev/ttyUSB*` on Linux.
Future<List<String>> usbSerialPorts() async {
  final patterns = Platform.isMacOS
      ? ['cu.usbmodem', 'cu.usbserial']
      : ['ttyACM', 'ttyUSB'];
  final dev = Directory('/dev');
  if (!await dev.exists()) return const [];
  return [
    await for (final entry in dev.list())
      if (patterns.any(entry.path.split('/').last.startsWith)) entry.path,
  ]..sort();
}
