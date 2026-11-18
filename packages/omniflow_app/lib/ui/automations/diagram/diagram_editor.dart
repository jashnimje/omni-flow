import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api/diagram_calls.dart';
import '../../../api/engine_calls.dart' show Json;
import '../../../rules/rule_spec.dart';
import '../../../state/providers.dart'
    show engineClientProvider, messengerKey, showMessage;
import '../../design/design.dart';
import '../look_picker.dart' show automationColor;
import '../pickers.dart';
import '../rule_blocks.dart';
import '../rule_words.dart' show RuleWords;
import 'diagram_view.dart';
import 'rule_paths.dart';

/// How long the diagram waits after an edit before it asks the engine
/// for the new one, so a run of quick edits asks once.
const diagramRefetchDelay = Duration(milliseconds: 300);

/// The rule in [draft] as a diagram that edits it: a tap opens the same
/// picker or page the sentence row opens, a "+" adds a step or a check
/// on its line, and a long press moves, copies or removes. Every edit
/// changes [draft], so the sentence view shows it too, and the diagram
/// is asked for again from the engine with the rule as it now stands.
class DiagramEditor extends ConsumerStatefulWidget {
  const DiagramEditor({super.key, required this.draft, this.id});

  final RuleDraft draft;

  /// The stored rule's id, or null for a new one.
  final String? id;

  @override
  ConsumerState<DiagramEditor> createState() => _DiagramEditorState();
}

class _DiagramEditorState extends ConsumerState<DiagramEditor> {
  Diagram? _diagram;
  var _loading = true;

  /// An edit is not in the diagram on screen yet, so its paths may point
  /// at the wrong part: taps wait for the new one.
  var _stale = false;

  /// The last ask for the diagram of the edited rule failed. The old one
  /// stays on screen but locked, with Retry, as its paths are out of date.
  var _failed = false;
  Timer? _debounce;

  /// Bumped by every ask and every edit: an answer counts only when
  /// nothing happened since it was asked for, so a diagram of the rule
  /// before an edit never unlocks the editor.
  var _asked = 0;

  RuleDraft get _draft => widget.draft;

  @override
  void initState() {
    super.initState();
    _draft.addListener(_onEdit);
    _fetch();
  }

  @override
  void didUpdateWidget(DiagramEditor old) {
    super.didUpdateWidget(old);
    if (old.draft != widget.draft) {
      old.draft.removeListener(_onEdit);
      widget.draft.addListener(_onEdit);
      _fetch();
    }
  }

  @override
  void dispose() {
    _draft.removeListener(_onEdit);
    _debounce?.cancel();
    super.dispose();
  }

  void _onEdit() {
    _debounce?.cancel();
    _asked++;
    if (!_stale || _failed) {
      setState(() {
        _stale = true;
        _failed = false;
      });
    }
    _debounce = Timer(diagramRefetchDelay, _fetch);
  }

  Future<void> _fetch() async {
    final asked = ++_asked;
    final diagram = await DiagramCalls.fetch(
      ref.read(engineClientProvider),
      DiagramCalls.specArgs(_draft.spec.toJson(), id: widget.id),
    );
    if (!mounted || asked != _asked) return;
    setState(() {
      _loading = false;
      if (diagram != null) {
        _diagram = diagram;
        _stale = false;
        _failed = false;
      } else if (_diagram != null) {
        // A failed ask keeps the last diagram rather than blanking it, but
        // locked: its paths are of the rule before the edit.
        _failed = _stale;
      }
    });
  }

