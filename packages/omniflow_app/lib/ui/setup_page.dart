import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/engine_calls.dart';
import '../state/providers.dart';
import 'sheets.dart' show PinSheet;

Future<void> openSetup(BuildContext context, Json device) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SetupPage(
          id: '${device['id']}',
          name: '${device['name'] ?? device['id']}',
        ),
      ),
    );

/// Walks a thing through the steps the engine says it needs, one at a
/// time: pair with `device.pair`, store secrets with `secret.set`, set
/// settings with `thing.configure`, and ask `thing.next` where it stands.
/// Without [first] it asks first, so a setup left half way picks up again.
class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({
    super.key,
    required this.id,
    required this.name,
    this.first,
  });

  final String id;
  final String name;
  final NextStep? first;

  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  NextStep? _step;
  var _busy = false;
  String? _failed;
  String? _note;
  final _fields = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _step = widget.first;
    if (_step == null) _run(() => _call(EngineCalls.thingNext, _nextArgs()));
  }

  @override
  void dispose() {
    _clearFields();
    super.dispose();
  }

  void _clearFields() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _fields.clear();
  }

  Json _nextArgs({bool paired = false}) =>
      EngineCalls.nextArgs(widget.id, paired: paired);

  Future<Json> _call(String command, Json args) =>
      ref.read(engineClientProvider).call(command, args);

  /// Runs one step's commands. [action] returns the reply carrying the next
  /// step, or a failed reply, which keeps the step up with why.
  Future<void> _run(Future<Json> Function() action) async {
    final devices = ref.read(devicesProvider.notifier);
    setState(() {
      _busy = true;
      _failed = null;
    });
    final result = await action();
    await devices.refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result['ok'] == true) {
        _step = EngineCalls.nextOf(result);
        _clearFields();
      } else {
        _failed = errorMessage(result);
      }
    });
  }

  Future<Json> _pair() async {
    final paired = await _call(
      EngineCalls.devicePair,
      EngineCalls.pairArgs(widget.id),
    );
    if (paired['ok'] != true) return paired;
    _note = paired['message'] as String?;
    return _call(EngineCalls.thingNext, _nextArgs(paired: true));
  }

  /// Stores each secret typed, then asks for the next step. The fields are
  /// cleared either way, so a secret never stays on screen.
  Future<Json> _storeSecrets(List<StepKey> keys) async {
    final stored = await _secrets(keys);
    return stored ?? _call(EngineCalls.thingNext, _nextArgs());
  }

  /// Stores the secrets typed for [keys] and clears every field. Returns a
  /// failed reply, or null when all were stored.
  Future<Json?> _secrets(List<StepKey> keys) async {
    final typed = {
      for (final k in keys)
        if (_field(k.key).text case final v when v.isNotEmpty) k.key: v,
    };
    for (final k in keys) {
      _field(k.key).clear();
    }
    for (final e in typed.entries) {
      final stored = await _call(
        EngineCalls.secretSet,
        EngineCalls.secretArgs(widget.id, e.key, e.value),
      );
      if (stored['ok'] != true) return stored;
    }
    return null;
  }

  Json _typedSettings(List<StepKey> keys) => {
    for (final k in keys)
      if (_field(k.key).text.trim() case final v when v.isNotEmpty)
        k.key: settingValue(v),
  };

  Future<Json> _configure(List<StepKey> keys) => _call(
    EngineCalls.thingConfigure,
    EngineCalls.configureArgs(widget.id, _typedSettings(keys)),
  );

  /// The optional keys a done step lists: secrets through `secret.set`,
  /// settings through `thing.configure`, then where setup stands now.
  Future<Json> _storeOptional(List<StepKey> keys) async {
    final secretKeys = [
      for (final k in keys)
        if (k.step == 'secret') k,
    ];
    final failed = await _secrets(secretKeys);
    if (failed != null) return failed;
    final settings = _typedSettings([
      for (final k in keys)
        if (k.step != 'secret') k,
    ]);
    if (settings.isNotEmpty) {
      final configured = await _call(
        EngineCalls.thingConfigure,
        EngineCalls.configureArgs(widget.id, settings),
      );
      if (configured['ok'] != true) return configured;
    }
    return _call(EngineCalls.thingNext, _nextArgs());
  }

  bool _anyTyped(List<StepKey> keys) =>
      keys.any((k) => _field(k.key).text.trim().isNotEmpty);

  TextEditingController _field(String key) =>
      _fields.putIfAbsent(key, TextEditingController.new);

  bool _filled(List<StepKey> keys) =>
      keys.every((k) => k.optional || _field(k.key).text.trim().isNotEmpty);

  Json? get _device => ref
      .read(devicesProvider)
      .value
      ?.where((d) => d['id'] == widget.id)
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final step = _step;
    return Scaffold(
      appBar: AppBar(title: Text('Set up ${widget.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (step == null && _failed == null)
            const Center(child: CircularProgressIndicator())
          else if (step != null)
            ..._stepBody(step),
          if (_note != null && step?.kind != NextKind.pair) ...[
            const SizedBox(height: 12),
            Text(_note!, key: const ValueKey('setup-note')),
          ],
          if (_failed != null) ...[
            const SizedBox(height: 12),
            Text(
              _failed!,
              key: const ValueKey('setup-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }

  Widget _title(String text) =>
      Text(text, style: Theme.of(context).textTheme.titleMedium);

  Widget _instruction(NextStep step, String fallback) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 8),
    child: Text(
      step.instruction ?? fallback,
      key: const ValueKey('setup-instruction'),
    ),
  );

  Widget _keyField(StepKey k, {bool secret = false}) => TextField(
    key: ValueKey('setup-field-${k.key}'),
    controller: _field(k.key),
    obscureText: secret,
    autocorrect: !secret,
    enableSuggestions: !secret,
    keyboardType: secret ? TextInputType.visiblePassword : null,
    decoration: InputDecoration(
      labelText: k.optional ? '${k.label} (optional)' : k.label,
    ),
    onChanged: (_) => setState(() {}),
  );

  List<Widget> _stepBody(NextStep step) => switch (step.kind) {
    NextKind.pair => [
      _title('Pair'),
      _instruction(step, 'Get ${widget.name} ready to pair, then start.'),
      FilledButton(
        key: const ValueKey('setup-pair'),
        onPressed: _busy ? null : () => _run(_pair),
        child: Text(_failed == null ? 'Start pairing' : 'Try again'),
      ),
    ],
    NextKind.secret => [
      _title('Secrets'),
      _instruction(step, 'Enter what ${widget.name} needs.'),
      for (final k in step.keys) _keyField(k, secret: true),
      const SizedBox(height: 16),
      FilledButton(
        key: const ValueKey('setup-secret-save'),
        onPressed: _busy || !_filled(step.keys)
            ? null
            : () => _run(() => _storeSecrets(step.keys)),
        child: const Text('Save'),
      ),
    ],
    NextKind.configure when step.isPins => [
      _title('Pins'),
      _instruction(step, 'Name the pins you wired up.'),
      OutlinedButton(
        key: const ValueKey('setup-pins'),
        onPressed: _device == null
            ? null
            : () async {
                await showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => PinSheet(device: _device!),
                );
                if (mounted) {
                  await _run(() => _call(EngineCalls.thingNext, _nextArgs()));
                }
              },
        child: const Text('Set pins'),
      ),
    ],
    NextKind.configure => [
      _title('Settings'),
      _instruction(step, 'Set up ${widget.name}.'),
      for (final k in step.keys) _keyField(k),
      const SizedBox(height: 16),
      FilledButton(
        key: const ValueKey('setup-configure'),
        onPressed: _busy || !_filled(step.keys)
            ? null
            : () => _run(() => _configure(step.keys)),
        child: const Text('Continue'),
      ),
    ],
    NextKind.done => [
      Text(
        step.instruction ?? '${widget.name} is ready',
        key: const ValueKey('setup-done'),
      ),
      if (step.optional.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Text('These are optional. Fill in any it needs.'),
        for (final k in step.optional) _keyField(k, secret: k.step == 'secret'),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const ValueKey('setup-optional-save'),
          onPressed: _busy || !_anyTyped(step.optional)
              ? null
              : () => _run(() => _storeOptional(step.optional)),
          child: const Text('Save these'),
        ),
      ],
      const SizedBox(height: 16),
      FilledButton(
        key: const ValueKey('setup-close'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Done'),
      ),
    ],
  };
}

/// A typed setting: JSON objects and lists stay structured, anything else
/// stays text, so an id like 0042 is not turned into a number. The CLI types
/// `omni add` settings the same way.
Object? settingValue(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map || decoded is List) return decoded;
  } on FormatException {
    return raw;
  }
  return raw;
}
