# Design system

Everything the redesigned screens are built from. Import one file:

```dart
import 'design/design.dart'; // from lib/ui/, or '../design/design.dart'
```

The spec is `docs/ui/design-v2.md`, on top of `docs/ui/mockups.html` (visual) and `docs/ui/ui-spec.md` (written). Use these components and tokens rather than raw colours, sizes or Material icons, so every screen matches and stays accessible. Every component already gives a 48 dp target, a semantics label and AA contrast, and skips animation when the system asks for reduced motion.

## Tokens (`tokens.dart`)

- `OmniPalette`: the colours that follow the Appearance setting and the theme's brightness. Read with `OmniPalette.of(context)`. Surfaces `background`, `bar`, `card`, `raised`, `highest`, `sheet`, `line`; text `text`, `muted`; the accent family `accent`, `onAccent`, `accentSoft`, `onAccentSoft`, `accentLine`, `heroTop`, `heroBottom`, `sliderFill`, `onSliderFill`; steps `trigger`, `triggerSoft`, `condition`, `conditionSoft`, `action` (the accent), `actionSoft`, `flowControl`, `flowSoft`, `flowLine`, `transformer`; status `warn`, `warnSoft`, `bad`, `onBad`, `badSoft`, `badLine`, `info`, `infoSoft`; `scrim`; `brightness` and `isDark`. `OmniPalette.teal` is the dark look, `OmniPalette.tealLight` the light one, and `OmniPalette.forSurface(surface)` the one a surface colour belongs to. Code reads the palette, never `OmniColors`.
- `OmniCardColors`: the seven automation card colours, each at 4.5:1 or more with white in both themes: `violet`, `orange`, `teal`, `blue`, `pink`, `green`, `slate`, with `onCard` (white) and `all` in picker order.
- `OmniColors`: the source values of `OmniPalette.teal`, read only inside `tokens.dart`: `background`, `bar`, `card`, `raised`, `sheet`, `line`, `text`, `muted`; `accent`, `accentInk`, `accentSoft`, `accentLine`, `onAccentSoft`, `heroTop`, `heroBottom`, `sliderFill`; `trigger` (WHEN), `condition` (ONLY IF), `action` (THEN), `flowControl`, `transformer`, `warn`, `bad`, `info`; the soft backgrounds `triggerSoft`, `conditionSoft`, `actionSoft`, `flowSoft`, `flowLine`, `infoSoft`, `warnSoft`, `badSoft`, `badLine`; `scrim`. Never put `muted` text on the hero gradient (below AA); use `onAccentSoft`.
- `LightWhite`: the warm (`warm`) and cool (`cool`) ends of a light's white, the same in both themes, with `onWarm` for text on either and the `kelvin` and `mired` slider gradients.
- `OmniSpace`: the 4 dp grid. `xs` 4, `sm` 8, `md` 12, `screen` 16, `lg` 16, `xl` 24, `xxl` 40, `target` 48, `targetLarge` 56 (power, D-pad keys, Run, Save), `row` 56 and `rowTwoLine` 72 (list rows), `screenPadding` (horizontal 16).
- `OmniShape`: the Material 3 corner scale `xs` 4, `sm` 8, `md` 12, `lg` 16, `lgIncreased` 20, `lgPlus` 24, `xl` 28, `full` 999. `OmniRadii` places each component on it: `tile`/`card`/`section` 24, `hero`/`sheet` 28, `step` 20, `banner`/`fab` 16, `field`/`iconBox` 12, `tooltip` 8, `button`/`segmented`/`segment`/`chip` full.
- `OmniText`: the Material 3 scale. `largeTitle` 32 (the open title of tab roots and pushed pages, shrinking to `screenTitle`/`pageTitle` 22), `reading`/`heroTitle` 28 tabular (the state card), `section` 18, `cardTitle` 18, `step` 18 on a 28 line (editor blocks), `body` 16, `bodyStrong` 16, `button` 16, `bodySmall` 14 (dense lists inside a section), `label` 14, `caption` 14, `number` 14 tabular, and 12 only for `navLabel`, `labelMedium` and `blockHeading` (tags on cards). No style carries a colour, so text takes the theme's: set another with `copyWith(color: OmniPalette.of(context).muted)`. `OmniText.captionOf(context)` is the caption in the theme's muted colour.
- `OmniDepth`: depth by tone. A card or tile is a lighter surface than the screen with a near-clear edge and no shadow (`surface(color:, radius:, [gradient, border, lifted = false])`). `shadow` (0 8 24 at 35 % black) is only for what floats: the floating button and sheets. `sheen` is no longer drawn. `edge` (white at 6 %, `edgeOn(surface)` as a solid border), `wash(tint, surface)` (a tile's own colour from 30 % at the top corner to 6 % at 70 %, backed off by `mutedTint(tint, surface, {amount, text})` so text stays at AA, `text` defaulting to the body text of the surface's theme) and `surface(color:, radius:, [gradient, border, lifted])` for the whole decoration. Grey text on a washed tile takes `captionOn(surface, {palette})`, which is the palette's `muted` where that reads at AA and nearer its body text where it does not.
- `omniSystemBars`, `omniSystemBarsLight` and `omniSystemBarsOf(context)`: the see-through system bars for the theme's brightness.
- `OmniMotion`: `fast` 150 ms, `standard` 200, `slow` 250, `curve`; `OmniMotion.reduced(context)` and `OmniMotion.of(context, [duration])` (zero under reduced motion). Pass `OmniMotion.of(context)` to every `AnimatedContainer` and transition you add.

