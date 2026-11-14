import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client_hub.dart';
import 'package:omniflow_app/service/hub_connection.dart';
import 'package:omniflow_app/service/hub_engine_client.dart';
import 'package:omniflow_app/service/hub_settings.dart';
import 'package:omniflow_app/state/hub_mode.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/app.dart';
import 'package:omniflow_app/ui/settings/hub_page.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/theme.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

import 'fake_engine.dart';
import 'fake_hub.dart';
import 'screen_harness.dart';

const _offered = 'ssh-ed25519 SHA256:q1w2e3r4t5y6';

/// The setup steps' outside world: a probe that returns [_offered], a
/// trial connection that does what [refuse] says, a counted restart and
/// the hub home it was handed.
class _Tools {
  final kept = <Json>[];
  var restarts = 0;
  HubConnectException? refuse;
  final probed = <String>[];
  final tried = <HubSettings>[];

  HubSetupTools get tools => HubSetupTools(
    probeHostKey: (host, port) async {
      probed.add('$host:$port');
      return _offered;
    },
    tryConnect: (settings) async {
      tried.add(settings);
      if (refuse case final refuse?) throw refuse;
      return const HubHello(hubVersion: omniflowEngineVersion);
    },
    restartService: () async => restarts++,
    keepHubHome: (backup) async => kept.add(backup),
  );
}

Map<String, Object?> _link(
  HubLinkState state, {
  String? reason,
  String? hubVersion = '0.4.0',
}) => HubLinkView(
  state: state,
  address: 'jade@mac-mini.local',
  phone: 'jade_pixel',
  person: 'jade',
  connectedSince: DateTime.utc(2026, 11, 12, 8),
  hubVersion: hubVersion,
  appVersion: '0.4.0',
  reason: reason,
).toJson();