  void _retry() {
    setState(() => _failed = false);
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final diagram = _diagram;
    if (diagram == null) {
      // The canvas is edge to edge, so the states pad themselves.
      return ListView(
        padding: OmniSpace.screenPadding,
        children: [
          if (_loading)
            const OmniPageSkeleton(label: 'Loading the diagram')
          else
            OmniErrorState(
              key: const ValueKey('diagram-unavailable'),
              title: 'The diagram did not load',
              message: 'Switch to Sentence to see and change this automation.',
              onRetry: () {
                setState(() => _loading = true);
                _fetch();
              },
            ),
        ],
      );
    }
    final editable = diagram.editable && !_stale;
    final spec = _draft.spec;
    final words = _draft.words;
    return Column(
      key: const ValueKey('diagram-editor'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_failed)
          Padding(
            padding: OmniSpace.screenPadding,
            child: OmniBanner.error(
              'The diagram did not refresh, so it cannot be changed until it '
              'does. Your edits are kept.',
              key: const ValueKey('diagram-refresh-failed'),
              actionLabel: 'Retry',
              onAction: _retry,
            ),
          )
        else
          SizedBox(
            height: 2,
            child: _stale
                ? const OmniProgressBar(
                    height: 2,
                    semanticLabel: 'Updating the diagram',
                  )
                : null,
          ),
        if (!diagram.editable)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpace.screen,
              OmniSpace.sm,
              OmniSpace.screen,
              0,
            ),
            child: Text(
              'This automation came as a graph, so it is shown but not '
              'changed here.',
              style: OmniText.captionOf(context),
            ),
          ),
        Expanded(
          child: DiagramViewer(
            diagram: diagram,
            handlers: DiagramHandlers(
              color: automationColor(spec.color),
              iconOf: (n) => _iconOf(n, spec, words),
              errorOf: (n) => _errorOf(n, diagram),
              onTap: editable ? _open : null,
              onLongPress: editable ? _menu : null,
              actionsOf: editable ? _actions : null,
              onPlus: editable ? _add : null,
            ),
          ),
        ),
      ],
    );
  }

  /// The engine's issue at [n]'s place: from the last save or test run,
  /// else from the diagram of the unsaved rule.
  String? _errorOf(DiagramNode n, Diagram diagram) {
    final p = n.path;
    if (p == null) return null;
    final at = editorPath(p);
    final own = n.kind == NodeKind.group
        ? _draft.groupErrorAt(at)
        : _draft.errorAt(at);
    if (own != null) return own;
    for (final i in diagram.issues) {
      final path = i.path.startsWith('/') ? editorPath(i.path) : i.path;
      if (path == at) return i.message;
    }
    return null;
  }

  /// A tap: the part's picker or page. An If with one condition opens that
  /// condition, as its diamond is the check.
  void _open(DiagramNode n) {
    final p = n.path;
    if (p == null) return;
    final checks = n.checks;
    openRulePart(context, _draft, checks.length == 1 ? checks.single.path : p);
  }

  /// A "+": what it adds, asking first when the line can take a step or a
  /// check.
  Future<void> _add(DiagramEdge e) async {
    final first = e.insert;
    if (first == null) return;
    var pick = first;
    if (e.alsoInsert case final also?) {
      final chosen = await showPickerSheet<DiagramInsert>(
        context,
        title: 'Add here',
        sections: [
          PickerSection([
            for (final insert in [first, also])
              PickerItem(
                key: ValueKey('diagram-add-${insert.as}'),
                value: insert,
                icon: insert.as == DiagramInsert.check
                    ? OmniIcons.branch
                    : OmniIcons.add,
                title: insert.as == DiagramInsert.check
                    ? 'A check'
                    : insert.as == DiagramInsert.trigger
                    ? 'A WHEN'
                    : 'A step',
              ),
          ]),
        ],
      );
      if (chosen == null) return;
      pick = chosen;
    }
    if (!mounted) return;
    await insertRulePart(context, _draft, pick);
  }

  static IconData? _iconOf(DiagramNode n, RuleSpec spec, RuleWords words) {
    final path = n.path;
    if (path == null) return null;
    return switch (partAt(spec, path)) {
      final RuleTrigger t => words.triggerIcon(t),
      final RuleCondition c => words.conditionIcon(c),
      final RuleStep s => words.stepIcon(s),
      _ => null,
    };
  }

  Map<CustomSemanticsAction, VoidCallback> _actions(DiagramNode n) {
    final place = _placeOf(n);
    if (place == null) return const {};
    return {
      for (final (label, action) in _choices(place))
        CustomSemanticsAction(label: label): () => action(),
    };
  }

  RulePlace? _placeOf(DiagramNode n) {
    final path = n.path;
    if (path == null) return null;
    final place = placeAt(_draft.spec, path);
    return place?.item == null ? null : place;
  }

  List<(String, void Function())> _choices(RulePlace place) => [
    if (place.index > 0) ('Move up', () => moveRulePart(_draft, place, -1)),
    if (place.index < place.list.length - 1)
      ('Move down', () => moveRulePart(_draft, place, 1)),
    ('Copy', () => copyRulePart(_draft, place)),
    ('Remove', () => removeRulePart(_draft, place)),
  ];

  Future<void> _menu(DiagramNode n) async {
    final place = _placeOf(n);
    if (place == null) return;
    final choice = await showPickerSheet<void Function()>(
      context,
      title: n.words,
      sections: [
        PickerSection([
          for (final (label, action) in _choices(place))
            PickerItem(
              key: ValueKey(
                'diagram-${label.toLowerCase().replaceAll(' ', '-')}',
              ),
              value: action,
              icon: switch (label) {
                'Move up' => OmniIcons.upload,
                'Move down' => OmniIcons.download,
                'Copy' => OmniIcons.add,
                _ => OmniIcons.delete,
              },
              title: label,
            ),
        ]),
      ],
    );
    choice?.call();
  }
}

