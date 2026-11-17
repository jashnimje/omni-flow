import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/appearance.dart';
import '../add/add_page.dart';
import '../theme.dart';
import 'hub_banner.dart';
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

/// The four tabs (Home, Automations, Devices, Settings), each with its own
/// back stack, and the Add or New button of the tab's root. The tabs sit
/// in a bottom bar on a phone and in a rail on wider screens, and a tab
/// slides in on a shared axis. [banner] shows above every tab (the hub
/// did not start). The shell applies the Appearance setting, so changing
/// it recolours the app at once.
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
  var _previous = ShellTab.home;
  OmniPalette? _palette;
  ThemeData? _theme;

  @override
  void initState() {
    super.initState();
    _shell._attach();
    // Pages draw under the status and navigation bars; each pads itself
    // by the real insets.
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }

  ThemeData _themeFor(OmniPalette palette) {
    if (palette != _palette || _theme == null) {
      _palette = palette;
      _theme = omniTheme(palette: palette);
    }
    return _theme!;
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
  Widget build(BuildContext context) {
    final theme = _themeFor(ref.watch(paletteProvider));
    return AnimatedTheme(
      data: theme,
      duration: OmniMotion.of(context),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: omniSystemBars,
        child: ListenableBuilder(listenable: _shell, builder: _frame),
      ),
    );
  }

  Widget _frame(BuildContext context, Widget? _) {
    final tab = _shell.tab;
    final forward = tab.index >= _previous.index;
    _previous = tab;
    _built.add(tab);
    final spec = _shell.atRoot(tab) ? shellTabs[tab]!.fab : null;
    final fab = spec?.hiddenWhen?.call(ref) == true ? null : spec;
    final fullScreen = shellTabs[tab]!.fullScreenWhen?.call(ref) == true;
    final wide = OmniWidth.of(context) != OmniWidth.compact;
    // A tab's page route blocks the semantics painted before it, so the
    // tabs get their own boundary and the banner and rail stay readable.
    Widget tabs = Semantics(
      container: true,
      explicitChildNodes: true,
      child: IndexedStack(
        index: tab.index,
        children: [
          for (final t in ShellTab.values)
            TickerMode(
              enabled: t == tab,
              child: _TabEntrance(
                active: t == tab,
                forward: forward,
                child: _built.contains(t) ? _navigator(t) : const SizedBox(),
              ),
            ),
        ],
      ),
    );
    if (hubBanner(ref) ?? widget.banner case final banner?) {
      tabs = Column(
        children: [
          SafeArea(
            bottom: false,
            left: !wide,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                OmniSpace.screen,
                OmniSpace.sm,
                OmniSpace.screen,
                0,
              ),
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
    final palette = OmniPalette.of(context);
    if (wide && !fullScreen) {
      tabs = Row(
        children: [
          _rail(context, tab, palette, fab),
          VerticalDivider(width: 1, color: palette.line),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeLeft: true,
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
        floatingActionButton: fab == null || (wide && !fullScreen)
            ? null
            : _fabButton(context, fab, tab),
        bottomNavigationBar: fullScreen || wide
            ? null
            : DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: palette.line)),
                ),
                // Built under the Scaffold so the bar reads the padding the
                // Scaffold already took the status bar out of.
                child: Builder(builder: (context) => _bar(context, tab)),
              ),
      ),
    );
  }

  void _select(int i) {
    unawaited(HapticFeedback.selectionClick());
    _shell.select(ShellTab.values[i]);
  }

  /// The bottom bar. It grows with the text size, and its labels stop
  /// growing at one and a half times so four still fit across a phone.
  Widget _bar(BuildContext context, ShellTab tab) {
    final scaler = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: _maxLabelScale);
    final label = scaler.scale(OmniText.navLabel.fontSize!) * 1.4;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: _maxLabelScale,
      child: NavigationBar(
        key: const ValueKey('shell-tabs'),
        height: OmniSpace.target + label,
        selectedIndex: tab.index,
        animationDuration: OmniMotion.of(context, OmniMotion.slow),
        onDestinationSelected: _select,
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
    );
  }

  static const _maxLabelScale = 1.5;

  /// The tab root's Add or New. Extended on a phone at normal text sizes;
  /// just the icon at large text sizes and in the rail, so it never sits
  /// over a row the list cannot scroll clear of it. The label is still
  /// read out and shown on a long press.
  Widget _fabButton(BuildContext context, ShellFab fab, ShellTab tab) {
    void press() {
      final nav = _shell.navigators[tab]!.currentContext;
      if (nav != null) fab.onPressed(nav);
    }

    final large =
        MediaQuery.textScalerOf(context).scale(OmniText.body.fontSize!) /
            OmniText.body.fontSize! >=
        largeTextScale;
    final wide = OmniWidth.of(context) != OmniWidth.compact;
    if (large || wide) {
      return MediaQuery.withNoTextScaling(
        child: FloatingActionButton(
          key: fab.key,
          heroTag: null,
          tooltip: fab.label,
          elevation: wide ? 0 : null,
          onPressed: press,
          child: Icon(fab.icon, weight: 600),
        ),
      );
    }
    return FloatingActionButton.extended(
      key: fab.key,
      heroTag: null,
      onPressed: press,
      icon: Icon(fab.icon, weight: 600),
      label: Text(fab.label),
    );
  }

  /// From this text size the floating button shows only its icon.
  static const largeTextScale = 1.3;

  /// The rail of a foldable, a tablet or a phone on its side. The tab
  /// root's button sits at its top, so it covers nothing; the space stays
  /// when a page hides it, so the tabs do not move.
  Widget _rail(
    BuildContext context,
    ShellTab tab,
    OmniPalette palette,
    ShellFab? fab,
  ) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: _maxLabelScale,
    child: SafeArea(
      right: false,
      child: NavigationRail(
        key: const ValueKey('shell-rail'),
        selectedIndex: tab.index,
        onDestinationSelected: _select,
        leading: Padding(
          padding: const EdgeInsets.only(top: OmniSpace.sm),
          child: fab == null
              ? const SizedBox.square(dimension: 56)
              : _fabButton(context, fab, tab),
        ),
        groupAlignment: -0.9,
        destinations: [
          for (final t in ShellTab.values)
            NavigationRailDestination(
              icon: Icon(shellTabs[t]!.icon),
              selectedIcon: Icon(shellTabs[t]!.icon, fill: 1),
              label: Text(shellTabs[t]!.label),
            ),
        ],
      ),
    ),
  );
}

/// A tab arriving: it slides a little from the side it comes from and
/// fades in (Material's shared axis). Nothing moves under reduced motion.
class _TabEntrance extends StatefulWidget {
  const _TabEntrance({
    required this.active,
    required this.forward,
    required this.child,
  });

  final bool active;
  final bool forward;
  final Widget child;

  @override
  State<_TabEntrance> createState() => _TabEntranceState();
}

class _TabEntranceState extends State<_TabEntrance>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: OmniMotion.medium,
    value: 1,
  );
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: OmniMotion.emphasizedIn,
  );

  @override
  void didUpdateWidget(_TabEntrance old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active && !OmniMotion.reduced(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.forward ? 1.0 : -1.0;
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) {
        final t = _curve.value;
        return FractionalTranslation(
          translation: Offset(side * 0.08 * (1 - t), 0),
          child: Opacity(opacity: t, child: child),
        );
      },
    );
  }
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