void main() {
  late InMemorySecretStore secrets;
  late HubSettingsStore store;
  late _Tools tools;

  setUp(() {
    secrets = InMemorySecretStore();
    store = HubSettingsStore(secrets);
    tools = _Tools();
  });

  List<Override> overrides() => [
    hubSettingsStoreProvider.overrideWithValue(store),
    hubSetupToolsProvider.overrideWithValue(tools.tools),
  ];

  group('the Hub not reachable banner', () {
    testWidgets('shows over every tab, and Try now reconnects', (tester) async {
      final engine = FakeEngine();
      engine.answers[HubLink.status] = {
        'ok': true,
        ..._link(HubLinkState.unreachable),
      };
      await pumpApp(tester, engine, overrides: overrides());
      expect(find.byKey(const ValueKey('hub-unreachable')), findsOneWidget);
      expect(find.textContaining('Hub not reachable'), findsOneWidget);
      await openTab(tester, 'Devices');
      expect(find.byKey(const ValueKey('hub-unreachable')), findsOneWidget);
      await tester.tap(find.text('Try now'));
      await tester.pump();
      expect(engine.callsOf(HubLink.reconnect), hasLength(1));
    });

    testWidgets('goes when the hub is back', (tester) async {
      final engine = FakeEngine();
      engine.answers[HubLink.status] = {
        'ok': true,
        ..._link(HubLinkState.unreachable),
      };
      await pumpApp(tester, engine, overrides: overrides());
      engine.eventsOut.add({
        'event': HubLink.event,
        ..._link(HubLinkState.connected),
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hub-unreachable')), findsNothing);
    });

    testWidgets('a version mismatch says which to update, with both versions', (
      tester,
    ) async {
      final engine = FakeEngine();
      await pumpApp(tester, engine, overrides: overrides());
      engine.eventsOut.add({
        'event': HubLink.event,
        ..._link(
          HubLinkState.versionMismatch,
          hubVersion: '0.3.0',
          reason: versionMismatchText('0.3.0', '0.4.0'),
        ),
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Update the hub. It runs 0.3.0 and this app is 0.4.0.'),
        findsOneWidget,
      );
    });

    testWidgets('is not there on a phone that runs its own home', (
      tester,
    ) async {
      await pumpApp(tester, FakeEngine(), overrides: overrides());
      expect(find.byKey(const ValueKey('hub-unreachable')), findsNothing);
    });

    testWidgets('with the hub gone the lists stay, read-only, and a change '
        'says why it cannot run', (tester) async {
      final hub = FakeHub();
      hub.answers['device.list'] = {
        'ok': true,
        'devices': [FakeEngine.lamp()],
      };
      final client = HubEngineClient(
        settings: const HubSettings(host: 'mac', user: 'jade', phone: 'p'),
        connect: hub.connect,
        backoff: (_) => const Duration(hours: 1),
      );
      addTearDown(client.close);
      await client.start();
      await client.call('device.list', {'withCapabilities': true});
      hub.refuse = const HubConnectException('unavailable', 'gone');
      hub.drop();
      tester.view.physicalSize = const Size(1236, 5400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            engineClientProvider.overrideWithValue(client),
            ...overrides(),
          ],
          child: const OmniFlowApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hub-unreachable')), findsOneWidget);
      await openTab(tester, 'Devices');
      expect(find.text('Desk lamp'), findsWidgets);
      final change = await callClient(client, 'device.invoke', {
        'id': 'desk_lamp',
        'capability': 'power',
        'params': {'value': true},
      });
      await tester.pump();
      expect(change['ok'], false);
      expect(find.text(HubEngineClient.unreachableReason), findsOneWidget);
      // The client's retry timer lives in the test's clock: stop it before
      // the test ends.
      await tester.pumpWidget(const SizedBox());
      await client.close();
    });
  });

  group('setting up the hub', () {
    Future<void> fill(WidgetTester tester) async {
      await tester.enterText(find.byKey(const ValueKey('hub-user')), 'jade');
      await tester.enterText(
        find.byKey(const ValueKey('hub-phone')),
        'Jade Pixel',
      );
      await tester.pump();
    }

    testWidgets('finds a hub, shows the allow line, then the fingerprint, and '
        'switches once it matches', (tester) async {
      final engine = FakeEngine();
      engine.answers[HubLink.discover] = {
        'ok': true,
        'hubs': [
          {'name': 'Mac mini', 'host': '192.168.1.20', 'port': 22},
        ],
      };
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      await pumpScreen(tester, engine, const HubPage(), overrides: overrides());
      expect(find.byKey(const ValueKey('hub-setup')), findsOneWidget);
      // Connect waits for an address, a user and the key.
      expect(
        tester.widget<OmniButton>(find.byKey(const ValueKey('hub-check'))),
        isA<OmniButton>().having((b) => b.onPressed, 'onPressed', isNull),
      );

      await tester.tap(find.byKey(const ValueKey('hub-look')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hub-found-0')));
      await tester.pump();
      expect(find.text('192.168.1.20'), findsOneWidget);
      await fill(tester);

      await tester.tap(find.byKey(const ValueKey('hub-make-key')));
      await tester.pumpAndSettle();
      final line = tester
          .widget<SelectableText>(find.byKey(const ValueKey('hub-allow-line')))
          .data!;
      expect(line, startsWith("omni hub allow jade_pixel 'ssh-ed25519 AAAA"));
      expect(await secrets.read(HubSettingsStore.privateKeyKey), isNotNull);
      expect(line, isNot(contains('PRIVATE')));
      await tester.tap(find.byKey(const ValueKey('hub-copy')));
      await tester.pump();
      expect(copied, line);

      await tester.tap(find.byKey(const ValueKey('hub-check')));
      await tester.pumpAndSettle();
      expect(tools.probed, ['192.168.1.20:22']);
      expect(find.text('SHA256:q1w2e3r4t5y6'), findsOneWidget);
      expect(find.textContaining('omni hub fingerprint'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('hub-matches')));
      await tester.pumpAndSettle();
      expect(tools.tried.single.phone, 'jade_pixel');
      expect(tools.restarts, 1);
      expect(await store.mode(), HomeMode.hub);
      final saved = await store.settings();
      expect(saved?.host, '192.168.1.20');
      expect(saved?.hostKey, _offered);
      expect(await store.pinnedHostKey(saved!), _offered);
    });

    testWidgets('a hub that refuses the key says to run the allow line, and '
        'nothing switches', (tester) async {
      tools.refuse = const HubConnectException('not_allowed', 'denied');
      await pumpScreen(
        tester,
        FakeEngine(),
        const HubPage(),
        overrides: overrides(),
      );
      await tester.enterText(
        find.byKey(const ValueKey('hub-host')),
        'mac-mini.local',
      );
      await fill(tester);
      await tester.tap(find.byKey(const ValueKey('hub-make-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hub-check')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hub-matches')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hub-problem')), findsOneWidget);
      expect(find.textContaining('did not let this phone in'), findsOneWidget);
      expect(tools.restarts, 0);
      expect(await store.mode(), HomeMode.phone);
    });

    testWidgets('a fingerprint that does not match connects to nothing', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        FakeEngine(),
        const HubPage(),
        overrides: overrides(),
      );
      await tester.enterText(find.byKey(const ValueKey('hub-host')), 'mac');
      await fill(tester);
      await tester.tap(find.byKey(const ValueKey('hub-make-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hub-check')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hub-no-match')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Do not connect'), findsOneWidget);
      expect(tools.tried, isEmpty);
      expect(await secrets.read(HostKeyPins.keyFor('mac', 22)), isNull);
    });

    testWidgets('with no hub found, it asks for the address', (tester) async {
      final engine = FakeEngine();
      engine.answers[HubLink.discover] = {
        'ok': false,
        'error': {'type': 'not_found', 'message': 'unknown command'},
      };
      await pumpScreen(tester, engine, const HubPage(), overrides: overrides());
      await tester.tap(find.byKey(const ValueKey('hub-look')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hub-none-found')), findsOneWidget);
    });
  });

  group('the hub page in hub mode', () {
    Future<FakeEngine> open(WidgetTester tester) async {
      await store.setMode(HomeMode.hub);
      await store.save(
        const HubSettings(
          host: 'mac-mini.local',
          user: 'jade',
          phone: 'jade_pixel',
        ),
      );
      final engine = FakeEngine();
      engine.answers[HubLink.status] = {
        'ok': true,
        ..._link(HubLinkState.connected),
      };
      engine.answers[HubLink.clients] = {
        'ok': true,
        'clients': [
          {'phone': 'jade_pixel', 'person': 'jade'},
          {'phone': 'sam-phone', 'person': 'sam'},
        ],
      };
      engine.answers['config.export'] = {
        'ok': true,
        'backup': {'schema': 'omniflow.backup', 'things': []},
      };
      await pumpScreen(tester, engine, const HubPage(), overrides: overrides());
      return engine;
    }

    testWidgets('shows the address, since, version and the phones', (
      tester,
    ) async {
      final engine = await open(tester);
      expect(find.text('Connected to the Mac mini hub'), findsOneWidget);
      expect(find.text('jade@mac-mini.local'), findsOneWidget);
      expect(find.text('0.4.0'), findsOneWidget);
      expect(find.text('sam-phone'), findsOneWidget);
      expect(find.text('Asks for jade show here'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hub-reconnect')));
      await tester.pumpAndSettle();
      expect(engine.callsOf(HubLink.reconnect), hasLength(1));
    });

    testWidgets('Switch back asks first, then brings the hub home along', (
      tester,
    ) async {
      await open(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('hub-switch-phone')),
      );
      await tester.tap(find.byKey(const ValueKey('hub-switch-phone')));
      await tester.pumpAndSettle();
      expect(find.text('Run the home on this phone?'), findsOneWidget);
      await tester.tap(find.text('Switch'));
      await tester.pumpAndSettle();
      expect(await store.mode(), HomeMode.phone);
      expect(tools.restarts, 1);
      expect(tools.kept.single['schema'], 'omniflow.backup');
    });

    testWidgets('Cancel on Switch back changes nothing', (tester) async {
      await open(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('hub-switch-phone')),
      );
      await tester.tap(find.byKey(const ValueKey('hub-switch-phone')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await store.mode(), HomeMode.hub);
      expect(tools.restarts, 0);
    });
  });

  testWidgets('Settings shows where the home runs', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          engineClientProvider.overrideWithValue(FakeEngine()),
          ...overrides(),
        ],
        child: MaterialApp(
          theme: omniTheme(),
          home: const Scaffold(body: HomeRunsOnRow()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This phone'), findsOneWidget);
  });
}
