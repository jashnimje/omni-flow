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

  /// Builds the virtual board once per test run. Returns null when no C++
  /// compiler is available, so callers can skip.
  static Future<String?> build() async {
    if (_binary != null) return _binary;
    final firmware = Directory('../../firmware/omniflow_node').absolute.path;
    final out = '${Directory.systemTemp.path}/omniflow_host_board_$pid';
    final result = await Process.run('c++', [
      '-std=c++11',
      '-O1',
      '-o',
      out,
      '$firmware/host/host_board.cpp',
      '$firmware/omni_core.cpp',
    ]);
    if (result.exitCode != 0) {
      stderr.writeln('host_board build failed: ${result.stderr}');
      return null;
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
    final port = udp ? (udpPort ?? await freePort()) : null;
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
    final first = (await lines.first.timeout(const Duration(seconds: 5)))
        .trim();
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