`lib/ui/theme.dart` re-exports the tokens and builds the Material theme from them with `omniTheme({palette, brightness})` (dark unless asked; the light brightness with the default palette uses `tealLight`). The app passes `theme` (light), `darkTheme` and `themeMode` from the Appearance setting (System by default, Light or Dark), `omniColorScheme(palette)` and `omniTextTheme(palette)`, so plain `Switch`, `AppBar`, `TextField`, `FilledButton`, `OutlinedButton`, dialogs and snackbars already match. The switch of the mockups is the themed Material `Switch`.

## Icons (`icons.dart`)

Material Symbols (rounded), from the `material_symbols_icons` package. Never emoji.

- `OmniIcons.<name>`: tabs (`home`, `automations`, `devices`, `settings`), actions (`add`, `search`, `notifications`, `back`, `chevron`, `close`, `more`, `drag`, `star`, `edit`, `delete`, `retry`, `check`, `enter`, `play`, `test`), banners (`info`, `warning`, `error`), capabilities (`power`, `level`, `colorTemp`, `color`, `remote`, `terminal`, `sensor`, `action`, `event`), things (`light`, `plug`, `tv`, `board`, `tag`, `person`, `place`, `phone`, `computer`, `server`, `gauge`, `zigbee`, `device`), and `room`, `scene`, `time`, `repeat`, `wait`, `branch`, `wifi`, `bluetooth`, `hub`, `permissions`, `agent`, `developer`, `about`, `packets`, `history`, `tune`, `handyman`, `apps`, `autoAwesome`, and the Appearance theme choices `themeSystem`, `themeLight`, `themeDark`. Screens use these, not `Symbols.*` directly.
- `OmniIcons.forCapability(String? type)`, `OmniIcons.forCategory(String? category)`, `OmniIcons.forManifestIcon(String? name)`, `OmniIcons.forDevice(Json row)` (manifest icon, then category, then the capability types).
- A filled star or tab icon: `Icon(OmniIcons.star, fill: 1)`.

## Components

Each line is the constructor; parameters in `[]` are optional.

### Tiles and rows

- `OmniTile({required IconData icon, required String name, [String? reading, String? state, bool on = false, bool offline = false, bool pending = false, double? level, Color? tint, Color? wash, VoidCallback? onTap, VoidCallback? onIconTap, String? iconLabel, VoidCallback? onLongPress, String? tapHint]})` (`tile.dart`). Home tile: a muted `tint` when `on`, filled from the left by `level` (0 to 1), dimmed when `offline`. `wash` is the tile's own colour (a room's), washed in while it is off. `tapHint` says what a tap does for screen readers ("Opens it").
- `OmniTileSkeleton()` (`tile.dart`). A tile's shape while loading.
- `OmniListSkeleton({[int rows = 5, String label = 'Loading', double rowHeight = 56]})`, `OmniPageSkeleton({[int rows = 3, String label]})` (hero bone and rows, for detail pages) and `OmniTileGridSkeleton({[int count = 6, int columns = 2, String label]})` (`skeleton.dart`). The only loading shapes: no centred spinner for a whole page and no blank box. The templates pick one for you.
- `OmniIconBox({required IconData icon, [bool on = false, double size = 32, Color? background, Color? foreground]})` (`tile.dart`). The rounded icon square of tiles and rows; `background` for an app's brand badge.
- `OmniListRow({required String title, [IconData? icon, Widget? leading, String? subtitle, String? value, Color? valueColor, StatusKind? dot, Widget? trailing, bool chevron = false, bool divider = true, VoidCallback? onTap, VoidCallback? onLongPress, Color? iconBackground, Color? iconForeground, String? semanticLabel, int subtitleLines = 1]})` (`list_row.dart`). A 40 dp icon box (or `leading`), a 16 title, a 14 muted subtitle (at least 56 dp high, 72 with a subtitle, growing with the text), then on the right the accent `value`, a status `dot`, a `trailing` widget (a `Switch`) or a chevron.
- `StatusDot(StatusKind kind, {String? label})` (`list_row.dart`). `StatusKind.online | offline | warning | problem`; `StatusDot.colorIn(context, kind)` (online follows the Appearance accent).

