import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

import 'package:material_symbols_icons/symbols.dart';

import '../automations/form_parts.dart'
    show ChoiceSheet, ParamChoice, ParamControls;
import '../automations/pickers.dart' show phoneAppChoices;
import '../design/design.dart';
import 'light_panels.dart' show ColourSwatches;

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

  /// What a switch the device does not report was last set to here.
  bool? _sent;
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
        // A switch like every other. One the device never reports shows
        // what was last set here. A phone's switches are the same: Android
        // tells no app whether the torch is on, so until it is set from
        // OmniFlow it says so rather than "Not read yet", which no read
        // would ever change.
        final name = '${cap['label']}';
        final readable =
            cap['stateKey'] != null && widget.device['driver'] != 'phone';
        final on = known ? current == true : _sent ?? false;
        return OmniListRow(
          key: key,
          icon: actionIconOf(cap),
          title: name,
          subtitle: known
              ? null
              : !readable
              ? (_sent == null
                    ? 'It does not report whether it is on'
                    : 'Last set ${_sent! ? 'on' : 'off'} here')
              : 'Not read yet',
          trailing: Switch(
            key: ValueKey('switch-$deviceId.$id'),
            value: on,
            onChanged: (v) async {
              if (await _invoke({'value': v}) && mounted) {
                setState(() => _sent = v);
              }
            },
          ),
          semanticLabel: name,
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
        final name = '${cap['label']}';
        if (inputs.isNotEmpty) {
          return OmniListRow(
            key: key,
            icon: actionIconOf(cap),
            title: name,
            chevron: true,
            onTap: () => SheetTemplate.show<void>(
              context,
              builder: (sheet) => SheetTemplate(
                title: name,
                children: (_) => [
                  ParamsForm(
                    label: name,
                    heading: false,
                    params: inputs,
                    choices: {
                      if (widget.device['driver'] == 'phone')
                        'package': phoneAppChoices,
                    },
                    onSubmit: (values) async {
                      final ok = await _invoke(values);
                      if (ok && sheet.mounted) Navigator.of(sheet).pop();
                      return ok;
                    },
                  ),
                ],
              ),
            ),
          );
        }
        return OmniListRow(
          key: key,
          icon: actionIconOf(cap),
          title: name,
          value: 'Run',
          semanticLabel: 'Run $name',
          onTap: () => _invoke(const {}),
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
        return OmniListRow(
          key: key,
          icon: OmniIcons.forCapability('event'),
          title: '${cap['label']}',
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
    this.heading = true,
    this.choices = const {},
  });

  /// Shows [label] above the fields. Off inside a sheet titled with it.
  final bool heading;

  /// For a text param, a list to pick its value from (the phone's apps
  /// for an app's package). The field stays for a value not listed.
  final Map<String, Future<List<ParamChoice>> Function()> choices;

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

  /// The words for a value picked from a list, by param.
  final _picked = <String, String>{};

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
        if (widget.heading)
          Padding(
            padding: const EdgeInsets.only(top: OmniSpace.sm),
            child: Text(widget.label),
          ),
        for (final e in widget.params.entries)
          if (_text[e.key] case final c?) ...[
            if (widget.choices[e.key] case final load?)
              OmniListRow(
                key: ValueKey('param-${e.key}-pick'),
                icon: OmniIcons.search,
                title: 'Choose from the list',
                subtitle: _picked[e.key],
                chevron: true,
                onTap: () async {
                  final choice = await showOmniSheet<ParamChoice>(
                    context,
                    builder: (_) => ChoiceSheet(
                      title: ParamControls.choiceTitleOf(e.key),
                      load: load,
                    ),
                  );
                  if (choice == null || !mounted) return;
                  setState(() {
                    c.text = choice.value;
                    _picked[e.key] = choice.label;
                  });
                },
              ),
            TextField(
              key: ValueKey('param-${e.key}'),
              controller: c,
              keyboardType: e.value['type'] == 'number'
                  ? TextInputType.number
                  : TextInputType.text,
              decoration: InputDecoration(
                labelText: e.value['optional'] == true
                    ? '${ParamControls.labelOf(e.key)} (optional)'
                    : ParamControls.labelOf(e.key),
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
            ),
          ] else if (e.value['values'] case final List options)
            DropdownButtonFormField<Object>(
              key: ValueKey('param-${e.key}'),
              initialValue: _choice[e.key],
              decoration: InputDecoration(
                labelText: ParamControls.labelOf(e.key),
              ),
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
              title: Text(ParamControls.labelOf(e.key)),
              value: _choice[e.key] == true,
              onChanged: (v) => setState(() => _choice[e.key] = v),
            ),
        const SizedBox(height: OmniSpace.md),
        OmniButton(
          key: ValueKey('params-run-${widget.label}'),
          label: widget.submitLabel ?? widget.label,
          onPressed: values == null ? null : () => widget.onSubmit(values),
        ),
      ],
    );
  }
}

/// The icon of an action or switch: the manifest's own, else one for
/// what its id says it does, else the generic action icon.
IconData actionIconOf(Json cap) {
  if (OmniIcons.forManifestIcon(cap['icon'] as String?) case final named?) {
    return named;
  }
  final id = '${cap['id']}'.toLowerCase();
  for (final (words, icon) in _actionIcons) {
    if (words.any(id.contains)) return icon;
  }
  return OmniIcons.forCapability(cap['type'] == 'toggle' ? 'toggle' : 'action');
}

const _actionIcons = <(List<String>, IconData)>[
  (['speak', 'say'], Symbols.record_voice_over_rounded),
  (['vibrat'], Symbols.vibration_rounded),
  (['torch', 'flash'], Symbols.flashlight_on_rounded),
  (['dnd', 'disturb'], Symbols.do_not_disturb_on_rounded),
  (['sound', 'ring'], Symbols.notifications_active_rounded),
  (['volume'], Symbols.volume_up_rounded),
  (['media'], Symbols.play_pause_rounded),
  (['open_app', 'launch'], OmniIcons.apps),
  (['link', 'url'], Symbols.link_rounded),
  (['alarm'], Symbols.alarm_rounded),
  (['timer'], Symbols.timer_rounded),
  (['message', 'notify'], Symbols.chat_rounded),
];

/// An option value as words: `long_press` reads "Long press".
String _words(String key) {
  final spaced = key
      .replaceAll('_', ' ')
      .replaceAllMapped(RegExp('([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .toLowerCase();
  return spaced.isEmpty
      ? key
      : '${spaced[0].toUpperCase()}${spaced.substring(1)}';
}
