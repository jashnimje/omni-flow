import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/tv/tizen_protocol.dart';
import 'package:omniflow_engine/src/devices/tv/tv_protocol.dart';
import 'package:omniflow_engine/src/devices/tv/tv_socket.dart';
import 'package:omniflow_engine/src/devices/tv/webos_protocol.dart';
import 'package:test/test.dart';

import 'fake_tvs.dart';

DriverManifest _driver(String file) => DriverManifest.parseJson(
  File('../../drivers/$file.omni_driver.json').readAsStringSync(),
);

final webOs = _driver('lg_webos_tv');
final tizen = _driver('samsung_tizen_tv');

/// [manifest] with its transport options changed, to shorten the pairing
/// wait or switch webOS to wss.
DriverManifest _withOptions(
  DriverManifest manifest,
  Map<String, Object?> options,
) {
  final json = jsonDecode(
    File('../../drivers/${manifest.id}.omni_driver.json').readAsStringSync(),
  );
  (json['transport'] as Map).addAll(options);
  return DriverManifest.parse(json);
}

/// [manifest] with a shorter reply timeout.
DriverManifest _withTimeout(DriverManifest manifest, int timeoutMs) {
  final json = jsonDecode(
    File('../../drivers/${manifest.id}.omni_driver.json').readAsStringSync(),
  );
  (json['reliability'] as Map)['timeoutMs'] = timeoutMs;
  return DriverManifest.parse(json);
}

/// [request] as an agent or a hub poll sends it: no pairing prompt.
ChannelRequest _unattended(ChannelRequest request) => ChannelRequest(
  device: request.device,
  manifest: request.manifest,
  command: request.command,
  context: request.context,
  allowPairing: false,
);

Device _tv(String driver, int port) => Device(
  id: 'tv',
  name: 'Living room TV',
  driverId: driver,
  host: '127.0.0.1',
  port: port,
);

ChannelRequest _request(
  DriverManifest manifest,
  Device device,
  String capability, [
  Map<String, Object?> params = const {},
]) {
  final spec = manifest.capability(capability)!;
  return ChannelRequest(
    device: device,
    manifest: manifest,
    command: spec.command,
    context: TemplateContext(params: spec.validateParams(params)),
  );
}

