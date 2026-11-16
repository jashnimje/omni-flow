import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:path_provider/path_provider.dart';

import '../api/engine_client.dart';
import '../api/engine_client_hub.dart';
import '../service/foreground_runtime.dart' show ForegroundServiceControl;
import '../service/hub_connection.dart';
import '../service/hub_handback.dart';
import '../service/hub_settings.dart';
import '../service/ssh_hub_connection.dart';
import 'providers.dart';

export '../api/engine_client_hub.dart' show HubLinkView, HubLinkState;
export '../service/hub_settings.dart' show HomeMode, HubSettings;

/// The home mode and hub settings, in the phone's keystore. Tests put in
/// one over an in-memory store.
final hubSettingsStoreProvider = Provider<HubSettingsStore>(
  (ref) => HubSettingsStore(SecureStorageSecretStore()),
);

/// Where this phone's home runs, as last saved.
final homeModeProvider = FutureProvider<HomeMode>(
  (ref) => ref.watch(hubSettingsStoreProvider).mode(),
);

final hubSettingsProvider = FutureProvider<HubSettings?>(
  (ref) => ref.watch(hubSettingsStoreProvider).settings(),
);

/// The link to the hub, kept current from the service's hub client. Null on
/// a phone that runs its own home. Coming back to the app while the hub is
/// not reachable tries again at once, since the phone may have changed
/// network while it was away.
class HubLinkNotifier extends Notifier<HubLinkView?> {
  @override
  HubLinkView? build() {
    final client = ref.watch(engineClientProvider);
    final sub = client.events
        .where((e) => e['event'] == HubLink.event)
        .listen((e) => state = HubLinkView.fromJson(e) ?? state);
    ref.onDispose(sub.cancel);
    final resumed = _onResume(() {
      final link = state;
      if (link != null && !link.connected) unawaited(reconnect());
    });
    if (resumed != null) ref.onDispose(resumed.dispose);
    unawaited(_load(client));
    return null;
  }

  /// Null where no Flutter binding runs, as in a plain unit test.
  static AppLifecycleListener? _onResume(void Function() onResume) {
    try {
      return AppLifecycleListener(onResume: onResume);
    } on Object {
      return null;
    }
  }

  Future<void> _load(EngineClient client) async {
    final view = await HubCalls(client).link();
    if (ref.mounted && view != null) state = view;
  }

  /// Connects again now instead of waiting for the next retry.
  Future<void> reconnect() =>
      HubCalls(ref.read(engineClientProvider)).reconnect();
}

final hubLinkProvider = NotifierProvider<HubLinkNotifier, HubLinkView?>(
  HubLinkNotifier.new,
);

/// The phones connected to the hub now.
final hubClientsProvider = FutureProvider<List<Json>?>(
  (ref) => HubCalls(ref.watch(engineClientProvider)).clients(),
);

/// The steps of setting up and leaving hub mode that reach outside the
/// engine client: the SSH host key probe, a trial connection, restarting
/// the service and keeping the hub home for the phone engine to import.
/// Tests put in fakes.
class HubSetupTools {
  const HubSetupTools({
    required this.probeHostKey,
    required this.tryConnect,
    required this.restartService,
    required this.keepHubHome,
  });

  /// The host key the hub offers, as `<type> SHA256:...`, without
  /// sending it any credential.
  final Future<String> Function(String host, int port) probeHostKey;

  /// Opens and closes one connection with the saved key and pinned host
  /// key. Throws [HubConnectException].
  final Future<HubHello> Function(HubSettings settings) tryConnect;
  final Future<void> Function() restartService;

  /// Keeps the hub home where the phone engine imports it as it opens.
  final Future<void> Function(Json backup) keepHubHome;
}

final hubSetupToolsProvider = Provider<HubSetupTools>(
  (ref) => HubSetupTools(
    probeHostKey: (host, port) => probeSshHostKey(host, port),
    tryConnect: (settings) async {
      final connection = sshHubSession(
        settings: settings,
        secrets: SecureStorageSecretStore(),
        privateKeySecret: HubSettingsStore.privateKeyKey,
      );
      try {
        return await connection.open();
      } finally {
        await connection.close();
      }
    },
    restartService: const ForegroundServiceControl().restart,
    keepHubHome: (backup) async {
      final support = await getApplicationSupportDirectory();
      await saveHubHandback(Directory('${support.path}/omniflow'), backup);
    },
  ),
);

/// Turns hub mode on once the user matched the host key and the hub let
/// this phone in, then restarts the service so it opens no local engine.
Future<void> switchToHub(
  WidgetRef ref,
  HubSettings settings, {
  required String hostKey,
}) async {
  final store = ref.read(hubSettingsStoreProvider);
  await store.save(settings.withHostKey(hostKey));
  await store.setMode(HomeMode.hub);
  ref.invalidate(homeModeProvider);
  ref.invalidate(hubSettingsProvider);
  await ref.read(hubSetupToolsProvider).restartService();
}

/// Back to running the home on this phone. When the hub answers, its home
/// comes along: the phone engine imports it as it opens.
Future<bool> switchToPhone(WidgetRef ref) async {
  final tools = ref.read(hubSetupToolsProvider);
  final backup = await HubCalls(ref.read(engineClientProvider)).export();
  if (backup != null) await tools.keepHubHome(backup);
  await ref.read(hubSettingsStoreProvider).setMode(HomeMode.phone);
  ref.invalidate(homeModeProvider);
  await tools.restartService();
  return backup != null;
}
