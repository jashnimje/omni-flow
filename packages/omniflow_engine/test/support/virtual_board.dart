import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The real board firmware core, built natively from
/// `firmware/omniflow_node/` with simulated pins (`host/host_board.cpp`).
/// Tests talk to it exactly as to a board: over a pseudo-terminal like USB
/// serial, or over loopback UDP like Wi-Fi.
class VirtualBoard {
  VirtualBoard._(this._process, {this.udpPort, this.tty});

  final Process _process;
  final int? udpPort;
  final String? tty;

  static String? _binary;

  static const _flags = ['-std=c++11', '-O1', '-Wall', '-Wextra', '-Werror'];

  /// Builds the virtual board, with the warning flags `check.sh` uses.
  /// Returns null when no C++ compiler is available, so callers can skip.
  ///
  /// The binary is named after a hash of the firmware sources and flags, so
  /// test isolates and runs share one build and a source change rebuilds.
  /// Each build writes a temporary name and renames it into place, so two
  /// isolates building at once never run a half-written file.
  static Future<String?> build() async {
    if (_binary != null) return _binary;
    final firmware = Directory('../../firmware/omniflow_node').absolute;
    final sources = [
      for (final entity in firmware.listSync(recursive: true))
        if (entity is File && RegExp(r'\.(cpp|h)$').hasMatch(entity.path))
          entity,
    ]..sort((a, b) => a.path.compareTo(b.path));
    var hash = 0xcbf29ce484222325;
    for (final bytes in [
      utf8.encode(_flags.join(' ')),
      for (final f in sources) ...[utf8.encode(f.path), f.readAsBytesSync()],
    ]) {
      for (final b in bytes) {
        hash = (hash ^ b) * 0x100000001b3;
      }
    }
    final name = [
      hash >>> 32,
      hash & 0xFFFFFFFF,
    ].map((h) => h.toRadixString(16).padLeft(8, '0')).join();
    final out = '${Directory.systemTemp.path}/omniflow_host_board_$name';
    if (File(out).existsSync()) return _binary = out;
    final scratch = Directory.systemTemp.createTempSync('omniflow_board');
    try {
      final built = '${scratch.path}/host_board';
      final result = await Process.run('c++', [
        ..._flags,
        '-o',
        built,
        '${firmware.path}/host/host_board.cpp',
        '${firmware.path}/omni_core.cpp',
      ]);
      if (result.exitCode != 0) {
        stderr.writeln('host_board build failed: ${result.stderr}');
        return null;
      }
      File(built).renameSync(out);
    } finally {
      scratch.deleteSync(recursive: true);
    }
    return _binary = out;
  }

  /// A free loopback UDP port.
  static Future<int> freePort() async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    s.close();
    return port;
  }

  /// Starts a board. With [pty] it is reachable at [tty]; with [udp] at
  /// 127.0.0.1:[udpPort]. [helloTo] is where its hello broadcasts go.
  static Future<VirtualBoard> start({
    String node = 'virtual_board',
    bool pty = false,
    bool udp = false,
    int? udpPort,
    int? helloTo,
    int helloEveryMs = 300,
  }) async {
    final binary = (await build())!;
    // A port picked here can be taken by a parallel test before the board
    // binds it; the board then exits at once, so start again on a new port.
    for (var attempt = 1; ; attempt++) {
      try {
        return await _startOnce(
          binary,
          node: node,
          pty: pty,
          port: udp ? (udpPort ?? await freePort()) : null,
          helloTo: helloTo,
          helloEveryMs: helloEveryMs,
        );
      } on StateError {
        if (!udp || udpPort != null || attempt == 3) rethrow;
      }
    }
  }

  static Future<VirtualBoard> _startOnce(
    String binary, {
    required String node,
    required bool pty,
    required int? port,
    required int? helloTo,
    required int helloEveryMs,
  }) async {
    final process = await Process.start(binary, [
      '--node',
      node,
      if (pty) '--pty',
      if (port != null) ...['--udp', '$port'],
      if (helloTo != null) ...['--hello-to', '$helloTo'],
      '--hello-every',
      '$helloEveryMs',
    ]);
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    // The first line is the pty path, or the boot line, which the board
    // prints after its UDP socket is bound.
    final String first;
    try {
      first = (await lines.first.timeout(const Duration(seconds: 5))).trim();
    } on StateError {
      process.kill();
      rethrow;
    }
    final tty = pty ? first : null;
    lines.listen((_) {});
    process.stderr.drain<void>();
    return VirtualBoard._(process, udpPort: port, tty: tty);
  }

  Future<void> stop() async {
    await _process.stdin.close();
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );
  }
}
