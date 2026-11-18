import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show clockWords;

import '../../api/engine_calls.dart' show Json;
import '../../rules/rule_spec.dart';
import '../../state/clock.dart' show hour12Provider;
import '../design/design.dart';
import '../devices/light_panels.dart';
import 'rule_words.dart';

/// A short form in a sheet: [build] lays out its controls, [result] is what
/// it makes of them (null while incomplete, which keeps Done disabled).
Future<T?> showFormSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<Widget> Function(BuildContext context, StateSetter setState)
  build,
  required T? Function() result,
  String doneLabel = 'Done',
  String? Function()? whyNot,
  List<ChangeNotifier> owns = const [],
}) => showOmniSheet<T>(
  context,
  builder: (context) => Owning(
    owns,
    child: StatefulBuilder(
      builder: (context, setState) {
        final value = result();
        return SheetTemplate(
          title: title,
          subtitle: subtitle,
          primaryLabel: doneLabel,
          primaryKey: const ValueKey('form-done'),
          onPrimary: value == null
              ? null
              : () => Navigator.of(context).pop(value),
          // Why Done is off, above it in the pinned bar.
          missing: value == null ? whyNot?.call() : null,
          children: (context) => build(context, setState),
        );
      },
    ),
  ),
);

/// One choice of a form: its row, with a check when it is the one picked.
class ChoiceRow extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.icon,
    this.warning = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onTap;

  /// Marks a high-risk choice.
  final bool warning;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    inMutuallyExclusiveGroup: true,
    child: OmniListRow(
      title: title,
      subtitle: subtitle,
      subtitleLines: 3,
      icon: icon,
      onTap: onTap,
      trailing: selected
          ? Icon(
              OmniIcons.check,
              color: OmniPalette.of(context).accent,
              size: 22,
            )
          : warning
          ? Icon(
              OmniIcons.warning,
              color: OmniPalette.of(context).warn,
              size: 20,
              semanticLabel: 'High risk',
            )
          : null,
    ),
  );
}

/// A labelled text field in the field style of the mockups.
class LabelledField extends StatelessWidget {
  const LabelledField({
    super.key,
    required this.label,
    required this.controller,
    required this.onChanged,
    this.hint,
    this.number = false,
    this.suffix,
    this.error,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool number;
  final String? suffix;
  final String? error;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: OmniSpace.sm),
    child: TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixText: suffix,
        errorText: error,
      ),
      onChanged: onChanged,
    ),
  );
}

/// A time of day as a row that opens the time picker.
class TimeRow extends ConsumerWidget {
  const TimeRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;

  /// `HH:MM`.
  final String value;
  final ValueChanged<String> onChanged;

  static String format(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static TimeOfDay parse(String hhmm) {
    final parts = hhmm.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts.first) ?? 18,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Kept as HH:MM, shown as the phone reads the time.
    final shown = clockWords(value, hour12: ref.watch(hour12Provider));
    return OmniListRow(
      title: label,
      icon: OmniIcons.time,
      value: shown,
      semanticLabel: '$label $shown. Change',
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: parse(value),
          initialEntryMode: TimePickerEntryMode.dial,
        );
        if (picked != null) onChanged(format(picked));
      },
    );
  }
}

/// The days of the week as chips. None picked means every day.
class DayChips extends StatelessWidget {
  const DayChips({super.key, required this.days, required this.onChanged});

  final Set<String> days;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    children: [
      for (final d in weekDays)
        OmniFilterChip(
          key: ValueKey('day-$d'),
          label: dayName(d),
          selected: days.contains(d),
          onTap: () {
            days.contains(d) ? days.remove(d) : days.add(d);
            onChanged();
          },
        ),
    ],
  );
}

enum DurationUnit {
  seconds('s', 'seconds', 1000),
  minutes('min', 'minutes', 60000),
  hours('h', 'hours', 3600000);

  const DurationUnit(this.short, this.label, this.ms);

  final String short;
  final String label;
  final int ms;

  static DurationUnit of(int ms) => values.lastWhere(
    (u) => ms >= u.ms && ms % u.ms == 0,
    orElse: () => seconds,
  );
}

/// A duration as a whole number and a unit. [onChanged] gets -1 while the
/// number is not a whole number.
class DurationInput extends StatefulWidget {
  const DurationInput({
    super.key,
    required this.ms,
    required this.onChanged,
    this.label = 'How long',
  });

  final int ms;
  final ValueChanged<int> onChanged;
  final String label;

  @override
  State<DurationInput> createState() => _DurationInputState();
}

class _DurationInputState extends State<DurationInput> {
  late var _unit = DurationUnit.of(widget.ms);
  late final _amount = TextEditingController(text: '${widget.ms ~/ _unit.ms}');

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _send() {
    final n = int.tryParse(_amount.text.trim());
    widget.onChanged(n == null || n < 0 ? -1 : n * _unit.ms);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LabelledField(
        key: const ValueKey('duration-amount'),
        label: widget.label,
        controller: _amount,
        number: true,
        onChanged: (_) => _send(),
      ),
      OmniSegmented<DurationUnit>(
        segments: [
          for (final u in DurationUnit.values) OmniSegment(u, u.label),
        ],
        selected: _unit,
        onChanged: (u) {
          setState(() => _unit = u);
          _send();
        },
      ),
    ],
  );
}

