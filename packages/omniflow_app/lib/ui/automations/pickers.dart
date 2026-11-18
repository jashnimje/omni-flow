import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show AutomationSummary, Json;
import '../../api/engine_client.dart';
import '../../api/tv_calls.dart';
import '../../rules/rule_spec.dart';
import '../../rules/things.dart';
import '../../service/installed_apps.dart';
import '../../service/permissions.dart';
import '../../state/clock.dart' show hour12Provider, timeOfDayText;
import '../../state/providers.dart';
import '../design/design.dart';
import '../settings/home_location_page.dart' show HomeLocationPage;
import 'form_parts.dart';
import 'library_sheet.dart';
import 'phone_words.dart';
import 'rule_words.dart';
import 'rules_core_forms.dart';
import 'scenes.dart' show automationIconFor;
import 'timer_forms.dart';
import 'token_field.dart';
import 'web_headers.dart';
import '../../api/home_location_calls.dart' show HomeLocationCalls;
import '../../api/screen_calls.dart';

part 'trigger_pickers.dart';
part 'condition_pickers.dart';
part 'step_library.dart';
part 'step_forms.dart';
part 'phone_pickers.dart';

/// 2.3: the trigger, condition and step pickers and their short forms in
/// plain words. The library sheets live in the part files; each choice
/// pops with what it built, or null.

final _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
final _variable = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// A searchable picker page: the field, then [sections] of rows whose
/// title or subtitle matches what was typed.
class _PickerPage extends StatefulWidget {
  const _PickerPage({
    required this.title,
    required this.hint,
    required this.sections,
  });

  final String title;
  final String hint;
  final List<(String, List<_Choice>)> sections;

  @override
  State<_PickerPage> createState() => _PickerPageState();
}

class _Choice {
  const _Choice({
    required this.key,
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
  });

  final String key;
  final String title;
  final String? subtitle;
  final IconData icon;
  final Future<void> Function(BuildContext context)? onTap;
}

class _PickerPageState extends State<_PickerPage> {
  var _query = '';

  bool _matches(_Choice c) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty ||
        c.title.toLowerCase().contains(q) ||
        (c.subtitle?.toLowerCase().contains(q) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final (title, choices) in widget.sections)
        (title, choices.where(_matches).toList()),
    ].where((s) => s.$2.isNotEmpty).toList();
    return ListPage(
      title: widget.title,
      search: TextField(
        key: const ValueKey('picker-search'),
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixIcon: const Icon(OmniIcons.search),
        ),
        onChanged: (v) => setState(() => _query = v),
      ),
      state: shown.isEmpty ? const OmniLoad.empty() : const OmniLoad.data(),
      empty: const OmniEmptyState(
        icon: OmniIcons.search,
        title: 'Nothing matches',
        message: 'Try another word, or clear the search.',
        compact: true,
      ),
      children: (context) => [
        for (final (title, choices) in shown) ...[
          OmniSectionHeader(title),
          for (final c in choices)
            OmniListRow(
              key: ValueKey(c.key),
              icon: c.icon,
              title: c.title,
              subtitle: c.subtitle,
              subtitleLines: 2,
              chevron: c.onTap != null,
              onTap: c.onTap == null ? null : () => c.onTap!(context),
            ),
        ],
      ],
    );
  }
}

Future<T?> _push<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));

/// Runs [form]; when it gives a value, the picker page closes with it.
Future<void> Function(BuildContext) _then<T>(
  Future<T?> Function(BuildContext context) form,
) => (context) async {
  final value = await form(context);
  if (value != null && context.mounted) Navigator.of(context).pop(value);
};

enum _Input { none, number, text }

/// One thing a form can pick: its words, the field it needs, and what it
/// builds from the field's value.
class _Option<T> {
  const _Option(
    this.id,
    this.title,
    this.make, {
    this.input = _Input.none,
    this.choices = const [],
    this.load,
  });

  final String id;
  final String title;
  final _Input input;
  final T Function(Object? input) make;

  /// The values a text input can take, shown as chips instead of a field.
  final List<Object> choices;

  /// A longer list, such as a TV's apps, opened from a row above the field.
  final Future<List<ParamChoice>> Function()? load;
}

