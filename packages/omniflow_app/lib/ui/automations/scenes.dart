import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/engine_calls.dart';
import '../../rules/rule_spec.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'automations_state.dart';
import 'pickers.dart';
import 'review_page.dart';
import 'rule_words.dart';

/// Scenes: named sets of device actions run together (Settings, Scenes and
/// Home, Scenes, Edit). They are automations with a manual trigger, so
/// they share validation, approval and the run log.

/// The icons a scene can wear, by the Material Symbols name stored with it.
const sceneIcons = <String, IconData>{
  'movie': Symbols.movie_rounded,
  'bedtime': Symbols.bedtime_rounded,
  'home': Symbols.home_rounded,
  'bed': Symbols.bed_rounded,
  'power_settings_new': Symbols.power_settings_new_rounded,
  'lightbulb': Symbols.lightbulb_rounded,
  'wb_sunny': Symbols.wb_sunny_rounded,
  'coffee': Symbols.coffee_rounded,
  'music_note': Symbols.music_note_rounded,
  'work': Symbols.work_rounded,
  'celebration': Symbols.celebration_rounded,
  'spa': Symbols.spa_rounded,
};

/// A scene's icon, the scene icon when it names none this app knows.
IconData sceneIconFor(String? name) => sceneIcons[name] ?? OmniIcons.scene;

Future<void> openScenes(BuildContext context) =>
    Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => const ScenesPage()));

/// Opens the scene [id], or a new scene. Saving it is the user's own edit,
/// so a scene waiting for review should open [ReviewPage] instead.
Future<void> openSceneEditor(BuildContext context, {String? id}) =>
    Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => SceneEditorPage(id: id)));

/// Runs a scene and says how it went.
Future<void> runScene(WidgetRef ref, String id, String name) async {
  final reply = await ref.read(engineApiProvider).runScene(id);
  final run = reply.value?.firstOrNull;
  if (run == null) return;
  final failed = run.steps.where((n) => n.error != null).firstOrNull;
  showMessage(
    run.ok
        ? '$name is set'
        : '$name ran, but ${failed?.label ?? 'a step'} failed'
              '${failed?.error == null ? '' : ': ${failed!.error}'}',
  );
}

/// Every scene, each with Run, and New scene.
class ScenesPage extends ConsumerWidget {
  const ScenesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(automationsProvider);
    return OmniPage(
      title: 'Scenes',
      body: switch (async) {
        AsyncData(:final value) => _list(context, ref, [
          for (final a in value)
            if (a.isScene) a,
        ]),
        AsyncError() => ListView(
          children: [
            OmniBanner.error(
              'OmniFlow did not answer, so the scenes cannot show. Try again '
              'in a moment.',
              key: const ValueKey('scenes-offline'),
              actionLabel: 'Try again',
              onAction: () => ref.read(automationsProvider.notifier).retry(),
            ),
          ],
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
      bottom: OmniButton.ghost(
        key: const ValueKey('scene-new'),
        label: 'New scene',
        icon: OmniIcons.add,
        onPressed: () => openSceneEditor(context),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    WidgetRef ref,
    List<AutomationSummary> scenes,
  ) {
    if (scenes.isEmpty) {
      return const OmniEmptyState(
        key: ValueKey('scenes-empty'),
        icon: OmniIcons.scene,
        title: 'No scenes yet',
        message:
            'A scene sets several things at once, like Movie: desk lamp 20%, '
            'hall bulb off.',
      );
    }
    return ListView(
      key: const ValueKey('scenes-list'),
      children: [
        for (final s in scenes)
          OmniListRow(
            key: ValueKey('scene-${s.id}'),
            icon: sceneIconFor(s.icon),
            title: s.name,
            subtitle: s.needsApproval
                ? 'Waiting for your review'
                : s.sentence
                      .where((p) => p.kind != SentenceKind.text)
                      .map((p) => p.text)
                      .join(', '),
            subtitleLines: 2,
            onTap: () => s.needsApproval
                ? Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => ReviewPage(id: s.id)),
                  )
                : openSceneEditor(context, id: s.id),
            trailing: s.needsApproval
                ? const StatusDot(StatusKind.warning)
                : OmniIconAction(
                    key: ValueKey('scene-run-${s.id}'),
                    icon: OmniIcons.play,
                    label: 'Run ${s.name}',
                    color: OmniColors.accent,
                    onPressed: () => runScene(ref, s.id, s.name),
                  ),
          ),
      ],
    );
  }
}

/// A scene: its name and icon, and the device actions it runs together.
class SceneEditorPage extends ConsumerStatefulWidget {
  const SceneEditorPage({super.key, this.id});

