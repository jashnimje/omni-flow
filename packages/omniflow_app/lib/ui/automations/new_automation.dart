import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../rules/things.dart';
import '../../state/providers.dart';
import '../design/automation_look.dart';
import '../design/design.dart';
import '../onboarding/home_setup.dart' show SetupStep, openHomeSetup;
import 'automations_state.dart';
import 'form_parts.dart';
import 'link_sheet.dart';
import 'rule_editor.dart';
import 'rule_words.dart';
import 'scenes.dart' show openSceneEditor;
import 'type_it_page.dart' show openTypeIt;

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
    case _NewTypeIt():
      await openTypeIt(tabContext);
    case _NewRule():
      await openRuleEditor(tabContext);
    case _NewLink():
      await showOmniSheet<void>(tabContext, builder: (_) => const LinkSheet());
    case _NewScene():
      await openSceneEditor(tabContext);
    case _NewTemplate(:final template):
      await Navigator.of(tabContext).push<void>(
        MaterialPageRoute(builder: (_) => TemplatePage(template: template)),
      );
  }
}

sealed class _NewChoice {
  const _NewChoice();
}

class _NewTypeIt extends _NewChoice {
  const _NewTypeIt();
}

class _NewRule extends _NewChoice {
  const _NewRule();
}

class _NewLink extends _NewChoice {
  const _NewLink();
}

class _NewScene extends _NewChoice {
  const _NewScene();
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
    return SheetTemplate(
      title: 'New automation',
      subtitle: 'Each runs on the phone, even with the screen off.',
      children: (context) => [
        // Saying it is the easiest start, so it comes first.
        OmniListRow(
          key: const ValueKey('type-it'),
          icon: OmniIcons.edit,
          title: 'Type what you want',
          subtitle: 'Say it in a sentence, then check it in the editor',
          subtitleLines: 2,
          chevron: true,
          onTap: () => pick(const _NewTypeIt()),
        ),
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
        OmniListRow(
          key: const ValueKey('new-scene'),
          icon: OmniIcons.scene,
          title: 'A scene',
          subtitle: 'Several things set at once, run with one tap',
          chevron: true,
          onTap: () => pick(const _NewScene()),
        ),
        // A caption, so it does not stack on the first group's heading.
        Padding(
          padding: const EdgeInsets.only(top: OmniSpace.md),
          child: Text(
            'Or start from a template',
            style: OmniText.captionOf(context),
          ),
        ),
        switch (templates) {
          AsyncData(:final value) when value.ok => TemplateGallery(
            templates: value.value!,
            onPick: (t) => pick(_NewTemplate(t)),
          ),
          AsyncData() || AsyncError() => OmniBanner.error(
            'The templates did not load.',
            key: const ValueKey('templates-error'),
            actionLabel: 'Try again',
            onAction: () => ref.invalidate(_templatesProvider),
          ),
          _ => const OmniListSkeleton(rows: 3, label: 'Loading templates'),
        },
      ],
    );
  }
}

/// The templates as illustrated cards, grouped under the contract's
/// categories in their order, then any without a known one under More.
class TemplateGallery extends StatelessWidget {
  const TemplateGallery({
    super.key,
    required this.templates,
    required this.onPick,
  });

  final List<AutomationTemplate> templates;
  final ValueChanged<AutomationTemplate> onPick;

