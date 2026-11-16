import '../api/plain_error.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/engine_calls.dart' show EngineApi, Json;
import '../api/engine_client.dart';
import '../nfc/nfc.dart';
import '../service/phone_files.dart';
import '../api/screen_calls.dart';
import 'house.dart' show scopedEngine;
import '../ui/design/action_bar.dart' show OmniActionBar;
import '../ui/design/tokens.dart' show OmniSpace;

export '../api/engine_calls.dart' show Json;
export '../service/phone_files.dart' show PhoneFiles, PickedFile;

/// The connection to the engine. Overridden in main() with the real
/// engine, and in tests with a fake. Screens use [engineClientProvider].
final engineConnectionProvider = Provider<EngineClient>(
  (ref) => throw UnimplementedError('override engineConnectionProvider'),
);

/// The engine as screens see it: every list, create and save is about the
/// house in view (lib/state/house.dart), and whatever reads it reads again
/// when that house changes.
final engineClientProvider = Provider<EngineClient>(scopedEngine);

/// Why the hub did not start at launch, or null when it runs.
final hubErrorProvider = Provider<String?>((ref) => null);

/// The phone's NFC reader. main() puts in the plugin; without it the app
/// behaves as on a phone with no NFC.
final nfcAdapterProvider = Provider<NfcAdapter>((ref) => const NoNfc());

/// Tags Android opened the app for.
final nfcIntentsProvider = Provider<NfcIntents>((ref) => const NoNfcIntents());

/// Asks for the location permission Android requires before it tells an
/// app the Wi-Fi network's name. True when it was granted.
final wifiNamePermissionProvider = Provider<Future<bool> Function()>(
  (ref) =>
      () async => false,
);

/// Picking phone files for a TV and the folder TV downloads land in. main()
/// puts in the file picker.
final phoneFilesProvider = Provider<PhoneFiles>((ref) => const NoPhoneFiles());

/// How often the TV control centre reads the TV's state while it is open.
final tvPollProvider = Provider<Duration>((ref) => const Duration(seconds: 3));

/// Whether the user accepted the TV console's warning in this session.
class ConsoleAccepted extends Notifier<bool> {
  @override
  bool build() => false;

  void accept() => state = true;
}

final consoleAcceptedProvider = NotifierProvider<ConsoleAccepted, bool>(
  ConsoleAccepted.new,
);

/// Shows API errors without each screen handling them.
final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// The text of the snackbar on screen or queued last, so the same message
/// from two places (a call's failure and the screen that made it) shows
/// once.
({ScaffoldMessengerState on, String text})? _lastMessage;

/// Shows [text] as a snackbar, in plain words: an address, a port, a
/// retry count or a rule path never reaches the user. When [text] carried
/// such detail and there is no other action, a Details action shows it.
/// The same message without an action, while it is still up, shows once.
/// Returns the snackbar, or null when nothing was shown.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showMessage(
  String text, {
  String? action,
  VoidCallback? onAction,
}) {
  final plain = plainWords(text);
  final messenger = messengerKey.currentState;
  if (messenger == null) return null;
  final hasAction = action != null && onAction != null;
  if (!hasAction && _lastMessage == (on: messenger, text: plain.text)) {
    return null;
  }
  final details = plain.details;
  final SnackBarAction? button;
  if (hasAction) {
    button = SnackBarAction(label: action, onPressed: onAction);
  } else if (details != null) {
    button = SnackBarAction(
      label: 'Details',
      onPressed: () => _showDetails(messenger, details),
    );
  } else {
    button = null;
  }
  final last = (on: messenger, text: plain.text);
  _lastMessage = last;
  final shown = messenger.showSnackBar(
    SnackBar(
      content: Text(plain.text),
      behavior: SnackBarBehavior.floating,
      margin: snackMargin(messenger.context),
      // With an action Flutter keeps it up until tapped, over the Save
      // button. It goes after the usual few seconds instead.
      persist: false,
      action: button,
    ),
  );
  unawaited(
    shown.closed.then((_) {
      if (_lastMessage == last) _lastMessage = null;
    }),
  );
  return shown;
}

