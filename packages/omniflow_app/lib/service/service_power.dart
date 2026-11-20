import 'dart:async';

import 'package:flutter/services.dart';

import 'multicast_lock.dart';

/// What the service holds and sets on the phone, so tests can stand in for
/// it. PowerBridge.kt and MulticastLockBridge.kt on the service's engine.
abstract interface class PowerHands {
  /// The CPU wake lock. With [atMost] it ends by itself after that long,
  /// so a lost release never keeps the phone awake for good.
  Future<void> holdCpu(bool hold, {Duration? atMost});

  /// Keeps Wi-Fi out of power save, for a run's device commands.
  Future<void> holdWifi(bool hold);

  /// Lets broadcast and multicast packets in, which wakes the CPU for each.
  Future<void> holdMulticast(bool hold);

  /// Sets the alarm that wakes the phone at [at], or clears it for null.
  /// True when the alarm is exact.
  Future<bool> wakeAt(DateTime? at);

  /// Whether Android lets OmniFlow set exact alarms (Alarms and reminders).
  Future<bool> exactAlarms();

  /// `wake` (the alarm fired), `clock` (the time or the time zone
  /// changed), `calendar` (the calendar changed) and `exactAlarms` (Alarms
  /// and reminders was granted or taken back).
  Stream<String> get signals;
}

/// The phone's side, on the `omniflow/power` channel.
class AndroidPowerHands implements PowerHands {
  AndroidPowerHands({MethodChannel? channel, MulticastLock? multicast})
    : _channel = channel ?? const MethodChannel(channelName),
      _multicast = multicast ?? MulticastLock();

  static const channelName = 'omniflow/power';

  final MethodChannel _channel;
  final MulticastLock _multicast;
  final _signals = StreamController<String>.broadcast();

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> holdCpu(bool hold, {Duration? atMost}) =>
      _invoke<bool>('cpu', {'hold': hold, 'forMs': ?atMost?.inMilliseconds});

  @override
  Future<void> holdWifi(bool hold) => _invoke<bool>('wifi', {'hold': hold});

  @override
  Future<void> holdMulticast(bool hold) async {
    hold ? await _multicast.acquire() : await _multicast.release();
  }

  @override
  Future<bool> wakeAt(DateTime? at) async =>
      await _invoke<bool>('wakeAt', {'atMs': ?at?.millisecondsSinceEpoch}) ??
      false;

  @override
  Future<bool> exactAlarms() async {
    final status = await _invoke<Map<Object?, Object?>>('status');
    return status?['exactAlarms'] == true;
  }

  /// Listens on first use: the channel needs the service's binding, which
  /// exists only once the task handler is set.
  @override
  Stream<String> get signals {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'signal' && call.arguments is String) {
          _signals.add(call.arguments as String);
        }
        return null;
      });
    }
    return _signals.stream;
  }

  var _listening = false;

  /// Posts the "Automations are not running" notice with [reason].
  Future<void> notRunning(String reason) =>
      _invoke<void>('notRunning', {'reason': reason});

  /// Takes the notice down.
  Future<void> running() => _invoke<void>('running');
}

/// What the phone should hold right now. [recheckAt] is when to plan again
/// while awake, and [wakeAt] the alarm that wakes a sleeping phone for the
/// next time trigger.
typedef PowerNeeds = ({
  bool cpu,
  Duration? cpuFor,
  bool wifi,
  bool multicast,
  DateTime? wakeAt,
  DateTime? recheckAt,
});

/// A time trigger closer than this keeps the CPU awake until it has run,
/// so the timer that fires it counts real time.
const stayAwakeBefore = Duration(minutes: 10);

/// The exact alarm wakes the phone this long before the time.
const wakeLead = Duration(minutes: 2);

/// A run that sent no `run.finished` (lost) stops holding the CPU after
/// this.
const longestRun = Duration(hours: 2);

/// Without exact alarms the CPU is held in turns of this long, renewed
/// before each ends, so even that lock ends by itself if the service dies.
const holdTurn = Duration(hours: 1);