### Collapsed sections

- `OmniDisclosure({required IconData icon, required String title, required List<Widget> children, [String? summary, bool initiallyOpen = false, String? storageId, ValueChanged<bool>? onChanged, EdgeInsetsGeometry margin]})` (`disclosure.dart`). Everything secondary on a page sits behind one: a card (24 corners, the card tone) whose header row is a 40 dp icon box, the `title`, a one-line `summary` that answers the first question ("5 changes today", "Used in 2") and a chevron that turns when open. The header is at least 56 dp (72 with a summary) and grows with the text size. It starts closed, opens on a tap anywhere on the header, and animates by `OmniMotion.of` (instant under reduced motion). Screen readers hear "Activity, 5 changes today" as a button with its expanded state. The open state is kept in the page's `PageStorage` under `storageId` (the title by default), so it survives a lazy list scrolling it away. One inside another (Developer details inside More settings) draws flat as a row of its parent. Use the standard labels from the spec: Activity, Automations, More settings, Developer details, More buttons, TV tools, Options, Ideas for you, Recently removed.

### Cards

- `OmniCard({[String? title, Widget? trailing, Widget? child, VoidCallback? onTap, bool highlighted = false, EdgeInsetsGeometry padding, EdgeInsetsGeometry margin]})` (`card.dart`). Title row with a `trailing` switch or value, then `child`. `highlighted` is the accent border of the "Do it" result. 24 corners, no shadow, default margin 12 below.
- `OmniHeroCard({required String title, [String? subtitle, Widget? trailing, Widget? child, String? footer, IconData? icon, bool centered = false, HeroTone tone = HeroTone.accent]})` (`card.dart`). The big card of device, sensor, tag, place and pairing pages. `trailing` takes an `OmniPowerButton`; `child` a chart; `footer` a second caption; `centered` with `icon` for the tag and pairing layouts. `HeroTone.accent | plain | problem`.
- `OmniPowerButton({required bool on, required VoidCallback? onPressed, [String label = 'Power', double size = 72]})` (`power_button.dart`). Read out as a toggle; null `onPressed` is disabled.

### Automations

- `SentenceChip(SentenceKind kind, String text)` (`sentence.dart`). One coloured phrase.
- `AutomationSentence(List<SentencePart> parts)` (`sentence.dart`). The whole sentence of an `automation.list` row: chips for `when`, `onlyIf`, `then`, `flow`, and muted words for `text` parts. Pass `summary.sentence` straight in.
- `SentenceColors.of(palette, kind)`, `SentenceColors.softOf(palette, kind)` and `SentenceColors.iconOf(kind)` (`sentence.dart`).
- `OmniRuleBlock({required SentenceKind kind, required String heading, required String caption, required List<Widget> children, [String? addLabel, VoidCallback? onAdd, bool isEmpty = false, String? emptyLabel]})` (`sentence.dart`). A stacked block of the rule editor, a rounded card in its kind's soft colour with the kind's icon: `OmniRuleBlock(kind: SentenceKind.when, heading: 'When', caption: 'any of these', addLabel: 'Add trigger', ...)`. The heading is upper-cased for you, and an empty `caption` shows the heading alone. Without `addLabel`, an empty block (`isEmpty`) offers `emptyLabel` as one big target that calls `onAdd`.
- `OmniStepRow({required String text, [IconData? icon, String? subtitle, StepRowStyle style = StepRowStyle.normal, VoidCallback? onTap, VoidCallback? onRemove, String? trailingText, int? reorderIndex, String? error]})` (`step_row.dart`). A rule editor row with a drag handle. `StepRowStyle.wait` is dashed, `StepRowStyle.flow` (a branch or group) has the pink border and takes `trailingText: '2'` for its count. Inside a `ReorderableListView(buildDefaultDragHandles: false)` pass `reorderIndex: i` and the handle drags. `error` (from `ApiFailure.issuesAt('then[2]')`) turns the row red with the reason under it. Inside an `OmniRuleBlock` the row's words and icon take the body text colour the block sets (`RuleBlockColor`).

