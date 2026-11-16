import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'local_client.dart';
import 'local_server.dart' show helloCommand;
import '../storage/secret_store.dart';
import '../transports/ndjson.dart';
import '../transports/ssh_executor.dart';
import '../version.dart';

/// The command a phone's key may run on the hub. The `authorized_keys`
/// line forces it anyway, so this is only what the client asks for.
const hubAttachCommand = 'omni hub attach';

/// A reply line longer than this is dropped rather than buffered, so a
/// broken hub cannot grow the client's memory without bound.
const maxHubReplyBytes = 64 << 20;

/// Why a hub could not be reached or used. [type] is one of the core API
/// error types: `host_key`, `version_mismatch`, `unavailable` or `invalid`.
class HubLinkException implements Exception {
  HubLinkException(this.type, this.message, {this.details = const {}});

  final String type;
  final String message;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => {
    'type': type,
    'message': message,
    ...details,
  };

  @override
  String toString() => 'HubLinkException($type): $message';
}

/// A byte channel to a hub's control socket: an SSH exec channel running
/// `omni hub attach`, or the socket itself.
abstract interface class HubChannel {
  /// What the hub sends. Ends when the channel is lost.
  Stream<List<int>> get input;

  void add(List<int> bytes);

  /// What the far end said when it refused, such as "no omni hub is
  /// running" from `omni hub attach`. Empty when it said nothing.
  String get errors;

  Future<void> close();
}

/// Opens one new channel to the hub.
typedef HubChannelOpener = Future<HubChannel> Function();

/// [HubChannel] over a connected socket, for the hub's own Unix socket.
class SocketHubChannel implements HubChannel {
  SocketHubChannel(this._socket) {
    _socket.done.catchError((Object _) {});
  }

  final Socket _socket;

  @override
  Stream<List<int>> get input => _socket;

  @override
  String get errors => '';

  @override
  void add(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> close() async => _socket.destroy();
}

/// `user@host[:port]`, the hub an `omni --hub` command drives.
class SshHubTarget {
  const SshHubTarget(this.user, this.host, [this.port = 22]);

  final String user;
  final String host;
  final int port;

  static final _user = RegExp(r'^[A-Za-z0-9._-]{1,32}$');
  static final _host = RegExp(r'^[A-Za-z0-9.-]{1,253}$');

  /// Parses `user@host`, `user@host:2222` or `user@[fd00::1]:22`. Throws
  /// [FormatException] with a plain reason.
  static SshHubTarget parse(String text) {
    final at = text.indexOf('@');
    if (at <= 0) {
      throw const FormatException('the hub is user@host or user@host:port');
    }
    final user = text.substring(0, at);
    var rest = text.substring(at + 1);
    var port = 22;
    String host;
    if (rest.startsWith('[')) {
      final close = rest.indexOf(']');
      if (close < 0) throw const FormatException('an IPv6 hub needs [ and ]');
      host = rest.substring(1, close);
      rest = rest.substring(close + 1);
      if (InternetAddress.tryParse(host)?.type != InternetAddressType.IPv6) {
        throw FormatException('$host is not an IPv6 address');
      }
    } else {
      final colon = rest.lastIndexOf(':');
      host = colon < 0 ? rest : rest.substring(0, colon);
      rest = colon < 0 ? '' : rest.substring(colon);
      if (!_host.hasMatch(host)) {
        throw FormatException('$host is not a host name or IPv4 address');
      }
    }
    if (rest.isNotEmpty) {
      final parsed = rest.startsWith(':')
          ? int.tryParse(rest.substring(1))
          : null;
      if (parsed == null || parsed < 1 || parsed > 65535) {
        throw const FormatException('the hub port is 1 to 65535');
      }
      port = parsed;
    }
    if (!_user.hasMatch(user)) {
      throw FormatException('$user is not a user name');
    }
    return SshHubTarget(user, host, port);
  }

