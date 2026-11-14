/// The ADB device commands started as `tv.*` and now control phones too, so
/// every one is also registered as `android.*` with the same handler. The
/// command table and the agent policy both take their `android.*` names from
/// here, so the two can never drift apart.
const tvCommandPrefix = 'tv.';
const androidCommandPrefix = 'android.';

/// The `android.*` name of a `tv.*` command, or null for any other command.
String? androidNameOf(String command) => command.startsWith(tvCommandPrefix)
    ? '$androidCommandPrefix${command.substring(tvCommandPrefix.length)}'
    : null;

/// The `tv.*` name an `android.*` command shares its handler and policy
/// with, or [command] itself when it is not an `android.*` name.
String tvNameOf(String command) => command.startsWith(androidCommandPrefix)
    ? '$tvCommandPrefix${command.substring(androidCommandPrefix.length)}'
    : command;

/// [commands] with every `tv.*` entry also under its `android.*` name. An
/// `android.*` name already given keeps its own value.
Map<String, T> withAndroidNames<T>(Map<String, T> commands) => {
  for (final e in commands.entries) ?androidNameOf(e.key): e.value,
  ...commands,
};

/// [commands] with the `android.*` name of every `tv.*` one added.
Set<String> withAndroidCommandNames(Set<String> commands) => {
  ...commands,
  for (final c in commands) ?androidNameOf(c),
};
