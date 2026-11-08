import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../manifest/driver_manifest.dart';
import '../storage/secret_store.dart';
import '../template/template_renderer.dart';
import '../transports/packet_tap.dart';
import '../transports/udp_transport.dart';
import 'channels.dart';
import 'device.dart';

/// State a device published on a topic it is watched on.
class MqttStateMessage {
  const MqttStateMessage(this.deviceId, this.state);

  final String deviceId;
  final Map<String, Object?> state;
}

/// MQTT 3.1.1 for devices behind a broker (Tasmota, Zigbee2MQTT, ESPHome).
///
/// The device host and port are the broker's. A command renders to
/// `{"topic": ..., "payload": ...}` and is published at QoS 1; an object
/// payload is sent as JSON, anything else as text. MQTT has no replies, so
/// state comes from the topics in the driver's `statePush.topics`, watched
/// with [watch]: a topic with a `key` stores its payload under that key, one
/// without must carry a JSON object. `statePush.refresh` is published once
/// after subscribing, to ask the device for its state.
///
/// One connection serves every device on the same broker and user. The
/// broker user is the device's `username` setting and the password its
/// `password` secret, read from whichever device connects first: after the
/// password changes, [resetBroker] makes the connection pick it up.
///
/// A watch is kept even while its broker is unreachable, and every new
/// connection subscribes the watches for its broker, so live state starts
/// as soon as the broker is back.
class MqttChannel implements DriverChannel {
  MqttChannel(
    this._secrets, {
    this._renderer = const TemplateRenderer(),
    this._tap,
  });

  final SecretStore _secrets;
  final TemplateRenderer _renderer;
  final PacketTap? _tap;
  final _brokers = <String, Future<MqttServerClient>>{};

  /// Brokers whose connection is up and whose watches are subscribed.
  final _connected = <String, MqttServerClient>{};
  final _watches = <String, _DeviceWatch>{};
  final _events = StreamController<MqttStateMessage>.broadcast();
  final _random = Random();