/// The options of a thing, the one picked and the field under it.
Future<T?> _optionsForm<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<_Option<T>> options,
  String? selected,
  Object? initialInput,
  String? unit,
  String doneLabel = 'Done',
  // More fields under the picked option (a state trigger's "for"), and
  // what they add to its result.
  List<Widget> Function(String? picked, StateSetter setState)? extra,
  T Function(T made)? finish,
}) {
  var picked = selected ?? (options.length == 1 ? options.single.id : null);
  // A chip keeps its value as it is (true, 3, "on"), not as typed text.
  Object? chosen = initialInput;
  final field = TextEditingController(
    text: initialInput == null ? '' : valueText(initialInput),
  );
  Object? input() {
    final option = options.where((o) => o.id == picked).firstOrNull;
    return switch (option?.input) {
      _Input.number => num.tryParse(field.text.trim()),
      _Input.text when option!.choices.isNotEmpty =>
        option.choices.contains(chosen) ? chosen : null,
      _Input.text =>
        field.text.trim().isEmpty ? null : literalFromText(field.text),
      _ => true,
    };
  }

  return showFormSheet<T>(
    context,
    owns: [field],
    title: title,
    subtitle: subtitle,
    doneLabel: doneLabel,
    whyNot: () {
      final option = options.where((o) => o.id == picked).firstOrNull;
      if (option == null) return options.isEmpty ? null : 'Pick one above';
      return switch (option.input) {
        _Input.number => 'Enter a number',
        _Input.text when option.choices.isNotEmpty => 'Choose a value',
        _Input.text => 'Enter a value',
        _ => null,
      };
    },
    result: () {
      final option = options.where((o) => o.id == picked).firstOrNull;
      final value = input();
      if (option == null || value == null) return null;
      final made = option.make(value);
      return finish == null ? made : finish(made);
    },
    build: (context, setState) {
      final option = options.where((o) => o.id == picked).firstOrNull;
      return [
        if (options.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: OmniSpace.md),
            child: Text(
              'It reports nothing an automation can use yet.',
              style: OmniText.captionOf(context),
            ),
          ),
        for (final o in options)
          ChoiceRow(
            key: ValueKey('opt-${o.id}'),
            title: o.input == _Input.none ? o.title : '${o.title}…',
            selected: o.id == picked,
            onTap: () => setState(() => picked = o.id),
          ),
        if (option != null && option.choices.isNotEmpty) ...[
          const SizedBox(height: OmniSpace.md),
          Wrap(
            key: const ValueKey('opt-choices'),
            spacing: OmniSpace.sm,
            runSpacing: OmniSpace.sm,
            children: [
              for (final v in option.choices)
                OmniFilterChip(
                  key: ValueKey('opt-choice-$v'),
                  label: valueText(v),
                  selected: chosen == v,
                  onTap: () => setState(() {
                    chosen = v;
                    field.text = valueText(v);
                  }),
                ),
            ],
          ),
        ] else if (option != null && option.input != _Input.none) ...[
          if (option.load case final load?) ...[
            const SizedBox(height: OmniSpace.md),
            OmniListRow(
              key: const ValueKey('opt-pick'),
              icon: OmniIcons.search,
              title: 'Choose from the list',
              subtitle: field.text.isEmpty ? null : field.text,
              chevron: true,
              onTap: () async {
                final choice = await showOmniSheet<ParamChoice>(
                  context,
                  builder: (_) => ChoiceSheet(title: option.title, load: load),
                );
                if (choice != null) setState(() => field.text = choice.value);
              },
            ),
          ],
          const SizedBox(height: OmniSpace.md),
          LabelledField(
            key: const ValueKey('opt-input'),
            label: option.title,
            controller: field,
            number: option.input == _Input.number,
            suffix: option.input == _Input.number ? unit : null,
            hint: option.input == _Input.number
                ? '28'
                : 'on, off, 30 or a word',
            autofocus: true,
            onChanged: (_) => setState(() {}),
          ),
        ],
        ...?extra?.call(picked, setState),
      ];
    },
  );
}

/// The filter on an event's details (an agent's or the JSON's), kept while
/// the same event stays picked, since no form here edits it.
Map<String, Object?>? _keptMatch(
  OnTrigger? current,
  String thing,
  String key,
) =>
    current != null &&
        current.mode == OnMode.event &&
        current.thing == thing &&
        current.key == key
    ? current.match
    : null;

/// The variables automations have set, as chips under a name field, so a
/// rule checks the same spelling another one sets.
class _KnownVariables extends ConsumerStatefulWidget {
  const _KnownVariables({required this.controller, required this.onPicked});

  final TextEditingController controller;
  final VoidCallback onPicked;

  @override
  ConsumerState<_KnownVariables> createState() => _KnownVariablesState();
}

class _KnownVariablesState extends ConsumerState<_KnownVariables> {
  late final Future<List<String>> _names = () async {
    final r = await ref.read(engineClientProvider).call(VarCalls.list);
    final vars = r['variables'];
    return [
      if (vars is Map)
        for (final k in vars.keys)
          // Names with _ are the engine's own.
          if (!'$k'.startsWith('_')) '$k',
    ]..sort();
  }();

  @override
  Widget build(BuildContext context) => FutureBuilder<List<String>>(
    future: _names,
    builder: (context, snap) {
      final names = snap.data ?? const <String>[];
      if (names.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: OmniSpace.sm),
        child: Wrap(
          key: const ValueKey('known-variables'),
          spacing: OmniSpace.sm,
          runSpacing: OmniSpace.sm,
          children: [
            for (final n in names)
              OmniFilterChip(
                key: ValueKey('known-var-$n'),
                label: n,
                selected: widget.controller.text.trim() == n,
                onTap: () {
                  widget.controller.text = n;
                  widget.onPicked();
                },
              ),
          ],
        ),
      );
    },
  );
}

/// Any device that takes commands, as a picker (a scene's actions).
Future<Thing?> pickDevice(
  BuildContext context,
  RuleWords words, {
  String title = 'Add an action',
}) => _push(
  context,
  _PickerPage(
    title: title,
    hint: 'Search devices',
    sections: [
      (
        'Devices',
        [
          for (final t in words.things)
            if (t.actions.isNotEmpty)
              _Choice(
                key: 'pick-device-${t.id}',
                title: t.name,
                subtitle: t.actionsText,
                icon: t.icon,
                onTap: (c) async => Navigator.of(c).pop(t),
              ),
        ],
      ),
    ],
  ),
);

/// The devices a keep step can hold, as a picker.
Future<Thing?> pickKeepThing(BuildContext context, RuleWords words) => _push(
  context,
  _PickerPage(
    title: 'Keep…',
    hint: 'Search devices',
    sections: [
      (
        'Devices',
        [
          for (final t in words.things)
            if (t.actions.any(
              (c) =>
                  c['type'] == 'toggle' ||
                  (c['params'] as Map?)?['value'] is Map,
            ))
              _Choice(
                key: 'pick-keep-${t.id}',
                title: t.name,
                subtitle: t.actionsText,
                icon: t.icon,
                onTap: (c) async => Navigator.of(c).pop(t),
              ),
        ],
      ),
    ],
  ),
);
