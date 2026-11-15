import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:path_provider/path_provider.dart';

import '../api/engine_client.dart';
import '../startup.dart';
import 'engine_host.dart';
import 'engine_owner.dart';
import 'engine_link.dart';
import 'hub_bridge.dart';
import 'hub_engine_client.dart';
import 'hub_handback.dart';
import 'hub_settings.dart';
import 'multicast_lock.dart';
import 'ssh_hub_connection.dart';
import 'notifier.dart';
import 'phone_actions.dart';
import 'phone_inputs.dart';
import 'service_engine_client.dart';
import 'usb_links.dart';

/// The id of the notification's Stop button.
const stopButtonId = 'stop';

/// The always-on service notification. The service keeps the options it
/// started with, even across an app update, so the app sets them again on
/// every start.
const serviceTitle = 'OmniFlow is running';
const serviceText = 'Flows keep running with the screen off';
const serviceIcon = NotificationIcon(
  metaDataName: 'com.jashnm.omniflow_app.SERVICE_ICON',
  backgroundColor: Color(0xFF00F5D4),
);
const serviceButtons = [NotificationButton(id: stopButtonId, text: 'Stop')];

/// Starts and checks the Android service, so tests can stand in for it.
abstract interface class ServiceControl {
  Future<bool> get isRunning;
  Future<void> start();
  Future<void> restart();
}

/// A service whose notification can be set again to the current title,
/// text, icon and buttons.
abstract interface class RefreshableService {
  Future<void> refreshNotification();
}

/// Connects the UI to the engine in the foreground service, starting the
/// service when it is not running. A running service that does not answer,
/// or whose engine did not open, is restarted once, so Retry on the start
/// screen is a real second attempt.
Future<Started> connectToService({
  required ServiceControl control,
  required EngineLink Function() link,
  Duration timeout = const Duration(seconds: 30),
  Duration runningTimeout = const Duration(seconds: 5),
}) async {
  if (await control.isRunning) {
    final client = ServiceEngineClient(link());
    try {
      final hubError = await client.connect(timeout: runningTimeout);
      await _refresh(control);
      return (client: client, hubError: hubError);
    } on Object {
      await client.close();
      await control.restart();
    }
  } else {
    await control.start();
  }
  final client = ServiceEngineClient(link());
  try {
    final hubError = await client.connect(timeout: timeout);
    await _refresh(control);
    return (client: client, hubError: hubError);
  } on Object {
    await client.close();
    rethrow;
  }
}

/// A notification that does not refresh still shows, so a failure here
/// never stops the app from connecting.
Future<void> _refresh(ServiceControl control) async {
  if (control is! RefreshableService) return;
  final RefreshableService service = control as RefreshableService;
  try {
    await service.refreshNotification();
  } on Object catch (e) {
    debugPrint('OmniFlow service notification not refreshed: $e');
  }
}

/// The service through flutter_foreground_task. The task runs in its own
/// Flutter engine and isolate, so the UI reaches it only through
/// [ForegroundTaskLink].
class ForegroundServiceControl implements ServiceControl, RefreshableService {
  const ForegroundServiceControl();

  static const _serviceId = 7101;

  @override
  Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  @override
  Future<void> start() async {
    _init();
    await _askToNotify();
    _check(
      await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: const [ForegroundServiceTypes.connectedDevice],
        notificationTitle: serviceTitle,
        notificationText: serviceText,
        notificationIcon: serviceIcon,
        notificationButtons: serviceButtons,
        callback: startOmniService,
      ),
    );
  }

  /// No callback, so the running task is not restarted: only the
  /// notification changes.
  @override
  Future<void> refreshNotification() async {
    final result = await FlutterForegroundTask.updateService(
      notificationTitle: serviceTitle,
      notificationText: serviceText,
      notificationIcon: serviceIcon,
      notificationButtons: serviceButtons,
    );
    if (result case ServiceRequestFailure(:final error)) throw error;
  }

  @override
  Future<void> restart() async {
    _init();
    _check(await FlutterForegroundTask.restartService());
  }

  /// connectedDevice, not dataSync: Android 15 limits dataSync services to
  /// 6 hours a day and does not start them at boot. The wake lock keeps
  /// timers and debounce gates running with the screen off, and the Wi-Fi
  /// lock keeps device pushes arriving.
  static void _init() => FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'omniflow_service',
      channelName: 'OmniFlow running',
      channelDescription: 'Shown while OmniFlow runs flows in the background',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
      allowAutoRestart: true,
      stopWithTask: false,
    ),
  );

  /// Android 13 and later hide the notification without the permission.
  /// The service runs either way, so a refusal is not an error.
  static Future<void> _askToNotify() async {
    try {
      final permission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (permission == NotificationPermission.denied) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } on PlatformException {
      return;
    }
  }

  static void _check(ServiceRequestResult result) {
    // The service from before a reinstall can come back between the
    // running check and this start. It is the service wanted, so connect.
    if (result case ServiceRequestFailure(
      error: ServiceAlreadyStartedException(),
    )) {
      return;
    }
    if (result case ServiceRequestFailure(:final error)) {
      throw StateError('The background service did not start: $error');
    }
  }
}

/// The UI end of the plugin's data channel.
class ForegroundTaskLink implements EngineLink {
  ForegroundTaskLink() {
    FlutterForegroundTask.addTaskDataCallback(_onData);
  }

  final _incoming = StreamController<String>.broadcast();

  void _onData(Object data) {
    if (data is String && !_incoming.isClosed) _incoming.add(data);
  }

  @override
  void send(String message) => FlutterForegroundTask.sendDataToTask(message);

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<void> close() async {
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    await _incoming.close();
  }
}