/// Where a snackbar floats: above the bottom bar a page pins its Save, Next
/// or Done in (an [OmniActionBar], stacked at large text), so the bar stays
/// tappable while the message shows. On a page with no bar it floats a
/// little higher, which covers nothing.
EdgeInsets snackMargin(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
  final stacked = scale > OmniActionBar.stackAbove;
  // The bar's buttons, the "why it is off" line above them, and the page
  // padding around the bar (OmniPage: sm above, md below).
  final buttons = stacked
      ? 2 * OmniSpace.target + OmniSpace.sm
      : OmniSpace.target;
  final missingLine = 20 * scale + OmniSpace.sm;
  return EdgeInsets.fromLTRB(
    OmniSpace.lg,
    0,
    OmniSpace.lg,
    buttons + missingLine + OmniSpace.sm + OmniSpace.md + OmniSpace.sm,
  );
}

void _showDetails(ScaffoldMessengerState messenger, String details) {
  _lastMessage = null;
  messenger.showSnackBar(
    SnackBar(
      key: const ValueKey('error-details'),
      content: Text(details),
      behavior: SnackBarBehavior.floating,
      margin: snackMargin(messenger.context),
      duration: const Duration(seconds: 8),
      persist: false,
    ),
  );
}

/// [text] in words a person can act on, and the technical detail it held.
typedef PlainWords = ({String text, String? details});

/// An address with a port, a bare IP address, a retry count or an
/// exception name: detail for Settings, Developer, not for a message.
final _transport = RegExp(
  r'\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b'
  r'|\b[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*:\d{2,5}\b'
  r'|\bafter \d+ attempts?\b'
  r'|\b(?:Socket|Http|Handshake|TlsException|OS Error|errno)\w*',
);

/// A rule path at the start of a line or after a space (`then[2].do: `).
final _rulePath = RegExp(
  r'(?:^|(?<=\s))[a-z]+(?:\[\d+\])(?:\.[a-z]+|\[\d+\])*:\s*',
  multiLine: true,
);

/// The sentence for a step or call that did not answer.
const didNotAnswer =
    'The device did not answer. Check that it is on and on this Wi-Fi.';

/// [text] with rule paths dropped and each piece of transport detail
/// swapped for what it means. "Desk lamp failed: no reply from
/// 10.0.2.2:38899 after 3 attempts" reads "Desk lamp failed: it did not
/// answer", with the original in [PlainWords.details].
PlainWords plainWords(String text) {
  final raw = <String>[];
  // The same sentence twice (two failed steps on one device) reads once.
  final seen = <String>{};
  final lines = <String>[];
  for (final line in text.replaceAll(_rulePath, '').split('\n')) {
    final sentences = <String>[];
    for (final sentence in line.split(RegExp(r'(?<=\.)\s+'))) {
      var s = sentence.trim();
      if (_transport.hasMatch(s)) {
        raw.add(s);
        final colon = s.indexOf(': ');
        final head = colon < 0 ? '' : s.substring(0, colon);
        s = head.isEmpty || _transport.hasMatch(head)
            ? didNotAnswer
            : '$head: it did not answer. Check that it is on and on this '
                  'Wi-Fi.';
      }
      if (s.isNotEmpty && seen.add(s)) sentences.add(s);
    }
    if (sentences.isNotEmpty) lines.add(sentences.join(' '));
  }
  return (text: lines.join('\n'), details: raw.isEmpty ? null : raw.join('\n'));
}

/// Calls the engine and shows the error message when the call fails.
Future<Json> callEngine(
  WidgetRef ref,
  String command, [
  Json args = const {},
]) => callClient(ref.read(engineClientProvider), command, args);

Future<Json> callClient(
  EngineClient client,
  String command, [
  Json args = const {},
]) async {
  final result = await client.call(command, args);
  if (result['ok'] != true) showMessage(_errorText(result));
  return result;
}

/// The error's message and, for a validation error, each issue, since the
/// message alone only names what was invalid. Plain words only: see
/// [plainWords].
String errorMessage(Json result) => plainWords(_errorText(result)).text;

/// [errorMessage] with its technical detail still in, for [showMessage]
/// to put under Details.
String _errorText(Json result) {
  final error = result['error'] as Map? ?? const {};
  return [
    plainError('${error['type'] ?? 'failed'}', error['message'] as String?),
    for (final issue in (error['issues'] as List? ?? const []))
      switch (issue) {
        // The rule path (then[2].do) means nothing to a person: the editor
        // shows each issue on its row instead.
        {'message': final message} => plainError('invalid', '$message'),
        _ => '$issue',
      },
  ].join('\n');
}

