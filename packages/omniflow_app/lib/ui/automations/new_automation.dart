import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../rules/things.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'automations_state.dart';
import 'form_parts.dart';
import 'link_sheet.dart';
import 'rule_editor.dart';
import 'rule_words.dart';

/// The New button of Automations: a rule, a quick link, or a template.
/// [tabContext] is inside the Automations tab, so what it opens keeps the
/// tab bar.
Future<void> openNewAutomation(BuildContext tabContext) async {
  final choice = await showOmniSheet<_NewChoice>(
    tabContext,
    builder: (_) => const _NewSheet(),
  );
  if (choice == null || !tabContext.mounted) return;
  switch (choice) {
    case _NewRule():
      await openRuleEditor(tabContext);
    case _NewLink():
      await showOmniSheet<void>(tabContext, builder: (_) => const LinkSheet());
    case _NewTemplate(:final template):
      await Navigator.of(tabContext).push<void>(
        MaterialPageRoute(builder: (_) => TemplatePage(template: template)),
      );
  }
}

sealed class _NewChoice {
  const _NewChoice();
}

class _NewRule extends _NewChoice {
  const _NewRule();
}

class _NewLink extends _NewChoice {
  const _NewLink();
}

class _NewTemplate extends _NewChoice {
  const _NewTemplate(this.template);

  final AutomationTemplate template;
}

final _templatesProvider =
    FutureProvider.autoDispose<Reply<List<AutomationTemplate>>>(
      (ref) => ref.watch(engineApiProvider).templates(),
    );

class _NewSheet extends ConsumerWidget {
  const _NewSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(_templatesProvider);
    void pick(_NewChoice c) => Navigator.of(context).pop(c);
    return OmniSheet(
      title: 'New automation',
      subtitle: 'Each runs on the phone, even with the screen off.',
      children: [
        OmniListRow(
          key: const ValueKey('new-blank-rule'),
          icon: AutomationIcons.rule,
          title: 'A rule',
          subtitle: 'When something happens, only if it fits, do these steps',
          subtitleLines: 2,
          chevron: true,
          onTap: () => pick(const _NewRule()),
        ),
        OmniListRow(
          key: const ValueKey('new-link'),
          icon: AutomationIcons.link,
          title: 'A quick link',
          subtitle: 'This to that: a button toggles a light',
          chevron: true,
          onTap: () => pick(const _NewLink()),
        ),
        const OmniSectionHeader('Start from a template'),
        switch (templates) {
          AsyncData(:final value) when value.ok => Column(
            children: [
              for (final t in value.value!)
                OmniListRow(
                  key: ValueKey('template-${t.id}'),
                  icon: AutomationIcons.template,
                  title: t.name,
                  subtitle: t.description,
                  subtitleLines: 2,
                  chevron: true,
                  onTap: () => pick(_NewTemplate(t)),
                ),
            ],
          ),
          AsyncData() || AsyncError() => OmniBanner.error(
            'The templates did not load.',
            key: const ValueKey('templates-error'),
            actionLabel: 'Try again',
            onAction: () => ref.invalidate(_templatesProvider),
          ),
          _ => const Padding(
            padding: EdgeInsets.all(OmniSpace.lg),
            child: Center(child: CircularProgressIndicator()),
          ),
        },
      ],
    );
  }
}

/// Fills a template's placeholders with the user's things, then opens the
/// filled rule in the editor to check and save.
class TemplatePage extends ConsumerStatefulWidget {
  const TemplatePage({super.key, required this.template});

  final AutomationTemplate template;

  @override
  ConsumerState<TemplatePage> createState() => _TemplatePageState();
}

class _TemplatePageState extends ConsumerState<TemplatePage> {
  late final Json _values = {
    for (final p in widget.template.placeholders)
      if (p.fallback != null) p.key: p.fallback,
  };
  var _busy = false;
  String? _error;

  List<TemplatePlaceholder> get _placeholders => widget.template.placeholders;