### Controls

- `OmniSegmented<T>({required List<OmniSegment<T>> segments, required T selected, required ValueChanged<T> onChanged})` and `OmniSegment<T>(T value, String label, {int? count, Key? key})` (`chips.dart`). Devices (By room, By type, Needs a look 1), the TV tabs, Developer tabs. Pill segments in a pill track, the selected one in the soft accent, 14 labels that wrap at large text.
- `OmniFilterChip({required String label, required VoidCallback? onTap, [bool selected = false, int? count, StatusKind? dot, IconData? icon]})` (`chips.dart`). 40 dp high with a 14 label and a 48 dp hit area. "All 6", "Needs you 1" with a warning dot, "＋ Install APK" with `icon: OmniIcons.add`.
- `OmniStatusChip({required String label, [VoidCallback? onTap, StatusKind? dot, IconData? icon]})` (`chips.dart`). Home's status chips.
- `OmniLabelledSlider({required String label, required double value, required ValueChanged<double>? onChangeEnd, [double min = 0, double max = 100, double? step, String Function(double)? format, ValueChanged<double>? onChanged, Gradient? fill, Color? labelOnFill, double height = 56]})` (`slider.dart`). The 56 dp slider with a 16 label. It sends `onChangeEnd` on release only (one device command per gesture); `onChanged` is for live labels. Warmth: `fill: LinearGradient(colors: [Color(0xFFFFB86B), Color(0xFFFFE7C2)]), labelOnFill: Color(0xFF2A1A00), format: (v) => '${v.round()} K'`.
- `OmniButton({required String label, required VoidCallback? onPressed, [IconData? icon, OmniButtonKind kind = OmniButtonKind.primary, bool expand = true]})`, `OmniButton.ghost(...)`, `OmniButton.danger(...)`, `OmniButton.destructive(...)` (`buttons.dart`). Full-radius pills, 56 dp high with a 16 label. Accent, outlined, red outlined (Reject, Remove in a page) and filled red (the action of a confirm or sheet that deletes). The primary fill and the ghost outline read `OmniPalette.of(context)`, so they follow Wallpaper colours and pure black.
- `OmniIconAction({required IconData icon, required String label, required VoidCallback? onPressed, [Color? color (the palette's `muted`), bool selected = false, int? badge]})` (`buttons.dart`). Header and row icon buttons; `label` is the tooltip and the spoken name (say the count in it); `selected` fills it in the accent (a set favourite). `badge` draws a count on the icon inside the button's own 48 dp box, its text growing only to 130 %, so it never covers the button beside it (key `omni-icon-badge`).
- `OmniTapTarget({required Widget child, required VoidCallback? onTap})` (`buttons.dart`). Grows a small custom control's hit area to 48 dp.

### Feedback

- `OmniBanner({required BannerKind kind, required String message, [String? actionLabel, VoidCallback? onAction, VoidCallback? onClose, IconData? icon, bool showIcon = true]})`, `OmniBanner.info(message, ...)`, `OmniBanner.warning(message, ...)`, `OmniBanner.error(message, ...)` (`banner.dart`). `BannerKind.info | warning | error`. Warnings and errors are live regions. Say what happened and what to do; never put raw exception text in one.
- `OmniProgressBar({[double? value, double height = 6, String? semanticLabel, Color? color]})` (the fill defaults to the palette accent) (`progress.dart`). Null `value` animates (so a widget test cannot `pumpAndSettle` while one shows; pump a duration instead), and holds still under reduced motion.
- `OmniStepBar({required int count, required int current})` (`progress.dart`). The step bar of the add flow; `current` is 1-based.
- `confirm(BuildContext context, {required String title, required String body, required String action, bool destructive = false})` (`confirm.dart`). The one yes or no dialog: Cancel (`confirm-cancel`) and the action (`confirm`), filled red (`OmniButtonKind.destructive`) when `destructive`. Every step that deletes or cannot be undone asks with it, passes `destructive: true` and says what is lost.
- `OmniEmptyState({required IconData icon, required String title, [String? message, Widget? action, EdgeInsetsGeometry? padding, Color iconColor, bool large = false, bool compact = false]})` (`banner.dart`). Empty Home, no automations, no results. `compact` is the "nothing matches" of a filtered list or a sheet: less padding and no icon.
- `OmniErrorState({[String title = 'This did not open', String? message, VoidCallback? onRetry, String retryLabel = 'Try again']})` (`banner.dart`). A page that could not open at all. A page with something to show keeps it and shows `OmniErrorBanner` above it.
- `OmniActionBar({[Widget? primary, Widget? secondary, Widget? leading, String? missing]})` (`action_bar.dart`). The commit row of forms, editors, steps and sheets: Back as `leading`, a ghost `secondary`, the `primary`, and the `missing` caption above when the primary is off. Above 130% text the buttons stack, the primary first.