/// Opens the picker, form or page for the part of [draft] at [pointer],
/// the same one its sentence row opens, and puts back what it gives.
Future<void> openRulePart(
  BuildContext context,
  RuleDraft draft,
  String pointer,
) async {
  final spec = draft.spec;
  final words = draft.words;
  final place = placeAt(spec, pointer);
  final at = editorPath(pointer);
  void put(Object? edited) {
    if (edited == null || place == null) return;
    place.list[place.index] = edited;
    draft.changed();
  }

  switch (place?.item ?? partAt(spec, pointer)) {
    case ManualTrigger():
      return;
    case final RuleTrigger t:
      put(await editTrigger(context, words, t));
    case UnknownCondition():
      return;
    case final RuleCondition c:
      put(await editCondition(context, words, c));
    case final KeepStep s:
      put(await openKeepPage(context, draft, s, at));
    case final RuleStep s when isGroupStep(s):
      await openGroupPage(context, draft, s, at);
    case UnknownStep():
      return;
    case final RuleStep s:
      put(
        await editStep(
          context,
          words,
          s,
          automations: draft.automations,
          tokens: draft.tokensAt(context, at),
        ),
      );
    case List():
      // A list of conditions as a whole (an If's check, a keep's while):
      // the page of the step that holds it.
      switch (ownerStepOf(spec, '$pointer/0')) {
        case (final KeepStep step, final stepAt):
          final kept = await openKeepPage(
            context,
            draft,
            step,
            editorPath(stepAt),
          );
          final owner = placeAt(spec, stepAt);
          if (kept == null || owner == null) return;
          owner.list[owner.index] = kept;
          draft.changed();
        case (final step, final stepAt) when isGroupStep(step):
          await openGroupPage(context, draft, step, editorPath(stepAt));
        default:
          return;
      }
  }
}

