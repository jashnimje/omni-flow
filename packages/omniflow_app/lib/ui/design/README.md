# Design system

Everything the redesigned screens are built from. Import one file:

```dart
import 'design/design.dart'; // from lib/ui/, or '../design/design.dart'
```

The spec is `docs/ui/mockups.html` (visual) and `docs/ui/ui-spec.md` (written). Use these components and tokens rather than raw colours, sizes or Material icons, so every screen matches and stays accessible. Every component already gives a 48 dp target, a semantics label and AA contrast, and skips animation when the system asks for reduced motion.

## Tokens (`tokens.dart`)

- `OmniColors`: `background`, `bar`, `card`, `raised`, `sheet`, `line`, `text`, `muted`; `accent`, `accentInk`, `accentSoft`, `accentLine`, `onAccentSoft`, `heroTop`, `heroBottom`, `sliderFill`; `trigger` (WHEN), `condition` (ONLY IF), `action` (THEN), `flowControl`, `transformer`, `warn`, `bad`, `info`; the soft backgrounds `triggerSoft`, `conditionSoft`, `actionSoft`, `flowSoft`, `flowLine`, `infoSoft`, `warnSoft`, `badSoft`, `badLine`; `scrim`. Never put `muted` text on the hero gradient (below AA); use `onAccentSoft`.
- `OmniSpace`: `xs` 4, `sm` 8, `gap` 10, `md` 12, `screen` 14, `lg` 16, `xl` 24, `target` 48, `screenPadding` (horizontal 14).
- `OmniRadii`: `tile`/`card` 18, `hero`/`sheet` 22, `button`/`banner` 14, `segmented`/`step`/`field` 12, `iconBox` 10, `chip` 999.
- `OmniText`: `screenTitle` 22, `pageTitle` 17, `heroTitle` 18, `section` 13, `body` 14, `bodyStrong`, `label` 13, `caption` 12 muted, `number` 12 tabular, `blockHeading` 11, `mono`.
- `OmniMotion`: `fast` 150 ms, `standard` 200, `slow` 250, `curve`; `OmniMotion.reduced(context)` and `OmniMotion.of(context, [duration])` (zero under reduced motion). Pass `OmniMotion.of(context)` to every `AnimatedContainer` and transition you add.

`lib/ui/theme.dart` re-exports the tokens and builds the Material theme from them, so plain `Switch`, `AppBar`, `TextField`, `FilledButton`, `OutlinedButton`, dialogs and snackbars already match. The switch of the mockups is the themed Material `Switch`.

## Icons (`icons.dart`)

Material Symbols (rounded), from the `material_symbols_icons` package. Never emoji.

- `OmniIcons.<name>`: tabs (`home`, `automations`, `devices`, `settings`), actions (`add`, `search`, `notifications`, `back`, `chevron`, `close`, `more`, `drag`, `star`, `edit`, `delete`, `retry`, `check`, `enter`, `play`, `test`), banners (`info`, `warning`, `error`), capabilities (`power`, `level`, `colorTemp`, `color`, `remote`, `terminal`, `sensor`, `action`, `event`), things (`light`, `plug`, `tv`, `board`, `tag`, `person`, `place`, `phone`, `computer`, `server`, `gauge`, `zigbee`, `device`), and `room`, `scene`, `time`, `repeat`, `wait`, `branch`, `wifi`, `bluetooth`, `hub`, `permissions`, `agent`, `developer`, `about`, `packets`.
- `OmniIcons.forCapability(String? type)`, `OmniIcons.forCategory(String? category)`, `OmniIcons.forManifestIcon(String? name)`, `OmniIcons.forDevice(Json row)` (manifest icon, then category, then the capability types).
- A filled star or tab icon: `Icon(OmniIcons.star, fill: 1)`.

## Components

Each line is the constructor; parameters in `[]` are optional.

### Tiles and rows