### Structure

- `OmniTabPage({required String title, required Widget body, [String? subtitle, List<Widget> actions = const [], bool padded = true, bool heroTitle = false, Widget? house, Widget? filters]})` (`headers.dart`). The root screen of a tab: safe area, screen padding, the 32 title that shrinks to 22 as the body scrolls, icon `actions`, the `house` chip and pinned `filters`, then `body`. `heroTitle` is for a body that opens with its own big title (Home's hero): the bar holds only the actions until the page scrolls, then the small title fades in. Screens use `TabPage` instead.
- `OmniScreenTitle(String title, {[String? subtitle, List<Widget> actions = const [], double collapse = 0, bool reveal = false]})` (`headers.dart`). The title alone, for a root that lays itself out.
- `OmniPage({required String title, required Widget body, [List<Widget> actions = const [], Widget? floatingActionButton, Widget? bottom, bool close = false, bool padded = true, bool large = true]})` (`headers.dart`). A pushed page: back chevron (or a cross with `close`), the title large under it that slides into the bar as the body scrolls, icon `actions` (star, more), the body with screen padding, and `bottom` pinned under it (Test run and Save). Screens use a template instead.
- `OmniSectionHeader(String title, {[String? actionLabel, VoidCallback? onAction, String? trailingText]})` (`headers.dart`). "Scenes · Edit", "Living room · All", "Found nearby · 3". The only section heading.
- `showOmniSheet<T>(BuildContext context, {required WidgetBuilder builder, bool dismissible = true})` and `OmniSheet({[String? title, String? subtitle, Widget? trailing, Widget? pinned, Widget? actions], required List<Widget> children})` (`sheet.dart`). Sheets open over the whole app (above the tab bar) with the grab handle, the 28 radius and the dim; `trailing` takes the quick sheet's power `Switch`. The header and `pinned` (a search field) stay in view, `children` scroll, and `actions` (an `OmniActionBar`) sit under the scroll. The last widget ends `OmniSheet.bottomPadding(context)` above the bottom: the system navigation bar plus 16. `OmniSheetHandle()` is the handle alone, in the palette line colour, for a sheet that draws its own body.

## Page templates (`templates/`)

Every screen is one of eight templates (the design is `docs/ui/page-templates.md`). A screen picks one and fills slots. It never builds its own scaffold, header, loading, empty or error widget, and never writes a bottom spacer.

### State

Each template takes `state:`, an `OmniLoad`, and draws the loading skeleton, the error and the empty state itself. The screen's `children` builder runs only for data.

- `OmniLoad.of<T>(AsyncValue<T> value, {bool Function(T)? isEmpty, VoidCallback? onRetry, String error = OmniLoad.defaultError})`. A value (even while it refreshes) is data, or empty when `isEmpty` says so. An error with a cached value stays data with an error banner. An error with nothing cached is an error.
- `OmniLoad.flags({bool loading = false, String? error, bool isEmpty = false, VoidCallback? onRetry})` for a screen with its own flags. Error wins, then loading, then empty.
- `const OmniLoad.loading()`, `const OmniLoad.empty()`, `const OmniLoad.data({String? error, VoidCallback? onRetry})`, `const OmniLoad.error([String message, VoidCallback? onRetry])`.
- Error words are plain ("The rooms did not load."), never exception text. The default is "OmniFlow did not answer."
- Error with nothing to show: tab, detail, form and editor pages show the full-page `OmniErrorState`. Lists, sheets, pickers and steps show `OmniErrorBanner` (`OmniBanner.error` with Try again, key `omni-error`). Both have Try again, which calls `onRetry`.
- Keys for tests: `template-primary`, `template-secondary`, `step-primary`, `step-skip`, `step-back`, `step-help`, `picker-search`, `picker-add`, `picker-chosen`, `prompt-field`, `prompt-save`, `omni-retry` (full-page Try again), `omni-sheet-handle`, `action-bar-missing`.

### T1 TabPage (`tab_page.dart`)

`TabPage({required String title, required List<Widget> Function(BuildContext) children, [String? subtitle, List<Widget> actions, Widget? house, Widget? filters, bool heroTitle = false, bool fab = true, OmniLoad state, OmniSkeleton skeleton = OmniSkeleton.rows, Widget? empty, List<Widget> banners, ScrollController? controller]})`, and `TabPage.custom({..., required Widget Function(BuildContext, EdgeInsets padding) body})` for a body that is not a plain list. `fab` pads the end of the list with `OmniInsets.fabClearance`, so the last row is never under the shell's button. Set it false on Settings. The shell draws that button extended (icon and label) on a phone at normal text sizes, as just its icon from 130 % text, and at the top of the rail on a wide screen or a phone on its side, where it covers nothing.

```dart
final devices = ref.watch(devicesProvider);
return TabPage(
  title: 'Devices',
  actions: [OmniIconAction(icon: OmniIcons.search, label: 'Search', onPressed: openSearch)],
  house: const HouseSwitcher(),
  filters: OmniSegmented(segments: views, selected: view, onChanged: pick),
  state: OmniLoad.of(devices, isEmpty: (d) => d.isEmpty, onRetry: () => ref.invalidate(devicesProvider)),
  empty: OmniEmptyState(icon: OmniIcons.devices, title: 'No devices yet', action: addButton),
  children: (context) => [
    for (final room in rooms) ...[OmniSectionHeader(room.name), for (final d in room.devices) DeviceRow(d)],
  ],
);
```

### T2 ListPage (`list_page.dart`)

`ListPage({required String title, required List<Widget> Function(BuildContext) children, [List<Widget> actions, bool close = false, Widget? search, Widget? filters, OmniLoad state, int skeletonRows = 5, Widget? empty, List<Widget> banners, Widget? bottom, ScrollController? controller]})`. `ListPage.builder({..., required int itemCount, required IndexedWidgetBuilder itemBuilder})` builds rows lazily. `ListPage.custom({..., required Widget Function(BuildContext, EdgeInsets padding) body})` takes any scroll view, such as a `ReorderableListView`. An add action is a header `OmniIconAction`, never a page FAB.

```dart
return ListPage.builder(
  title: 'Scenes',
  actions: [OmniIconAction(icon: OmniIcons.add, label: 'New scene', onPressed: add)],
  search: TextField(controller: query, decoration: const InputDecoration(hintText: 'Search')),
  state: OmniLoad.of(scenes, isEmpty: (s) => shown.isEmpty),
  empty: query.text.isEmpty
      ? OmniEmptyState(icon: OmniIcons.scene, title: 'No scenes yet', action: newButton)
      : const OmniEmptyState(icon: OmniIcons.search, title: 'Nothing matches', compact: true),
  itemCount: shown.length,
  itemBuilder: (context, i) => SceneRow(shown[i]),
);
```

### T3 DetailPage (`detail_page.dart`)

`DetailPage({required String title, required List<Widget> Function(BuildContext) children, [List<Widget> actions, List<Widget> banners, Widget? hero, Widget? tabs, OmniLoad state, Widget? notFound, Widget? bottom, ScrollController? controller, List<OmniDisclosure> Function(BuildContext)? sections]})`, and `DetailPage.custom({..., required WidgetBuilder body})` for a body under the hero that is not a list (the TV tabs; it fills the rest edge to edge). Loading is `OmniPageSkeleton`. `OmniLoadStatus.empty` means the thing is gone and shows `notFound`, or `DetailPage.gone` ("This is not here any more"). `sections` are the page's collapsed sections, placed after `children` in the standard order (Automations, Activity, More settings). `DetailPage.custom` has none: its body places its own.

```dart
final device = ref.watch(deviceProvider(id));
return DetailPage(
  title: name,
  actions: [starAction, moreMenu],
  state: OmniLoad.of(device, isEmpty: (d) => d == null),
  banners: [if (offline) const OmniBanner.warning('Desk lamp is not answering.')],
  hero: OmniHeroCard(title: 'On', subtitle: '80% warm', trailing: power),
  children: (context) => [const OmniSectionHeader('Controls'), ...controls],
  sections: (context) => [
    OmniDisclosure(icon: OmniIcons.automations, title: 'Automations', summary: 'Used in 2', children: usedIn),
    OmniDisclosure(icon: OmniIcons.info, title: 'Activity', summary: '5 changes today', children: activity),
  ],
);
```

### T4 FormPage (`form_page.dart`)

`FormPage({required String title, required List<Widget> Function(BuildContext) children, required VoidCallback? onCommit, [String commitLabel = 'Save', Key? commitKey, String? missing, String? secondaryLabel, VoidCallback? onSecondary, String? saveError, bool dirty = false, String discardWhat = 'this', VoidCallback? onDiscard, bool close = false, List<Widget> actions, OmniLoad state, List<Widget> banners, ScrollController? controller]})`. The commit button sits in the bottom bar, never at the end of the scroll. A null `onCommit` turns it off and `missing` says why. `dirty` asks "Discard changes?" on back. `FormPage.instant({required String title, required children, [actions, state, banners, controller]})` is the settings variant with no bar.

```dart
return FormPage(
  title: 'New scene',
  dirty: draft.changed,
  discardWhat: 'this scene',
  onCommit: draft.name.isEmpty ? null : save,
  missing: 'Give the scene a name first.',
  saveError: failure?.message,
  children: (context) => [const OmniSectionHeader('Name'), nameField, const OmniSectionHeader('Devices'), ...rows],
);
```

`OmniDiscardGuard({required bool dirty, required Widget child, [String what = 'this', VoidCallback? onDiscard]})` is the same guard on its own.

### T5 EditorPage (`editor_page.dart`)

`EditorPage({required String title, required VoidCallback? onPrimary, [List<Widget> Function(BuildContext)? children, WidgetBuilder? canvas, Widget? views, List<Widget> actions, List<Widget> banners, String primaryLabel = 'Save', Key? primaryKey, String? secondaryLabel, VoidCallback? onSecondary, Key? secondaryKey, String? missing, bool dirty = false, String discardWhat = 'this automation', VoidCallback? onDiscard, OmniLoad state, Widget? empty]})`. Give exactly one of `children` (the padded sentence list) or `canvas` (the diagram, edge to edge). The title is small from the start. While loading, the title is the summary name or "Automation", never the id.

```dart
return EditorPage(
  title: name.isEmpty ? 'Automation' : name,
  actions: [moreMenu],
  views: OmniSegmented(segments: const [OmniSegment(0, 'Sentence'), OmniSegment(1, 'Diagram')], selected: view, onChanged: setView),
  state: OmniLoad.flags(loading: draft == null, error: loadError, onRetry: reload),
  dirty: draft?.dirty ?? false,
  secondaryLabel: 'Test run',
  onSecondary: testRun,
  onPrimary: missingPart == null ? save : null,
  missing: missingPart,
  children: view == 0 ? (context) => sentenceRows : null,
  canvas: view == 1 ? (context) => DiagramViewer(draft: draft!) : null,
);
```

### T6 SheetTemplate and PromptSheet (`sheet_template.dart`)

`SheetTemplate({required List<Widget> Function(BuildContext) children, [String? title, String? subtitle, Widget? trailing, Widget? pinned, String? primaryLabel, VoidCallback? onPrimary, Key? primaryKey, bool destructive = false, String? secondaryLabel, VoidCallback? onSecondary, String? missing, OmniLoad state, Widget? empty, List<Widget> banners]})`, opened with `SheetTemplate.show<T>(context, builder: ...)`. The action row is pinned under the scroll and above the system bar. `destructive` fills the primary red.

```dart
await SheetTemplate.show<void>(context, builder: (_) => SheetTemplate(
  title: 'Pins',
  state: OmniLoad.of(pins, isEmpty: (p) => p.isEmpty),
  primaryLabel: 'Save',
  onPrimary: save,
  children: (context) => [for (final p in pins.requireValue) PinRow(p)],
));
```

`showPromptSheet(BuildContext context, {required String title, required String label, [String? message, String initial = '', String action = 'Save', String? hint, TextInputType? keyboardType, int? maxLength, bool allowEmpty = false, String? Function(String)? validate]})` returns the trimmed text or null. It replaces every `AlertDialog` with a `TextField`. `PromptSheet` is its body.

```dart
final name = await showPromptSheet(context, title: 'Rename the room', label: 'Name', initial: room.name,
    validate: (t) => taken(t) ? 'Another room has that name.' : null);
if (name != null) await api.saveRoom(id: room.id, name: name, order: room.order);
```

### T7 PickerSheet (`picker_sheet.dart`)

`showPickerSheet<T>(BuildContext context, {required String title, required List<PickerSection<T>> sections, [String? subtitle, T? selected, OmniLoad state, String? addLabel, VoidCallback? onAdd, int searchFrom = 8]})` returns the picked value or null. `PickerSheet<T>` takes the same. `PickerSection<T>(List<PickerItem<T>> items, {String? title})` and `PickerItem<T>({required T value, required String title, [String? subtitle, IconData? icon, Key? key]})`. A search field is pinned once there are more than `searchFrom` choices, the current one is marked and checked, and `addLabel` adds a last row that closes the sheet and runs `onAdd`.

```dart
final room = await showPickerSheet<String>(context,
  title: 'Room',
  selected: device.room,
  sections: [PickerSection([for (final r in rooms) PickerItem(value: r.id, title: r.name, icon: OmniIcons.room)])],
  addLabel: 'Add a room',
  onAdd: addRoom,
);
```

### T8 StepFlow (`step_flow.dart`)

`StepFlow({required String title, required int count, required int current, required List<Widget> Function(BuildContext) children, required VoidCallback? onPrimary, [String? heading, String? why, String primaryLabel = 'Next', Key? primaryKey, String? missing, VoidCallback? onSkip, String skipLabel = 'Skip', VoidCallback? onBack, String backLabel = 'Back', VoidCallback? onHelp, bool close = true, List<Widget> actions, OmniLoad state, List<Widget> banners]})`. The step bar stays under the title, the step's buttons stay in the bottom bar (Back, Skip, the primary), and the done step passes `primaryLabel: 'Done'` with no skip or back.

```dart
return StepFlow(
  title: 'Set up the hub',
  count: 3,
  current: step,
  heading: 'Find the hub',
  why: 'The phone and the hub need to be on the same Wi-Fi.',
  state: OmniLoad.flags(loading: progress == null, error: stepError, onRetry: retry),
  onBack: step > 1 ? back : null,
  onSkip: skip,
  onHelp: showWhatToTry,
  onPrimary: found ? next : null,
  missing: 'Turn the hub on to go on.',
  children: (context) => [OmniHeroCard(title: 'Looking for the hub', centered: true, icon: OmniIcons.hub)],
);
```

### Migrating a screen

1. Pick the template by kind: tab root -> `TabPage`; pushed list -> `ListPage`; one thing -> `DetailPage`; fields with Save -> `FormPage` (settings toggles -> `FormPage.instant`); rule or scene editor -> `EditorPage`; any sheet -> `SheetTemplate`; one-field text prompt -> `showPromptSheet`; pick one from a list -> `showPickerSheet`; guided setup -> `StepFlow`. The per-screen mapping is in `docs/ui/page-templates.md`.
2. Replace `OmniTabPage`, `OmniPage`, `OmniSheet` and raw `Scaffold`s with the template. Use `showOmniSheet` or `SheetTemplate.show`, never `showModalBottomSheet`.
3. Pass the provider through `OmniLoad.of(...)` (or `OmniLoad.flags`) and delete the screen's own loading, error and empty branches: centred `CircularProgressIndicator`s, blank `SizedBox`es, private skeletons (`_Skeleton`, `_RowSkeleton`, `_Loading`), `FunEmptyState`, `_Quiet`, caption `Text` empties, `TvLoading` and `TvLoadError`. `EngineSilent` stays only as an `empty`/error copy if its words are wanted; its retry goes in `onRetry`.
4. Move the commit button out of the scroll into the template's bar (`onCommit`, `onPrimary`). Move a page FAB to a header `OmniIconAction`.
5. Delete hand-written bottom spacers (`SizedBox(height: 88)`, `right: 88`, `OmniSpace.xl` at the end of a list) and the screen's own `PopScope` discard dialog (`dirty:` does it).
6. Replace `AlertDialog` text prompts with `showPromptSheet`, and pass `destructive: true` to every `confirm` that removes or deletes.
7. Replace `Text(style: OmniText.titleMedium)` headings in bodies with `OmniSectionHeader`, any `OmniColors.*` in screens with its `OmniPalette.of(context)` field, and literal radii, font sizes and paddings with tokens.
8. Keep the screen's test keys working: pass `commitKey` / `primaryKey` where a test taps a key, or update the test to the template keys above.

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
