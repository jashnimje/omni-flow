import 'conditions.dart' show peopleHome;

/// The household as one: the first person to get home, the last to leave.
/// A trigger `{people: first_arrives | last_leaves}` and a condition
/// `{people: all_away | anyone_home}`, read from each person's `home`.
const peopleTriggerKinds = ['first_arrives', 'last_leaves'];
const peopleConditionKinds = ['all_away', 'anyone_home'];

/// The driver of a person thing.
const personDriver = 'person';

/// Who the people are, for a run's `people` conditions. Null when not
/// known, and the person-shaped states count.
abstract interface class PeopleSource {
  Set<String>? get people;
}

/// Which people trigger a person's `home` going from [before] to [after]
/// fires, given who else [othersHome] is home: the first arriving when
/// nobody else is home, the last leaving when nobody else is. Null when it
/// fires none. A person with no `home` before (just added) was away.
String? peopleTriggerFor(Object? before, Object? after, bool othersHome) {
  if (after is! bool || (before == true) == after || othersHome) return null;
  return after ? 'first_arrives' : 'last_leaves';
}

/// Whether anyone but [person] is home in [states].
bool othersHome(
  Map<String, Map<String, Object?>> states,
  Set<String>? people,
  String person,
) => peopleHome(states, people).any((p) => p != person);