void main() {
  group('driver manifests', () {
    final samples = <String, Map<String, Object?>>{
      'volume': {'value': 25},
      'mute': {'value': true},
      'remote': {'value': 'home'},
      'launch_app': {'app': '111299001912'},
      'toast': {'message': 'Hello'},
    };

    for (final (manifest, protocol) in [
      (webOs, const WebOsProtocol() as TvProtocol),
      (tizen, const TizenProtocol() as TvProtocol),
    ]) {
      test(
        'every ${manifest.id} command renders to a valid ${manifest.transport.options['protocol']} command',
        () {
          expect(manifest.transport.type, TransportType.websocket);
          final secrets = manifest.settings.where((s) => s.secret);
          expect(
            secrets.map((s) => s.key),
            unorderedEquals([protocol.pairingSecret, tvCertificateSecret]),
          );
          for (final c in manifest.capabilities) {
            final params = c.validateParams({
              for (final e in (samples[c.id] ?? const {}).entries)
                if (c.params.containsKey(e.key)) e.key: e.value,
            });
            final rendered = const TemplateRenderer().render(
              c.command,
              TemplateContext(params: params),
            );
            expect(
              () => protocol.parse(rendered),
              returnsNormally,
              reason: c.id,
            );
          }
        },
      );
    }

    test('a numeric Tizen token is kept as text', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        final ws = await WebSocketTransformer.upgrade(r);
        ws.add(
          jsonEncode({
            'event': 'ms.channel.connect',
            'data': {'token': 42},
          }),
        );
      });
      final socket = await TvSocket.connect(
        deviceId: 'tv',
        uri: Uri.parse('ws://127.0.0.1:${server.port}/'),
        timeout: const Duration(seconds: 2),
      );
      final token = await const TizenProtocol().pair(
        socket,
        deviceId: 'tv',
        transport: tizen.transport,
        pairingKey: null,
        allowPairing: true,
        timeout: const Duration(seconds: 2),
      );
      expect(token, '42');
      socket.close();
      await server.close(force: true);
    });
  });

  group('LG webOS', () {
    late FakeWebOsTv tv;
    late InMemorySecretStore secrets;
    final channels = <TvWebSocketChannel>[];

    TvWebSocketChannel channel({PacketTap? tap}) {
      final c = TvWebSocketChannel(secrets, tap: tap);
      channels.add(c);
      return c;
    }

    setUp(() async {
      tv = await FakeWebOsTv.start();
      secrets = InMemorySecretStore();
    });

    tearDown(() async {
      for (final c in channels) {
        await c.close();
      }
      channels.clear();
      await tv.close();
    });

    test('pairs on first use, keeps the client key, and reuses it', () async {
      final device = _tv('lg_webos_tv', tv.port);
      await channel().send(_request(webOs, device, 'volume', {'value': 20}));
      expect(tv.volume, 20);
      expect(tv.prompts, 1);
      final first = tv.registrations.single['payload'] as Map;
      expect(first.containsKey('client-key'), isFalse);
      expect(first['pairingType'], 'PROMPT');
      expect((first['manifest'] as Map)['permissions'], [
        'CONTROL_AUDIO',
        'CONTROL_POWER',
        'LAUNCH',
        'WRITE_NOTIFICATION_TOAST',
      ]);
      expect(
        await secrets.read(deviceSecretKey('tv', 'clientKey')),
        'fake-client-key-1',
      );

      await channel().send(_request(webOs, device, 'mute', {'value': true}));
      expect(tv.muted, isTrue);
      expect(tv.prompts, 1, reason: 'a stored key pairs without a prompt');
      final second = tv.registrations.last['payload'] as Map;
      expect(second['client-key'], 'fake-client-key-1');
    });

    test('keeps one paired connection for later commands', () async {
      final device = _tv('lg_webos_tv', tv.port);
      final c = channel();
      await c.send(_request(webOs, device, 'volume', {'value': 5}));
      await c.send(_request(webOs, device, 'power_off'));
      expect(tv.requests, hasLength(1));
      expect(tv.registrations, hasLength(1));
    });

    test('matches each reply to its request by id', () async {
      final device = _tv('lg_webos_tv', tv.port);
      final c = channel();
      await c.send(_request(webOs, device, 'volume', {'value': 7}));
      tv.noiseFirst = true;
      final poll = ChannelRequest(
        device: device,
        manifest: webOs,
        command: webOs.statePoll!['command'],
        context: const TemplateContext(),
      );
      final reply = await c.send(poll);
      expect(reply.json!['volume'], 7, reason: 'not the noise reply of 99');

      tv
        ..noiseFirst = false
        ..answerInReverse = true;
      final replies = await Future.wait([
        c.send(_request(webOs, device, 'volume', {'value': 30})),
        c.send(poll),
      ]);
      expect(replies[0].json!.containsKey('volume'), isFalse);
      expect(replies[1].json!['volume'], 30);
    });

    test('reads volume and mute from both reply shapes', () async {
      final store = InMemoryDeviceStore();
      await store.put(_tv('lg_webos_tv', tv.port));
      final service = DeviceService(
        registry: DriverRegistry.withBuiltIns(
          sources: {
            'lg_webos_tv.omni_driver.json': File(
              '../../drivers/lg_webos_tv.omni_driver.json',
            ).readAsStringSync(),
          },
        ),
        store: store,
        channels: {TransportType.websocket: channel()},
      );
      tv
        ..volume = 12
        ..muted = true;
      var device = await service.refreshState('tv');
      expect(device.state['volume'], 12);
      expect(device.state['muted'], isTrue);

      tv
        ..nestedVolume = false
        ..volume = 40
        ..muted = false;
      device = await service.refreshState('tv');
      expect(device.state['volume'], 40);
      expect(device.state['muted'], isFalse);

      await service.toggle('tv', 'mute');
      expect(tv.muted, isTrue);
      await service.close();
    });

    test(
      'a TV that refuses pairing fails and is not asked again at once',
      () async {
        tv.rejectPairing = true;
        final device = _tv('lg_webos_tv', tv.port);
        final c = channel();
        await expectLater(
          c.send(_request(webOs, device, 'power_off')),
          throwsA(
            isA<TvPairingException>().having(
              (e) => e.message,
              'message',
              contains('403 User denied access'),
            ),
          ),
        );
        expect(await secrets.read(deviceSecretKey('tv', 'clientKey')), isNull);

        await expectLater(
          c.send(_request(webOs, device, 'power_off')),
          throwsA(isA<TvPairingException>()),
        );
        expect(tv.requests, hasLength(1), reason: 'no second prompt');

        tv.rejectPairing = false;
        c.forget('tv');
        await c.send(_request(webOs, device, 'power_off'));
        expect(tv.prompts, 2);
      },
    );

    test('nobody answering the prompt is a pairing failure', () async {
      final device = _tv('lg_webos_tv', tv.port);
      final silent = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      silent.listen((r) async => WebSocketTransformer.upgrade(r));
      final quick = _withOptions(webOs, {'pairingTimeoutMs': 200});
      await expectLater(
        channel().send(
          _request(quick, device.copyWith(port: silent.port), 'power_off'),
        ),
        throwsA(
          isA<TvPairingException>().having(
            (e) => e.message,
            'message',
            contains('no answer to the pairing prompt'),
          ),
        ),
      );
      await silent.close(force: true);
    });

    test('a stale client key without pairing allowed is needs_user, and the '
        'prompt is not raised again', () async {
      final device = _tv('lg_webos_tv', tv.port);
      final keyName = deviceSecretKey('tv', 'clientKey');
      await secrets.write(keyName, 'stale-key');
      tv.answerPrompt = false;
      final c = channel();
      final clock = Stopwatch()..start();
      await expectLater(
        c.send(_unattended(_request(webOs, device, 'volume', {'value': 5}))),
        throwsA(isA<PairingRequiredException>()),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(await secrets.read(keyName), 'stale-key');
      await expectLater(
        c.send(_unattended(_request(webOs, device, 'volume', {'value': 5}))),
        throwsA(isA<PairingRequiredException>()),
      );
      expect(tv.registrations, hasLength(1), reason: 'one prompt only');
      expect(tv.volume, 10);

      tv.answerPrompt = true;
      await c.send(_request(webOs, device, 'volume', {'value': 5}));
      expect(await secrets.read(keyName), 'fake-client-key-1');
      c.forget('tv');
      await c.send(
        _unattended(_request(webOs, device, 'mute', {'value': true})),
      );
      expect(tv.muted, isTrue);
    });

    test('closing the channel cuts off a pairing still waiting', () async {
      tv.answerPrompt = false;
      final c = channel();
      final failed = expectLater(
        c.send(_request(webOs, _tv('lg_webos_tv', tv.port), 'power_off')),
        throwsA(isA<CommandFailedException>()),
      );
      await tv.until(() => tv.registrations.isNotEmpty);
      await c.close();
      await failed;
      await tv.until(() => tv.closedSockets == 1);
      expect(tv.closedSockets, 1);
    });

    test('a connect that finishes after close is closed, not kept', () async {
      tv.knownKeys.add('known-key');
      await secrets.write(deviceSecretKey('tv', 'clientKey'), 'known-key');
      final gate = tv.holdUpgrade = Completer<void>();
      final c = channel();
      final failed = expectLater(
        c.send(_request(webOs, _tv('lg_webos_tv', tv.port), 'power_off')),
        throwsA(isA<CommandFailedException>()),
      );
      await tv.until(() => tv.requests.isNotEmpty);
      await c.close();
      gate.complete();
      await failed;
      await tv.until(() => tv.closedSockets == 1);
      expect(tv.closedSockets, 1);
      expect(tv.received.where((m) => m['type'] == 'request'), isEmpty);
    });

    test('a TV error reply or returnValue false fails the command', () async {
      final device = _tv('lg_webos_tv', tv.port);
      final c = channel();
      ChannelRequest literal(String uri) => ChannelRequest(
        device: device,
        manifest: webOs,
        command: {'uri': uri},
        context: const TemplateContext(),
      );
      await expectLater(
        c.send(literal('ssap://nope/missing')),
        throwsA(
          isA<CommandFailedException>().having(
            (e) => e.message,
            'message',
            contains('404'),
          ),
        ),
      );
      await expectLater(
        c.send(literal('ssap://audio/refuse')),
        throwsA(
          isA<CommandFailedException>().having(
            (e) => e.message,
            'message',
            contains('not now'),
          ),
        ),
      );
    });

    test('app ids and toasts are validated before anything is sent', () async {
      final device = _tv('lg_webos_tv', tv.port);
      expect(
        () => webOs.capability('launch_app')!.validateParams({
          'app': 'netflix; reboot',
        }),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => webOs.capability('toast')!.validateParams({'message': 'x' * 101}),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => webOs.capability('toast')!.validateParams({
          'message': 'two\nlines',
        }),
        throwsA(isA<ValidationException>()),
      );
      final c = channel();
      await expectLater(
        c.send(
          ChannelRequest(
            device: device,
            manifest: webOs,
            command: {
              'uri': 'ssap://system.notifications/createToast',
              'payload': {'message': 'x' * 101},
            },
            context: const TemplateContext(),
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        c.send(
          ChannelRequest(
            device: device,
            manifest: webOs,
            command: {'uri': 'http://elsewhere/'},
            context: const TemplateContext(),
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(tv.requests, isEmpty);

      await c.send(
        _request(webOs, device, 'launch_app', {'app': 'com.webos.app.hdmi1'}),
      );
      await c.send(_request(webOs, device, 'toast', {'message': 'Dinner!'}));
      final sent = tv.received.where((m) => m['type'] == 'request').toList();
      expect(sent[0]['uri'], 'ssap://system.launcher/launch');
      expect(sent[0]['payload'], {'id': 'com.webos.app.hdmi1'});
      expect(sent[1]['payload'], {'message': 'Dinner!'});
    });

    test('the packet tap never shows the client key', () async {
      final device = _tv('lg_webos_tv', tv.port);
      final tap = PacketTap();
      await channel(tap: tap)
          .send(_request(webOs, device, 'volume', {'value': 3}));
      await channel(tap: tap)
          .send(_request(webOs, device, 'volume', {'value': 4}));
      expect(tap.recent, isNotEmpty);
      for (final p in tap.recent) {
        expect(p.text, isNot(contains('fake-client-key')));
      }
      expect(tap.recent.map((p) => p.text), contains(contains('<secret>')));
    });

    test(
      'the built-in driver uses wss on 3001 unless the device says 3000',
      () {
        const protocol = WebOsProtocol();
        expect(
          protocol
              .uri('10.0.0.5', webOs.transport.port, webOs.transport, null)
              .toString(),
          'wss://10.0.0.5:3001/',
        );
        expect(
          protocol.uri('10.0.0.5', 3000, webOs.transport, null).toString(),
          'ws://10.0.0.5:3000/',
        );
      },
    );

    test('port 3001 means wss, anything else ws unless secure is set', () {
      const protocol = WebOsProtocol();
      expect(
        protocol.uri('10.0.0.5', 3001, webOs.transport, null).toString(),
        'wss://10.0.0.5:3001/',
      );
      expect(
        protocol.uri('10.0.0.5', null, webOs.transport, null).toString(),
        'ws://10.0.0.5:3000/',
      );
      final secure = _withOptions(webOs, {'secure': true}).transport;
      expect(
        protocol.uri('10.0.0.5', 3000, secure, null).toString(),
        'wss://10.0.0.5:3000/',
      );
    });

    test('an unreachable TV is a transport timeout', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      await expectLater(
        channel().send(_request(webOs, _tv('lg_webos_tv', port), 'power_off')),
        throwsA(isA<TransportTimeoutException>()),
      );
    });
  });

  group('TLS pinning and Samsung Tizen', () {
    late Directory dir;
    late TestCertificate certA;
    late TestCertificate certB;
    late InMemorySecretStore secrets;
    final channels = <TvWebSocketChannel>[];
    final tvs = <FakeTizenTv>[];

    TvWebSocketChannel channel({PacketTap? tap}) {
      final c = TvWebSocketChannel(secrets, tap: tap);
      channels.add(c);
      return c;
    }

    Future<FakeTizenTv> start(TestCertificate cert) async {
      final tv = await FakeTizenTv.start(cert.context());
      tvs.add(tv);
      return tv;
    }

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('omniflow_tv_tls');
      certA = await TestCertificate.generate(dir, 'fake-tv-a');
      certB = await TestCertificate.generate(dir, 'fake-tv-b');
    });

    tearDownAll(() => dir.delete(recursive: true));

    setUp(() => secrets = InMemorySecretStore());

    tearDown(() async {
      for (final c in channels) {
        await c.close();
      }
      channels.clear();
      for (final t in tvs) {
        await t.close();
      }
      tvs.clear();
    });

    test(
      'pins the certificate and keeps the token on first use, then reuses both',
      () async {
        final tv = await start(certA);
        final device = _tv('samsung_tizen_tv', tv.port);
        await channel().send(_request(tizen, device, 'volume_up'));

        expect(tv.prompts, 1);
        final first = tv.requests.single;
        expect(first.path, '/api/v2/channels/samsung.remote.control');
        expect(
          first.queryParameters['name'],
          base64.encode(utf8.encode('OmniFlow')),
        );
        expect(first.queryParameters.containsKey('token'), isFalse);
        expect(await secrets.read(deviceSecretKey('tv', 'token')), '10000001');
        expect(
          await secrets.read(deviceSecretKey('tv', tvCertificateSecret)),
          certificateSha256(certA.der),
        );
        await tv.receivedCount(1);
        expect(tv.received.single, {
          'method': 'ms.remote.control',
          'params': {
            'Cmd': 'Click',
            'DataOfCmd': 'KEY_VOLUP',
            'Option': 'false',
            'TypeOfRemote': 'SendRemoteKey',
          },
        });

        final c = channel();
        await c.send(_request(tizen, device, 'remote', {'value': 'ok'}));
        await c.send(
          _request(tizen, device, 'launch_app', {'app': '3201907018807'}),
        );
        expect(
          tv.prompts,
          1,
          reason: 'the stored token pairs without a prompt',
        );
        expect(tv.requests.last.queryParameters['token'], '10000001');
        await tv.receivedCount(3);
        expect((tv.received[1]['params'] as Map)['DataOfCmd'], 'KEY_ENTER');
        expect(tv.received[2], {
          'method': 'ms.channel.emit',
          'params': {
            'event': 'ed.apps.launch',
            'to': 'host',
            'data': {
              'appId': '3201907018807',
              'action_type': 'DEEP_LINK',
              'metaTag': '',
            },
          },
        });
      },
    );

    test('refuses a TV whose certificate does not match the pin', () async {
      final original = await start(certA);
      final device = _tv('samsung_tizen_tv', original.port);
      await channel().send(_request(tizen, device, 'power'));
      final pinned = await secrets.read(
        deviceSecretKey('tv', tvCertificateSecret),
      );

      final impostor = await start(certB);
      await expectLater(
        channel().send(
          _request(tizen, device.copyWith(port: impostor.port), 'power'),
        ),
        throwsA(
          isA<TvCertificateMismatchException>()
              .having((e) => e.pinned, 'pinned', pinned)
              .having(
                (e) => e.presented,
                'presented',
                certificateSha256(certB.der),
              )
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('Nothing was sent'),
                  contains('add it again'),
                  contains(certificateSha256(certB.der)),
                ),
              ),
        ),
      );
      expect(impostor.requests, isEmpty, reason: 'no request, so no token');
      expect(
        await secrets.read(deviceSecretKey('tv', tvCertificateSecret)),
        pinned,
      );
    });

    test('accepts a pin stored with colons and capitals', () async {
      final tv = await start(certA);
      final hex = certificateSha256(certA.der).toUpperCase();
      final colons = [
        for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2),
      ].join(':');
      await secrets.write(deviceSecretKey('tv', tvCertificateSecret), colons);
      await channel().send(
        _request(tizen, _tv('samsung_tizen_tv', tv.port), 'mute'),
      );
      await tv.receivedCount(1);
      expect(
        tv.received.single['params'],
        containsPair('DataOfCmd', 'KEY_MUTE'),
      );
    });

    test('a TV that refuses pairing stores nothing but the pin', () async {
      final tv = await start(certA)
        ..rejectPairing = true;
      final device = _tv('samsung_tizen_tv', tv.port);
      await expectLater(
        channel().send(_request(tizen, device, 'volume_down')),
        throwsA(isA<TvPairingException>()),
      );
      expect(await secrets.read(deviceSecretKey('tv', 'token')), isNull);
      expect(tv.received, isEmpty);
    });

    test('webOS over wss pins the certificate too', () async {
      final tv = await FakeWebOsTv.start(tls: certA.context());
      final secure = _withOptions(webOs, {'secure': true});
      final device = _tv('lg_webos_tv', tv.port);
      await channel().send(_request(secure, device, 'volume', {'value': 9}));
      expect(tv.volume, 9);
      expect(
        await secrets.read(deviceSecretKey('tv', tvCertificateSecret)),
        certificateSha256(certA.der),
      );
      await tv.close();

      final impostor = await FakeWebOsTv.start(tls: certB.context());
      await expectLater(
        channel().send(
          _request(secure, device.copyWith(port: impostor.port), 'power_off'),
        ),
        throwsA(isA<TvCertificateMismatchException>()),
      );
      expect(impostor.requests, isEmpty);
      await impostor.close();
    });

    test('a refused upgrade never puts the token in the error', () async {
      final tv = await start(certA)
        ..refuseUpgradeWith = HttpStatus.forbidden;
      await secrets.write(deviceSecretKey('tv', 'token'), '12345678');
      await expectLater(
        channel().send(
          _request(tizen, _tv('samsung_tizen_tv', tv.port), 'volume_up'),
        ),
        throwsA(
          isA<CommandFailedException>().having(
            (e) => e.message,
            'message',
            allOf(contains('HTTP 403'), isNot(contains('12345678'))),
          ),
        ),
      );
      expect(tv.requests.single.queryParameters['token'], '12345678');
    });

    test('a stale token without pairing allowed is needs_user without waiting '
        'for the prompt', () async {
      final tv = await start(certA)
        ..answerPrompt = false;
      final device = _tv('samsung_tizen_tv', tv.port);
      final keyName = deviceSecretKey('tv', 'token');
      await secrets.write(keyName, '99999999');
      final quick = _withTimeout(tizen, 300);
      final c = channel();
      final clock = Stopwatch()..start();
      await expectLater(
        c.send(_unattended(_request(quick, device, 'volume_up'))),
        throwsA(isA<PairingRequiredException>()),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(await secrets.read(keyName), '99999999');
      await expectLater(
        c.send(_unattended(_request(quick, device, 'volume_up'))),
        throwsA(isA<PairingRequiredException>()),
      );
      expect(tv.requests, hasLength(1), reason: 'one prompt only');
      expect(tv.received, isEmpty);
    });

    test('the packet tap never shows the token', () async {
      final tv = await start(certA);
      final tap = PacketTap();
      final device = _tv('samsung_tizen_tv', tv.port);
      await channel(tap: tap).send(_request(tizen, device, 'volume_up'));
      await channel(tap: tap).send(_request(tizen, device, 'volume_up'));
      expect(tap.recent, isNotEmpty);
      for (final p in tap.recent) {
        expect(p.text, isNot(contains('10000001')));
      }
    });

    test('keys and app ids outside the allowed shapes are refused', () async {
      final tv = await start(certA);
      final device = _tv('samsung_tizen_tv', tv.port);
      final c = channel();
      for (final command in <Map<String, Object?>>[
        {'key': 'KEY_VOLUP; rm'},
        {'key': 'volup'},
        {
          'key': 'sideways',
          'keyMap': {'up': 'KEY_UP'},
        },
        {'launch': 'bad app'},
        {'launch': '111299001912', 'actionType': 'SHELL'},
      ]) {
        await expectLater(
          c.send(
            ChannelRequest(
              device: device,
              manifest: tizen,
              command: command,
              context: const TemplateContext(),
            ),
          ),
          throwsA(isA<ArgumentError>()),
          reason: '$command',
        );
      }
      expect(tv.requests, isEmpty);
    });
  });
}
