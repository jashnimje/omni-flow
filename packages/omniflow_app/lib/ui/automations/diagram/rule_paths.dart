import '../../../rules/rule_spec.dart';

/// A place in a rule a diagram node or "+" names: item [index] of [list],
/// which is one of the rule's own lists (`when`, `onlyIf`, `then`) or one
/// inside a step. [index] can be the list's length, the place after its
/// last item.
class RulePlace {
  const RulePlace(this.list, this.index, {this.owner});

  final List<Object?> list;
  final int index;

  /// The step that holds [list], or null for the rule's own lists.
  final RuleStep? owner;

  /// What sits at [index], or null past the end.
  Object? get item => index < list.length ? list[index] : null;
}

/// The segments of a JSON pointer (`/then/2/if/0`), with `~1` and `~0`
/// read back as `/` and `~`.
List<String> pointerSegments(String pointer) => [
  for (final s in pointer.split('/').skip(1))
    s.replaceAll('~1', '/').replaceAll('~0', '~'),
];

/// The rule path the editor names errors by (`then[2].if[0]`) for the
/// JSON pointer [pointer] (`/then/2/if/0`).
String editorPath(String pointer) {
  final out = StringBuffer();
  for (final s in pointerSegments(pointer)) {
    if (int.tryParse(s) != null) {
      out.write('[$s]');
    } else {
      if (out.isNotEmpty) out.write('.');
      out.write(s);
    }
  }
  return out.toString();
}

/// The list a step keeps under [key], as the rule's JSON names it.
List<Object?>? _listOf(Object? owner, String key) => switch ((owner, key)) {
  (IfStep s, 'if') => s.conditions,
  (IfStep s, 'then') => s.then,
  (IfStep s, 'else') => s.otherwise,
  (TogetherStep s, 'together') => s.branches,
  (TryStep s, 'try') => s.steps,
  (TryStep s, 'otherwise') => s.otherwise,
  (WaitForStep s, 'onTimeout') => s.onTimeout,
  (RepeatStep s, 'do') => s.steps,
  (RepeatStep s, 'until') => s.until,
  (ForEachStep s, 'do') => s.steps,
  (KeepStep s, 'while') => s.whileConditions,
  _ => null,
};

/// The keys that only wrap a step's lists in its JSON (`repeat` in
/// `{"repeat": {"do": [...]}}`), skipped on the way down.
const _wrappers = {
  RepeatStep: 'repeat',
  ForEachStep: 'forEach',
  WaitForStep: 'waitFor',
  KeepStep: 'keep',
};

/// The place [pointer] names in [spec], or null when it names nothing
/// there (a raw graph, or a diagram older than the rule).
RulePlace? placeAt(RuleSpec spec, String pointer) {
  final segments = pointerSegments(pointer);
  if (segments.length < 2) return null;
  List<Object?>? list = switch (segments.first) {
    'when' => spec.when,
    'onlyIf' => spec.onlyIf,
    'then' => spec.then,
    _ => null,
  };
  RuleStep? owner;
  var i = 1;
  while (list != null) {
    final index = int.tryParse(segments[i]);
    if (index == null || index < 0 || index > list.length) return null;
    if (i == segments.length - 1) return RulePlace(list, index, owner: owner);
    if (index == list.length) return null;
    final item = list[index];
    i++;
    if (item is List<Object?>) {
      // A together branch: the next segment indexes into it.
      list = item;
      continue;
    }
    if (item is! RuleStep) return null;
    owner = item;
    if (_wrappers[item.runtimeType] == segments[i]) {
      i++;
      if (i >= segments.length) return null;
    }
    list = _listOf(item, segments[i]);
    i++;
    if (i >= segments.length) return null;
  }
  return null;
}

/// What [pointer] names in [spec]: a trigger, condition or step, or a
/// list of conditions (an If's check, written as `/then/2/if`), or null.
Object? partAt(RuleSpec spec, String pointer) {
  final place = placeAt(spec, pointer);
  if (place != null) return place.item;
  // A pointer to a list itself, such as an If's conditions.
  final segments = pointerSegments(pointer);
  if (segments.isEmpty) return null;
  final parent = placeAt(
    spec,
    '/${segments.take(segments.length - 1).join('/')}',
  );
  final owner = parent?.item;
  if (owner is RuleStep) return _listOf(owner, segments.last);
  // `/then/2/repeat/until`: the wrapper sits between.
  if (segments.length >= 2) {
    final grand = placeAt(
      spec,
      '/${segments.take(segments.length - 2).join('/')}',
    );
    if (grand?.item case final RuleStep step
        when _wrappers[step.runtimeType] == segments[segments.length - 2]) {
      return _listOf(step, segments.last);
    }
  }
  return null;
}

/// The step that holds the list [pointer] ends in, with the pointer of
/// that step: for `/then/2/if/0` the If at `/then/2`.
(RuleStep, String)? ownerStepOf(RuleSpec spec, String pointer) {
  final segments = pointerSegments(pointer);
  for (var n = segments.length - 1; n >= 2; n--) {
    final at = '/${segments.take(n).join('/')}';
    if (placeAt(spec, at)?.item case final RuleStep step) {
      return (step, at);
    }
  }
  return null;
}