/// Decides the locks and the alarm from what is going on:
///
/// - the CPU while a run is going, inside a short window ([awakeUntil],
///   after an alarm or a Wi-Fi change), and from [stayAwakeBefore] a time
///   trigger until it has run. Without exact alarms the CPU stays awake
///   while any time trigger is armed, since timers count only awake time.
/// - Wi-Fi out of power save only while a run is going.
/// - multicast while a run is going, while a board that reports by
///   broadcast is in the home, and inside [multicastUntil].
PowerNeeds planPower({
  required DateTime now,
  required int runs,
  required bool exact,
  DateTime? nextDue,
  DateTime? awakeUntil,
  DateTime? multicastUntil,
  bool boards = false,
}) {
  final untilDue = nextDue?.difference(now);
  final soon = untilDue != null && untilDue <= stayAwakeBefore;
  final window = awakeUntil != null && awakeUntil.isAfter(now)
      ? awakeUntil.difference(now)
      : null;
  final forever = nextDue != null && !exact;
  final reasons = <Duration>[
    if (runs > 0) longestRun,
    ?window,
    if (soon) (untilDue.isNegative ? Duration.zero : untilDue) + wakeLead,
  ];
  final cpu = forever || reasons.isNotEmpty;
  final cpuFor = forever
      ? holdTurn
      : reasons.isEmpty
      ? null
      : reasons.reduce((a, b) => a > b ? a : b);
  final checks = <DateTime>[
    if (soon) nextDue!.add(const Duration(seconds: 5)),
    if (window != null) awakeUntil!,
    if (multicastUntil != null && multicastUntil.isAfter(now)) multicastUntil,
    if (nextDue != null && !soon) nextDue.subtract(stayAwakeBefore),
    if (forever) now.add(holdTurn - const Duration(minutes: 5)),
  ]..sort();
  return (
    cpu: cpu,
    cpuFor: cpuFor,
    wifi: runs > 0,
    multicast:
        runs > 0 ||
        boards ||
        (multicastUntil != null && multicastUntil.isAfter(now)),
    wakeAt: nextDue == null || soon ? null : nextDue.subtract(wakeLead),
    recheckAt: checks.isEmpty ? null : checks.first,
  );
}

/// Holds the CPU, Wi-Fi and multicast locks only while something needs
/// them, and wakes a sleeping phone with an exact alarm for the next time
/// trigger, instead of keeping the CPU awake all day.
class ServicePower {
  ServicePower({
    required this.hands,
    required this._events,
    DateTime? Function()? nextDue,
    void Function()? retime,
    Future<bool> Function()? hasBoards,
    this.onCalendarChanged,
    this.explain,
    DateTime Function()? now,
  }) : _nextDue = nextDue ?? (() => null),
       _retime = retime ?? (() {}),
       _hasBoards = hasBoards ?? (() async => false),
       _now = now ?? DateTime.now;

  final PowerHands hands;
  final Stream<Map<String, Object?>> _events;
  final DateTime? Function() _nextDue;
  final void Function() _retime;
  final Future<bool> Function() _hasBoards;
  final DateTime Function() _now;

  /// The calendar changed: read it again.
  final void Function()? onCalendarChanged;

  /// Says once why time triggers keep the phone awake: exact alarms are
  /// off. `(title, body, open)`, where open names the settings page.
  final Future<void> Function(String title, String body, String open)? explain;

  final _runs = <String, DateTime>{};
  final _subs = <StreamSubscription<Object?>>[];
  DateTime? _awakeUntil;
  DateTime? _multicastUntil;
  var _exact = true;
  var _boards = false;
  var _explained = false;
  var _stopped = false;
  Timer? _recheck;
  Timer? _settle;
  PowerNeeds? _held;

  /// The last plan applied, for tests and the status.
  PowerNeeds? get held => _held;

  /// Short windows, long enough for the next reading to land and the
  /// place away delay (2 minutes) to run out.
  static const afterWake = Duration(seconds: 30);
  static const afterWifi = Duration(minutes: 3);
  static const afterTrouble = Duration(seconds: 30);

  Future<void> start() async {
    _subs
      ..add(_events.listen(_onEvent, onError: (Object _) {}))
      ..add(hands.signals.listen(_onSignal, onError: (Object _) {}));
    _exact = await hands.exactAlarms();
    _boards = await _hasBoards().catchError((Object _) => false);
    await plan();
  }