/// Devices with their capabilities, kept current from engine events. A
/// device the engine reports unreachable carries `online: false` and the
/// reason in `offlineReason` until it is heard from again.
class DevicesNotifier extends AsyncNotifier<List<Json>>
    with _KeepsListOnFailure {
  /// How long a burst of `device.changed` events (a move adds the thing
  /// again, an import adds many) waits before one reload.
  static const settle = Duration(milliseconds: 300);

  final _offline = <String, String>{};
  String? _lastBoardError;
  Timer? _reload;

  /// State changes heard while the first list loads, put on top of it once
  /// it lands so none is lost.
  List<Json>? _early;

  @override
  Future<List<Json>> build() async {
    final client = ref.watch(engineClientProvider);
    _early = [];
    final sub = client.events.listen(_onEvent);
    ref.onDispose(() {
      sub.cancel();
      _reload?.cancel();
      _reload = null;
    });
    var list = await _load(client);
    final early = _early ?? const <Json>[];
    _early = null;
    for (final changed in early) {
      list = [
        for (final d in list)
          d['id'] == changed['id']
              ? _merge(d, changed, changed['online'] != false)
              : d,
      ];
    }
    return list;
  }

  void _onEvent(Json e) {
    final current = state.value;
    switch (e['event']) {
      // A thing added, removed, renamed or moved anywhere (the CLI, an
      // agent, another phone): the list is read again.
      case deviceChangedEvent || 'house.thingMoved':
        _reloadSoon();
      // The event carries the stored presence, which is the home place's.
      // device.list says it for the house in view, so a person is read
      // again rather than merged.
      case 'device.stateChanged' when _isPerson(e['device']):
        _reloadSoon();
      case 'device.stateChanged':
        final changed = Map<String, Object?>.from(e['device'] as Map);
        final heard = changed['online'] != false;
        if (heard) _offline.remove(changed['id']);
        if (_early case final early?) {
          early.add(changed);
          return;
        }
        if (current == null) return;
        state = AsyncData([
          for (final d in current)
            d['id'] == changed['id'] ? _merge(d, changed, heard) : d,
        ]);
      case 'device.offline' || 'board.offline' || 'device.pollFailed':
        final id = e['device'];
        if (id is! String) return;
        _offline[id] = plainError(
          '${e['errorType'] ?? 'timeout'}',
          e['error'] as String?,
        );
        if (current == null) return;
        state = AsyncData([for (final d in current) _withStatus(d)]);
      case 'board.error':
        // A failing board repeats its error with every hello.
        final text =
            'A board had a problem: '
            '${plainError('${e['errorType'] ?? 'device_error'}', e['error'] as String?)}';
        if (text == _lastBoardError) return;
        _lastBoardError = text;
        showMessage(text);
    }
  }

  static bool _isPerson(Object? device) =>
      device is Map && device['driver'] == 'person';

  void _reloadSoon() => _reload ??= Timer(settle, () {
    _reload = null;
    if (ref.mounted) unawaited(refresh());
  });

  Json _merge(Json d, Json changed, bool heard) {
    final merged = {...d, ...changed, 'capabilities': d['capabilities']};
    if (heard) {
      merged['online'] = changed['online'] ?? true;
      merged.remove('offlineReason');
    }
    return _withStatus(merged);
  }

  Json _withStatus(Json d) {
    final reason = _offline[d['id']];
    return reason == null
        ? d
        : {...d, 'online': false, 'offlineReason': reason};
  }

  Future<List<Json>> _load(EngineClient client) async {
    final result = await client.call(DeviceCalls.list, {
      'withCapabilities': true,
    });
    if (result['ok'] != true) throw EngineReadFailed(errorMessage(result));
    return [
      for (final d in (result['devices'] as List? ?? const []))
        _withStatus(Map<String, Object?>.from(d as Map)),
    ];
  }

  Future<void> refresh() =>
      reloadWith(() => _load(ref.read(engineClientProvider)));
}

final devicesProvider = AsyncNotifierProvider<DevicesNotifier, List<Json>>(
  DevicesNotifier.new,
);

/// The engine's event after a thing or a room is added, removed, renamed,
/// moved or organized, from this phone or anywhere else.
const deviceChangedEvent = 'device.changed';

