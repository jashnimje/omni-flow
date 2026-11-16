import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../boards/board_page.dart' show saveBoardPins;
import '../boards/board_pins.dart';
import '../boards/pin_sheet.dart' show PinSheet;
import '../design/design.dart';
import '../devices/open_device.dart' show DeviceRoute;
import '../help/setting_help.dart' show settingHelpLine;
import 'pair_sheet.dart' show pairFailureText;
import 'room_field.dart';

/// How long the engine waits at the device for a pairing to be accepted
/// (its ADB and TV pairing timeout), which the countdown shows.
const pairingWait = Duration(seconds: 60);

/// The guided steps for a thing already added: picks up from what the
/// engine says is left, or shows its settings when nothing is.
Future<void> openSetup(BuildContext context, Json device) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GuidedStepsPage(
          id: '${device['id']}',
          name: '${device['name'] ?? device['id']}',
          stepsBefore: 0,
        ),
      ),
    );

/// Adds [candidate] and opens the guided steps on what the engine says
/// comes next. [replaceRoute] swaps the current page for them. [always]
/// opens the steps even when nothing is left, for the name and room.
Future<void> addAndFollow(
  BuildContext context,
  WidgetRef ref,
  Json candidate, {
  required String name,
  String? room,
  bool replaceRoute = false,
  bool always = false,
}) async {
  final navigator = Navigator.of(context);
  final devices = ref.read(devicesProvider.notifier);
  final reply = await ref
      .read(engineApiProvider)
      .addCandidate(candidate, name: name, room: room);
  final added = reply.value;
  if (added == null) return;
  await devices.refresh();
  await followAdded(
    navigator,
    added,
    name: name,
    replaceRoute: replaceRoute,
    always: always,
  );
}

/// After an add, opens the guided steps on the step the engine says comes
/// next, or says it was added when nothing is left, optional keys included.
/// [id] is the id the add was given, when the reply does not carry one.
Future<void> followAdded(
  NavigatorState navigator,
  Added added, {
  required String name,
  String? id,
  bool replaceRoute = false,
  bool always = false,
}) async {
  final thingId = id ?? added.id;
  final next = added.next;
  if (added.provisionError case final error?) {
    showMessage('The board is offline: $error');
  }
  if (thingId == null ||
      (!always && next.kind == NextKind.done && next.optional.isEmpty)) {
    showMessage('Added $name');
    if (replaceRoute) navigator.pop();
    return;
  }
  final route = MaterialPageRoute<void>(
    builder: (_) => GuidedStepsPage(id: thingId, name: name, first: next),
  );
  await (replaceRoute
      ? navigator.pushReplacement(route)
      : navigator.push(route));
}

/// A typed setting: JSON objects and lists stay structured, anything else
/// stays text, so an id like 0042 is not turned into a number. The CLI
/// types `omni add` settings the same way.
Object? typedSetting(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map || decoded is List) return decoded;
  } on FormatException {
    return raw;
  }
  return raw;
}

/// 6.2 Guided steps: a step bar, then one step per screen from the
/// engine's `next`: pair with what to do and a countdown, a masked secret
/// with where to find it, configure, done. Name and room sit under every
/// step and are saved on Finish. Without [first] it asks where the setup
/// stands, so a setup left half way picks up again.
class GuidedStepsPage extends ConsumerStatefulWidget {
  const GuidedStepsPage({
    super.key,
    required this.id,
    required this.name,
    this.first,
    this.stepsBefore = 1,
  });

  final String id;
  final String name;
  final NextStep? first;

  /// Steps already done before this page: finding and adding the thing.
  final int stepsBefore;

  @override
  ConsumerState<GuidedStepsPage> createState() => _GuidedStepsPageState();
}

class _GuidedStepsPageState extends ConsumerState<GuidedStepsPage> {
  NextStep? _step;
  var _total = 0;
  var _busy = false;
  ApiFailure? _failure;
  String? _note;
  final _fields = <String, TextEditingController>{};
  final _shown = <String>{};
  late final _name = ReplaceableText(widget.name);
  String? _room;
  Timer? _tick;
  var _waited = Duration.zero;
  var _autoPaired = false;

  EngineApi get _api => EngineApi(ref.read(engineClientProvider));

