import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../design/design.dart';
import 'device_controls.dart' show ColourSwatches;

/// The controls of the capabilities the device page has no special layout
/// for (actions with params, text commands, remotes, sensors, events),
/// chosen by capability type, and the params form the rule builder reuses.
/// Nothing here knows about a specific device.

/// True for a device that runs commands on a host, where a tap can do harm.
bool isHighRiskCapability(Json cap) =>
    cap['highRisk'] == true || cap['type'] == 'exec';

/// One control for one capability, chosen by capability type.
class CapabilityControl extends ConsumerStatefulWidget {
  const CapabilityControl({
    super.key,
    required this.device,
    required this.capability,
  });

  final Json device;
  final Json capability;

  @override
  ConsumerState<CapabilityControl> createState() => _CapabilityControlState();
}

class _CapabilityControlState extends ConsumerState<CapabilityControl> {
  double? _dragging;
  final _text = TextEditingController();

  Json get cap => widget.capability;
  String get deviceId => widget.device['id'] as String;
  String get id => cap['id'] as String;
  Json get state =>
      Map<String, Object?>.from(widget.device['state'] as Map? ?? const {});
  Object? get current =>
      cap['stateKey'] == null ? null : state[cap['stateKey']];
  Json get params =>
      Map<String, Object?>.from(cap['params'] as Map? ?? const {});
  Json get valueParam =>
      Map<String, Object?>.from(params['value'] as Map? ?? const {});

  /// Invokes the capability, after the user confirms when it runs on a host.
  Future<bool> _invoke(Json params) async {
    if (isHighRiskCapability(cap)) {
      final ok = await confirm(
        context,
        title: 'Run ${cap['label']}?',
        body:
            'This runs a command on ${widget.device['host']} '
            '(${widget.device['name']}).',
        action: 'Run',
      );
      if (!ok || !mounted) return false;
    }
    final result = await callEngine(ref, 'device.invoke', {
      'id': deviceId,
      'capability': id,
      'params': params,
    });
    return result['ok'] == true;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = Text('${cap['label']}');
    final key = ValueKey('$deviceId.$id');
    final known = cap['stateKey'] != null && state.containsKey(cap['stateKey']);
    switch (cap['type']) {
      case 'toggle':
        if (!known) {
          return ListTile(
            key: key,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: label,
            subtitle: const Text('-'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => _invoke({'value': false}),
                  child: Text('Off', semanticsLabel: '${cap['label']} off'),
                ),
                TextButton(
                  onPressed: () => _invoke({'value': true}),
                  child: Text('On', semanticsLabel: '${cap['label']} on'),
                ),
              ],
            ),
          );
        }
        return SwitchListTile(
          key: key,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: label,
          value: current == true,
          onChanged: (v) => _invoke({'value': v}),
        );
      case 'level' || 'color_temp':
        final min = (valueParam['min'] as num? ?? 0).toDouble();
        final max = (valueParam['max'] as num? ?? 100).toDouble();
        final unit = '${valueParam['unit'] ?? ''}';
        final shown =
            _dragging ?? (current is num ? (current! as num).toDouble() : null);
        final value = (shown ?? min).clamp(min, max);
        return Row(
          key: key,
          children: [
            SizedBox(width: 110, child: label),
            Expanded(
              child: Slider(
                min: min,
                max: max,
                value: value,
                label: '${value.round()}$unit',
                semanticFormatterCallback: (v) => '${v.round()}$unit',
                divisions: (max - min).round().clamp(1, 100),
                onChanged: (v) => setState(() => _dragging = v),
                onChangeEnd: (v) async {
                  await _invoke({'value': v.round()});
                  if (mounted) setState(() => _dragging = null);
                },
              ),
            ),
            SizedBox(
              width: 56,
              child: Text(
                shown == null ? '-' : '${shown.round()}$unit',
                key: ValueKey('level-$deviceId.$id'),
                textAlign: TextAlign.end,
              ),
            ),
          ],
        );
      case 'color_rgb':
        return ColourSwatches(key: key, onPick: _invoke);
      case 'action' || 'exec':
        final inputs = {
          for (final e in params.entries)
            e.key: Map<String, Object?>.from(e.value as Map),
        };
        if (inputs.isNotEmpty) {
          return ParamsForm(
            key: key,
            label: '${cap['label']}',
            params: inputs,
            onSubmit: _invoke,
          );
        }
        return Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: key,
            onPressed: () => _invoke(const {}),
            child: label,
          ),
        );
      case 'dpad_remote':
        final keys = (valueParam['values'] as List? ?? const []).cast<String>();
        return Wrap(
          key: key,
          spacing: 6,
          children: [
            for (final k in keys)
              OutlinedButton(
                onPressed: () => _invoke({'value': k}),
                child: Text(k),
              ),
          ],
        );
      case 'text_command':
        return Row(
          key: key,
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                decoration: InputDecoration(labelText: cap['label'] as String),
              ),
            ),
            IconButton(
              icon: const Icon(OmniIcons.enter),
              tooltip: 'Send',
              onPressed: () {
                if (_text.text.isNotEmpty) _invoke({'value': _text.text});
              },
            ),
          ],
        );
      case 'sensor':
        final value = current;
        return ListTile(
          key: key,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: label,
          trailing: Text(
            value == null
                ? '-'
                : value is bool
                ? (value ? 'on' : 'off')
                : '$value${valueParam['unit'] ?? ''}',
            key: ValueKey('sensor-$deviceId.$id'),
          ),
        );
      case 'event':
        return ListTile(
          key: key,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: label,
          subtitle: const Text('Something it does. Use it in a rule'),
        );
      default:
        return ListTile(
          key: key,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: label,
          subtitle: const Text('Not supported in the app yet'),
        );
    }
  }
}