  @override
  String toString() => '$user@$host${port == 22 ? '' : ':$port'}';
}

/// How long connecting to a hub may take, from the first byte to the
/// version check.
const hubConnectTimeout = Duration(seconds: 10);

/// How often a client pings each hub channel, and how long a ping may go
/// unanswered before the channel counts as lost.
const hubKeepAlive = Duration(seconds: 15);
const hubPingTimeout = Duration(seconds: 10);

/// Opens an SSH exec channel to [target] that runs [command], which the
/// hub's `authorized_keys` line forces to `omni hub attach --phone NAME`.
///
/// With [expectedHostKey] (`<type> SHA256:<base64>`, the key the user
/// matched against `omni hub fingerprint`), the hub must offer exactly that
/// key: anything else fails with `host_key`, and nothing is pinned or read
/// from [secrets]. Without it, as for `omni --hub`, the key is pinned on
/// first use in [secrets] (`ssh/hostkey/<host>:<port>`), a different key
/// fails with `host_key` and both fingerprints, and a pin that cannot be
/// read stops the connection rather than counting as no pin.
Future<HubChannel> openSshHubChannel({
  required SshHubTarget target,
  required String privateKeyPem,
  required SecretStore secrets,
  String? expectedHostKey,
  String command = hubAttachCommand,
  Duration timeout = const Duration(seconds: 8),
  Duration keepAlive = const Duration(seconds: 10),
  Future<SSHSocket> Function(String host, int port, Duration timeout)? socket,
}) async {
  final List<SSHKeyPair> identities;
  try {
    identities = SSHKeyPair.fromPem(privateKeyPem);
  } catch (e) {
    throw HubLinkException('invalid', 'the hub key is not a private key');
  }
  final where = '${target.host}:${target.port}';
  final SSHSocket ssh;
  try {
    ssh = await (socket ?? _connect)(target.host, target.port, timeout);
  } on Exception catch (e) {
    throw HubLinkException(
      'unavailable',
      'cannot reach the hub at $where ($e)',
    );
  }
  final pins = HostKeyPins(secrets);
  HostKeyMismatchException? mismatch;
  Object? pinError;
  final client = SSHClient(
    ssh,
    username: target.user,
    identities: identities,
    keepAliveInterval: keepAlive,
    onVerifyHostKey: (type, fingerprint) async {
      final offered = '$type ${utf8.decode(fingerprint)}';
      if (expectedHostKey != null) {
        if (offered == expectedHostKey) return true;
        mismatch = HostKeyMismatchException(where, expectedHostKey, offered);
        return false;
      }
      try {
        await pins.verify(
          target.host,
          target.port,
          type,
          utf8.decode(fingerprint),
        );
        return true;
      } on HostKeyMismatchException catch (e) {
        mismatch = e;
        return false;
      } catch (e) {
        pinError = e;
        return false;
      }
    },
  );
  try {
    final session = await client.execute(command).timeout(timeout);
    return _SshHubChannel(client, session);
  } catch (e) {
    client.close();
    if (mismatch case final m?) {
      throw HubLinkException(
        'host_key',
        'the hub at $where offered a different host key than the one you '
            'matched. If the Mac was reinstalled, check the new fingerprint '
            'with omni hub fingerprint on it, then set the hub up again',
        details: {'pinned': m.pinned, 'offered': m.offered},
      );
    }
    if (pinError case final p?) {
      throw HubLinkException(
        'host_key',
        'cannot read the host key kept for the hub at $where ($p), so '
            'nothing was sent. Try again, and set the hub up again if it '
            'keeps failing',
      );
    }
    if (e is SSHAuthError) {
      throw HubLinkException(
        'unavailable',
        'the hub at $where refused this key. Run omni hub allow on the hub',
      );
    }
    if (e is TimeoutException) {
      throw HubLinkException('unavailable', 'the hub at $where did not answer');
    }
    throw HubLinkException(
      'unavailable',
      'cannot reach the hub at $where ($e)',
    );
  }
}

Future<SSHSocket> _connect(String host, int port, Duration timeout) =>
    SSHSocket.connect(host, port, timeout: timeout);

class _SshHubChannel implements HubChannel {
  _SshHubChannel(this._client, this._session) {
    _client.done.catchError((Object _) {});
    _session.done.catchError((Object _) {});
    // The input ends only once stderr is read too, so a refusal such as
    // "no omni hub is running" is in [errors] when the reader sees the end.
    final stderrDone = Completer<void>();
    _session.stderr.listen(
      _errors.addAll,
      onError: (Object _) {},
      onDone: stderrDone.complete,
    );
    _session.stdout.listen(
      _input.add,
      onError: (Object _) {},
      onDone: () async {
        await stderrDone.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        await _input.close();
      },
    );
  }