  @override
  void initState() {
    super.initState();
    if (widget.first case final first?) {
      _show(first);
    } else {
      unawaited(_run(() => _api.nextStep(widget.id)));
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _name.dispose();
    _clearFields();
    super.dispose();
  }

  void _clearFields() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _fields.clear();
  }

  void _show(NextStep step) {
    _step = step;
    final left = step.kind == NextKind.done
        ? 0
        : step.remaining.length.clamp(1, 99);
    final total = widget.stepsBefore + left + 1;
    if (total > _total) _total = total;
    if (step.kind == NextKind.pair &&
        !_autoPaired &&
        (step.method == 'adb' || step.method == 'tv')) {
      _autoPaired = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_busy) unawaited(_run(_pair));
      });
    }
  }

  int get _current {
    final step = _step;
    if (step == null) return widget.stepsBefore;
    if (step.kind == NextKind.done) return _total;
    return (_total - step.remaining.length.clamp(1, 99)).clamp(1, _total);
  }

  /// Runs one step's commands. [action] returns the next step, or a
  /// failure, which keeps the step up with why.
  Future<void> _run(Future<Reply<NextStep>> Function() action) async {
    final devices = ref.read(devicesProvider.notifier);
    setState(() {
      _busy = true;
      _failure = null;
    });
    final reply = await action();
    await devices.refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (reply.value case final next?) {
        _show(next);
        _clearFields();
      } else {
        _failure = reply.failure;
      }
    });
  }

  Future<Reply<NextStep>> _pair() async {
    _waited = Duration.zero;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _waited += const Duration(seconds: 1));
    });
    try {
      final paired = await _api.pairDevice(widget.id);
      if (paired.failure case final f?) return Reply.failed(f);
      _note = paired.value?.message;
      return await _api.nextStep(widget.id, paired: true);
    } finally {
      _tick?.cancel();
      _tick = null;
    }
  }

  /// Stores each secret typed, then asks for the next step. The fields are
  /// cleared either way, so a secret never stays on screen.
  Future<Reply<NextStep>> _storeSecrets(List<StepKey> keys) async {
    final failed = await _secrets(keys);
    return failed == null ? _api.nextStep(widget.id) : Reply.failed(failed);
  }

  Future<ApiFailure?> _secrets(List<StepKey> keys) async {
    final typed = {
      for (final k in keys)
        if (_field(k.key).text case final v when v.isNotEmpty) k.key: v,
    };
    for (final k in keys) {
      _field(k.key).clear();
    }
    for (final e in typed.entries) {
      final stored = await _api.setSecret(widget.id, e.key, e.value);
      if (stored.failure case final f?) return f;
    }
    return null;
  }

  Json _typedSettings(List<StepKey> keys) => {
    for (final k in keys)
      if (_field(k.key).text.trim() case final v when v.isNotEmpty)
        k.key: typedSetting(v),
  };

  /// The optional keys of a done step: secrets through `secret.set`,
  /// settings through `thing.configure`, then where setup stands now.
  Future<Reply<NextStep>> _storeOptional(List<StepKey> keys) async {
    final failed = await _secrets([
      for (final k in keys)
        if (k.step == 'secret') k,
    ]);
    if (failed != null) return Reply.failed(failed);
    final settings = _typedSettings([
      for (final k in keys)
        if (k.step != 'secret') k,
    ]);
    if (settings.isNotEmpty) {
      final configured = await _api.configureThing(widget.id, settings);
      if (!configured.ok) return configured;
    }
    return _api.nextStep(widget.id);
  }

  /// A board's pins: the ones set in the pin sheet, or none yet, which the
  /// engine counts as set up.
  Future<Reply<NextStep>> _pinsDone() async {
    final device = _device;
    if (device != null && NamedPin.ofDevice(device).isEmpty) {
      final saved = await saveBoardPins(ref, widget.id, const {}, quiet: true);
      if (saved.failure case final f?) return Reply.failed(f);
    }
    return _api.nextStep(widget.id);
  }

  /// One Finish saves everything on the last step: the optional keys
  /// typed, then the name and room. A new thing then opens on its page.
  Future<void> _finish() async {
    final navigator = Navigator.of(context);
    final devices = ref.read(devicesProvider.notifier);
    final optional = _step?.optional ?? const <StepKey>[];
    if (_anyTyped(optional)) {
      await _run(() => _storeOptional(optional));
      if (!mounted || _failure != null) return;
    }
    final name = _name.text.trim();
    final device = _device;
    final room = _room;
    final rename =
        name.isNotEmpty && name != '${device?['name'] ?? widget.name}';
    final move =
        room != null && room != (DeviceView(device ?? {}).roomId ?? '');
    if (rename || move) {
      setState(() => _busy = true);
      final reply = await ref
          .read(engineApiProvider)
          .organizeDevice(
            widget.id,
            name: rename ? name : null,
            room: move ? room : null,
          );
      if (!mounted) return;
      setState(() => _busy = false);
      if (!reply.ok) return;
      await devices.refresh();
    }
    showMessage('Added ${name.isEmpty ? widget.name : name}');
    if (widget.stepsBefore == 0) {
      navigator.pop();
      return;
    }
    await navigator.pushReplacement(
      MaterialPageRoute<void>(builder: (_) => DeviceRoute(id: widget.id)),
    );
  }

  TextEditingController _field(String key) =>
      _fields.putIfAbsent(key, TextEditingController.new);

  bool _filled(List<StepKey> keys) =>
      keys.every((k) => k.optional || _field(k.key).text.trim().isNotEmpty);

  bool _anyTyped(List<StepKey> keys) =>
      keys.any((k) => _field(k.key).text.trim().isNotEmpty);

  Json? get _device => ref
      .watch(devicesProvider)
      .value
      ?.where((d) => d['id'] == widget.id)
      .firstOrNull;

  /// People and places are not tiles, so they get no room.
  bool get _presence => _device?['category'] == 'presence';

  bool get _tv => _step?.method == 'adb' || _step?.method == 'tv';

  @override
  Widget build(BuildContext context) {
    final step = _step;
    return OmniPage(
      title: widget.stepsBefore == 0
          ? 'Set up ${widget.name}'
          : 'Add ${widget.name}',
      body: ListView(
        key: const ValueKey('guided-steps'),
        padding: const EdgeInsets.only(bottom: OmniSpace.xl),
        children: [
          if (_total > 0) ...[
            const SizedBox(height: OmniSpace.xs),
            OmniStepBar(count: _total, current: _current),
            const SizedBox(height: OmniSpace.md),
          ],
          if (step == null && _failure == null)
            const Padding(
              padding: EdgeInsets.all(OmniSpace.xl),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
            )
          else if (step != null) ...[
            Text(
              'Step $_current of $_total · ${_stepName(step)}',
              key: const ValueKey('setup-step'),
              style: OmniText.caption,
            ),
            const SizedBox(height: OmniSpace.gap),
            ..._stepBody(step),
          ],
          if (_note != null && step?.kind != NextKind.pair)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.sm),
              child: Text(
                _note!,
                key: const ValueKey('setup-note'),
                style: OmniText.caption,
              ),
            ),
          if (_failure case final f?)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.sm),
              child: OmniBanner.error(
                key: const ValueKey('setup-error'),
                _failureText(f, step),
                actionLabel: step == null ? 'Try again' : null,
                onAction: step == null
                    ? () => _run(() => _api.nextStep(widget.id))
                    : null,
              ),
            ),
          if (_busy && step?.kind != NextKind.pair)
            const Padding(
              padding: EdgeInsets.only(top: OmniSpace.sm),
              child: OmniProgressBar(height: 2, semanticLabel: 'Working'),
            ),
          // The last step puts these above its Finish.
          if (step?.kind != NextKind.done) ...[
            const SizedBox(height: OmniSpace.lg),
            ..._nameAndRoom(),
          ],
        ],
      ),
    );
  }

  List<Widget> _nameAndRoom() => [
    TextField(
      key: const ValueKey('setup-name'),
      controller: _name,
      onTap: _name.firstTap,
      textCapitalization: TextCapitalization.sentences,
      decoration: const InputDecoration(labelText: 'Name'),
      onChanged: (_) => setState(() {}),
    ),
    if (!_presence) ...[
      const SizedBox(height: OmniSpace.sm),
      RoomField(
        value: _room ?? DeviceView(_device ?? {}).roomId ?? '',
        onChanged: (r) => setState(() => _room = r),
      ),
    ],
  ];

  static String _stepName(NextStep step) => switch (step.kind) {
    NextKind.pair => 'Pair',
    NextKind.secret => 'Key',
    NextKind.configure when step.isPins => 'Pins',
    NextKind.configure => 'Set up',
    NextKind.done => 'Done',
  };

  Widget _keyField(StepKey k, {bool secret = false}) {
    final shown = _shown.contains(k.key);
    return Padding(
      padding: const EdgeInsets.only(bottom: OmniSpace.sm),
      child: TextField(
        key: ValueKey('setup-field-${k.key}'),
        controller: _field(k.key),
        obscureText: secret && !shown,
        autocorrect: !secret,
        enableSuggestions: !secret,
        keyboardType: secret ? TextInputType.visiblePassword : null,
        decoration: InputDecoration(
          labelText: k.optional && !k.label.contains('(optional)')
              ? '${k.label} (optional)'
              : k.label,
          helper: settingHelpLine(
            settingKey: k.key,
            label: k.label,
            help: _step?.help[k.key],
          ),
          suffixIcon: secret
              ? OmniIconAction(
                  icon: shown
                      ? Symbols.visibility_off_rounded
                      : Symbols.visibility_rounded,
                  label: shown ? 'Hide ${k.label}' : 'Show ${k.label}',
                  onPressed: () => setState(
                    () => shown ? _shown.remove(k.key) : _shown.add(k.key),
                  ),
                )
              : null,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  List<Widget> _stepBody(NextStep step) => switch (step.kind) {
    NextKind.pair => _pairBody(step),
    NextKind.secret => [
      OmniHeroCard(
        icon: OmniIcons.permissions,
        centered: true,
        title: 'Enter the key',
        subtitle:
            step.instruction ?? 'Enter what ${widget.name} needs to answer.',
      ),
      for (final k in step.keys) _keyField(k, secret: true),
      for (final k in step.keys)
        for (final other in step.sameAs[k.key] ?? const [])
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.sm),
            child: OmniButton.ghost(
              key: ValueKey('setup-same-${k.key}-${other.id}'),
              label: 'Use the same ${k.label} as ${other.name}',
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      final copied = await _api.copySecret(
                        widget.id,
                        k.key,
                        other.id,
                      );
                      final failed = copied.failure;
                      return failed != null
                          ? Reply<NextStep>.failed(failed)
                          : _api.nextStep(widget.id);
                    }),
            ),
          ),
      OmniButton(
        key: const ValueKey('setup-secret-save'),
        label: 'Save',
        onPressed: _busy || !_filled(step.keys)
            ? null
            : () => _run(() => _storeSecrets(step.keys)),
      ),
      const SizedBox(height: OmniSpace.xs),
      const Text(
        'Kept in the phone\'s secret store, never in settings or logs.',
        style: OmniText.caption,
      ),
    ],
    NextKind.configure when step.isPins => [
      const OmniHeroCard(
        icon: OmniIcons.board,
        centered: true,
        title: 'Name the pins you wired',
        subtitle:
            'A button, a relay or a sensor. You can add more later from the '
            'board page.',
      ),
      for (final p in NamedPin.ofDevice(_device ?? const {}))
        OmniListRow(
          key: ValueKey('setup-pin-${p.name}'),
          icon: p.role.icon,
          title: p.label,
          subtitle: p.description,
        ),
      OmniButton.ghost(
        key: const ValueKey('setup-pins'),
        label: 'Set pins',
        icon: OmniIcons.add,
        onPressed: _device == null
            ? null
            : () => showOmniSheet<void>(
                context,
                builder: (_) => PinSheet(device: _device!),
              ),
      ),
      const SizedBox(height: OmniSpace.sm),
      OmniButton(
        key: const ValueKey('setup-pins-continue'),
        label: NamedPin.ofDevice(_device ?? const {}).isEmpty
            ? 'No pins yet, continue'
            : 'Continue',
        onPressed: _busy ? null : () => _run(_pinsDone),
      ),
    ],
    NextKind.configure => [
      OmniHeroCard(
        icon: OmniIcons.settings,
        centered: true,
        title: 'Set up ${widget.name}',
        subtitle: step.instruction,
      ),
      for (final k in step.keys) _keyField(k),
      OmniButton(
        key: const ValueKey('setup-configure'),
        label: 'Continue',
        onPressed: _busy || !_filled(step.keys)
            ? null
            : () => _run(
                () => _api.configureThing(widget.id, _typedSettings(step.keys)),
              ),
      ),
    ],
    NextKind.done => [
      OmniHeroCard(
        key: const ValueKey('setup-done'),
        icon: OmniIcons.check,
        centered: true,
        title: step.instruction ?? '${widget.name} is ready',
        subtitle: _presence
            ? 'Give it a name, then finish.'
            : 'Give it a name and a room, then finish.',
      ),
      const SizedBox(height: OmniSpace.sm),
      ..._nameAndRoom(),
      if (step.optional.isNotEmpty) ...[
        const OmniSectionHeader('Optional'),
        const Text(
          'Fill in any it needs. These can wait. Finish saves what you type.',
          style: OmniText.caption,
        ),
        const SizedBox(height: OmniSpace.sm),
        for (final k in step.optional) _keyField(k, secret: k.step == 'secret'),
      ],
      const SizedBox(height: OmniSpace.md),
      OmniButton(
        key: const ValueKey('setup-close'),
        label: 'Finish',
        onPressed: _busy ? null : _finish,
      ),
    ],
  };

  List<Widget> _pairBody(NextStep step) {
    final waitingFor = _tv
        ? 'the TV'
        : step.method == 'hue_bridge'
        ? 'the bridge'
        : widget.name;
    final left = pairingWait - _waited;
    return [
      OmniHeroCard(
        icon: _tv
            ? OmniIcons.tv
            : step.method == 'hue_bridge'
            ? OmniIcons.zigbee
            : OmniIcons.device,
        centered: true,
        title: _tv
            ? 'Look at the TV'
            : step.method == 'hue_bridge'
            ? 'Press the button on the bridge'
            : 'Pair ${widget.name}',
        subtitle: step.instruction ?? 'Get ${widget.name} ready to pair.',
      ),
      if (_busy)
        OmniCard(
          key: const ValueKey('setup-waiting'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                left.inSeconds > 0
                    ? 'Waiting for $waitingFor · ${left.inSeconds} s'
                    : 'Waiting for $waitingFor',
                textAlign: TextAlign.center,
                style: OmniText.caption,
              ),
              const SizedBox(height: OmniSpace.xs),
              OmniProgressBar(
                value: (_waited.inSeconds / pairingWait.inSeconds).clamp(0, 1),
                semanticLabel: 'Waiting for $waitingFor',
              ),
            ],
          ),
        )
      else
        OmniButton(
          key: const ValueKey('setup-pair'),
          label: _failure == null ? 'Start pairing' : 'Try again',
          onPressed: () => _run(_pair),
        ),
      const SizedBox(height: OmniSpace.sm),
      OmniButton.ghost(
        key: const ValueKey('setup-help'),
        label: _tv ? 'The TV shows nothing' : 'Nothing happens',
        onPressed: () => showOmniSheet<void>(
          context,
          builder: (context) => OmniSheet(
            title: _tv ? 'The TV shows nothing' : 'Nothing happens',
            children: [
              Text(
                _tv
                    ? 'Check the TV is on, awake and on the same Wi-Fi as this '
                          'phone. The TV asks only once debugging is on:\n'
                          '1. On the TV open Settings, then System (or Device '
                          'preferences), then About.\n'
                          '2. Select Build (Android TV OS build) 7 times, until '
                          'it says you are a developer.\n'
                          '3. Go back, open Developer options, and turn on USB '
                          'debugging and Network debugging (on some TVs, ADB '
                          'debugging).\n'
                          '4. Try again here, and choose Allow on the TV.'
                    : 'Check $waitingFor is switched on and on the same Wi-Fi '
                          'as this phone, then try again.',
                style: OmniText.body,
              ),
              const SizedBox(height: OmniSpace.md),
              OmniButton(
                label: 'Try again',
                icon: OmniIcons.retry,
                onPressed: _busy
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        unawaited(_run(_pair));
                      },
              ),
            ],
          ),
        ),
      ),
    ];
  }
}

String _failureText(ApiFailure f, NextStep? step) => step?.kind == NextKind.pair
    ? pairFailureText(f)
    : [f.message, for (final i in f.issues) i.message].join('. ');