/// A form for an action that takes params: a number field with its range,
/// a dropdown for a fixed list, a switch for on/off, text otherwise.
class ParamsForm extends StatefulWidget {
  const ParamsForm({
    super.key,
    required this.label,
    required this.params,
    required this.onSubmit,
    this.submitLabel,
    this.initial = const {},
  });

  final String label;
  final Map<String, Json> params;
  final Future<bool> Function(Json params) onSubmit;

  /// The button's text, `Send <label>` when null.
  final String? submitLabel;

  /// Values to start from, for editing params already chosen.
  final Json initial;

  @override
  State<ParamsForm> createState() => _ParamsFormState();
}

class _ParamsFormState extends State<ParamsForm> {
  late final _text = {
    for (final e in widget.params.entries)
      if (e.value['type'] != 'boolean' && e.value['values'] == null)
        e.key: TextEditingController(
          text: widget.initial[e.key] == null ? '' : '${widget.initial[e.key]}',
        ),
  };
  late final _choice = <String, Object?>{
    for (final e in widget.initial.entries)
      if (!_text.containsKey(e.key)) e.key: e.value,
  };

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// The params to send, or null while a required one is missing or a
  /// number is out of its range.
  Json? get _values {
    final out = <String, Object?>{};
    for (final e in widget.params.entries) {
      final spec = e.value;
      final Object? value;
      if (_text[e.key] case final c?) {
        final text = c.text.trim();
        if (text.isEmpty) {
          value = null;
        } else if (spec['type'] == 'number') {
          final n = num.tryParse(text);
          if (n == null || _outOfRange(spec, n)) return null;
          value = n;
        } else {
          value = text;
        }
      } else {
        value = _choice[e.key] ?? (spec['type'] == 'boolean' ? false : null);
      }
      if (value == null) {
        if (spec['optional'] != true) return null;
        continue;
      }
      out[e.key] = value;
    }
    return out;
  }

  static bool _outOfRange(Json spec, num n) =>
      (spec['min'] is num && n < (spec['min'] as num)) ||
      (spec['max'] is num && n > (spec['max'] as num));

  String? _rangeHelp(Json spec) => switch ((spec['min'], spec['max'])) {
    (final num min, final num max) => '$min to $max',
    (final num min, _) => 'at least $min',
    (_, final num max) => 'at most $max',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final values = _values;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(widget.label),
        ),
        for (final e in widget.params.entries)
          if (_text[e.key] case final c?)
            TextField(
              key: ValueKey('param-${e.key}'),
              controller: c,
              keyboardType: e.value['type'] == 'number'
                  ? TextInputType.number
                  : TextInputType.text,
              decoration: InputDecoration(
                labelText: e.value['optional'] == true
                    ? '${_words(e.key)} (optional)'
                    : _words(e.key),
                helperText: _rangeHelp(e.value),
                errorText: switch (num.tryParse(c.text.trim())) {
                  final n? when _outOfRange(e.value, n) =>
                    'Must be ${_rangeHelp(e.value)}',
                  null
                      when e.value['type'] == 'number' &&
                          c.text.trim().isNotEmpty =>
                    'Must be a number',
                  _ => null,
                },
              ),
              onChanged: (_) => setState(() {}),
            )
          else if (e.value['values'] case final List options)
            DropdownButtonFormField<Object>(
              key: ValueKey('param-${e.key}'),
              initialValue: _choice[e.key],
              decoration: InputDecoration(labelText: _words(e.key)),
              items: [
                for (final o in options)
                  DropdownMenuItem(
                    value: o as Object,
                    child: Text(o is String ? _words(o) : '$o'),
                  ),
              ],
              onChanged: (v) => setState(() => _choice[e.key] = v),
            )
          else
            SwitchListTile(
              key: ValueKey('param-${e.key}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(_words(e.key)),
              value: _choice[e.key] == true,
              onChanged: (v) => setState(() => _choice[e.key] = v),
            ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: ValueKey('params-run-${widget.label}'),
          onPressed: values == null ? null : () => widget.onSubmit(values),
          child: Text(widget.submitLabel ?? 'Send ${widget.label}'),
        ),
      ],
    );
  }
}

/// A param or value as words: `long_press` reads "Long press".
String _words(String key) {
  final spaced = key
      .replaceAll('_', ' ')
      .replaceAllMapped(RegExp('([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .toLowerCase();
  return spaced.isEmpty
      ? key
      : '${spaced[0].toUpperCase()}${spaced.substring(1)}';
}