  /// The groups in gallery order, each with its templates in list order.
  static List<(String, List<AutomationTemplate>)> groupsOf(
    List<AutomationTemplate> templates,
  ) {
    const known = AutomationTemplate.categories;
    return [
      for (final c in [...known, 'More'])
        if ([
              for (final t in templates)
                if (known.contains(t.category) ? t.category == c : c == 'More')
                  t,
            ]
            case final group when group.isNotEmpty)
          (c, group),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final groups = groupsOf(templates);
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 340 ? 2 : 1;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (category, group) in groups) ...[
              // One group alone needs no header over it.
              if (groups.length > 1 || category != 'More')
                OmniSectionHeader(category),
              for (var i = 0; i < group.length; i += columns)
                Padding(
                  padding: const EdgeInsets.only(bottom: OmniSpace.md),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var c = 0; c < columns; c++) ...[
                          if (c > 0) const SizedBox(width: OmniSpace.md),
                          Expanded(
                            child: i + c < group.length
                                ? _TemplateCard(
                                    template: group[i + c],
                                    onTap: () => onPick(group[i + c]),
                                  )
                                : const SizedBox(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// One template: its coloured badge, name and what it does.
class _TemplateCard extends StatelessWidget {
  const _TemplateCard({required this.template, required this.onTap});

  final AutomationTemplate template;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = template;
    final radius = BorderRadius.circular(OmniRadii.card);
    final palette = OmniPalette.of(context);
    return Semantics(
      container: true,
      button: true,
      label: [t.name, if (t.description.isNotEmpty) t.description].join('. '),
      hint: 'Fill it in with your devices',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        key: ValueKey('template-${t.id}'),
        color: AutomationLook.tintOf(t.color, palette),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: AutomationLook.lineOf(t.color, palette)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(OmniSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AutomationBadge(
                  icon: AutomationLook.iconOf(
                    t.icon,
                    fallback: AutomationIcons.template,
                  ),
                  color: t.color,
                  size: 44,
                ),
                const SizedBox(height: OmniSpace.md),
                Text(t.name, style: OmniText.bodyStrong),
                if (t.description.isNotEmpty) ...[
                  const SizedBox(height: OmniSpace.xs),
                  Text(t.description, style: OmniText.captionOf(context)),
                ],
              ],
            ),
          ),
        ),
      ),
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
    return FormPage(
      title: widget.template.name,
      commitLabel: 'Continue',
      commitKey: const ValueKey('template-continue'),
      onCommit: _busy || !_ready ? null : _continue,
      missing: _busy ? null : 'Fill in every part first.',
      banners: [
        if (_error != null)
          OmniBanner.error(_error!, key: const ValueKey('template-error')),
      ],
      children: (context) => [
        Padding(
          padding: const EdgeInsets.only(bottom: OmniSpace.sm),
          child: Row(
            children: [
              AutomationBadge(
                icon: AutomationLook.iconOf(
                  widget.template.icon,
                  fallback: AutomationIcons.template,
                ),
                color: widget.template.color,
              ),
              const SizedBox(width: OmniSpace.md),
              Expanded(
                child: Text(
                  widget.template.description,
                  style: OmniText.captionOf(context),
                ),
              ),
            ],
          ),
        ),
        for (final p in _placeholders) ..._field(p, words),
      ],
    );
  }

  List<Widget> _field(TemplatePlaceholder p, RuleWords words) {
    void set(Object? v) => setState(() => _values[p.key] = v);
    final value = _values[p.key];
    final choices = _choicesFor(
      p.kind,
      words.things,
      wakeAndSleep: !widget.template.toggles(p.key),
    );
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
        OmniBanner.warning(
          switch (p.kind) {
            'person' =>
              'This needs to know who you are and when you are home. Set up '
                  'your home first, then come back.',
            'tag' => 'This needs an NFC tag. Add one with Add first.',
            _ => 'Nothing you have added can do this yet.',
          },
          key: ValueKey('tpl-missing-${p.key}'),
          actionLabel: p.kind == 'person' ? 'Set up home' : null,
          onAction: p.kind == 'person'
              ? () => openHomeSetup(context, start: SetupStep.you)
              : null,
        ),
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
    List<Thing> things, {
    bool wakeAndSleep = true,
  }) => switch (kind) {
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
        if (wakeAndSleep && t.toggles.isEmpty && t.wakesAndSleeps)
          (value: '${t.id}.power', title: t.name, icon: t.icon),
    ],
    _ => const [],
  };
}