  final SSHClient _client;
  final SSHSession _session;
  final _errors = <int>[];
  final _input = StreamController<List<int>>();

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  String get errors => utf8.decode(_errors, allowMalformed: true).trim();

  @override
  void add(List<int> bytes) =>
      _session.write(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));

  @override
  Future<void> close() async {
    _session.close();
    _client.close();
  }
}

/// The two numbers that must match between a client and its hub.
String majorMinor(String version) => version.split('.').take(2).join('.');

/// Throws `version_mismatch` unless [hubVersion] has the same major and
/// minor version as [localVersion], so command shapes never drift.
void checkHubVersion(Object? hubVersion, String localVersion) {
  final hub = hubVersion is String ? hubVersion : 'an unknown version';
  if (hubVersion is String &&
      majorMinor(hubVersion) == majorMinor(localVersion)) {
    return;
  }
  final hubOlder = hubVersion is! String || _older(hubVersion, localVersion);
  throw HubLinkException(
    'version_mismatch',
    'the hub runs $hub and this is $localVersion. '
        '${hubOlder ? 'Update the hub' : 'Update the app'}',
    details: {'hubVersion': hubVersion, 'localVersion': localVersion},
  );
}

bool _older(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.split('.').take(2)) int.tryParse(p) ?? 0,
  ];
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < 2; i++) {
    final l = i < x.length ? x[i] : 0;
    final r = i < y.length ? y[i] : 0;
    if (l != r) return l < r;
  }
  return false;
}

/// The core API of a hub reached over a [HubChannel]: the same newline
/// JSON as [LocalClient]. Commands share one channel, and each event
/// subscription has its own, as on the local socket.
///
/// Every channel opens with a `hello` whose answer carries the hub's
/// version, checked each time, and on a phone session the phone and person
/// the hub took the key for. Each command has a deadline
/// ([hubRequestDeadline], 10 s for most) after which it answers `timeout`,
/// and each channel is pinged every [keepAlive]: a ping unanswered for
/// [pingTimeout] drops it. A lost command channel is opened again on the
/// next command. When that fails the command answers `unavailable`, and so
/// do commands that were waiting when it was lost. An event stream that
/// loses its channel emits `hub.connection {state: lost}`, keeps trying with
/// [retryDelays], and emits `hub.connection {state: restored}` once it
/// subscribed again.
class HubConnection implements EngineConnection {
  HubConnection._(
    this._open,
    this.name,
    this._hello,
    this._localVersion,
    this.retryDelays,
    this.keepAlive,
    this.pingTimeout,
    this._deadline,
  );

  /// Opens the first channel, sends the hello, and checks the hub's
  /// version, all within [timeout]. Throws [HubLinkException] when the hub
  /// cannot be reached, refuses this client, or runs another major or minor
  /// version.
  static Future<HubConnection> connect(
    HubChannelOpener open, {
    String name = 'the hub',
    Map<String, Object?> hello = const {'client': 'omni'},
    String localVersion = omniflowEngineVersion,
    List<Duration> retryDelays = defaultRetryDelays,
    Duration timeout = hubConnectTimeout,
    Duration keepAlive = hubKeepAlive,
    Duration pingTimeout = hubPingTimeout,
    Duration Function(String command, Map<String, Object?> args) deadline =
        hubRequestDeadline,
  }) async {
    final hub = HubConnection._(
      open,
      name,
      hello,
      localVersion,
      retryDelays,
      keepAlive,
      pingTimeout,
      deadline,
    );
    try {
      await hub._channel().timeout(timeout);
    } on TimeoutException {
      await hub.close();
      throw HubLinkException(
        'unavailable',
        '$name did not answer within ${timeout.inSeconds} s',
      );
    } catch (_) {
      await hub.close();
      rethrow;
    }
    return hub;
  }

  static const defaultRetryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  final HubChannelOpener _open;
  final String name;
  final Map<String, Object?> _hello;
  final String _localVersion;

  /// How long an event stream waits between tries after a loss. The last
  /// delay repeats.
  final List<Duration> retryDelays;

  final Duration keepAlive;
  final Duration pingTimeout;

  /// How long each command may take, [hubRequestDeadline] unless a test
  /// gives another.
  final Duration Function(String, Map<String, Object?>) _deadline;

