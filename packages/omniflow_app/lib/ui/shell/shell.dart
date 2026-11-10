import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../add/add_page.dart';
import '../design/design.dart';
import 'links.dart';
import 'tabs.dart';

export 'links.dart';

/// Where the app is: the selected tab and each tab's own navigator, so each
/// tab keeps its back stack. Any screen opens a place with
/// `ref.read(shellControllerProvider).open(link)`; a link that arrives
/// before the shell is on screen (a notification that launched the app)
/// waits for it.
class ShellController extends ChangeNotifier {
  final navigators = {
    for (final t in ShellTab.values) t: GlobalKey<NavigatorState>(),
  };
  final _depth = {for (final t in ShellTab.values) t: 1};
  var _tab = ShellTab.home;
  ShellLink? _pending;
  var _attached = false;

  ShellTab get tab => _tab;

  /// Whether [tab] shows its root page, which is when its button shows.
  bool atRoot(ShellTab tab) => _depth[tab]! <= 1;

  /// Shows [tab]. Choosing the tab already shown goes back to its root.
  void select(ShellTab tab) {
    if (tab == _tab) {
      navigators[tab]!.currentState?.popUntil((r) => r.isFirst);
      return;
    }
    _tab = tab;
    notifyListeners();
  }

  /// Opens [link] on its tab, over the tab's root.
  Future<void> open(ShellLink link) async {
    if (!_attached) {
      _pending = link;
      return;
    }
    final tab = link is AddLink ? _tab : link.tab;
    if (tab != _tab) {
      _tab = tab;
      notifyListeners();
    }
    // A tab shown for the first time builds its navigator on the next frame.
    if (navigators[tab]!.currentState == null) {
      await WidgetsBinding.instance.endOfFrame;
    }
    final nav = navigators[tab]!.currentState;
    if (nav == null || !nav.mounted) return;
    if (link is AddLink) {
      await openAddThing(nav.context);
      return;
    }
    nav.popUntil((r) => r.isFirst);
    final page = shellPageFor(link);
    if (page == null) return;
    await nav.push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: link.location),
        builder: (_) => page,
      ),
    );
  }

  /// What the system back does: pop the tab's own stack, then go to Home,
  /// then leave the app. False when it should leave.
  Future<bool> back() async {
    final nav = navigators[_tab]!.currentState;
    if (nav != null && nav.canPop()) {
      await nav.maybePop();
      return true;
    }
    if (_tab != ShellTab.home) {
      select(ShellTab.home);
      return true;
    }
    return false;
  }

  void _attach() {
    _attached = true;
    if (_pending case final link?) {
      _pending = null;
      scheduleMicrotask(() => open(link));
    }
  }

  void _detach() => _attached = false;

  void _setDepth(ShellTab tab, int depth) {
    if (_depth[tab] == depth) return;
    _depth[tab] = depth;
    notifyListeners();
  }
}

final shellControllerProvider = Provider<ShellController>((ref) {
  final controller = ShellController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// The four tabs (Home, Automations, Devices, Settings) in a bottom bar,
/// each with its own back stack, and the Add or New button of the tab's
/// root. [banner] shows above every tab (the hub did not start).
class OmniShell extends ConsumerStatefulWidget {
  const OmniShell({super.key, this.banner});

  final Widget? banner;

  @override
  ConsumerState<OmniShell> createState() => _OmniShellState();
}

class _OmniShellState extends ConsumerState<OmniShell> {
  late final ShellController _shell = ref.read(shellControllerProvider);
  final _built = <ShellTab>{};
  late final _observers = {
    for (final t in ShellTab.values) t: _DepthObserver(t, _shell._setDepth),
  };

  @override
  void initState() {
    super.initState();
    _shell._attach();
  }

  @override
  void dispose() {
    _shell._detach();
    super.dispose();
  }

  Widget _navigator(ShellTab tab) => Navigator(
    key: _shell.navigators[tab],
    observers: [_observers[tab]!],
    onGenerateRoute: (settings) => MaterialPageRoute<void>(
      settings: settings,
      builder: shellTabs[tab]!.root,
    ),
  );

  Future<void> _back() async {
    if (!await _shell.back()) await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _shell,
    builder: (context, _) {
      final tab = _shell.tab;
      _built.add(tab);
      final spec = _shell.atRoot(tab) ? shellTabs[tab]!.fab : null;
      final fab = spec?.hiddenWhen?.call(ref) == true ? null : spec;
      Widget tabs = IndexedStack(
        index: tab.index,
        children: [
          for (final t in ShellTab.values)
            TickerMode(
              enabled: t == tab,
              child: _built.contains(t) ? _navigator(t) : const SizedBox(),
            ),
        ],
      );
      if (widget.banner case final banner?) {
        tabs = Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                child: banner,
              ),
            ),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: tabs,
              ),
            ),
          ],
        );
      }
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_back());
        },
        child: Scaffold(
          body: tabs,
          floatingActionButton: fab == null
              ? null
              : FloatingActionButton.extended(
                  key: fab.key,
                  heroTag: null,
                  onPressed: () {
                    final nav = _shell.navigators[tab]!.currentContext;
                    if (nav != null) fab.onPressed(nav);
                  },
                  icon: Icon(fab.icon, weight: 600),
                  label: Text(fab.label),
                ),
          bottomNavigationBar: shellTabs[tab]!.fullScreenWhen?.call(ref) == true
              ? null
              : DecoratedBox(
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: OmniColors.line)),
                  ),
                  child: NavigationBar(
                    key: const ValueKey('shell-tabs'),
                    selectedIndex: tab.index,
                    animationDuration: OmniMotion.of(context, OmniMotion.slow),
                    onDestinationSelected: (i) =>
                        _shell.select(ShellTab.values[i]),
                    destinations: [
                      for (final t in ShellTab.values)
                        NavigationDestination(
                          key: ValueKey('tab-${t.name}'),
                          icon: Icon(shellTabs[t]!.icon),
                          selectedIcon: Icon(shellTabs[t]!.icon, fill: 1),
                          label: shellTabs[t]!.label,
                        ),
                    ],
                  ),
                ),
        ),
      );
    },
  );
}

/// Counts the routes on one tab's navigator. A sheet or menu opened in the
/// tab counts too, so the tab's button never floats over it.
class _DepthObserver extends NavigatorObserver {
  _DepthObserver(this.tab, this.report);

  final ShellTab tab;
  final void Function(ShellTab tab, int depth) report;
  var _pages = 0;

  void _changed(Route<dynamic>? route, int delta) {
    if (route is! ModalRoute) return;
    _pages += delta;
    final depth = _pages;
    // Navigator callbacks arrive mid-build, so the shell rebuilds after.
    WidgetsBinding.instance.addPostFrameCallback((_) => report(tab, depth));
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _changed(route, 1);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _changed(route, -1);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _changed(route, -1);
}
