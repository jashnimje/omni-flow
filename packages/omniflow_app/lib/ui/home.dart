import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/engine_calls.dart';
import '../state/providers.dart';
import 'add_thing.dart';
import 'command_bar.dart';
import 'dashboard.dart';
import 'flows_screen.dart';
import 'inspector.dart';
import 'nfc_ui.dart';
import 'rule_builder.dart';
import 'theme.dart';

class OmniFlowApp extends StatelessWidget {
  const OmniFlowApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OmniFlow',
    theme: omniTheme(),
    scaffoldMessengerKey: messengerKey,
    home: const Home(),
  );
}

class Home extends ConsumerStatefulWidget {
  const Home({super.key});

  @override
  ConsumerState<Home> createState() => _HomeState();
}

class _HomeState extends ConsumerState<Home> {
  var _tab = 0;
  var _hubBannerClosed = false;
  final _offered = <String>{};
  final _offeredTags = <String>{};
  StreamSubscription<Json>? _found;
  StreamSubscription<Json>? _unknownTags;
  StreamSubscription<Json>? _announced;
  late final NfcForwarder _nfc;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final engine = ref.read(engineClientProvider);
    // A board on Wi-Fi says hello every 30 seconds: offer to add it once.
    _found = engine.events
        .where((e) => e['event'] == 'board.found')
        .listen(_offerBoard);
    _unknownTags = engine.events
        .where((e) => e['event'] == EngineCalls.tagUnknownEvent)
        .listen((e) {
          if (mounted) offerToNameTag(context, ref, e, _offeredTags);
        });
    // A rule's Notify step, while the app is open. Android notifications
    // from the service come later.
    _announced = engine.events
        .where((e) => e['event'] == EngineCalls.flowAnnounceEvent)
        .listen((e) => showMessage(announcementText(e)));
    _nfc = NfcForwarder(
      engine,
      ref.read(nfcAdapterProvider),
      ref.read(nfcIntentsProvider),
    );
    unawaited(_nfc.start());
    // Reader mode only works while the app is in front.
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_nfc.resume()),
      onPause: () => unawaited(_nfc.pause()),
    );
  }

  @override
  void dispose() {
    _found?.cancel();
    _unknownTags?.cancel();
    _announced?.cancel();
    _lifecycle.dispose();
    unawaited(_nfc.close());
    super.dispose();
  }

  void _offerBoard(Json e) {
    final node = e['node'];
    if (node is! String || !_offered.add(node)) return;
    messengerKey.currentState?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 20),
        content: Text('New board found: $node (${e['board']}) at ${e['host']}'),
        action: SnackBarAction(
          label: 'Add',
          onPressed: () async {
            final added = await callEngine(
              ref,
              'device.add',
              Map<String, Object?>.from(e['add'] as Map? ?? const {}),
            );
            if (added['ok'] == true) {
              await ref.read(devicesProvider.notifier).refresh();
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep the inspector collecting from launch, without rebuilding here
    // on every packet.
    ref.listen(packetsProvider, (_, _) {});
    final hubError = ref.watch(hubErrorProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('OmniFlow')),
      floatingActionButton: switch (_tab) {
        0 => FloatingActionButton.extended(
          key: const ValueKey('add-device'),
          onPressed: () => openAddThing(context),
          icon: const Icon(Icons.add),
          label: const Text('Add'),
        ),
        1 => FloatingActionButton.extended(
          key: const ValueKey('new-rule'),
          onPressed: () => openRuleBuilder(context),
          icon: const Icon(Icons.add),
          label: const Text('New rule'),
        ),
        _ => null,
      },
      body: Column(
        children: [
          if (hubError != null && !_hubBannerClosed)
            MaterialBanner(
              key: const ValueKey('hub-error'),
              content: Text(
                'The hub did not start, so flows only run when you run them: $hubError',
              ),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _hubBannerClosed = true),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          const CommandBar(),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: const [Dashboard(), FlowsScreen(), Inspector()],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            label: 'Devices',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_tree_outlined),
            label: 'Flows',
          ),
          NavigationDestination(
            icon: Icon(Icons.wifi_tethering),
            label: 'Packets',
          ),
        ],
      ),
    );
  }
}

/// A Notify step's title, then its text when it has one.
String announcementText(Json event) => [
  for (final key in const ['title', 'body'])
    if (event[key] case final Object value when '$value'.trim().isNotEmpty)
      '$value',
].join(': ');
