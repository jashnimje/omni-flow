import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:path_provider/path_provider.dart';

import '../api/engine_client.dart';
import '../startup.dart';
import '../state/providers.dart' show errorMessage;
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
import 'service_power.dart';
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
  /// 6 hours a day and does not start them at boot. No wake lock and no
  /// Wi-Fi lock for the service's life: [ServicePower] holds them only
  /// while a run, a short window or a near time trigger needs them, and
  /// wakes the phone with an exact alarm for the next time trigger.
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
      allowWakeLock: false,
      allowWifiLock: false,
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
    power: servicePowerFor,
    notice: PluginServiceNotice(),
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

/// The service notification and the "not running" notice, so tests can
/// stand in for them.
abstract interface class ServiceNotice {
  /// Sets the always-on service notification.
  Future<void> show(
    String title,
    String text,
    List<NotificationButton> buttons,
  );

  /// Posts "Automations are not running" with [reason] and a Start button.
  Future<void> notRunning(String reason);

  /// Takes that notice down.
  Future<void> running();
}

/// The plugin's service notification and PowerBridge's notice.
class PluginServiceNotice implements ServiceNotice {
  PluginServiceNotice([AndroidPowerHands? power])
    : _power = power ?? AndroidPowerHands();

  final AndroidPowerHands _power;

  @override
  Future<void> show(
    String title,
    String text,
    List<NotificationButton> buttons,
  ) async {
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
        notificationIcon: serviceIcon,
        notificationButtons: buttons,
      );
    } on Object catch (e) {
      debugPrint('OmniFlow service notification not updated: $e');
    }
  }

  @override
  Future<void> notRunning(String reason) => _power.notRunning(reason);

  @override
  Future<void> running() => _power.running();
}

/// The Stop button asks first: these answer it.
const stopConfirmId = 'stop_yes';
const keepRunningId = 'keep';
const stopConfirmTitle = 'Stop automations?';
const stopConfirmText =
    'Nothing runs until you start OmniFlow again from the app, a widget, '
    'or the Start button on the notice that follows.';
const stopConfirmButtons = [
  NotificationButton(id: stopConfirmId, text: 'Stop'),
  NotificationButton(id: keepRunningId, text: 'Keep running'),
];
const stoppedByYou =
    'You stopped OmniFlow. Tap Start, or open the app, to run automations '
    'again';

/// The service notification when the engine or the hub did not start.
const notArmedTitle = 'Automations are not running';

/// How long a background start waits before each new try, then the last
/// one again and again.
const startRetryDelays = [
  Duration(seconds: 10),
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
  Duration(minutes: 15),
];

/// What `hub.start` binds: the WiZ push and board hello ports.
const hubStartArgs = {'wizPort': 38900, 'helloPort': 38951};