- `OmniTile({required IconData icon, required String name, [String? state, bool on = false, bool offline = false, double? level, VoidCallback? onTap, VoidCallback? onLongPress, String? tapHint]})` (`tile.dart`). Home tile: accent gradient when `on`, dimmed when `offline`, a 4 dp bar for `level` (0 to 1). `tapHint` says what a tap does for screen readers ("Turns it off").
- `OmniTileSkeleton()` (`tile.dart`). A tile's shape while loading.
- `OmniIconBox({required IconData icon, [bool on = false, double size = 32, Color? background, Color? foreground]})` (`tile.dart`). The rounded icon square of tiles and rows; `background` for an app's brand badge.
- `OmniListRow({required String title, [IconData? icon, Widget? leading, String? subtitle, String? value, Color? valueColor, StatusKind? dot, Widget? trailing, bool chevron = false, bool divider = true, VoidCallback? onTap, VoidCallback? onLongPress, Color? iconBackground, Color? iconForeground, String? semanticLabel, int subtitleLines = 1]})` (`list_row.dart`). Icon box (or `leading`), title, muted subtitle, then on the right the accent `value`, a status `dot`, a `trailing` widget (a `Switch`) or a chevron.
- `StatusDot(StatusKind kind, {String? label})` (`list_row.dart`). `StatusKind.online | offline | warning | problem`; `StatusDot.colorOf(kind)`.

### Cards

- `OmniCard({[String? title, Widget? trailing, Widget? child, VoidCallback? onTap, bool highlighted = false, EdgeInsetsGeometry padding, EdgeInsetsGeometry margin]})` (`card.dart`). Title row with a `trailing` switch or value, then `child`. `highlighted` is the accent border of the "Do it" result. Default margin is 10 below.
- `OmniHeroCard({required String title, [String? subtitle, Widget? trailing, Widget? child, String? footer, IconData? icon, bool centered = false, HeroTone tone = HeroTone.accent]})` (`card.dart`). The big card of device, sensor, tag, place and pairing pages. `trailing` takes an `OmniPowerButton`; `child` a chart; `footer` a second caption; `centered` with `icon` for the tag and pairing layouts. `HeroTone.accent | plain | problem`.
- `OmniPowerButton({required bool on, required VoidCallback? onPressed, [String label = 'Power', double size = 64]})` (`power_button.dart`). Read out as a toggle; null `onPressed` is disabled.

### Automations

- `SentenceChip(SentenceKind kind, String text)` (`sentence.dart`). One coloured phrase.
- `AutomationSentence(List<SentencePart> parts)` (`sentence.dart`). The whole sentence of an `automation.list` row: chips for `when`, `onlyIf`, `then`, `flow`, and muted words for `text` parts. Pass `summary.sentence` straight in.
- `SentenceColors.of(kind)`, `SentenceColors.softOf(kind)` (`sentence.dart`).
- `OmniRuleBlock({required SentenceKind kind, required String heading, required String caption, required List<Widget> children, [String? addLabel, VoidCallback? onAdd]})` (`sentence.dart`). A block of the rule editor: `OmniRuleBlock(kind: SentenceKind.when, heading: 'When', caption: 'any of these', addLabel: 'Add trigger', ...)`. The heading is upper-cased for you.
- `OmniStepRow({required String text, [IconData? icon, String? subtitle, StepRowStyle style = StepRowStyle.normal, VoidCallback? onTap, VoidCallback? onRemove, String? trailingText, int? reorderIndex, String? error]})` (`step_row.dart`). A rule editor row with a drag handle. `StepRowStyle.wait` is dashed, `StepRowStyle.flow` (a branch or group) has the pink border and takes `trailingText: '2'` for its count. Inside a `ReorderableListView(buildDefaultDragHandles: false)` pass `reorderIndex: i` and the handle drags. `error` (from `ApiFailure.issuesAt('then[2]')`) turns the row red with the reason under it. Inside an `OmniRuleBlock` the row's words and icon take the block's colour (`RuleBlockColor`).