/// Counts `device.changed` events, at most one per [DevicesNotifier.settle].
/// A list besides the devices (rooms, places) watches it to read again.
class DeviceChanges extends Notifier<int> {
  Timer? _bump;

  @override
  int build() {
    final client = ref.watch(engineClientProvider);
    final sub = client.events
        .where(
          (e) =>
              e['event'] == deviceChangedEvent ||
              e['event'] == 'house.thingMoved',
        )
        .listen(
          (_) => _bump ??= Timer(DevicesNotifier.settle, () {
            _bump = null;
            if (ref.mounted) state++;
          }),
        );
    ref.onDispose(() {
      sub.cancel();
      _bump?.cancel();
      _bump = null;
    });
    return 0;
  }
}

final deviceChangesProvider = NotifierProvider<DeviceChanges, int>(
  DeviceChanges.new,
);

/// A list the engine did not give: it did not answer, or said why not.
class EngineReadFailed implements Exception {
  const EngineReadFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A reload that keeps the list on screen when it fails: the error shows
/// only when there is nothing to keep.
mixin _KeepsListOnFailure on AsyncNotifier<List<Json>> {
  Future<void> reloadWith(Future<List<Json>> Function() load) async {
    try {
      final next = await load();
      if (ref.mounted) state = AsyncData(next);
    } on EngineReadFailed catch (e, stack) {
      if (!ref.mounted || state.hasValue) return;
      state = AsyncError(e, stack);
    }
  }
}

/// Flows, reloaded after runs finish (at most once per [settle]) or a flow
/// changes.
class FlowsNotifier extends AsyncNotifier<List<Json>> with _KeepsListOnFailure {
  static const settle = Duration(milliseconds: 500);
  Timer? _reload;

  @override
  Future<List<Json>> build() async {
    final client = ref.watch(engineClientProvider);
    final sub = client.events
        .where((e) => e['event'] == 'run.finished')
        .listen(
          (_) => _reload ??= Timer(settle, () {
            _reload = null;
            refresh();
          }),
        );
    ref.onDispose(() {
      sub.cancel();
      _reload?.cancel();
    });
    return _load(client);
  }

  Future<List<Json>> _load(EngineClient client) async {
    final result = await client.call(FlowCalls.list);
    if (result['ok'] != true) throw EngineReadFailed(errorMessage(result));
    return [
      for (final f in (result['flows'] as List? ?? const []))
        Map<String, Object?>.from(f as Map),
    ];
  }

  Future<void> refresh() =>
      reloadWith(() => _load(ref.read(engineClientProvider)));
}

final flowsProvider = AsyncNotifierProvider<FlowsNotifier, List<Json>>(
  FlowsNotifier.new,
);

/// Asks the service to send captured packets to the UI ([on] true) or to
/// stop. Packets cost a copy across the isolate for every UDP broadcast and
/// HTTP body on the LAN, so they flow only while the inspector is open.
/// `EngineHost` answers it and forwards captures only while a UI asks.
const packetsCommand = 'link.packets';

/// The newest packets for the inspector, oldest dropped past [cap]. It
/// listens only while a screen watches it, and tells the service when.
class PacketsNotifier extends Notifier<List<Json>> {
  static const cap = 200;

  @override
  List<Json> build() {
    final client = ref.watch(engineClientProvider);
    unawaited(client.call(packetsCommand, {'on': true}));
    final sub = client.events
        .where((e) => e['event'] == 'packet.captured')
        .listen((p) {
          final next = [p, ...state];
          state = next.length > cap ? next.sublist(0, cap) : next;
        });
    ref.onDispose(() {
      sub.cancel();
      unawaited(client.call(packetsCommand, {'on': false}));
    });
    return const [];
  }

  void clear() => state = const [];
}

final packetsProvider =
    NotifierProvider.autoDispose<PacketsNotifier, List<Json>>(
      PacketsNotifier.new,
    );

/// The typed engine calls. A failure shows as a snackbar, as with
/// [callEngine], and comes back in the reply for the screen to show inline.
/// The snackbar carries only the message: each issue shows on the row it
/// is about, so it is not said twice.
final engineApiProvider = Provider<EngineApi>(
  (ref) => EngineApi(
    ref.watch(engineClientProvider),
    onFailure: (f) => showMessage(f.message),
  ),
);