/// The params of a capability as proper controls: a switch for on/off,
/// chips for a fixed list, a slider for a number with a range, a field
/// otherwise. [values] is edited in place.
class ParamControls extends StatefulWidget {
  const ParamControls({
    super.key,
    required this.params,
    required this.values,
    required this.onChanged,
    this.choices = const {},
  });

  final Map<String, Json> params;
  final Json values;
  final VoidCallback onChanged;

  /// For a text param, what it can be, loaded when the user opens the
  /// list: the apps on a TV for its `package`. The field stays for a value
  /// the list does not have.
  final Map<String, Future<List<ParamChoice>> Function()> choices;

  /// [values] when every required param is set and every number is in its
  /// range, else null.
  static Json? complete(Map<String, Json> params, Json values) {
    final out = <String, Object?>{};
    for (final e in params.entries) {
      final v = values[e.key];
      if (v == null || (v is String && v.isEmpty)) {
        if (e.value['optional'] == true) continue;
        if (e.value['type'] == 'boolean') {
          out[e.key] = false;
          continue;
        }
        return null;
      }
      if (e.value['type'] == 'number') {
        if (v is! num) return null;
        if (e.value['min'] is num && v < (e.value['min'] as num)) return null;
        if (e.value['max'] is num && v > (e.value['max'] as num)) return null;
      }
      out[e.key] = v;
    }
    // A param the action does not declare (an agent's, or a newer
    // driver's) has no control here, so it goes back as it came.
    for (final e in values.entries) {
      if (!params.containsKey(e.key)) out[e.key] = e.value;
    }
    return out;
  }

  /// Starts each required number with a range at its middle: a slider
  /// always shows a value, so the form should hold the value it shows.
  static void seed(Map<String, Json> params, Json values) {
    for (final e in params.entries) {
      final spec = e.value;
      if (values[e.key] != null || spec['optional'] == true) continue;
      if (spec['type'] == 'number' &&
          spec['min'] is num &&
          spec['max'] is num &&
          spec['values'] == null) {
        final mid = ((spec['min'] as num) + (spec['max'] as num)) / 2;
        values[e.key] = spec['integer'] == true ? mid.round() : mid;
      }
    }
  }