### Controls

- `OmniSegmented<T>({required List<OmniSegment<T>> segments, required T selected, required ValueChanged<T> onChanged})` and `OmniSegment<T>(T value, String label, {int? count})` (`chips.dart`). Devices (By room, By type, Problems 1), the TV tabs, Developer tabs.
- `OmniFilterChip({required String label, required VoidCallback? onTap, [bool selected = false, int? count, StatusKind? dot, IconData? icon]})` (`chips.dart`). "All 6", "Needs you 1" with a warning dot, "＋ Install APK" with `icon: OmniIcons.add`.
- `OmniStatusChip({required String label, [VoidCallback? onTap, StatusKind? dot, IconData? icon]})` (`chips.dart`). Home's status chips.
- `OmniLabelledSlider({required String label, required double value, required ValueChanged<double>? onChangeEnd, [double min = 0, double max = 100, double? step, String Function(double)? format, ValueChanged<double>? onChanged, Gradient? fill, Color? labelOnFill, double height = 36]})` (`slider.dart`). The pill slider. It sends `onChangeEnd` on release only (one device command per gesture); `onChanged` is for live labels. Warmth: `fill: LinearGradient(colors: [Color(0xFFFFB86B), Color(0xFFFFE7C2)]), labelOnFill: Color(0xFF2A1A00), format: (v) => '${v.round()} K'`.
- `OmniButton({required String label, required VoidCallback? onPressed, [IconData? icon, OmniButtonKind kind = OmniButtonKind.primary, bool expand = true]})`, `OmniButton.ghost(...)`, `OmniButton.danger(...)` (`buttons.dart`). Accent, outlined, and red outlined (Reject, Remove).
- `OmniIconAction({required IconData icon, required String label, required VoidCallback? onPressed, [Color color = OmniColors.muted, bool selected = false]})` (`buttons.dart`). Header and row icon buttons; `label` is the tooltip and the spoken name; `selected` fills it in the accent (a set favourite).
- `OmniTapTarget({required Widget child, required VoidCallback? onTap})` (`buttons.dart`). Grows a small custom control's hit area to 48 dp.

### Feedback

- `OmniBanner({required BannerKind kind, required String message, [String? actionLabel, VoidCallback? onAction, VoidCallback? onClose, IconData? icon, bool showIcon = true]})`, `OmniBanner.info(message, ...)`, `OmniBanner.warning(message, ...)`, `OmniBanner.error(message, ...)` (`banner.dart`). `BannerKind.info | warning | error`. Warnings and errors are live regions. Say what happened and what to do; never put raw exception text in one.
- `OmniProgressBar({[double? value, double height = 6, String? semanticLabel, Color color = OmniColors.accent]})` (`progress.dart`). Null `value` animates (so a widget test cannot `pumpAndSettle` while one shows; pump a duration instead), and holds still under reduced motion.
- `OmniStepBar({required int count, required int current})` (`progress.dart`). The step bar of the add flow; `current` is 1-based.
- `confirm(BuildContext context, {required String title, required String body, required String action, bool destructive = false})` (`confirm.dart`). The one yes or no dialog: Cancel (`confirm-cancel`) and the action (`confirm`), red when `destructive`. Every step that deletes or cannot be undone asks with it and says what is lost.
- `OmniEmptyState({required IconData icon, required String title, [String? message, Widget? action, EdgeInsetsGeometry padding]})` (`banner.dart`). Empty Home, no automations, no results.

### Structure