  /// Null for a new scene.
  final String? id;

  @override
  ConsumerState<SceneEditorPage> createState() => _SceneEditorPageState();
}

class _SceneEditorPageState extends ConsumerState<SceneEditorPage> {
  final _name = TextEditingController();
  String? _icon;
  List<SceneAction>? _actions;
  ApiFailure? _loadFailure;
  ApiFailure? _saveFailure;
  var _missing = false;
  var _dirty = false;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.id == null) {
      _actions = [];
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadFailure = null);
    final reply = await ref.read(engineApiProvider).scenes();
    if (!mounted) return;
    final scene = reply.value?.where((s) => s.id == widget.id).firstOrNull;
    setState(() {
      _loadFailure = reply.failure;
      _missing = reply.ok && scene == null;
      if (scene != null) {
        _name.text = scene.name;
        _icon = scene.icon;
        _actions = [...scene.actions];
      }
    });
  }

  void _changed() => setState(() {
    _dirty = true;
    _saveFailure = null;
  });

  RuleStep _stepOf(SceneAction a) {
    final (thing, capability) = splitRef(a.action);
    return DoStep(thing, capability, params: {...a.params});
  }

  Future<void> _add(RuleWords words) async {
    final thing = await pickDevice(context, words);
    if (thing == null || !mounted) return;
    final step = await actionForm(context, thing, null, false);
    if (step is! DoStep) return;
    _actions!.add(SceneAction('${step.thing}.${step.capability}', step.params));
    _changed();
  }

  Future<void> _edit(RuleWords words, int i) async {
    final step = _stepOf(_actions![i]) as DoStep;
    final thing = words.thing(step.thing);
    if (thing == null) return;
    final edited = await actionForm(context, thing, step, false);
    if (edited is! DoStep) return;
    _actions![i] = SceneAction(
      '${edited.thing}.${edited.capability}',
      edited.params,
    );
    _changed();
  }

  bool get _ready =>
      !_busy && _name.text.trim().isNotEmpty && (_actions?.isNotEmpty ?? false);

  Future<void> _save() async {
    setState(() => _busy = true);
    final reply = await ref
        .read(engineApiProvider)
        .saveScene(
          Scene(
            id: widget.id,
            name: _name.text.trim(),
            icon: _icon,
            actions: _actions!,
          ),
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (reply.failure case final f?) {
      setState(() => _saveFailure = f);
      return;
    }
    _dirty = false;
    await ref.read(automationsProvider.notifier).refresh();
    showMessage('Saved ${_name.text.trim()}');
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _remove() async {
    final name = _name.text.trim();
    final ok = await confirm(
      context,
      title: 'Remove $name?',
      body: 'The scene is deleted. The devices stay as they are.',
      action: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final reply = await ref.read(engineApiProvider).removeScene(widget.id!);
    if (!reply.ok || !mounted) return;
    _dirty = false;
    await ref.read(automationsProvider.notifier).refresh();
    showMessage('Removed $name');
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _leave() async {
    final ok = await confirm(
      context,
      title: 'Discard changes?',
      body: 'What you changed in this scene is not saved and will be lost.',
      action: 'Discard',
      destructive: true,
    );
    if (!ok || !mounted) return;
    _dirty = false;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final words = RuleWords(ref.watch(ruleThingsProvider));
    final actions = _actions;
    final title = _name.text.trim().isEmpty
        ? (widget.id == null ? 'New scene' : 'Scene')
        : _name.text.trim();
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: OmniPage(
        title: title,
        actions: [
          if (widget.id != null && actions != null) ...[
            OmniIconAction(
              key: const ValueKey('scene-run'),
              icon: OmniIcons.play,
              label: 'Run $title',
              onPressed: _dirty ? null : () => runScene(ref, widget.id!, title),
            ),
            OmniIconAction(
              key: const ValueKey('scene-remove'),
              icon: OmniIcons.delete,
              label: 'Remove $title',
              onPressed: _remove,
            ),
          ],
        ],
        body: switch ((actions, _loadFailure)) {
          (_, final ApiFailure f) => OmniEmptyState(
            key: const ValueKey('scene-load-error'),
            icon: OmniIcons.error,
            title: 'Could not open this scene',
            message: f.message,
            action: OmniButton.ghost(label: 'Try again', onPressed: _load),
          ),
          _ when _missing => const OmniEmptyState(
            key: ValueKey('scene-missing'),
            icon: OmniIcons.info,
            title: 'This scene is gone',
            message: 'It was removed.',
          ),
          (null, _) => const Center(child: CircularProgressIndicator()),
          (final List<SceneAction> list, _) => ListView(
            children: [
              if (_saveFailure case final f?)
                OmniBanner.error(
                  [
                    for (final i in f.issues)
                      if (!i.path.startsWith('actions[')) i.message,
                    if (f.issues.any((i) => i.path.startsWith('actions[')))
                      'Fix the actions marked in red.',
                    if (f.issues.isEmpty) f.message,
                  ].join('\n'),
                  key: const ValueKey('scene-errors'),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextField(
                  key: const ValueKey('scene-name'),
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    hintText: 'Movie',
                    errorText: _saveFailure?.issuesAt('name').firstOrNull,
                  ),
                  onChanged: (_) => _changed(),
                ),
              ),
              const OmniSectionHeader('Icon'),
              Wrap(
                children: [
                  for (final e in sceneIcons.entries)
                    OmniIconAction(
                      key: ValueKey('scene-icon-${e.key}'),
                      icon: e.value,
                      label: 'Icon ${e.key.replaceAll('_', ' ')}',
                      selected: _icon == e.key,
                      onPressed: () {
                        _icon = e.key;
                        _changed();
                      },
                    ),
                ],
              ),
              OmniSectionHeader(
                'What it does',
                trailingText: list.isEmpty ? null : 'all at once',
              ),
              OmniRuleBlock(
                kind: SentenceKind.then,
                heading: 'Then',
                caption: 'together',
                addLabel: 'Add an action',
                onAdd: () => _add(words),
                children: [
                  // Scene actions run together, so their rows have no
                  // drag handle.
                  for (final (i, a) in list.indexed)
                    _ActionRow(
                      key: ValueKey('scene-action-$i'),
                      icon: words.stepIcon(_stepOf(a)),
                      text: words.step(_stepOf(a)),
                      error: _saveFailure?.issuesAt('actions[$i]').firstOrNull,
                      onTap: () => _edit(words, i),
                      onRemove: () {
                        list.removeAt(i);
                        _changed();
                      },
                    ),
                ],
              ),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    'Add what it should set, like the desk lamp at 20% and '
                    'the hall bulb off.',
                    style: OmniText.caption,
                  ),
                ),
              const SizedBox(height: OmniSpace.xl),
            ],
          ),
        },
        bottom: actions == null
            ? null
            : OmniButton(
                key: const ValueKey('scene-save'),
                label: 'Save',
                onPressed: _ready ? _save : null,
              ),
      ),
    );
  }
}

/// One action of a scene: the device and what it is set to, a remove
/// button, and the engine's reason when it refused it.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    super.key,
    required this.icon,
    required this.text,
    required this.onTap,
    required this.onRemove,
    this.error,
  });

  final IconData icon;
  final String text;
  final String? error;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      OmniListRow(
        icon: icon,
        title: text,
        iconForeground: error == null ? null : OmniColors.bad,
        onTap: onTap,
        trailing: OmniIconAction(
          icon: OmniIcons.close,
          label: 'Remove $text',
          onPressed: onRemove,
        ),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(44, 4, 2, 6),
          child: Text(
            error!,
            style: OmniText.caption.copyWith(color: OmniColors.bad),
          ),
        ),
    ],
  );
}
