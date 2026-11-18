import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rules/rule_spec.dart' show wordValue;
import '../../state/providers.dart';
import '../automations/form_parts.dart';
import '../automations/rule_words.dart' show valueText;
import '../design/design.dart';
import '../../api/screen_calls.dart';

/// The values automations set for each other ($Away, $Mood), so one stuck
/// at the wrong value can be seen, changed or cleared.
class VariablesPage extends ConsumerStatefulWidget {
  const VariablesPage({super.key});

  @override
  ConsumerState<VariablesPage> createState() => _VariablesPageState();
}

/// Variables OmniFlow itself keeps up to date: shown, not edited.
bool isSystemVariable(String name) =>
    name.startsWith('Zone_') ||
    name == 'WifiSsid' ||
    name == 'HomeWifiConnected';

/// Bookkeeping of the engine's own (a keep step's state), never shown.
bool isInternalVariable(String name) =>
    name.startsWith('_') || name.startsWith('keep_');

/// How a variable comes to be, under an empty list. The header's Add is
/// named in words, so no lone + ends up on a line of its own.
const _howToAdd =
    'Tap the plus at the top to add one, or a rule\'s "Set a variable" '
    'step makes one.';

class _VariablesPageState extends ConsumerState<VariablesPage> {
  Map<String, Object?>? _vars;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ref.read(engineClientProvider).call(VarCalls.list);
    if (!mounted) return;
    setState(() {
      if (r['ok'] == true && r['variables'] is Map) {
        _vars = Map<String, Object?>.from(r['variables'] as Map);
        _error = null;
      } else {
        _error = errorMessage(r);
      }
    });
  }

  Future<void> _edit({String? name, Object? value}) async {
    final nameField = TextEditingController(text: name ?? '');
    final valueField = TextEditingController(
      text: value == null ? '' : valueText(value),
    );
    final valid = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');
    final picked = await showFormSheet<(String, Object?)>(
      context,
      owns: [nameField, valueField],
      title: name ?? 'New variable',
      subtitle: 'Automations read it with \$${name ?? 'Name'}.',
      result: () {
        final n = nameField.text.trim();
        if (!valid.hasMatch(n) || isSystemVariable(n)) return null;
        if (valueField.text.trim().isEmpty) return null;
        return (n, wordValue(valueField.text));
      },
      whyNot: () {
        final n = nameField.text.trim();
        if (n.isNotEmpty && !valid.hasMatch(n)) {
          return 'A name starts with a letter, then letters, numbers and _';
        }
        if (isSystemVariable(n)) return 'OmniFlow sets that one itself';
        return null;
      },
      build: (context, setState) => [
        if (name == null)
          LabelledField(
            key: const ValueKey('var-edit-name'),
            label: 'Name',
            hint: 'Away',
            controller: nameField,
            onChanged: (_) => setState(() {}),
            autofocus: true,
          ),
        LabelledField(
          key: const ValueKey('var-edit-value'),
          label: 'Value',
          hint: 'on, off, 30 or a word',
          controller: valueField,
          onChanged: (_) => setState(() {}),
          autofocus: name != null,
        ),
      ],
    );
    if (picked == null || !mounted) return;
    final r = await ref.read(engineClientProvider).call(VarCalls.set, {
      'name': picked.$1,
      'value': picked.$2,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      showMessage(errorMessage(r));
      return;
    }
    await _load();
  }

  Future<void> _remove(String name) async {
    final ok = await confirm(
      context,
      title: 'Clear \$$name?',
      body: 'Automations that check it see no value until one sets it again.',
      action: 'Clear',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final r = await ref.read(engineClientProvider).call(VarCalls.remove, {
      'name': name,
    });
    if (!mounted) return;
    if (r['ok'] != true) showMessage(errorMessage(r));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final vars = _vars;
    final names = [
      for (final n in vars?.keys ?? const <String>[])
        if (!isInternalVariable(n)) n,
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final own = [
      for (final n in names)
        if (!isSystemVariable(n)) n,
    ];
    final system = [
      for (final n in names)
        if (isSystemVariable(n)) n,
    ];
    return ListPage(
      title: 'Variables',
      actions: [
        if (vars != null)
          OmniIconAction(
            key: const ValueKey('var-add'),
            icon: OmniIcons.add,
            label: 'Add a variable',
            onPressed: () => _edit(),
          ),
      ],
      state: OmniLoad.flags(
        loading: vars == null,
        error: _error,
        onRetry: _load,
      ),
      children: (context) => [
        Text(
          'Values automations set for each other to check. Change one '
          'that is stuck, or clear it.',
          style: OmniText.captionOf(context),
        ),
        const SizedBox(height: OmniSpace.md),
        if (own.isEmpty && system.isEmpty)
          const OmniEmptyState(
            key: ValueKey('vars-empty'),
            icon: OmniIcons.level,
            title: 'No variables yet',
            message: _howToAdd,
          )
        else if (own.isEmpty)
          const OmniEmptyState(
            key: ValueKey('vars-empty'),
            icon: OmniIcons.level,
            title: 'None of your own yet',
            message: _howToAdd,
            compact: true,
          ),
        for (final n in own)
          OmniListRow(
            key: ValueKey('var-$n'),
            icon: OmniIcons.level,
            title: '\$$n',
            subtitle: valueText(vars![n]),
            onTap: () => _edit(name: n, value: vars[n]),
            trailing: OmniIconAction(
              key: ValueKey('var-clear-$n'),
              icon: OmniIcons.delete,
              label: 'Clear \$$n',
              onPressed: () => _remove(n),
            ),
          ),
        if (system.isNotEmpty) ...[
          const OmniSectionHeader('Set by OmniFlow'),
          for (final n in system)
            OmniListRow(
              key: ValueKey('var-$n'),
              icon: OmniIcons.info,
              title: '\$$n',
              subtitle: valueText(vars![n]),
            ),
        ],
      ],
    );
  }
}