- `OmniTabPage({required String title, required Widget body, [String? subtitle, List<Widget> actions = const [], bool padded = true]})` (`headers.dart`). The root screen of a tab: safe area, screen padding, the 22 title with icon `actions`, then `body`.
- `OmniScreenTitle(String title, {[String? subtitle, List<Widget> actions = const []]})` (`headers.dart`). The title alone, for a root that lays itself out (Home's greeting scrolls with the page).
- `OmniPage({required String title, required Widget body, [List<Widget> actions = const [], Widget? floatingActionButton, Widget? bottom, bool close = false, bool padded = true]})` (`headers.dart`). A pushed page: back chevron (or a cross with `close`), the 17 title, icon `actions` (star, more), the body with screen padding, and `bottom` pinned under it (Test run and Save).
- `OmniSectionHeader(String title, {[String? actionLabel, VoidCallback? onAction, String? trailingText]})` (`headers.dart`). "Scenes · Edit", "Living room · All", "Found nearby · 3".
- `showOmniSheet<T>(BuildContext context, {required WidgetBuilder builder, bool dismissible = true})` and `OmniSheet({[String? title, String? subtitle, Widget? trailing], required List<Widget> children})` (`sheet.dart`). Sheets open over the whole app (above the tab bar) with the grab handle, the 22 radius and the dim; `trailing` takes the quick sheet's power `Switch`.

## Engine calls

Typed calls for every command of the Engine additions contract are in `lib/api/engine_calls.dart`, reached as `ref.read(engineApiProvider)`:

- `rooms()`, `saveRoom(id:, name:, order:)`, `removeRoom(id)`, `orderRooms(ids)`
- `devices()` (rows as `DeviceView`), `device(id)`, `invoke(id, capability, params)`, `organizeDevice(id, name:, room:, favourite:, order:)`, `removeDevice(id)`, `history(id, key:, limit:, since:)`
- `scenes()`, `saveScene(Scene)`, `runScene(id)`, `removeScene(id)`
- `automations(device:, tag:, needsYou:)` (rows as `AutomationSummary` with `sentence`, `lastRun`, `devices`), `automation(id)`, `enableAutomation(id, enabled)`, `approveAutomation(id, revision)`, `runAutomation(id)`, `runLog(id:, limit:)` (as `RunRecord`), `removeAutomation(id)`, `templates()` (as `AutomationTemplate`)
- `tags()`, `interpret(text)`

Each returns a `Reply<T>`: `reply.ok`, `reply.value`, `reply.failure` (an `ApiFailure` with `message` and `issuesAt(path)`), `reply.or(fallback)`. A failure has already shown as a snackbar. `Presence.of(personRow)` reads where the person is and what decided it; `RuleParts.keep(...)` and `RuleParts.stopOnError(rule)` build the new rule parts. `DeviceView(json)` wraps the maps `devicesProvider` holds.

## Shell and routes

`lib/ui/shell/`: the four tabs, each with its own back stack. Open any place from anywhere with a `WidgetRef`:

```dart
ref.read(shellControllerProvider).open(const DeviceLink('desk_lamp'));
ref.read(shellControllerProvider).select(ShellTab.automations);
```

Links (`links.dart`), each with a `location` a notification launches the app with (`FlutterForegroundTask.launchApp(link.location)`):

- `TabLink(ShellTab)`: `/home`, `/automations`, `/devices`, `/settings`
- `SearchLink()`: `/search`
- `AddLink()`: `/add`, the add flow on the current tab
- `DeveloperLink()`: `/settings/developer`
- `AutomationLink(id)`: `/automation/<id>`
- `RunLink(automationId, runId)`: `/automation/<id>/run/<runId>`, a failed run
- `ReviewLink(id)`: `/review/<id>`, an approval request
- `DeviceLink(id)`: `/device/<id>`

`ShellLink.parse` also takes the same paths under `omniflow://open/`.

To land a screen, edit `lib/ui/shell/tabs.dart` only: set the tab's `root` in `shellTabs` (and its `fab`, with `hiddenWhen` for a root that carries its own add action, and `fullScreenWhen` for a root that hides the tab bar, such as the first run), and return the new page for a link in `shellPageFor`. Pages pushed from a tab with `Navigator.of(context).push` stay inside the tab, under the tab bar. A tab's button shows only at its root. System back pops the tab's stack, then goes to Home, then leaves.