  bool get _ready => _placeholders.every((p) {
    final v = _values[p.key];
    return v != null && (v is! List || v.isNotEmpty);
  });

  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final reply = await ref
        .read(engineApiProvider)
        .fillTemplate(widget.template.id, _values);
    if (!mounted) return;
    setState(() => _busy = false);
    if (reply.failure case final f?) {
      setState(() => _error = f.message);
      return;
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => RuleEditorPage(initial: reply.value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final words = RuleWords(ref.watch(ruleThingsProvider));
    if (_placeholders.any((p) => p.kind == 'person') &&
        words.me != null &&
        _values['person'] == null) {
      _values['person'] = words.me;
    }
    return OmniPage(
      title: widget.template.name,
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.sm),
            child: Text(widget.template.description, style: OmniText.caption),
          ),
          if (_error != null)
            OmniBanner.error(_error!, key: const ValueKey('template-error')),
          for (final p in _placeholders) ..._field(p, words),
          const SizedBox(height: OmniSpace.xl),
        ],
      ),
      bottom: OmniButton(
        key: const ValueKey('template-continue'),
        label: 'Continue',
        onPressed: _busy || !_ready ? null : _continue,
      ),
    );
  }

  List<Widget> _field(TemplatePlaceholder p, RuleWords words) {
    void set(Object? v) => setState(() => _values[p.key] = v);
    final value = _values[p.key];
    final choices = _choicesFor(p.kind, words.things);
    final header = OmniSectionHeader(p.label);
    switch (p.kind) {
      case 'time':
        return [
          header,
          TimeRow(
            key: ValueKey('tpl-${p.key}'),
            label: p.label,
            value: '${value ?? '23:00'}',
            onChanged: set,
          ),
        ];
      case 'duration':
        return [
          header,
          DurationInput(
            key: ValueKey('tpl-${p.key}'),
            label: p.label,
            ms: (value as num?)?.toInt() ?? 120000,
            onChanged: (ms) => set(ms < 1000 ? null : ms),
          ),
        ];
    }
    if (choices.isEmpty) {
      return [
        header,
        OmniBanner.warning(switch (p.kind) {
          'person' => 'This needs a person. Add a place and a person first.',
          'tag' => 'This needs an NFC tag. Add one with Add first.',
          _ => 'Nothing you have added can do this yet.',
        }, key: ValueKey('tpl-missing-${p.key}')),
      ];
    }
    final many = p.kind == 'toggles';
    final picked = many ? {...(value as List? ?? const [])} : {value};
    return [
      header,
      for (final c in choices)
        ChoiceRow(
          key: ValueKey('tpl-${p.key}-${c.value}'),
          title: c.title,
          icon: c.icon,
          selected: picked.contains(c.value),
          onTap: () => many
              ? set([
                  for (final o in choices)
                    if (o.value == c.value
                        ? !picked.contains(c.value)
                        : picked.contains(o.value))
                      o.value,
                ])
              : set(c.value),
        ),
    ];
  }

  /// What a placeholder of [kind] can be: people, tags, readings
  /// (`thing.key`) or switches (`thing.action`).
  static List<({String value, String title, IconData icon})> _choicesFor(
    String kind,
    List<Thing> things,
  ) => switch (kind) {
    'person' => [
      for (final t in things)
        if (t.isPerson) (value: t.id, title: t.name, icon: OmniIcons.person),
    ],
    'tag' => [
      for (final t in things)
        if (t.isTag) (value: t.id, title: t.name, icon: OmniIcons.tag),
    ],
    'sensor' => [
      for (final t in things)
        if (!t.isPerson && !t.isTag && !t.isPlace)
          for (final k in t.stateKeys)
            if (t.isOnOff(k.key))
              (
                value: '${t.id}.${k.key}',
                title: '${t.name} · ${k.label.toLowerCase()}',
                icon: t.icon,
              ),
    ],
    'toggle' || 'toggles' => [
      for (final t in things)
        for (final c in t.toggles)
          (
            value: '${t.id}.${c['id']}',
            title: t.toggles.length > 1
                ? '${t.name} · ${'${c['label']}'.toLowerCase()}'
                : t.name,
            icon: t.icon,
          ),
      for (final t in things)
        if (t.toggles.isEmpty && t.wakesAndSleeps)
          (value: '${t.id}.power', title: t.name, icon: t.icon),
    ],
    _ => const [],
  };
}
