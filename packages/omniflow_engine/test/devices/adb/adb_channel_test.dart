import 'dart:io';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:test/test.dart';

import 'fake_adbd.dart';

void main() {
  late AdbHostKey hostKey;
  late FakeAdbd adbd;
  late InMemorySecretStore secrets;
  late InMemoryDeviceStore store;
  late List<AdbChannel> channels;
  late List<String> prompts;
  late List<Uint8List> wakePackets;
  late int generated;

  setUpAll(() {
    hostKey = AdbHostKey.generateSync();
  });

  AdbChannel newChannel({
    Duration pairing = const Duration(seconds: 5),
    Future<void> Function()? onWake,
    Duration wakeWait = const Duration(seconds: 45),
  }) {
    final channel = AdbChannel(
      secrets,
      keyName: 'omniflow@test',
      pairingTimeout: pairing,
      generateKey: () async {
        generated++;
        return hostKey;
      },
      onPairingPrompt: prompts.add,
      wakeOnLan: (packet) async {
        wakePackets.add(packet);
        await onWake?.call();
      },
      wakeWait: wakeWait,
      wakeRetry: const Duration(milliseconds: 50),
    );
    channels.add(channel);
    return channel;
  }

  DeviceService serviceFor(AdbChannel channel) => DeviceService(
    registry: DriverRegistry.withBuiltIns(),
    store: store,
    channels: {TransportType.adb: channel},
  );

  Future<void> addTv({Map<String, Object?> settings = const {}, int? port}) =>
      store.put(
        Device(
          id: 'tv',
          name: 'Living room TV',
          driverId: 'android_tv_adb',
          host: InternetAddress.loopbackIPv4.address,
          port: port ?? adbd.port,
          settings: settings,
        ),
      );

  setUp(() async {
    adbd = await FakeAdbd.start();
    secrets = InMemorySecretStore();
    store = InMemoryDeviceStore();
    channels = [];
    prompts = [];
    wakePackets = [];
    generated = 0;
    await addTv();
  });

  tearDown(() async {
    for (final c in channels) {
      await c.close();
    }
    await adbd.close();
  });

  test('first pairing: signature refused, public key sent, accepted', () async {
    final service = serviceFor(newChannel());
    final result = await service.invoke('tv', 'wake', const {});

    expect(generated, 1);
    expect(await secrets.read(adbHostKeySecret), hostKey.toPem());
    expect(adbd.hostVersions.single, 0x01000000);
    expect(adbd.hostMaxData.single, 256 * 1024);
    expect(adbd.hostBanners.single, 'host::\x00');
    expect(adbd.signaturesSent, 1);
    expect(adbd.signaturesAccepted, 0);
    expect(adbd.offeredNames, ['omniflow@test']);
    expect(adbd.offeredKeys.single.n, hostKey.modulus);
    expect(adbd.offeredKeyMatchesSignature, [isTrue]);
    expect(prompts, ['tv']);
    expect(adbd.commands, ['input keyevent 224']);
    expect(result.reply.json, {'shell': 'input keyevent 224', 'output': ''});
  });

  test('a returning host signs with the saved key and is let in', () async {
    await serviceFor(newChannel()).invoke('tv', 'wake', const {});
    adbd.dropAll();

    final later = serviceFor(newChannel());
    await later.invoke('tv', 'sleep', const {});

    expect(generated, 1);
    expect(adbd.connections, 2);
    expect(adbd.signaturesAccepted, 1);
    expect(adbd.offeredKeys, hasLength(1));
    expect(prompts, ['tv']);
    expect(adbd.commands, ['input keyevent 224', 'input keyevent 223']);
  });

  test('shell output comes back and the connection is reused', () async {
    adbd.respond = (command) =>
        command.startsWith('c=') ? 'Starting: Intent\n' : '';
    final service = serviceFor(newChannel());

    final launched = await service.invoke('tv', 'launch_app', {
      'package': 'com.netflix.ninja',
    });
    await service.invoke('tv', 'remote', {'value': 'down'});
    await service.invoke('tv', 'open_url', {
      'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    });

    expect(launched.reply.json, {
      'shell': TvShell.launch('com.netflix.ninja'),
      'output': 'Starting: Intent\n',
    });
    expect(adbd.commands, [
      TvShell.launch('com.netflix.ninja'),
      'input keyevent 20',
      "am start -a android.intent.action.VIEW -d "
          "'https://www.youtube.com/watch?v=dQw4w9WgXcQ'",
    ]);
    expect(adbd.connections, 1);
  });

  test('a launch of an app that is not installed fails', () async {
    adbd.respond = (_) => '** No activities found to run, monkey aborted.\n';
    await expectLater(
      serviceFor(newChannel())
          .invoke('tv', 'launch_app', {'package': 'com.not.installed'}),
      throwsA(isA<CommandFailedException>()),
    );
  });

  test('a malicious param never reaches the device', () async {
    final service = serviceFor(newChannel());
    for (final (capability, params) in [
      ('launch_app', {'package': 'com.example; reboot'}),
      ('launch_app', {'package': "com.example' && reboot && '"}),
      ('open_url', {'url': "https://x.example/'; reboot; '"}),
      ('open_url', {'url': 'file:///sdcard/secret'}),
      ('remote', {'value': 'reboot'}),
    ]) {
      await expectLater(
        service.invoke('tv', capability, params),
        throwsA(isA<ValidationException>()),
        reason: '$capability $params',
      );
    }
    expect(adbd.commands, isEmpty);
    expect(adbd.connections, 0);
  });

  test(
    'the channel refuses free text even when a manifest has no pattern',
    () async {
      final loose = DriverManifest.parse({
        'schemaVersion': 1,
        'id': 'loose_tv',
        'name': 'Loose',
        'category': 'media',
        'transport': {'type': 'adb'},
        'capabilities': [
          {
            'id': 'launch_app',
            'type': 'action',
            'params': {
              'package': {'type': 'string'},
            },
            'command': {'op': 'launch', 'package': '{{package}}'},
          },
          {
            'id': 'say',
            'type': 'text_command',
            'command': {'op': 'shell', 'command': '{{value}}'},
          },
        ],
      });
      final channel = newChannel();
      final device = (await store.get('tv'))!;
      for (final (capability, params) in [
        ('launch_app', {'package': 'com.example;reboot'}),
        ('say', {'value': 'reboot'}),
      ]) {
        await expectLater(
          channel.send(
            ChannelRequest(
              device: device,
              manifest: loose,
              command: loose.capability(capability)!.command,
              context: TemplateContext(params: params),
            ),
          ),
          throwsA(isA<ValidationException>()),
        );
      }
      expect(adbd.commands, isEmpty);
    },
  );

  test('a device that drops the connection fails the command', () async {
    adbd.dropOnOpen = true;
    final service = serviceFor(newChannel());
    await expectLater(
      service.invoke('tv', 'mute', const {}),
      throwsA(
        isA<CommandFailedException>().having(
          (e) => e.message,
          'message',
          contains('closed the ADB connection'),
        ),
      ),
    );

    adbd.dropOnOpen = false;
    await service.invoke('tv', 'mute', const {});
    expect(adbd.connections, 2);
  });

  test(
    'an idle connection the TV closed is replaced without an error',
    () async {
      final service = serviceFor(newChannel());
      await service.invoke('tv', 'volume_up', const {});
      adbd.dropAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await service.invoke('tv', 'volume_down', const {});
      expect(adbd.commands, ['input keyevent 24', 'input keyevent 25']);
      expect(adbd.connections, 2);
    },
  );

  test(
    'a stream the TV dropped before accepting is retried once, fresh',
    () async {
      final service = serviceFor(newChannel());
      await service.invoke('tv', 'volume_up', const {});
      adbd.dropNextOpens = 1;

      await service.invoke('tv', 'volume_down', const {});
      expect(adbd.connections, 2);
      expect(adbd.commands.last, 'input keyevent 25');
    },
  );

  test('a stream the TV accepted and then dropped is not retried', () async {
    final service = serviceFor(newChannel());
    await service.invoke('tv', 'volume_up', const {});
    adbd.dropAfterOkay = true;

    await expectLater(
      service.invoke('tv', 'power', const {}),
      throwsA(isA<CommandFailedException>()),
    );
    expect(adbd.commands.where((c) => c == 'input keyevent 26'), hasLength(1));
    expect(adbd.connections, 1);
  });

  test('no answer on the TV prompt fails with what to do', () async {
    adbd.prompt = KeyPrompt.ignore;
    final service = serviceFor(
      newChannel(pairing: const Duration(milliseconds: 200)),
    );
    await expectLater(
      service.invoke('tv', 'wake', const {}),
      throwsA(
        isA<AdbPairingException>().having(
          (e) => e.message,
          'message',
          contains('Allow USB debugging?'),
        ),
      ),
    );
    expect(prompts, ['tv']);
    expect(adbd.commands, isEmpty);
  });

  test('closing the channel cuts off a handshake waiting on the TV', () async {
    adbd.prompt = KeyPrompt.ignore;
    final channel = newChannel();
    final failed = expectLater(
      serviceFor(channel).invoke('tv', 'wake', const {}),
      throwsA(
        isA<CommandFailedException>().having(
          (e) => e.message,
          'message',
          contains('shut down'),
        ),
      ),
    );
    for (var i = 0; i < 200 && prompts.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(adbd.openConnections, 1);
    await channel.close();
    await failed;
    for (var i = 0; i < 200 && adbd.openConnections > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(adbd.openConnections, 0);
    expect(adbd.commands, isEmpty);
  });

  test('a TV that refuses the key fails pairing', () async {
    adbd.prompt = KeyPrompt.reject;
    await expectLater(
      serviceFor(newChannel()).invoke('tv', 'wake', const {}),
      throwsA(isA<AdbPairingException>()),
    );
  });

  test('a TV with nothing on the port is unreachable', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = probe.port;
    await probe.close();
    await store.remove('tv');
    await addTv(port: closedPort);
    await expectLater(
      serviceFor(newChannel()).invoke('tv', 'wake', const {}),
      throwsA(isA<TransportTimeoutException>()),
    );
  });

  test('Wake-on-LAN sends the magic packet to the mac setting', () async {
    await store.remove('tv');
    await addTv(settings: const {'mac': 'AA:BB:CC:00:11:22'});
    final result = await serviceFor(newChannel())
        .invoke('tv', 'wake_on_lan', const {});
    expect(result.reply.json, {'wakeOnLan': 'AA:BB:CC:00:11:22'});
    expect(wakePackets.single.length, 102);
    expect(wakePackets.single.sublist(6, 12), [
      0xAA,
      0xBB,
      0xCC,
      0x00,
      0x11,
      0x22,
    ]);
    expect(adbd.connections, 0);
  });

  group('wake on a TV in deep standby', () {
    late int asleepPort;
    setUp(() async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      asleepPort = probe.port;
      await probe.close();
      await store.remove('tv');
      await addTv(
        port: asleepPort,
        settings: const {'mac': 'AA:BB:CC:00:11:22'},
      );
    });

    test('sends Wake-on-LAN, then the key once ADB is back', () async {
      FakeAdbd? woken;
      addTearDown(() async => woken?.close());
      final channel = newChannel(
        onWake: () async {
          woken = await FakeAdbd.start(port: asleepPort);
          woken!.trusted.addAll(adbd.trusted);
        },
      );
      await serviceFor(channel).invoke('tv', 'wake', const {});
      expect(wakePackets, hasLength(1));
      expect(woken!.connections, greaterThan(0));
    });

    test('says what to turn on when the TV never comes back', () async {
      await expectLater(
        serviceFor(newChannel(wakeWait: const Duration(milliseconds: 200)))
            .invoke('tv', 'wake', const {}),
        throwsA(
          isA<TransportTimeoutException>().having(
            (e) => e.message,
            'message',
            contains('network standby'),
          ),
        ),
      );
      expect(wakePackets, hasLength(1));
    });

    test('no mac setting fails at once with no packet', () async {
      await store.remove('tv');
      await addTv(port: asleepPort);
      await expectLater(
        serviceFor(newChannel()).invoke('tv', 'wake', const {}),
        throwsA(isA<TransportTimeoutException>()),
      );
      expect(wakePackets, isEmpty);
    });
  });

  test('Wake-on-LAN without a valid mac setting is refused', () async {
    await expectLater(
      serviceFor(newChannel()).invoke('tv', 'wake_on_lan', const {}),
      throwsA(isA<ValidationException>()),
    );
    expect(wakePackets, isEmpty);
  });
}