/// Owns the engine for as long as the service runs: answers the UI through
/// [EngineHost], keeps the service notification true to what runs, tries
/// again when the engine or the hub fails to start, and closes the engine
/// when the service stops.
class OmniTaskHandler extends TaskHandler {
  OmniTaskHandler({
    required this.open,
    required void Function(String message) send,
    required this.stopService,
    MulticastLock? lock,
    this.inputs,
    this.actions,
    this.owner,
    this.power,
    this.notice,
    this.retryDelays = startRetryDelays,
    this.confirmFor = const Duration(seconds: 30),
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

  /// The locks and alarms, planned from what the engine is doing. Null
  /// holds the multicast lock for the task's life instead (tests).
  final ServicePower Function(
    EngineClient engine,
    PhoneInputs? inputs,
    PhoneActionRunner? actions,
  )?
  power;
  ServicePower? _power;

  /// The service notification and the "not running" notice. Null in tests
  /// that do not look at them.
  final ServiceNotice? notice;

  final List<Duration> retryDelays;

  /// How long the Stop question stays before the notification goes back.
  final Duration confirmFor;

  final Future<Started> Function() open;
  final Future<Object?> Function() stopService;
  final EngineHost _host;
  final MulticastLock _lock;
  EngineClient? _engine;
  Timer? _retry;
  Timer? _confirm;
  var _tries = 0;
  var _destroyed = false;

  /// Why automations are not running now, or null when they are.
  String? get trouble => _trouble;
  String? _trouble;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await owner?.claim();
    if (power == null) await _lock.acquire();
    await _openEngine();
  }

  Duration _nextDelay() =>
      retryDelays[(_tries++).clamp(0, retryDelays.length - 1)];

  Future<void> _openEngine() async {
    if (_destroyed) return;
    final Started started;
    try {
      started = await open();
    } on Object catch (e) {
      _host.fail('$e');
      await _failed('OmniFlow could not open its home: $e');
      _retry = Timer(_nextDelay(), () => unawaited(_openEngine()));
      return;
    }
    if (_destroyed) return;
    final client = started.client;
    _engine = client;
    _host.attach(client, hubError: started.hubError);
    _inputs = inputs?.call(client)?..start();
    _actions = actions?.call(client)?..start();
    final notifier = _notifier = AutomationNotifier(
      client,
      shows: client is HubEngineClient ? client.showsOnThisPhone : null,
    );
    unawaited(notifier.start());
    _power = power?.call(client, _inputs, _actions);
    unawaited(_power?.start());
    _tries = 0;
    if (started.hubError case final error?) {
      await _failed('Automations did not start: $error');
      _retry = Timer(_nextDelay(), () => unawaited(_startHub()));
    } else {
      await _healthy();
    }
  }

  /// `hub.start` again: it arms the time triggers and the listeners.
  Future<void> _startHub() async {
    final engine = _engine;
    if (_destroyed || engine == null) return;
    Map<String, Object?> reply;
    try {
      reply = await engine.call('hub.start', hubStartArgs);
    } on Object catch (e) {
      reply = {
        'ok': false,
        'error': {'message': '$e'},
      };
    }
    if (_destroyed) return;
    if (reply['ok'] == true) {
      _host.hubStarted();
      await _healthy();
      unawaited(_power?.plan());
      return;
    }
    await _failed('Automations did not start: ${errorMessage(reply)}');
    _retry = Timer(_nextDelay(), () => unawaited(_startHub()));
  }

  Future<void> _failed(String reason) async {
    _trouble = reason;
    await notice?.show(
      notArmedTitle,
      '$reason. OmniFlow tries again by itself.',
      serviceButtons,
    );
    await notice?.notRunning(reason);
  }

  Future<void> _healthy() async {
    _trouble = null;
    await notice?.show(serviceTitle, serviceText, serviceButtons);
    await notice?.running();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onReceiveData(Object data) => unawaited(_host.receive(data));

  @override
  void onNotificationButtonPressed(String id) {
    switch (id) {
      case stopButtonId:
        // An accidental tap in the shade must not end every automation.
        if (notice == null) return _stop();
        unawaited(
          notice!.show(stopConfirmTitle, stopConfirmText, stopConfirmButtons),
        );
        _confirm?.cancel();
        _confirm = Timer(confirmFor, () => unawaited(_restoreNotice()));
      case stopConfirmId:
        _confirm?.cancel();
        unawaited(notice?.notRunning(stoppedByYou));
        _stop();
      case keepRunningId:
        _confirm?.cancel();
        unawaited(_restoreNotice());
    }
  }

  Future<void> _restoreNotice() async {
    final trouble = _trouble;
    if (trouble == null) {
      await notice?.show(serviceTitle, serviceText, serviceButtons);
    } else {
      await notice?.show(
        notArmedTitle,
        '$trouble. OmniFlow tries again by itself.',
        serviceButtons,
      );
    }
  }

  void _stop() {
    unawaited(_host.stop(stoppedFromNotification));
    unawaited(stopService());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _destroyed = true;
    _retry?.cancel();
    _confirm?.cancel();
    try {
      await _power?.stop();
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
      if (power == null) await _lock.release();
    } finally {
      owner?.release();
    }
  }
}

/// The locks and alarms for the service's engine. In hub mode the phone
/// runs no timers, so only runs and windows count.
ServicePower servicePowerFor(
  EngineClient engine,
  PhoneInputs? inputs,
  PhoneActionRunner? actions,
) {
  final hands = AndroidPowerHands();
  final flows = engine is InProcessEngineClient ? engine.engine.flows : null;
  DateTime? nextDue() {
    final times = [?flows?.nextTimeDue, ?actions?.nextCalendarDue]..sort();
    return times.firstOrNull;
  }

  final power = ServicePower(
    hands: hands,
    events: engine.events,
    nextDue: nextDue,
    retime: () {
      flows?.retime();
      actions?.retime();
    },
    hasBoards: () async {
      final reply = await engine.call('device.list');
      return [
        for (final d in reply['devices'] as List? ?? const [])
          if (d is Map &&
              d['board'] == true &&
              !'${d['host']}'.startsWith('usb:'))
            d,
      ].isNotEmpty;
    },
    onCalendarChanged: actions?.calendarChanged,
    explain: (title, body, open) => AutomationNotifier.platformPost(
      channel: 'problems',
      id: 'power/$open'.hashCode & 0x7fffffff,
      title: title,
      body: body,
      open: open,
    ),
  );
  inputs?.onWifiChanged = power.wifiChanged;
  actions?.onCalendarTimed = () => unawaited(power.plan());
  return power;
}
