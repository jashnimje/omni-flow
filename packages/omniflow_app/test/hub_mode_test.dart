// The test checks the phone's key the way the hub's SSH client reads it.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/api/engine_client_hub.dart';
import 'package:omniflow_app/service/foreground_runtime.dart';
import 'package:omniflow_app/service/hub_bridge.dart';
import 'package:omniflow_app/service/hub_connection.dart';
import 'package:omniflow_app/service/hub_engine_client.dart';
import 'package:omniflow_app/service/hub_handback.dart';
import 'package:omniflow_app/service/hub_key.dart';
import 'package:omniflow_app/service/hub_settings.dart';
import 'package:omniflow_app/service/notifier.dart';
import 'package:omniflow_app/startup.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

import 'fake_engine.dart';
import 'fake_hub.dart';

const _settings = HubSettings(
  host: 'mac-mini.local',
  user: 'jade',
  phone: 'jade_pixel',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHub hub;
  late HubEngineClient client;
  late List<Map<String, Object?>> links;

  HubEngineClient make({
    Duration retry = const Duration(milliseconds: 10),
    Map<String, Map<String, Object?>>? lastKnown,
  }) {
    final c = HubEngineClient(
      settings: _settings,
      connect: hub.connect,
      backoff: (_) => retry,
      lastKnown: lastKnown,
      now: () => DateTime.utc(2026, 11, 12, 9),
    );
    c.events.where((e) => e['event'] == HubLink.event).listen(links.add);
    return c;
  }

  setUp(() {
    hub = FakeHub();
    links = [];
    client = make();
  });

  tearDown(() => client.close());

  group('the phone key', () {
    test('is an ed25519 pair the SSH client reads, named for the phone', () {
      final key = HubKey.generate('jade_pixel');
      final pairs = SSHKeyPair.fromPem(key.privatePem);
      expect(pairs.single.type, 'ssh-ed25519');
      expect(key.publicLine, startsWith('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5'));
      expect(key.publicLine, endsWith(' omniflow-jade_pixel'));
      expect(
        hubAllowLine('jade_pixel', key),
        "omni hub allow jade_pixel '${key.publicKey}'",
      );
    });

    test('is made once and kept in the keystore', () async {
      final store = HubSettingsStore(InMemorySecretStore());
      final first = await store.phoneKey('a');
      final again = await store.phoneKey('a');
      expect(again.privatePem, first.privatePem);
      expect(await store.publicKey(), first.publicLine);
    });

    test('phone names are made safe for the hub', () {
      expect(hubPhoneName(' Jade Pixel 8! '), 'jade_pixel_8');
      expect(hubPhoneName('***'), '');
      expect(hubPhoneName('8 Pro'), 'pro');
    });
  });

  group('the hub client', () {
    test('says it is connected, and tags readings with this phone', () async {
      await client.start();
      expect(client.view.connected, isTrue);
      expect(links.last['state'], 'connected');
      expect(links.last['hubVersion'], omniflowEngineVersion);
      await client.call('phone.wifi', {'ssid': 'Home'});
      await client.call('nfc.scanned', {'uid': '04aa'});
      await client.call('device.list');
      expect(hub.callsOf('phone.wifi').single.$2, {
        'ssid': 'Home',
        'phone': 'jade_pixel',
      });
      expect(hub.callsOf('nfc.scanned').single.$2['phone'], 'jade_pixel');
      expect(hub.callsOf('device.list').single.$2.containsKey('phone'), false);
    });

    test('with the hub gone, lists are the last known and changes wait, then '
        'the latest presence goes on reconnect', () async {
      client = make(retry: const Duration(milliseconds: 30));
      await client.start();
      final before = await client.call('device.list');
      await client.call('phone.wifi', {'ssid': 'Home'});
      hub.refuse = const HubConnectException('unavailable', 'no route');
      hub.drop();
      await pumpEventQueue();
      expect(client.view.state, HubLinkState.unreachable);
      expect(links.last['state'], 'unreachable');

      expect(await client.call('device.list'), before);
      final invoke = await client.call('device.invoke', {'id': 'desk_lamp'});
      expect(invoke['ok'], false);
      expect((invoke['error'] as Map)['type'], 'unavailable');
      expect(
        (invoke['error'] as Map)['message'],
        HubEngineClient.unreachableReason,
      );

      await client.call('phone.wifi', {'ssid': 'Office'});
      await client.call('phone.battery', {'level': 40});
      hub.calls.clear();
      hub.refuse = null;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(client.view.connected, isTrue);
      expect(hub.callsOf('phone.wifi').single.$2['ssid'], 'Office');
      expect(hub.callsOf('phone.battery'), isEmpty);
    });

    test('readings go untagged while the hub has no phone thing for this '
        'phone, since it would refuse the id', () async {
      hub.answers['device.get'] = {
        'ok': false,
        'error': {'type': 'not_found', 'message': 'no jade_pixel'},
      };
      await client.start();
      await client.call('phone.wifi', {'ssid': 'Home'});
      expect(hub.callsOf('phone.wifi').single.$2, {'ssid': 'Home'});
    });

    test('keeps retrying with backoff until the hub answers', () async {
      hub.refuse = const HubConnectException('unavailable', 'down');
      client = make(retry: const Duration(milliseconds: 20));
      await client.start();
      expect(client.view.state, HubLinkState.unreachable);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(hub.opens, greaterThan(2));
      hub.refuse = null;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(client.view.connected, isTrue);
    });

    test('Reconnect tries at once instead of waiting', () async {
      hub.refuse = const HubConnectException('unavailable', 'down');
      client = make(retry: const Duration(minutes: 5));
      await client.start();
      hub.refuse = null;
      await client.call(HubLink.reconnect);
      await pumpEventQueue();
      expect(client.view.connected, isTrue);
    });

    test('an older hub says Update the hub, with both versions', () async {
      hub.hello = const HubHello(hubVersion: '0.3.2');
      await client.start();
      expect(client.view.state, HubLinkState.versionMismatch);
      expect(
        client.view.reason,
        'Update the hub. It runs 0.3.2 and this app is $omniflowEngineVersion.',
      );
      final r = await client.call('device.invoke');
      expect((r['error'] as Map)['message'], contains('Update the hub'));
    });

    test('a newer hub says Update the app', () async {
      hub.refuse = const HubConnectException(
        'version_mismatch',
        'differs',
        hubVersion: '0.5.0',
        appVersion: '0.4.0',
      );
      await client.start();
      expect(client.view.state, HubLinkState.versionMismatch);
      expect(client.view.reason, startsWith('Update the app.'));
    });

    test('the last known lists survive a service restart', () async {
      await client.start();
      final list = await client.call('device.list');
      final kept = <String, Map<String, Object?>>{};
      final home = await Directory.systemTemp.createTemp('omni_hub_last');
      addTearDown(() => home.delete(recursive: true));
      final store = HubLastKnown(home);
      final remembering = HubEngineClient(
        settings: _settings,
        connect: hub.connect,
        remember: (m) {
          kept.addAll(m);
          store.write(m);
        },
      );
      addTearDown(remembering.close);
      await remembering.start();
      await remembering.call('device.list');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      hub.refuse = const HubConnectException('unavailable', 'down');
      final restarted = HubEngineClient(
        settings: _settings,
        connect: hub.connect,
        lastKnown: await store.read(),
        backoff: (_) => const Duration(minutes: 5),
      );
      addTearDown(restarted.close);
      await restarted.start();
      expect(restarted.view.connected, isFalse);
      expect(await restarted.call('device.list'), list);
    });
  });

  group('asks in hub mode', () {
    late List<AskNotice> asked;
    late List<int> cancelled;
    late AutomationNotifier notifier;

    setUp(() async {
      asked = [];
      cancelled = [];
      await client.start();
      notifier = AutomationNotifier(
        client,
        post: ({required channel, required id, required title, body, link}) =>
            Future.value(),
        postAsk: (ask) async => asked.add(ask),
        cancel: (id) async => cancelled.add(id),
        shows: client.showsOnThisPhone,
      );
      await notifier.start();
    });

    tearDown(() => notifier.stop());

    Map<String, Object?> ask(String id, {String? person}) => {
      'event': 'ask.request',
      'askId': id,
      'kind': 'confirm',
      'title': 'Start film night?',
      'person': ?person,
    };

    test('show only for this phone\'s person, or for no one', () async {
      hub.eventsOut.add(ask('mine', person: 'jade'));
      hub.eventsOut.add(ask('theirs', person: 'sam'));
      hub.eventsOut.add(ask('anyone'));
      await pumpEventQueue();
      expect([for (final a in asked) a.askId], ['mine', 'anyone']);
    });

    test('ask.closed from the hub clears it here', () async {
      hub.eventsOut.add(ask('mine', person: 'jade'));
      await pumpEventQueue();
      hub.eventsOut.add({'event': 'ask.closed', 'askId': 'mine'});
      await pumpEventQueue();
      expect(cancelled, [askNotificationId('mine')]);
    });

    test('answering goes to the hub', () async {
      await client.call('ask.answer', {'askId': 'mine', 'answer': 'Run'});
      expect(hub.callsOf('ask.answer').single.$2, {
        'askId': 'mine',
        'answer': 'Run',
      });
    });

    test('a person from the hub\'s phone thing when hello has none', () async {
      hub.hello = const HubHello(hubVersion: omniflowEngineVersion);
      hub.answers['device.get'] = {
        'ok': true,
        'device': {
          'id': 'jade_pixel',
          'driver': 'phone',
          'settings': {'person': 'sam'},
        },
      };
      final other = make();
      addTearDown(other.close);
      await other.start();
      expect(other.person, 'sam');
      expect(other.showsOnThisPhone({'person': 'sam'}), isTrue);
      expect(other.showsOnThisPhone({'to': 'jade'}), isFalse);
    });
  });

  test('the private socket in hub mode passes widget and ask commands on to '
      'the hub', () async {
    await client.start();
    final home = await Directory.systemTemp.createTemp('omni_br');
    addTearDown(() => home.delete(recursive: true));
    final bridge = await HubBridge.start(client, home: home);
    addTearDown(bridge.close);
    final mode = (await File(bridge.path).stat()).mode & 511;
    expect(mode.toRadixString(8), '600');
    final local = await LocalClient.connect(bridge.path);
    expect(local, isNotNull);
    addTearDown(local!.close);
    final answer = await local.handle('ask.answer', {
      'askId': 'a1',
      'answer': 'Run',
    });
    expect(answer['ok'], true);
    expect(hub.callsOf('ask.answer').single.$2['askId'], 'a1');
  });

  group('the service', () {
    test('in hub mode opens no local engine', () async {
      var phoneOpened = false;
      final started = await openServiceHome(
        mode: () async => HomeMode.hub,
        openPhone: () async {
          phoneOpened = true;
          return (client: FakeEngine() as EngineClient, hubError: null);
        },
        openHub: () async => (client: client as EngineClient, hubError: null),
      );
      expect(phoneOpened, isFalse);
      expect(started.client, same(client));
    });

    test('in phone mode opens the phone engine', () async {
      var hubOpened = false;
      final Started started = await openServiceHome(
        mode: () async => HomeMode.phone,
        openPhone: () async =>
            (client: FakeEngine() as EngineClient, hubError: null),
        openHub: () async {
          hubOpened = true;
          return (client: client as EngineClient, hubError: null);
        },
      );
      expect(hubOpened, isFalse);
      expect(started.client, isA<FakeEngine>());
    });

    test('the mode is kept, phone by default', () async {
      final store = HubSettingsStore(InMemorySecretStore());
      expect(await store.mode(), HomeMode.phone);
      await store.setMode(HomeMode.hub);
      await store.save(_settings);
      expect(await store.mode(), HomeMode.hub);
      expect((await store.settings())?.address, 'jade@mac-mini.local');
    });

    test(
      'switching back imports the hub home into the phone engine once',
      () async {
        final home = await Directory.systemTemp.createTemp('omni_handback');
        addTearDown(() => home.delete(recursive: true));
        await saveHubHandback(home, {'schema': 'omniflow.backup'});
        final engine = FakeEngine();
        await takeBackHubHome(engine, home);
        expect(engine.callsOf('config.import').single.$2, {
          'backup': {'schema': 'omniflow.backup'},
          'mode': 'replace',
        });
        expect(hubHandbackFile(home).existsSync(), isFalse);
        await takeBackHubHome(engine, home);
        expect(engine.callsOf('config.import'), hasLength(1));
      },
    );
  });
}