  /// What a field for the param [key] is called: plain words for the
  /// names that are not ([paramWords]), else the name spaced out.
  static String labelOf(String key) {
    if (paramWords[key] case final words?) return words;
    final spaced = key
        .replaceAll('_', ' ')
        .replaceAllMapped(RegExp('([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
        .toLowerCase();
    return spaced.isEmpty
        ? key
        : '${spaced[0].toUpperCase()}${spaced.substring(1)}';
  }

  /// The title of the sheet that picks [key]'s value from a list.
  static String choiceTitleOf(String key) => switch (key) {
    'package' => 'Choose an app',
    _ => labelOf(key),
  };

  @override
  State<ParamControls> createState() => _ParamControlsState();
}

class _ParamControlsState extends State<ParamControls> {
  final _text = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    ParamControls.seed(widget.params, widget.values);
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(String key) => _text.putIfAbsent(
    key,
    () => TextEditingController(
      text: widget.values[key] == null ? '' : '${widget.values[key]}',
    ),
  );

  /// The params a choice of another param takes (a moving scene's
  /// `speed`), with whether the picked choice takes them now.
  Map<String, bool> get _taken {
    final out = <String, bool>{};
    for (final e in widget.params.entries) {
      final choices = sceneChoicesOf({
        'params': {'scene': e.value},
      });
      if (choices.isEmpty) continue;
      final picked = choices
          .where((c) => c['value'] == widget.values[e.key])
          .firstOrNull;
      for (final c in choices) {
        for (final k in (c['takes'] as List? ?? const [])) {
          out['$k'] = (out['$k'] ?? false) || choiceTakes(picked, '$k');
        }
      }
    }
    return out;
  }

  /// Whether [params] are a colour: r, g and b, picked on a wheel.
  bool get _colour =>
      ['r', 'g', 'b'].every((k) => widget.params[k]?['type'] == 'number');

  @override
  Widget build(BuildContext context) {
    final taken = _taken;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_colour) _colourControl(),
        for (final e in widget.params.entries)
          if (taken[e.key] != false &&
              !(_colour && const {'r', 'g', 'b'}.contains(e.key)))
            _control(e.key, e.value),
      ],
    );
  }

  Widget _colourControl() => Padding(
    key: const ValueKey('param-colour'),
    padding: const EdgeInsets.only(bottom: OmniSpace.sm),
    child: ColourPicker(
      value: {
        for (final k in ['r', 'g', 'b']) k: widget.values[k],
      },
      onPick: (rgb) {
        setState(() => widget.values.addAll(rgb));
        widget.onChanged();
      },
    ),
  );

  Widget _control(String key, Json spec) {
    final label =
        '${ParamControls.labelOf(key)}${spec['optional'] == true ? ' (optional)' : ''}';
    final unit = spec['unit'] as String?;
    void set(Object? v) {
      setState(() => widget.values[key] = v);
      widget.onChanged();
    }

    if (spec['type'] == 'boolean') {
      return OmniListRow(
        key: ValueKey('param-$key'),
        title: label,
        trailing: Switch(value: widget.values[key] == true, onChanged: set),
      );
    }
    final scenes = sceneChoicesOf({
      'params': {'scene': spec},
    });
    if (scenes.isNotEmpty) {
      return Padding(
        key: ValueKey('param-$key'),
        padding: const EdgeInsets.only(bottom: OmniSpace.sm),
        child: SceneGrid(
          choices: scenes,
          active: widget.values[key] as String?,
          onPick: set,
        ),
      );
    }
    if (spec['values'] case final List options) {
      return Padding(
        padding: const EdgeInsets.only(bottom: OmniSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: OmniText.captionOf(context)),
            Wrap(
              key: ValueKey('param-$key'),
              spacing: 6,
              children: [
                for (final o in options)
                  OmniFilterChip(
                    label: '$o',
                    selected: widget.values[key] == o,
                    onTap: () => set(o),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    final min = spec['min'];
    final max = spec['max'];
    if (spec['type'] == 'number' && min is num && max is num) {
      final integer = spec['integer'] == true;
      final current = widget.values[key];
      final slider = Padding(
        padding: const EdgeInsets.only(bottom: OmniSpace.sm),
        child: OmniLabelledSlider(
          key: ValueKey('param-$key'),
          label: label,
          min: min.toDouble(),
          max: max.toDouble(),
          step: integer ? 1 : null,
          value: (current is num ? current : (min + max) / 2).toDouble(),
          format: (v) => valueText(integer ? v.round() : v, unit: unit),
          onChanged: (v) => set(integer ? v.round() : v),
          onChangeEnd: (v) => set(integer ? v.round() : v),
        ),
      );
      if (unit != 'K') return slider;
      // A white, with the warm to cool whites the light takes.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          slider,
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.sm),
            child: WhitePresets(
              min: min.toDouble(),
              max: max.toDouble(),
              value: current is num ? current : null,
              onPick: set,
            ),
          ),
        ],
      );
    }
    final c = _field(key);
    final field = LabelledField(
      key: ValueKey('param-$key'),
      label: label,
      controller: c,
      number: spec['type'] == 'number',
      suffix: unit,
      onChanged: (t) =>
          set(spec['type'] == 'number' ? num.tryParse(t.trim()) : t.trim()),
    );
    final load = widget.choices[key];
    if (load == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniListRow(
          key: ValueKey('param-$key-pick'),
          leading: Icon(
            OmniIcons.search,
            color: OmniPalette.of(context).accent,
          ),
          title: 'Choose from the list',
          subtitle: widget.values[key] == null
              ? null
              : _picked[key] ?? '${widget.values[key]}',
          onTap: () async {
            final choice = await showOmniSheet<ParamChoice>(
              context,
              builder: (_) => ChoiceSheet(
                title: ParamControls.choiceTitleOf(key),
                load: load,
              ),
            );
            if (choice == null || !mounted) return;
            c.text = choice.value;
            _picked[key] = choice.label;
            set(choice.value);
          },
        ),
        field,
      ],
    );
  }

  final _picked = <String, String>{};
}

/// One value a param can take, with the words for it.
typedef ParamChoice = ({String value, String label});

/// Plain words for the param names drivers use that do not read as words
/// on their own: an app is picked by its package, a link is a URL.
const paramWords = <String, String>{
  'package': 'App',
  'url': 'Link',
  'key': 'Button',
  'phoneMac': 'Phone MAC address',
  'c': 'Cool white',
  'w': 'Warm white',
};

/// A searchable list of choices, loaded when it opens, that pops the one
/// picked.
class ChoiceSheet extends StatefulWidget {
  const ChoiceSheet({super.key, required this.title, required this.load});

  final String title;
  final Future<List<ParamChoice>> Function() load;

  @override
  State<ChoiceSheet> createState() => _ChoiceSheetState();
}

class _ChoiceSheetState extends State<ChoiceSheet> {
  late final _choices = widget.load();

  @override
  Widget build(BuildContext context) => FutureBuilder<List<ParamChoice>>(
    future: _choices,
    builder: (context, snap) {
      final e = snap.error;
      return PickerSheet<ParamChoice>(
        title: widget.title,
        // Searchable however short: the list is a TV's apps or the like.
        searchFrom: 0,
        state: snap.hasError
            ? OmniLoad.error(
                e is String
                    ? e
                    : 'The list did not load. Close this and try again.',
              )
            : snap.data == null
            ? const OmniLoad.loading()
            : const OmniLoad.data(),
        sections: [
          PickerSection([
            for (final c in snap.data ?? const <ParamChoice>[])
              PickerItem(
                key: ValueKey('choice-${c.value}'),
                value: c,
                title: c.label,
                subtitle: c.label == c.value ? null : c.value,
              ),
          ]),
        ],
      );
    },
  );
}