/// Adds a step, check or trigger where [insert] points, picked from the
/// same library and pickers the sentence view's Add buttons open. A new
/// group opens its page, as it does from the sentence view.
Future<void> insertRulePart(
  BuildContext context,
  RuleDraft draft,
  DiagramInsert insert,
) async {
  final spec = draft.spec;
  final place = placeAt(spec, insert.path);
  if (place == null) return;
  final at = editorPath(insert.path);
  final topThen = identical(place.list, spec.then);
  Object? made;
  if (identical(place.list, spec.when) || insert.as == DiagramInsert.trigger) {
    made = await pickTrigger(context, draft.words);
  } else if (insert.as == DiagramInsert.check) {
    made = await pickCondition(context, draft.words);
  } else {
    var step = await pickStep(
      context,
      draft.words,
      automations: draft.automations,
      allowKeep: topThen,
      rule: spec,
      tokens: draft.tokensAt(context, at),
    );
    if (step is KeepStep && context.mounted) {
      step = await openKeepPage(context, draft, step, null);
    }
    made = step;
  }
  if (made == null || !context.mounted) return;
  place.list.insert(place.index.clamp(0, place.list.length), made);
  if (topThen) keepsLast(spec.then);
  draft.changed();
  if (made is RuleStep && isGroupStep(made)) {
    final i = place.list.indexOf(made);
    final segments = pointerSegments(insert.path);
    final pointer =
        '/${[...segments.take(segments.length - 1), '$i'].join('/')}';
    await openGroupPage(context, draft, made, editorPath(pointer));
  }
}

/// Moves the part at [place] [by] places in its list.
void moveRulePart(RuleDraft draft, RulePlace place, int by) {
  final to = place.index + by;
  if (to < 0 || to >= place.list.length) return;
  place.list.insert(to, place.list.removeAt(place.index));
  if (identical(place.list, draft.spec.then)) keepsLast(draft.spec.then);
  draft.changed();
}

/// Puts a copy of the part at [place] right after it.
void copyRulePart(RuleDraft draft, RulePlace place) {
  final item = place.item;
  Json copy(Json json) =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(json)) as Map);
  final Object? made = switch (item) {
    final RuleTrigger t => RuleTrigger.fromJson(copy(t.toJson())),
    final RuleCondition c => RuleCondition.fromJson(copy(c.toJson())),
    final RuleStep s => RuleStep.fromJson(copy(s.toJson())),
    _ => null,
  };
  if (made == null) return;
  place.list.insert(place.index + 1, made);
  if (identical(place.list, draft.spec.then)) keepsLast(draft.spec.then);
  draft.changed();
}

/// The draft an Undo the diagram offered would change, while its editor
/// is open and nothing else changed it.
RuleDraft? _undoDraft;

/// Stops watching the draft for the edit that takes the Undo away.
VoidCallback? _stopWatchingUndo;

void _forgetUndo() {
  _stopWatchingUndo?.call();
  _stopWatchingUndo = null;
  _undoDraft = null;
}

/// Removes the part at [place] and offers to put it back, as the sentence
/// view does. The Undo puts it back at the index it had, so any other edit
/// before it is tapped takes the Undo away: the index may point elsewhere
/// by then.
void removeRulePart(RuleDraft draft, RulePlace place) {
  final list = place.list;
  final i = place.index;
  final removed = list.removeAt(i);
  draft.changed();
  _forgetUndo();
  _undoDraft = draft;
  final what = switch (removed) {
    RuleTrigger() => 'WHEN',
    RuleCondition() => 'Condition',
    _ => 'Step',
  };
  // Shown at once rather than queued, so it is the current snackbar until
  // it closes and an edit can take it away.
  messengerKey.currentState
    ?..clearSnackBars()
    ..removeCurrentSnackBar();
  final shown = showMessage(
    '$what removed',
    action: 'Undo',
    onAction: () {
      if (!identical(_undoDraft, draft)) return;
      _forgetUndo();
      list.insert(i.clamp(0, list.length), removed);
      if (identical(list, draft.spec.then)) keepsLast(draft.spec.then);
      draft.changed();
    },
  );
  var up = shown != null;
  unawaited(shown?.closed.then((_) => up = false));
  void edited() {
    _forgetUndo();
    if (up) shown?.close();
  }

  draft.addListener(edited);
  _stopWatchingUndo = () => draft.removeListener(edited);
}

/// Called when [draft]'s editor closes: an Undo the diagram still shows
/// for it is taken away.
void dropDiagramUndoFor(RuleDraft draft) {
  if (!identical(_undoDraft, draft)) return;
  _forgetUndo();
  messengerKey.currentState?.hideCurrentSnackBar();
}
