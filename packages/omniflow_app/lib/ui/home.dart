import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'command_bar.dart';
import 'dashboard.dart';
import 'flows_screen.dart';
import 'inspector.dart';
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

  @override
  Widget build(BuildContext context) {
    // Keep the inspector collecting from launch, not from the first visit.
    ref.watch(packetsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('OmniFlow')),
      body: Column(
        children: [
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
