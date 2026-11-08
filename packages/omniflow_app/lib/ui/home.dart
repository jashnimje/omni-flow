import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'command_bar.dart';
import 'dashboard.dart';
import 'flows_screen.dart';
import 'inspector.dart';
import 'device_sheets.dart';
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
  StreamSubscription<Json>? _found;

  @override
  void initState() {
    super.initState();
    // A board on Wi-Fi says hello every 30 seconds: offer to add it once.
    _found = ref
        .read(engineClientProvider)
        .events
        .where((e) => e['event'] == 'board.found')
        .listen(_offerBoard);
  }

  @override
  void dispose() {
    _found?.cancel();
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
      floatingActionButton: _tab == 0
          ? FloatingActionButton.extended(
              key: const ValueKey('add-device'),
              onPressed: () => showAddDevice(context),
              icon: const Icon(Icons.add),
              label: const Text('Add device'),
            )
          : null,
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