  Stream<MqttStateMessage> get events => _events.stream;

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    final rendered = _renderer.render(request.command, request.context);
    if (rendered is! Map || rendered['topic'] is! String) {
      throw ArgumentError('an MQTT command renders to {"topic", "payload"}');
    }
    final topic = rendered['topic'] as String;
    final payload = _payloadText(rendered['payload']);
    final client = await _client(request.device, request.manifest);
    _publish(
      client,
      request.device.host,
      topic,
      payload,
      retain: rendered['retain'] == true,
    );
    return ChannelReply({'published': topic});
  }

  /// Subscribes to the device's state topics. Safe to call again. When the
  /// broker cannot be reached this throws, and the watch starts once a later
  /// command or watch connects to that broker.
  Future<void> watch(Device device, DriverManifest manifest) async {
    final push = manifest.statePush;
    final topics = push?['topics'];
    if (topics is! List || topics.isEmpty) return;
    final context = TemplateContext(device: device.settings);
    final refresh = push?['refresh'];
    final rendered = refresh is Map && refresh['topic'] is String
        ? _renderer.render(refresh, context) as Map
        : null;
    final watch = _DeviceWatch(
      _brokerKey(device, manifest),
      device.host,
      [
        for (final t in topics)
          if (t is Map && t['topic'] is String)
            _Watch(
              '${_renderer.render(t['topic'], context)}',
              t['key'] is String ? t['key'] as String : null,
            ),
      ],
      rendered == null ? null : '${rendered['topic']}',
      rendered == null ? '' : _payloadText(rendered['payload']),
    );
    _watches[device.id] = watch;
    final ready = _connected[watch.broker];
    if (ready != null) return _subscribe(ready, watch);
    await _client(device, manifest);
  }

  void unwatch(String deviceId) => _watches.remove(deviceId);

  /// Disconnects the connection [device] shares, so the next connection
  /// reads the current password. Watches on that broker reconnect now.
  Future<void> resetBroker(Device device, DriverManifest manifest) async {
    final key = _brokerKey(device, manifest);
    _connected.remove(key);
    final old = _brokers.remove(key);
    if (old != null) {
      try {
        (await old).disconnect();
      } catch (_) {
        // It never connected.
      }
    }
    if (!_watches.values.any((w) => w.broker == key)) return;
    try {
      await _client(device, manifest);
    } on Exception {
      // The next command reports it.
    }
  }

  void _subscribe(MqttServerClient client, _DeviceWatch watch) {
    _guard(watch.host, () {
      for (final w in watch.topics) {
        client.subscribe(w.topic, MqttQos.atLeastOnce);
      }
    });
    final refresh = watch.refreshTopic;
    if (refresh != null) {
      _publish(client, watch.host, refresh, watch.refreshPayload);
    }
  }

  void _publish(
    MqttServerClient client,
    String host,
    String topic,
    String payload, {
    bool retain = false,
  }) {
    final bytes = utf8.encode(payload);
    _tap?.record(
      CapturedPacket(
        transport: 'mqtt',
        direction: PacketDirection.outgoing,
        remote: '$host $topic',
        bytes: Uint8List.fromList(bytes),
      ),
    );
    _guard(
      host,
      () => client.publishMessage(
        topic,
        MqttQos.atLeastOnce,
        MqttClientPayloadBuilder().addUTF8String(payload).payload!,
        retain: retain,
      ),
    );
  }

  /// The client throws [ConnectionException] while it is reconnecting: to a
  /// caller that is the broker not answering, the same as a timeout.
  static void _guard(String host, void Function() action) {
    try {
      action();
    } on ConnectionException catch (e) {
      throw TransportTimeoutException('MQTT broker $host is not connected: $e');
    } on NoConnectionException catch (e) {
      throw TransportTimeoutException('MQTT broker $host is not connected: $e');
    }
  }

  static String _payloadText(Object? payload) => switch (payload) {
    null => '',
    Map() || List() => jsonEncode(payload),
    _ => '$payload',
  };

  static int _port(Device device, DriverManifest manifest) =>
      device.port ?? manifest.transport.port ?? 1883;

  static String _brokerKey(Device device, DriverManifest manifest) =>
      '${device.host}:${_port(device, manifest)}:'
      '${device.settings['username'] as String? ?? ''}';

  Future<MqttServerClient> _client(Device device, DriverManifest manifest) {
    final key = _brokerKey(device, manifest);
    final existing = _brokers[key];
    if (existing != null) return existing;
    final connecting = _connect(
      key,
      device,
      _port(device, manifest),
      device.settings['username'] as String?,
    );
    _brokers[key] = connecting;
    // A failed connection is forgotten, so the next command tries again.
    connecting.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_brokers[key], connecting)) _brokers.remove(key);
      },
    );
    return connecting;
  }

  Future<MqttServerClient> _connect(
    String key,
    Device device,
    int port,
    String? username,
  ) async {
    final id = 'omniflow_${_random.nextInt(1 << 32).toRadixString(16)}';
    final client = MqttServerClient.withPort(device.host, id, port)
      ..logging(on: false)
      ..setProtocolV311()
      ..keepAlivePeriod = 30
      ..connectTimeoutPeriod = 3000
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true;
    final password = username == null
        ? null
        : await _secrets.read(deviceSecretKey(device.id, 'password'));
    Object? failure;
    try {
      await client.connect(username, password);
    } on Exception catch (e) {
      failure = e;
    }
    final status = client.connectionStatus;
    if (status?.state != MqttConnectionState.connected) {
      client.disconnect();
      final code = status?.returnCode;
      if (code == MqttConnectReturnCode.notAuthorized ||
          code == MqttConnectReturnCode.badUsernameOrPassword) {
        throw CommandFailedException(
          'MQTT broker ${device.host}:$port refused the user ${username ?? '(none)'}: check the username setting and the password secret',
        );
      }
      throw TransportTimeoutException(
        'MQTT broker ${device.host}:$port did not accept a connection${failure == null ? '' : ': $failure'}',
      );
    }
    client.updates?.listen((messages) {
      for (final m in messages) {
        final message = m.payload;
        if (message is! MqttPublishMessage) continue;
        final bytes = Uint8List.fromList(message.payload.message);
        _tap?.record(
          CapturedPacket(
            transport: 'mqtt',
            direction: PacketDirection.incoming,
            remote: '${device.host} ${m.topic}',
            bytes: bytes,
          ),
        );
        _route(key, m.topic, utf8.decode(bytes, allowMalformed: true));
      }
    });
    void subscribeAll() {
      for (final watch in _watches.values) {
        if (watch.broker == key) _subscribe(client, watch);
      }
    }

    subscribeAll();
    // A watch added while the client was reconnecting was never subscribed.
    client.onAutoReconnected = () {
      try {
        subscribeAll();
      } on TransportTimeoutException {
        // Dropped again: the next reconnect subscribes.
      }
    };
    _connected[key] = client;
    return client;
  }

  void _route(String broker, String topic, String text) {
    for (final entry in _watches.entries) {
      if (entry.value.broker != broker) continue;
      for (final w in entry.value.topics) {
        if (!mqttTopicMatches(w.topic, topic)) continue;
        Object? value;
        try {
          value = jsonDecode(text);
        } on FormatException {
          value = text;
        }
        final state = w.key != null
            ? {w.key!: value}
            : value is Map
            ? Map<String, Object?>.from(value)
            : null;
        if (state != null && !_events.isClosed) {
          _events.add(MqttStateMessage(entry.key, state));
        }
      }
    }
  }

  Future<void> close() async {
    for (final b in _brokers.values) {
      try {
        (await b).disconnect();
      } catch (_) {
        // Never connected.
      }
    }
    _brokers.clear();
    _connected.clear();
    await _events.close();
  }
}

class _DeviceWatch {
  const _DeviceWatch(
    this.broker,
    this.host,
    this.topics,
    this.refreshTopic,
    this.refreshPayload,
  );

  final String broker;
  final String host;
  final List<_Watch> topics;
  final String? refreshTopic;
  final String refreshPayload;
}

class _Watch {
  const _Watch(this.topic, this.key);

  final String topic;
  final String? key;
}

/// MQTT topic filter matching: `+` is one level, `#` the rest.
bool mqttTopicMatches(String filter, String topic) {
  final f = filter.split('/');
  final t = topic.split('/');
  for (var i = 0; i < f.length; i++) {
    if (f[i] == '#') return true;
    if (i >= t.length) return false;
    if (f[i] != '+' && f[i] != t[i]) return false;
  }
  return f.length == t.length;
}
