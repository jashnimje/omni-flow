import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/engine_calls.dart';
import '../state/appearance.dart' show paletteProvider;
import '../state/providers.dart';
import 'design/design.dart';
import 'settings/whats_new.dart' show whatsNewOnStart;
import 'shell/shell.dart';
import 'tags/nfc_forwarder.dart';
import 'theme.dart';

/// The app. Route pushes from Android (a notification that names a place)
/// become shell links: the app registers for them before MaterialApp does,
/// so MaterialApp never tries to resolve them as named routes.
class OmniFlowApp extends ConsumerStatefulWidget {
  const OmniFlowApp({super.key});

  @override
  ConsumerState<OmniFlowApp> createState() => _OmniFlowAppState();
}

class _OmniFlowAppState extends ConsumerState<OmniFlowApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final launched = ShellLink.parse(
      WidgetsBinding.instance.platformDispatcher.defaultRouteName,
    );
    if (launched != null && launched is! TabLink) {
      unawaited(ref.read(shellControllerProvider).open(launched));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation info) async {
    final link = ShellLink.parse(info.uri.toString());
    if (link != null) unawaited(ref.read(shellControllerProvider).open(link));
    // The app has no named routes, so nothing else should try to push one.
    return true;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OmniFlow',
    theme: omniTheme(palette: ref.watch(paletteProvider)),
    scaffoldMessengerKey: messengerKey,
    onGenerateInitialRoutes: (_) => [
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/'),
        builder: (_) => const Home(),
      ),
    ],
    routes: {'/': (_) => const Home()},
  );
}

/// The shell, plus what the app does whatever tab is open: offer to add a
/// board that says hello, offer to name an unknown NFC tag, show a rule's
/// Notify step and forward NFC scans.
class Home extends ConsumerStatefulWidget {
  const Home({super.key});

  @override
  ConsumerState<Home> createState() => _HomeState();
}

class _HomeState extends ConsumerState<Home> {
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
    whatsNewOnStart(context, ref);
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
        persist: false,
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
    final hubError = ref.watch(hubErrorProvider);
    return OmniShell(
      banner: hubError == null || _hubBannerClosed
          ? null
          : OmniBanner.error(
              'The hub did not start, so automations only run when you run '
              'them: $hubError',
              key: const ValueKey('hub-error'),
              actionLabel: 'Dismiss',
              onAction: () => setState(() => _hubBannerClosed = true),
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