  /// The hub's engine version, from its hello.
  String? hubVersion;

  /// On a phone session, the phone and person the hub took this key for.
  String? hubPhone;
  String? hubPerson;

  _Link? _link;
  Future<_Link>? _opening;
  var _closed = false;
  final _streams =
      <StreamController<Map<String, Object?>>, Future<void> Function()>{};

  HubLinkException _closedError() =>
      HubLinkException('unavailable', 'the connection to $name is closed');

  Future<_Link> _channel() async {
    if (_link case final l? when !l.lost) return l;
    return _opening ??= () async {
      try {
        final channel = await _open();
        if (_closed) {
          await channel.close();
          throw _closedError();
        }
        final link = _Link(channel);
        final hello = await link.call(helloCommand, _hello, hubRequestTimeout);
        if (_closed) {
          link.lose('closed');
          throw _closedError();
        }
        if (hello['ok'] != true) {
          link.lose('refused');
          final error = hello['error'];
          throw HubLinkException(
            error is Map && error['type'] is String
                ? error['type'] as String
                : 'unavailable',
            error is Map ? '${error['message']}' : '$name did not answer',
          );
        }
        try {
          checkHubVersion(hello['version'], _localVersion);
        } catch (_) {
          link.lose('version');
          rethrow;
        }
        hubVersion = hello['version'] as String;
        hubPhone = hello['phone'] as String?;
        hubPerson = hello['person'] as String?;
        link.keepAlive(keepAlive, pingTimeout);
        return _link = link;
      } finally {
        _opening = null;
      }
    }();
  }

  static Map<String, Object?> _unavailable(String message) => {
    'ok': false,
    'error': {'type': 'unavailable', 'message': message},
  };