/// Runs in the service's own isolate when Android starts the service, from
/// the app, after a reboot or after Android killed it.
@pragma('vm:entry-point')
void startOmniService() => FlutterForegroundTask.setTaskHandler(
  OmniTaskHandler(
    open: openServiceEngine,
    send: FlutterForegroundTask.sendDataToMain,
    stopService: FlutterForegroundTask.stopService,
    inputs: PhoneInputs.new,
    actions: PhoneActionRunner.new,
    owner: EngineOwner(),
  ),
);

/// The engine's control socket, which the app's agent bridge (adb only),
/// widgets, tiles and ask answers hand commands to. Private to the app: a
/// 0600 socket in its own files. In hub mode it forwards to the hub.
LocalServer? _agentBridge;
HubBridge? _hubBridge;

/// What the service runs, by the home mode the user chose: the phone's own
/// engine, or a client of the Mac mini hub with no engine on the phone.
Future<Started> openServiceHome({
  required Future<HomeMode> Function() mode,
  required Future<Started> Function() openPhone,
  required Future<Started> Function() openHub,
}) async => switch (await mode()) {
  HomeMode.phone => openPhone(),
  HomeMode.hub => openHub(),
};

/// The service's entry point for [OmniTaskHandler.open].
Future<Started> openServiceEngine() {
  final store = HubSettingsStore(SecureStorageSecretStore());
  return openServiceHome(
    mode: store.mode,
    openPhone: _openPhoneEngine,
    openHub: () => _openHubClient(store),
  );
}

Future<Directory> _serviceHome() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/omniflow');
}

/// The engine the service owns: the only one that opens the database.
Future<Started> _openPhoneEngine() async {
  final home = await _serviceHome();
  final started = await startEngine(
    home: home,
    secrets: SecureStorageSecretStore(),
    tap: PacketTap(),
    serialLinks: UsbLinks(),
  );
  await takeBackHubHome(started.client, home);
  if (started.client case final InProcessEngineClient client) {
    try {
      _agentBridge = await LocalServer.start(client.engine, home: home);
    } on Object catch (e) {
      // The app works without it; only agents over adb lose the engine.
      debugPrint('OmniFlow agent bridge not started: $e');
    }
  }
  return started;
}

/// Hub mode: no engine and no database on the phone. Every command goes
/// to the hub over SSH.
Future<Started> _openHubClient(HubSettingsStore store) async {
  final settings = await store.settings();
  if (settings == null) {
    throw StateError(
      'Hub mode is on but no hub is set. Open Settings, Home runs on.',
    );
  }
  final home = await _serviceHome();
  final lastKnown = HubLastKnown(home);
  final client = HubEngineClient(
    settings: settings,
    connect: () => sshHubSession(
      settings: settings,
      secrets: SecureStorageSecretStore(),
      privateKeySecret: HubSettingsStore.privateKeyKey,
    ),
    lastKnown: await lastKnown.read(),
    remember: lastKnown.write,
  );
  unawaited(client.start());
  try {
    _hubBridge = await HubBridge.start(client, home: home);
  } on Object catch (e) {
    debugPrint('OmniFlow hub bridge not started: $e');
  }
  return (client: client as EngineClient, hubError: null);
}

/// Owns the engine for as long as the service runs: holds the multicast
/// lock, answers the UI through [EngineHost], and closes the engine when
/// the service stops.
class OmniTaskHandler extends TaskHandler {
  OmniTaskHandler({
    required this.open,
    required void Function(String message) send,
    required this.stopService,
    MulticastLock? lock,
    this.inputs,
    this.actions,
    this.owner,
  }) : _host = EngineHost(send: send),
       _lock = lock ?? MulticastLock();

  /// The phone's battery and Wi-Fi readings, fed to the engine once it is
  /// open. Null leaves the phone thing to the CLI.
  final PhoneInputs Function(EngineClient engine)? inputs;
  PhoneInputs? _inputs;

  /// Runs the phone's actions the engine asks for, and says the phone is
  /// ready. Null leaves the phone without actions (tests).
  final PhoneActionRunner Function(EngineClient engine)? actions;
  PhoneActionRunner? _actions;
  AutomationNotifier? _notifier;

  /// Holds off opening while a task this one replaced still has the
  /// engine. Null for a lone handler (tests).
  final EngineOwner? owner;

  final Future<Started> Function() open;
  final Future<Object?> Function() stopService;
  final EngineHost _host;
  final MulticastLock _lock;
  EngineClient? _engine;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await owner?.claim();
    await _lock.acquire();
    try {
      final started = await open();
      _engine = started.client;
      _host.attach(started.client, hubError: started.hubError);
      _inputs = inputs?.call(started.client)?..start();
      _actions = actions?.call(started.client)?..start();
      final client = started.client;
      final notifier = _notifier = AutomationNotifier(
        client,
        shows: client is HubEngineClient ? client.showsOnThisPhone : null,
      );
      unawaited(notifier.start());
    } on Object catch (e) {
      _host.fail('$e');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onReceiveData(Object data) => unawaited(_host.receive(data));

  @override
  void onNotificationButtonPressed(String id) {
    if (id != stopButtonId) return;
    unawaited(_host.stop(stoppedFromNotification));
    unawaited(stopService());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    try {
      await _inputs?.stop();
      await _actions?.stop();
      await _notifier?.stop();
      await _host.stop(
        isTimeout
            ? 'Android stopped the service at its time limit'
            : 'OmniFlow was stopped',
      );
      await _agentBridge?.close();
      _agentBridge = null;
      await _hubBridge?.close();
      _hubBridge = null;
      switch (_engine) {
        case final InProcessEngineClient client:
          await client.engine.close();
        case final HubEngineClient client:
          await client.close();
      }
      await _lock.release();
    } finally {
      owner?.release();
    }
  }
}