  Future<void> stop() async {
    _stopped = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _recheck?.cancel();
    _settle?.cancel();
    await hands.wakeAt(null);
    await hands.holdCpu(false);
    await hands.holdWifi(false);
    await hands.holdMulticast(false);
    _held = null;
  }

  /// A Wi-Fi network joined or left: stay awake while presence settles,
  /// and let broadcasts in so boards and lights are found again.
  void wifiChanged() {
    final now = _now();
    _awakeUntil = _later(_awakeUntil, now.add(afterWifi));
    _multicastUntil = _later(_multicastUntil, now.add(afterWifi));
    unawaited(plan());
  }

  static DateTime _later(DateTime? a, DateTime b) =>
      a == null || b.isAfter(a) ? b : a;

  void _onEvent(Map<String, Object?> e) {
    final event = e['event'];
    switch (event) {
      case 'run.node':
        final run = e['run'];
        if (run is String && !_runs.containsKey(run)) {
          _runs[run] = _now();
          unawaited(plan());
        }
      case 'run.finished':
        if (_runs.remove(e['run']) != null) unawaited(plan());
      case 'automation.changed':
        _planSoon();
      case 'discovery.started':
        // A find (Add, Look again, the WiZ import) hears broadcast and
        // multicast answers only while the lock is held.
        final window = e['windowMs'];
        final ms = window is int && window > 0 ? window : 3000;
        _multicastUntil = _later(
          _multicastUntil,
          _now().add(Duration(milliseconds: ms) + afterTrouble),
        );
        unawaited(plan());
      case 'device.offline' || 'device.pollFailed' || 'device.moved':
        // Finding a device again uses mDNS and broadcasts.
        _multicastUntil = _later(_multicastUntil, _now().add(afterTrouble));
        unawaited(plan());
      case 'device.added' || 'device.removed' || 'device.changed':
        _planSoon(boards: true);
    }
  }

  /// After a change the engine arms its timers again: plan once it has.
  void _planSoon({bool boards = false}) {
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 500), () async {
      if (boards) _boards = await _hasBoards().catchError((Object _) => false);
      await plan();
    });
  }

  Future<void> _onSignal(String signal) async {
    switch (signal) {
      case 'wake':
        _awakeUntil = _later(_awakeUntil, _now().add(afterWake));
        _retime();
      case 'clock':
        _retime();
      case 'exactAlarms':
        _exact = await hands.exactAlarms();
      case 'calendar':
        onCalendarChanged?.call();
        return;
    }
    await plan();
  }

  /// Applies what is needed now, and sets the next alarm and check.
  Future<void> plan() async {
    if (_stopped) return;
    final now = _now();
    _runs.removeWhere((_, started) => now.difference(started) > longestRun);
    final nextDue = _nextDue();
    final needs = planPower(
      now: now,
      runs: _runs.length,
      exact: _exact,
      nextDue: nextDue,
      awakeUntil: _awakeUntil,
      multicastUntil: _multicastUntil,
      boards: _boards,
    );
    final before = _held;
    _held = needs;
    if (needs.cpu) {
      await hands.holdCpu(true, atMost: needs.cpuFor);
    } else if (before == null || before.cpu) {
      await hands.holdCpu(false);
    }
    if (before?.wifi != needs.wifi) await hands.holdWifi(needs.wifi);
    if (before?.multicast != needs.multicast) {
      await hands.holdMulticast(needs.multicast);
    }
    if (before == null || before.wakeAt != needs.wakeAt) {
      final exact = await hands.wakeAt(needs.wakeAt);
      if (needs.wakeAt != null) _exact = exact;
    }
    _recheck?.cancel();
    if (needs.recheckAt case final at?) {
      final wait = at.difference(now);
      _recheck = Timer(wait.isNegative ? Duration.zero : wait, plan);
    }
    if (!_exact && nextDue != null && !_explained) {
      _explained = true;
      await explain?.call(
        'Allow Alarms and reminders',
        'Time-based automations keep the phone awake until you allow '
            'OmniFlow to set alarms, which uses more battery. It also lets '
            'OmniFlow start again by itself if Android stops it. Tap to '
            'allow it.',
        'alarms',
      );
    }
  }
}