  @override
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> args,
  ) async {
    if (_closed) return _unavailable('the connection to $name is closed');
    final _Link link;
    try {
      link = await _channel();
    } on HubLinkException catch (e) {
      return {'ok': false, 'error': e.toJson()};
    } catch (e) {
      return _unavailable('$name is not reachable ($e)');
    }
    if (_closed) return _unavailable('the connection to $name is closed');
    final id = link.nextId();
    final List<int> request;
    try {
      request = utf8.encode(
        '${jsonEncode({'id': id, 'command': command, 'args': args})}\n',
      );
    } on JsonUnsupportedObjectError catch (e) {
      return {
        'ok': false,
        'error': {'type': 'invalid', 'message': 'args are not JSON: $e'},
      };
    }
    if (request.length - 1 > maxLocalRequestBytes) {
      return {
        'ok': false,
        'error': {
          'type': 'invalid',
          'message':
              'the $command request is ${request.length} bytes, over the '
              'omni hub limit of $maxLocalRequestBytes',
        },
      };
    }
    return link.request(
      id,
      request,
      () => link.lostReply(name),
      command: command,
      deadline: _deadline(command, args),
    );
  }

  @override
  Future<Stream<Map<String, Object?>>> events({bool packets = false}) async {
    if (_closed) throw _closedError();
    final out = StreamController<Map<String, Object?>>();
    var cancelled = false;
    HubChannel? current;
    StreamSubscription<NdjsonLine>? lines;
    Timer? pinger;
    bool stopped() => cancelled || _closed;

    Future<void> drop() async {
      pinger?.cancel();
      pinger = null;
      // Not awaited: the line decoder is an async* generator parked on the
      // channel, and its cancel would wait for a line that never comes.
      lines?.cancel().ignore();
      lines = null;
      final channel = current;
      current = null;
      await channel?.close();
    }

    _streams[out] = drop;
    late final Future<void> Function() subscribe;

    void lostChannel(HubChannel channel) {
      if (current != channel || stopped()) return;
      out.add({'event': 'hub.connection', 'state': 'lost'});
      unawaited(
        _resubscribe(stopped, drop, () async {
          await subscribe();
          if (!cancelled) {
            out.add({'event': 'hub.connection', 'state': 'restored'});
          }
        }),
      );
    }

    subscribe = () async {
      final subscribed = Completer<void>();
      final channel = await _open();
      if (stopped()) {
        await channel.close();
        throw _closedError();
      }
      current = channel;
      Completer<void>? pong;
      final request = {'id': 1, 'subscribe': 'events', 'packets': packets};
      lines = channel.input
          .cast<List<int>>()
          .transform(const NdjsonDecoder(maxLineLength: maxHubReplyBytes))
          .listen(
            (line) {
              final json = line.json;
              if (json == null) return;
              final result = json['result'];
              if (json['id'] == _pingId) {
                if (pong case final p? when !p.isCompleted) p.complete();
                return;
              }
              if (json['id'] == null &&
                  result is Map &&
                  result['ok'] == false &&
                  !subscribed.isCompleted) {
                final error = result['error'];
                subscribed.completeError(
                  HubLinkException(
                    error is Map && error['type'] is String
                        ? error['type'] as String
                        : 'unavailable',
                    error is Map
                        ? '${error['message']}'
                        : '$name refused the subscription',
                  ),
                );
                return;
              }
              if (json['id'] != 1) return;
              final event = json['event'];
              if (event is Map) {
                if (!cancelled) out.add(Map<String, Object?>.from(event));
              } else if (result is Map && !subscribed.isCompleted) {
                if (result['ok'] == true) {
                  subscribed.complete();
                } else {
                  subscribed.completeError(
                    HubLinkException(
                      'unavailable',
                      '$name refused the subscription',
                    ),
                  );
                }
              }
            },
            onError: (Object _) {},
            onDone: () {
              if (!subscribed.isCompleted) {
                subscribed.completeError(
                  HubLinkException(
                    'unavailable',
                    channel.errors.isEmpty
                        ? '$name closed the channel'
                        : '$name: ${channel.errors}',
                  ),
                );
                return;
              }
              lostChannel(channel);
            },
          );
      try {
        channel
          ..add(
            encodeNdjson({'id': 0, 'command': helloCommand, 'args': _hello}),
          )
          ..add(encodeNdjson(request));
        await subscribed.future.timeout(hubRequestTimeout);
      } catch (e) {
        await drop();
        if (e is HubLinkException) rethrow;
        throw HubLinkException(
          'unavailable',
          '$name did not answer the subscription',
        );
      }
      pinger = Timer.periodic(keepAlive, (_) async {
        if (pong != null || current != channel) return;
        final waiting = pong = Completer<void>();
        try {
          channel.add(encodeNdjson({'id': _pingId, 'command': pingCommand}));
          await waiting.future.timeout(pingTimeout);
        } catch (_) {
          lostChannel(channel);
        } finally {
          pong = null;
        }
      });
    };

    out.onCancel = () async {
      cancelled = true;
      _streams.remove(out);
      await drop();
    };
    try {
      await subscribe();
    } catch (_) {
      _streams.remove(out);
      // Not awaited: nobody listens yet, so the close would never finish.
      out.close().ignore();
      rethrow;
    }
    return out.stream;
  }

  /// The id an event channel's pings use: 0 is its hello, 1 its
  /// subscription.
  static const _pingId = 2;

  Future<void> _resubscribe(
    bool Function() stopped,
    Future<void> Function() drop,
    Future<void> Function() again,
  ) async {
    await drop();
    for (var attempt = 0; !stopped(); attempt++) {
      final delay = retryDelays.isEmpty
          ? Duration.zero
          : retryDelays[attempt < retryDelays.length
                ? attempt
                : retryDelays.length - 1];
      await Future<void>.delayed(delay);
      if (stopped()) return;
      try {
        await again();
        return;
      } catch (_) {
        // Tries again after the next delay.
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final link = _link;
    _link = null;
    link?.lose('the connection to $name was closed');
    await link?.channel.close();
    final streams = Map.of(_streams);
    _streams.clear();
    for (final MapEntry(key: stream, value: drop) in streams.entries) {
      await drop();
      // Not awaited: a stream nobody listens to never finishes closing.
      stream.close().ignore();
    }
  }
}

/// One command channel and the replies it is waiting for.
class _Link {
  _Link(this.channel) {
    _lines = channel.input
        .cast<List<int>>()
        .transform(const NdjsonDecoder(maxLineLength: maxHubReplyBytes))
        .listen(
          _onLine,
          onError: (Object _) => lose('the channel failed'),
          onDone: () => lose('the channel closed'),
        );
  }

  final HubChannel channel;
  late final StreamSubscription<NdjsonLine> _lines;
  final _pending =
      <
        int,
        (Completer<Map<String, Object?>>, Map<String, Object?> Function())
      >{};
  var _id = 0;
  var lost = false;
  Timer? _pinger;
  var _pinging = false;

  /// What the hub said when it refused this channel outright, such as a
  /// phone socket that does not know the phone.
  Map<String, Object?>? _refusal;

  int nextId() => ++_id;

  /// What a request answers when the channel went before its reply.
  Map<String, Object?> lostReply(String name) {
    if (_refusal case final r?) return {'ok': false, 'error': r};
    return {
      'ok': false,
      'error': {
        'type': 'unavailable',
        'message': channel.errors.isEmpty
            ? '$name was lost before it replied'
            : '$name: ${channel.errors}',
      },
    };
  }

  /// Sends one command and waits for its reply, for the hello.
  Future<Map<String, Object?>> call(
    String command,
    Map<String, Object?> args,
    Duration deadline,
  ) {
    final id = nextId();
    return request(
      id,
      encodeNdjson({'id': id, 'command': command, 'args': args}),
      () => lostReply('the hub'),
      command: command,
      deadline: deadline,
    );
  }

  Future<Map<String, Object?>> request(
    int id,
    List<int> bytes,
    Map<String, Object?> Function() whenLost, {
    required String command,
    required Duration deadline,
  }) {
    if (lost) return Future.value(whenLost());
    final reply = Completer<Map<String, Object?>>();
    _pending[id] = (reply, whenLost);
    try {
      channel.add(bytes);
    } catch (_) {
      lose('the channel failed');
      return reply.future;
    }
    return reply.future.timeout(
      deadline,
      onTimeout: () {
        _pending.remove(id);
        return hubTimeoutReply(command, deadline);
      },
    );
  }

  /// Pings every [every]: a ping unanswered within [within] drops the
  /// channel, so a half-open link is noticed in seconds.
  void keepAlive(Duration every, Duration within) {
    _pinger?.cancel();
    _pinger = Timer.periodic(every, (_) async {
      if (lost || _pinging) return;
      _pinging = true;
      final id = nextId();
      final reply = await request(
        id,
        encodeNdjson({'id': id, 'command': pingCommand}),
        () => const {'ok': false},
        command: pingCommand,
        deadline: within,
      );
      _pinging = false;
      final error = reply['error'];
      if (error is Map && error['type'] == 'timeout') {
        lose('the hub stopped answering');
      }
    });
  }

  void _onLine(NdjsonLine line) {
    final json = line.json;
    final id = json?['id'];
    final result = json?['result'];
    if (id is int && result is Map) {
      _pending.remove(id)?.$1.complete(Map<String, Object?>.from(result));
    } else if (id == null && result is Map && result['ok'] == false) {
      final error = result['error'];
      if (error is Map) _refusal = Map<String, Object?>.from(error);
    }
  }

  void lose(String why) {
    if (lost) return;
    lost = true;
    _pinger?.cancel();
    for (final (reply, whenLost) in _pending.values) {
      if (!reply.isCompleted) reply.complete(whenLost());
    }
    _pending.clear();
    _lines.cancel().ignore();
    channel.close().ignore();
  }
}

/// Connects to the hub at [target] over SSH with [privateKeyPem] and checks
/// its version. With [expectedHostKey] the hub must offer that key, as the
/// app's hub mode does with the one the user matched; without it the key is
/// pinned in [secrets] on first use, as `omni --hub user@host --hub-key
/// FILE` does.
Future<HubConnection> connectSshHub({
  required SshHubTarget target,
  required String privateKeyPem,
  required SecretStore secrets,
  String? expectedHostKey,
  Map<String, Object?> hello = const {'client': 'omni'},
  String localVersion = omniflowEngineVersion,
  Duration timeout = const Duration(seconds: 8),
  List<Duration> retryDelays = HubConnection.defaultRetryDelays,
}) => HubConnection.connect(
  () => openSshHubChannel(
    target: target,
    privateKeyPem: privateKeyPem,
    secrets: secrets,
    expectedHostKey: expectedHostKey,
    timeout: timeout,
  ),
  name: 'the hub at $target',
  hello: hello,
  localVersion: localVersion,
  retryDelays: retryDelays,
);
