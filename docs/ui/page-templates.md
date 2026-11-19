# OmniFlow app: page templates

> Status: audit, read-only. Source: `packages/omniflow_app/lib/ui/**` as on disk 2026-11-17. Method: reads and greps only, no emulator. Every bug cites file:line and was confirmed by reading the exact code path unless it says "suspected".

Paths below are relative to `packages/omniflow_app/lib/ui/`.

## 1. What exists today

### Design layer

- `design/headers.dart`: `OmniTabPage` (tab root, 28 -> 22 collapsing title, icon actions, `heroTitle` for Home, `SafeArea(bottom: false)`), `OmniPage` (pushed page, back or close, large title that slides into the bar, `bottom` slot pinned under the body, `floatingActionButton`, `padded`, `large`), `OmniScreenTitle`, `OmniSectionHeader`.
- `design/sheet.dart`: `showOmniSheet` (root navigator, scrim, 28 radius, `useSafeArea: true`) and `OmniSheet` (own drag handle, title, subtitle, trailing, children in a `SingleChildScrollView`, keyboard inset).
- `design/list_row.dart` `OmniListRow` + `StatusDot`. `design/card.dart` `OmniCard`, `OmniHeroCard`. `design/tile.dart` `OmniTile`, `OmniTileSkeleton`, `OmniIconBox`.
- `design/buttons.dart` `OmniButton` (primary, ghost, danger), `OmniIconAction`. `design/banner.dart` `OmniBanner` and `OmniEmptyState`. `design/skeleton.dart` `OmniShimmer`, `OmniBone`, `OmniListSkeleton`. `design/progress.dart` `OmniProgressBar`, `OmniStepBar`. `design/confirm.dart` `confirm`.
- `design/tokens.dart` `OmniSpace` (4, 8, 10, 12, 14, 16, 24, 40, target 48), `OmniInsets.fabClearance` / `OmniInsets.bottom`, `OmniRadii`, `OmniText`, `OmniColors` (static teal) and `OmniPalette` (theme extension that changes with Appearance: teal, wallpaper colours, pure black).
- The FAB is not per page. `shell/shell.dart:261` puts one `FloatingActionButton.extended` on the shell Scaffold for the tab root, driven by `shell/tabs.dart` (`Add` on Home and Devices, `New` on Automations, none on Settings).

Totals from the greps: 0 `CustomScrollView` or slivers anywhere, 54 `MaterialPageRoute` pushes against 4 `OmniContainerRoute`, 4 raw `Scaffold`s outside the design layer (`home_screen.dart:65`, `empty_home.dart:79`, `first_run.dart:85`, the shell), 1 raw `showModalBottomSheet` (`device_sections.dart:126`), 6 `AlertDialog` text prompts, 56 uses of the static `OmniColors.accent` in screens against 11 of `OmniPalette.of(context).accent`.

### Inventory

Kinds: Tab = tab root, Page = pushed page, Sheet = bottom sheet, Dialog, Part = a body embedded in another page. Header: L = large collapsing, S = small (`large: false`), C = custom, none. "Off-token" lists literals outside the tokens found by grep (font sizes, radii, colours, numeric paddings).

| File | Kind | Scaffold | Header | Body | Primary action | Empty / loading / error | Off-token |
| --- | --- | --- | --- | --- | --- | --- | --- |
| home/home_screen.dart `HomeScreen` | Tab | `OmniTabPage(heroTitle, padded: false)`; raw `Scaffold` on error | L (hero) | sectioned list: hero, notices, chips, tile grid, rooms, run grid | shell FAB Add | `_Loading` tile skeletons; `EngineSilent` in a raw Scaffold with no title or actions (:65) | - |
| home/home_screen.dart `RoomDevicesPage` | Page | `OmniPage` | L | flat list | none | no empty or loading | list has no bottom padding |
| home/home_screen.dart `showFavourites`, `showNeedsYou` | Sheet | `OmniSheet` | sheet title | list | row tap | Needs you has `OmniEmptyState` | - |
| home/empty_home.dart | Tab (state) | raw `Scaffold` + `SafeArea(bottom: false)` | none (empty state is the title) | empty state + candidate rows | inline `OmniButton.ghost` | is the empty state | - |
| home/first_run.dart | Full screen | raw `Scaffold` + `SafeArea` | none | empty state (large) + rows | inline `OmniButton` | - | - |
| home/energy_card.dart `EnergyPage` | Page | `OmniPage` | L | hero + sections | `AlertDialog` for price (:261) | none | - |
| home/search_page.dart | Page | `OmniPage` | L | search field + sections (Do it, Devices, Automations, Settings, Try) | row tap | info banner | - |
| home/house_switcher.dart | Sheet + Dialog | `OmniSheet`; `AlertDialog` rename (:123) | sheet title | list | Add a house row | - | - |
| home/mode_picker.dart, room_tile.dart, quick_sheet.dart | Sheet | `OmniSheet` | sheet title | list / controls | row tap, ghost button | quick sheet: "Not here any more", error banner | - |
| home/run_section.dart, suggestion_card.dart, timer_strip.dart, home_hero.dart, home_notices.dart | Part | - | section header | grid / card | inline | spinner in run tile (:338) | - |
| onboarding/home_setup.dart | Page (step flow) | `OmniPage` + `TextButton` Not now action | L | step bar + step body | inline `OmniButton`s; Back / Skip `TextButton`s at end of the list (:228) | spinner while progress loads (:214) | own `_StepBar` (:441), radius 2 (:478) |
| onboarding/start_options.dart | Part | - | section header | rows | row tap | - | - |
| help/help_sheet.dart, screen_help.dart, setting_help.dart | Sheet | `OmniSheet` | sheet title | text + rows | inline `OmniButton` | - | - |
| fun/your_home_page.dart | Page | `OmniPage` | L | sectioned list + grid | none | `FunEmptyState`; centred spinner; `_Quiet` text with no retry (:66-70) | - |
| fun/home_stats.dart, home_today_card.dart, week_bars.dart | Part | - | - | cards | - | - | - |
| automations/automations_screen.dart | Tab | `OmniTabPage` | L + subtitle, search toggles inline field | chips + banners + card list | shell FAB New (hidden when no rules) | `OmniEmptyState`, own `_Skeleton` (:604), error banner in a list; inline caption text for filter-empty (:225, :250) | `right: 88` (:172), spacer 88 (:286), radius 6 (:626), fontSize 12 (:570) |
| automations/automation_page.dart | Page (router) | `OmniPage` while loading | L, title = raw id (:64) | spinner / empty state, then hands to editor, scene editor, review or test run | - | spinner, `OmniEmptyState` with retry | - |
| automations/rule_editor.dart | Page (editor) | `OmniPage` + `PopScope` | L, `PopupMenuButton` more | Sentence `ListView` or Diagram canvas, picked by `OmniSegmented` inside the body | `bottom:` Test run + Save | spinner, empty states, warning and error banners | raw `TextStyle` (:460) |
| automations/rule_blocks.dart block page (:626), Keep page (:863) | Page | `OmniPage` | L | rule blocks | block page: none (edits in place); Keep page: `bottom:` Done (:925) | - | fontSize 12 (:402) |
| automations/diagram/diagram_editor.dart, diagram_view.dart | Part (canvas) | inside rule editor | - | `InteractiveViewer` canvas, list fallback | node tap, "+" | spinner, empty state, error banner, 2 px progress | `boundaryMargin 120` |
| automations/diagram/run_view.dart `RunPage` | Page | `OmniPage(large: false)` | S | diagram + run section | none | - | - |
| automations/test_run.dart `TestRunPage`, run detail (:490) | Page | `OmniPage` | L | banners + run list | inline Run it now (:376) | spinners, empty states, error banners | - |
| automations/review_page.dart | Page | `OmniPage` | L | banners + sections | `bottom:` Reject + Approve | spinner, empty state with retry | - |
| automations/scenes.dart list (:79), editor (:333) | Page | `OmniPage` | L | list / form | list: `bottom:` ghost New scene; editor: `bottom:` Save | spinner, empty state, error banner | - |
| automations/new_automation.dart chooser (:67), template page (:298) | Sheet + Page | `OmniSheet`; `OmniPage` | sheet title; L | template sections; form | row tap; `bottom:` Save | spinner, error banner | - |
| automations/pickers.dart | Page (picker) | `OmniPage` | L | search field + sections | row tap | `OmniEmptyState` no match | - |
| automations/library_sheet.dart, form_parts.dart param sheet (:510), look_picker.dart, link_sheet.dart, capture_scene.dart, type_it_page.dart | Sheet | `OmniSheet` | sheet title | search + sections / form | inline `OmniButton` at the end | empty states, spinners, error banners | look_picker `Color(0xFF000000 \| v)` (:32) |
| automations/removed_page.dart | Page | `OmniPage` | L | list | row action | `OmniEmptyState`, `OmniListSkeleton` | - |
| automations/suggestions_page.dart | Page | `OmniPage` | L | list | row tap | spinner | - |
| automations/sun_lighting_page.dart | Page (form) | `OmniPage` | L | sections + sliders | inline Save the range mid-list (:224) | info banner | radius 2 (:362) |
| automations/dialogs.dart | Dialog | `AlertDialog` + `TextField` | - | - | - | - | - |
| automations/automation_insights.dart, sentence_row.dart, token_field.dart, step_forms.dart, trigger_pickers.dart, condition_pickers.dart, phone_pickers.dart, timer_forms.dart, web_headers.dart | Part | - | section headers | rows, segmented, fields | inline | `LinearProgressIndicator` (insights :159, :176) | fontSize 13 (sentence_row :73), 12 (token_field :233) |
| devices/devices_screen.dart | Tab | `OmniTabPage` | L, search icon opens global Search | segmented + inline filter field + sectioned list; two panes when wide | shell FAB Add | `OmniListSkeleton`, `EngineSilent`, `OmniEmptyState` | - |
| devices/open_device.dart `DeviceRoute` | Page (router) | `OmniPage` | L "Device" | skeleton / not-found empty state, then hands to the kind's page | - | yes | - |
| devices/device_page.dart | Page (detail) | `OmniPage` | L, star + more | warnings + `OmniHeroCard` + sections | power on hero | blank `SizedBox` when the device is null (:89) | - |
| devices/sensor_page.dart | Page (detail) | `OmniPage` | L | hero + chart + sections | ghost button | blank `SizedBox` when null (:47) | radius 2 (:168) |
| devices/weather_page.dart | Page (detail) | `OmniPage` | L | hero + sections | none | info banner | - |
| devices/device_sections.dart | Part + Sheets + Dialog | `OmniSheet`; raw `showModalBottomSheet` (:126); `AlertDialog` room name (:545) | - | sections | danger Remove | spinners, banners | - |
| devices/host_key_sheet.dart | Sheet | `OmniSheet` | sheet title | banners + rows | inline buttons | spinner, banners | - |
| devices/capability_control.dart, device_controls.dart | Part | - | section header | controls | - | - | 5 colour literals (device_controls :166-170) |
| tv/tv_page.dart | Page (detail with tabs) | `OmniPage(padded: false)` | L, power + more | banners + `TvHeader` + chip tabs + tab body | header power | error banner | - |
| tv/tv_remote.dart, phone_remote.dart, tv_mouse.dart, tv_screen.dart, tv_system.dart, tv_console.dart | Part (TV tab) | inside `TvPage` | section headers | keypads, canvas, lists | inline | `TvLoading` spinner, `TvLoadError`, spinners | colour literals (remote :76-79, :264; console :20-21), fontSize 13/18 (remote :446), radii 10/16/12/4 (mouse :426 :518, screen :315, system :213) |
| tv/tv_apps.dart | Part (TV tab) + sheets + dialog | `OmniSheet`, `AlertDialog` (:265) | - | search + list | row tap | `OmniListSkeleton`, `OmniEmptyState`, `TvLoadError` | - |
| tv/tv_files.dart | Part (TV tab) + sheets + dialog | `Stack` with a `Positioned` action bar (:534) | breadcrumbs | list | own bottom bar while selecting | `TvLoading` spinner, `OmniEmptyState`, `TvLoadError` | padding `14, 0, 14, 96/24` (:482), `Positioned 12/12/14` (:534), radius 16 (:694), fontSize 12 (:815) |
| tv/tv_settings.dart tab, raw key page (:447) | Part + Page | `OmniPage` for the key page | L | search + sections | row tap | `TvLoading`, `TvLoadError`, `OmniEmptyState` | `bottom: 24` (:606) |
| tv/tv_widgets.dart | Part + Dialog | `AlertDialog` text prompt (:379) | - | - | - | `TvLoading`, `TvLoadError` | 20 brand colours (:56-77), fontSize 13 (:207) |
| boards/board_page.dart | Page (detail) | `OmniPage` | L | hero + pins + extras | row tap, ghost add pin | empty states, banners | - |
| boards/add_pin_page.dart | Page (form) | `OmniPage` | L | fields + sections | `bottom:` Save (:143) | spinner, banners | radius 8 (:341), fontSize 13 (:355) |
| boards/pin_sheet.dart, board_extras.dart, firmware_sheet.dart, usb_board.dart | Sheet | `OmniSheet` | sheet title | form | inline buttons at end | spinners, banners, progress | - |
| tags/tags_page.dart | Page (list) | `OmniPage` | L | list | header action opens add sheet | `OmniListSkeleton`, `OmniEmptyState`, error banner | - |
| tags/tag_page.dart | Page (detail) | `OmniPage` | L | hero + sections | ghost buttons | own `_Loading` (:405), empty state, error banner | - |
| tags/write_tag_sheet.dart | Sheet | `OmniSheet` | none | hero + buttons | inline | - | - |
| add/add_page.dart | Page (list) | `OmniPage(close: true)` | L | found / added / by-hand sections | row tap | own `_RowSkeleton` (:282), banners | - |
| add/add_by_hand_page.dart | Page (form) | `OmniPage` + `PopScope` | L | kinds list, then fields | `bottom:` Add (:208) | spinner, empty state, banners | - |
| add/add_phone_page.dart | Page (step-like form) | `OmniPage` | L | segmented route + numbered sections | inline buttons per section | banners | - |
| add/guided_steps_page.dart | Page (step flow) | `OmniPage` | L | `OmniStepBar` + hero per step | inline `OmniButton`s in the body | spinner, error banner | - |
| add/name_sheet.dart, pair_sheet.dart, room_field.dart | Sheet | `OmniSheet` | sheet title | form | inline at end | banners | - |
| settings/settings_screen.dart | Tab | `OmniTabPage` | L | sectioned rows | none | - | - |
| settings/appearance_page.dart, alerts_page.dart, away_lighting_page.dart, phone_access.dart | Page (instant settings) | `OmniPage` | L | sectioned rows and switches | none (changes apply at once) | phone_access: blank page while loading (:408) | - |
| settings/home_location_page.dart, places_page.dart | Page (detail + form) | `OmniPage` | L | hero + sections + fields | inline buttons | banners; places: blank 52 px box while zones load (:238); `AlertDialog` beacon (:120) | - |
| settings/hub_page.dart, hubs_page.dart | Page (detail + steps) | `OmniPage` | L | hero + numbered sections | inline buttons | spinner, banners | - |
| settings/backup_page.dart, whats_new.dart | Page | `OmniPage` | L | sections | inline buttons | spinner, banners | - |
| settings/rooms_page.dart | Page (list) | `OmniPage` | L | `ReorderableListView` | `bottom:` Add room (:70) | empty state | - |
| settings/variables_page.dart | Page (list) | `OmniPage` + its own FAB (:193) | L | list + section | page FAB Add | `OmniListSkeleton`, `OmniEmptyState`, error banner | - |
| settings/developer_page.dart, inspector.dart | Page (tabs) | `OmniPage` | L | segmented + lists | ghost buttons | empty state | - |
| settings/agent_access.dart, shake_scene.dart | Part + Sheet | `OmniSheet` picker | sheet title | list | row tap | - | - |
| shell/shell.dart, tabs.dart, hub_banner.dart | Shell | `Scaffold` + `NavigationBar` / rail + shell FAB | - | `IndexedStack` of tab navigators | FAB per tab root | hub banner above every tab | - |

Helpers with no UI of their own: `automations/rule_words.dart`, `rules_core_*`, `automations_state.dart`, `phone_words.dart`, `step_library.dart`, `diagram/diagram_layout.dart`, `diagram_painter.dart`, `rule_paths.dart`, `view_prefs.dart`, `devices/device_text.dart`, `smart_home_sections.dart`, `home/home_data.dart`, `home_helpers.dart`, `home_presence.dart`, `tile_look.dart`, `tv/tv_controller.dart`, `tv_frame.dart`, `boards/board_pins.dart`, `tags/nfc_forwarder.dart`, `fun/confetti.dart`, `springy_press.dart`, `breathing_mark.dart`, `fun_prefs.dart`, `add/driver_kinds.dart`, `shell/links.dart`.

### What the inventory shows

- Two scaffolds already cover almost everything: `OmniTabPage` for the 4 tab roots and `OmniPage` for about 45 pushed pages. The drift is inside them, not around them.
- Loading has six shapes: `OmniListSkeleton`, `OmniTileSkeleton`, three private skeletons (automations `_Skeleton`, add `_RowSkeleton`, tag `_Loading`), a centred `CircularProgressIndicator` (19 files), `TvLoading`, and a blank `SizedBox`.
- Empty has four: `OmniEmptyState`, `FunEmptyState`, `_Quiet`, and a plain caption `Text`.
- Error has three: `OmniBanner.error` in a list, `EngineSilent`, `TvLoadError` (a wrapped banner), plus `OmniEmptyState` with an error icon for a page that failed to open.
- Primary action sits in five places: the shell FAB, a page FAB (Variables only), `OmniPage.bottom`, an inline button at the end of the list, and a header icon.
- Step flows are built three ways: `guided_steps_page` (`OmniStepBar`, buttons in the hero), `home_setup` (own `_StepBar`, Back and Skip as text buttons at the end of the list), `hub_page` and `add_phone_page` (numbered section headers).
- Text prompts are a sheet in `add/name_sheet.dart` and `room_field.dart` but an `AlertDialog` in six other places.
- Search is three patterns: Home and Devices open the global Search page, Automations toggles an inline field in its list, Devices also has a filter field under its segmented control, and pickers put a field at the top.

## 2. Templates to adopt

Eight templates, each a thin wrapper in `design/templates/` that composes the existing components. A screen picks one and fills slots. It never builds its own scaffold, header, loading, empty or error widget.

### Shared rules (all templates)

1. **Header per kind.** Tab roots: large collapsing title (`OmniScreenTitle`). Pushed pages: large title that slides into the bar (`OmniPage`, `large: true`). Editors and run views: small title from the start (`large: false`). Sheets: `OmniSheet` title. No screen draws its own title row.
2. **One back affordance.** The `OmniPage` chevron. The cross (`close: true`) only for a flow that is entered modally and can be left without saving (Add, setup flows). "Not now" in home_setup becomes that cross.
3. **One section header.** `OmniSectionHeader`, with the trailing count or action. No `Text(style: OmniText.titleMedium)` headings inside bodies (`home_setup.dart:257`).
4. **One list row family.** `OmniListRow` for every row that opens, toggles or picks. `OmniStepRow` only inside rule blocks. `OmniTile` only in grids.
5. **One primary button placement.** A page's commit action (Save, Done, Add, Approve) goes in the template's bottom bar (`OmniPage.bottom`), never inline at the end of a scroll. Secondary actions sit beside it as ghost. A page with instant settings has no bottom bar.
6. **One FAB rule.** Only a tab root has a FAB, and only the shell draws it. A pushed list's add action is a header `OmniIconAction` or the bottom bar. Every scrolling body under a FAB gets `OmniInsets.fabClearance(context)` as bottom padding from the template, not a hand-written spacer.
7. **One empty state.** `OmniEmptyState`, with an action whenever the user can fix it. A filtered-to-nothing list uses it too, with `compact: true` (new parameter, smaller padding, no icon).
8. **One loading component.** `OmniListSkeleton` for lists, `OmniTileSkeleton` for grids, a new `OmniPageSkeleton` (hero bone + 3 rows) for detail pages. No centred spinner for a whole page, no blank `SizedBox`. Inline progress (a busy row, a transfer) keeps `OmniProgressBar`.
9. **One error banner.** `OmniBanner.error` with Try again, at the top of the body. A page that cannot open at all shows `OmniEmptyState(icon: error)` with Try again. `EngineSilent` and `TvLoadError` become thin presets of these two.
10. **Spacing.** Body horizontal padding is `OmniSpace.screenPadding` from the template. Gaps use `OmniSpace` only. Bottom padding is `OmniInsets.bottom` or `fabClearance`, never a literal. Radii from `OmniRadii`, text from `OmniText`, colours from `OmniPalette.of(context)` for anything the Appearance page changes.
11. **State in one switch.** Each template takes an `AsyncValue<T>` (or `loading` / `error` / `isEmpty` flags) and renders skeleton, error and empty itself, so a screen only writes the data case.
12. **Text input.** A one-field prompt is `PromptSheet` (a `SheetTemplate` preset), not an `AlertDialog`. `confirm` stays the only dialog, with `destructive: true` on every remove or delete.

### T1 TabPage

- Purpose: the root of each of the 4 tabs.
- Structure: large collapsing title with subtitle; optional house chip (the `HouseSwitcher`) under the title on Home, Automations and Devices, the three tabs whose content is per house; header actions (search, help, notifications); optional pinned filter row (segmented or chips) above the scroll; sectioned scroll body; shell FAB with `fabClearance` applied by the template; `SafeArea(bottom: false)` as today because the tab bar takes the inset.
- Builds on: `OmniTabPage`. Add `house`, `filters`, `state` slots and a `TabPage.sections(...)` body that pads for the FAB.
- Built in: skeleton by `layout` (tiles or rows), `OmniBanner.error` with Try again on the cached list (or full-page error empty state when nothing is cached), `OmniEmptyState` with the tab's primary action.
- Moves on: `home/home_screen.dart` (drop the raw Scaffold error path), `home/empty_home.dart` (becomes Home's empty state), `automations/automations_screen.dart`, `devices/devices_screen.dart`, `settings/settings_screen.dart`. `first_run.dart` stays full screen (StepFlow intro).
- Search: one rule. The header search icon always opens global Search filtered to the tab's scope. The inline filter field in Devices and the toggle in Automations become the same pinned `filters` search field.

### T2 ListPage

- Purpose: a pushed list of many things of one kind.
- Structure: large title; header actions (add as `OmniIconAction`, more); optional pinned search field; optional filter chips; sections of `OmniListRow`; optional bottom bar for a bulk or commit action; bottom padding `OmniInsets.bottom`.
- Builds on: `OmniPage` + `OmniSectionHeader` + `OmniListRow`, lazy `ListView.builder` over a flat item list with section markers.
- Built in: `OmniListSkeleton`, error banner with retry, `OmniEmptyState` for none and the compact variant for "nothing matches".
- Moves on: `home/search_page.dart`, `home/home_screen.dart` `RoomDevicesPage`, `automations/removed_page.dart`, `automations/suggestions_page.dart`, `automations/scenes.dart` list, `automations/pickers.dart` (multi-level step, trigger and condition pickers stay pushed because they nest further pages), `tags/tags_page.dart`, `settings/variables_page.dart` (FAB -> header add), `settings/rooms_page.dart` (reorderable mode), `settings/hubs_page.dart`, `settings/developer_page.dart` (with a pinned segmented filter), `fun/your_home_page.dart`, `settings/whats_new.dart`, `add/add_page.dart` (`close: true`), `tv/tv_settings.dart` raw key page.

### T3 DetailPage

- Purpose: one thing (device, sensor, tag, board, place, hub, run).
- Structure: large title = the thing's name; header actions (star, more menu); top banners slot (offline, needs pairing); `OmniHeroCard` hero with its primary control (power, reading); sections; optional tab chips under the hero (TV); bottom padding from the template.
- Builds on: `OmniPage` + `OmniHeroCard` + `OmniSectionHeader`.
- Built in: `OmniPageSkeleton` while loading, not-found `OmniEmptyState` when the thing is gone (the `DeviceRoute` copy moves here), error banner on refresh failure.
- Moves on: `devices/device_page.dart`, `devices/sensor_page.dart`, `devices/weather_page.dart`, `devices/open_device.dart` (its loading and not-found move into the template), `tv/tv_page.dart` (tabs variant, unpadded tab body), `boards/board_page.dart`, `tags/tag_page.dart`, `settings/places_page.dart`, `settings/home_location_page.dart`, `settings/hub_page.dart` (connected state), `home/energy_card.dart` `EnergyPage`, `automations/test_run.dart` (both pages), `automations/diagram/run_view.dart`, `automations/review_page.dart` (with a decision bottom bar).

### T4 FormPage

- Purpose: create or edit one thing with fields.
- Structure: large title (`New ...` or the name); body of field groups under section headers; sticky bottom bar with the commit button (Save, Done, Add) and an optional ghost secondary; a "what is missing" caption above the button when it is disabled; `PopScope` discard guard when dirty; keyboard handled by the Scaffold.
- Instant variant: same body, no bottom bar, each control applies at once (settings toggles).
- Builds on: `OmniPage(bottom:)` and the discard `confirm` already in `rule_editor.dart` and `scenes.dart`.
- Built in: load skeleton when editing an existing thing, error banner at the top for a failed save with the field issues, disabled commit with the reason.
- Moves on: `add/add_by_hand_page.dart`, `boards/add_pin_page.dart`, `automations/scenes.dart` editor, `automations/new_automation.dart` template page, `automations/rule_blocks.dart` block page and Keep page (both get Done), `automations/sun_lighting_page.dart` (Save the range moves to the bar), instant variant for `settings/appearance_page.dart`, `alerts_page.dart`, `away_lighting_page.dart`, `phone_access.dart`, `backup_page.dart`.

### T5 EditorPage

- Purpose: the rule editor and its two views.
- Structure: small title (`large: false`) so the canvas gets the height; more menu; Sentence and Diagram segmented control pinned under the bar, outside the scroll; banners slot; body is the sentence `ListView` (padded) or the diagram canvas (unpadded, edge to edge); sticky bottom bar Test run + Save with the missing-part caption; `PopScope` discard guard.
- Builds on: the current `RuleEditorPage` build (`rule_editor.dart:396-565`), lifted into a template so the scene editor can share the bar and guard.
- Built in: `OmniPageSkeleton` while loading (title from the list summary, never the id), load-failed empty state with retry, not-a-rule empty state.
- Moves on: `automations/rule_editor.dart`, `automations/diagram/diagram_editor.dart` (its loading and failure states use the template's), `automations/automation_page.dart` (its loading view uses the template's skeleton and a summary-or-"Automation" title).

### T6 SheetTemplate

- Purpose: every bottom sheet.
- Structure: drag handle; title, subtitle, trailing; scrolling body; optional pinned action row (primary + ghost) outside the scroll; bottom padding = keyboard inset + `MediaQuery.paddingOf(context).bottom` + `OmniSpace.lg`.
- Builds on: `showOmniSheet` + `OmniSheet`. Add the `actions` slot and the system-bar inset. Presets: `PromptSheet` (one text field + Save, replaces the six `AlertDialog` prompts) and `ConfirmSheet` is not needed (keep `confirm`).
- Built in: inline skeleton rows, error banner at the top of the body, empty state compact.
- Moves on: every `OmniSheet` user: `add/name_sheet.dart`, `pair_sheet.dart`, `room_field.dart`, `automations/capture_scene.dart`, `link_sheet.dart`, `type_it_page.dart`, `form_parts.dart` (:20 sheet), `new_automation.dart` chooser, `boards/pin_sheet.dart`, `board_extras.dart`, `firmware_sheet.dart`, `usb_board.dart`, `tags/write_tag_sheet.dart`, `tags/tags_page.dart` add sheet, `tags/tag_page.dart` sheet, `devices/host_key_sheet.dart`, `device_sections.dart` settings sheet (:438) and the raw sheet (:126), `home/quick_sheet.dart`, `room_tile.dart`, `home_screen.dart` favourites and needs-you sheets, `help/help_sheet.dart`, `settings/alerts_page.dart` add sheet, `whats_new.dart` sheet, `tv/tv_apps.dart` sheets, `tv/tv_files.dart` sheets, `tv/tv_page.dart` device sheet. Prompts: `home/energy_card.dart:261`, `home/house_switcher.dart:123`, `settings/places_page.dart:120`, `automations/dialogs.dart:14`, `devices/device_sections.dart:545`, `tv/tv_widgets.dart:379`.

### T7 PickerSheet

- Purpose: pick one item from a list (a mode, a room, a scene, a template, a param value, an app).
- Structure: SheetTemplate with a pinned search field once the list passes 8 items; sections (Suggestions first, then groups); `OmniListRow` per choice with a check on the current one; returns the choice on tap; "Add new" row at the end when the list can grow.
- Builds on: `library_sheet.dart` (`showLibrary`), which already does search + suggestions + sections.
- Built in: skeleton rows while choices load, compact empty for no match, error banner.
- Moves on: `automations/library_sheet.dart` (becomes the template), `automations/form_parts.dart` param choice (:472, :510), `automations/look_picker.dart`, `home/mode_picker.dart`, `home/house_switcher.dart` list, `devices/device_sections.dart` room picker (:496), `settings/agent_access.dart`, `settings/shake_scene.dart`, `tv/tv_page.dart` tab picker (:119), `automations/pickers.dart` single-level choice (:270), `tags/tag_page.dart` choice (:157), `boards/board_page.dart` choice (:124).

### T8 StepFlow

- Purpose: a guided setup with ordered steps.
- Structure: close cross; title "Set up X" / "Add X"; `OmniStepBar` under the bar; step heading + why line; step body (hero, fields, permission rows); sticky bottom bar with the step's primary action, Skip as ghost and Back as the leading text button; done step with a single Done.
- Builds on: `OmniPage(close: true, bottom:)` + `OmniStepBar`.
- Built in: skeleton while progress loads, error banner per step with retry, the "what to try" help sheet slot.
- Moves on: `add/guided_steps_page.dart`, `onboarding/home_setup.dart` (drop `_StepBar`), `settings/hub_page.dart` connect flow (:352, sections "1. Find the hub" ...), `add/add_phone_page.dart` pair routes, `home/first_run.dart` (intro step, full screen).

## 3. Migration plan

Batch 0 lands first because every other batch imports it. Batches 1 to 3 then run in parallel: each owns a disjoint set of files, and cross-folder calls only change at the call site inside the owning batch (for example `device_sections.dart` switches its raw sheet to `showOmniSheet` in batch 1 while `link_sheet.dart` itself stays in batch 2).

### Batch 0: design layer (one builder, small)

- New: `design/templates/tab_page.dart`, `list_page.dart`, `detail_page.dart`, `form_page.dart`, `editor_page.dart`, `sheet_template.dart`, `picker_sheet.dart`, `step_flow.dart`, `design/templates/templates.dart`.
- Change: `design/sheet.dart` (actions slot, bottom system inset, palette handle colour), `design/headers.dart` (house and filters slots on `OmniTabPage`), `design/skeleton.dart` (`OmniPageSkeleton`), `design/banner.dart` (`compact` empty state, `OmniText` styles instead of raw `TextStyle`), `design/buttons.dart` and `design/list_row.dart` (palette colours), `design/design.dart` (export), `design/README.md`.
- Gate: widget tests for each template's loading, error, empty and data cases; existing a11y tests stay green.

### Batch 1: Home, Devices, TV, boards, tags, fun, help

- `home/home_screen.dart`, `empty_home.dart`, `energy_card.dart`, `search_page.dart`, `house_switcher.dart`, `mode_picker.dart`, `quick_sheet.dart`, `room_tile.dart`, `run_section.dart`.
- `devices/devices_screen.dart`, `open_device.dart`, `device_page.dart`, `sensor_page.dart`, `weather_page.dart`, `device_sections.dart`, `host_key_sheet.dart`.
- `tv/tv_page.dart`, `tv_apps.dart`, `tv_files.dart`, `tv_settings.dart`, `tv_system.dart`, `tv_screen.dart`, `tv_mouse.dart`, `tv_remote.dart`, `tv_console.dart`, `tv_widgets.dart`.
- `boards/board_page.dart`, `add_pin_page.dart`, `pin_sheet.dart`, `board_extras.dart`, `firmware_sheet.dart`, `usb_board.dart`.
- `tags/tags_page.dart`, `tag_page.dart`, `write_tag_sheet.dart`.
- `fun/your_home_page.dart`, `fun/breathing_mark.dart` (retire `FunEmptyState`), `help/help_sheet.dart`.

### Batch 2: Automations, editor and diagram

- `automations/automations_screen.dart`, `automation_page.dart`, `rule_editor.dart`, `rule_blocks.dart`, `scenes.dart`, `new_automation.dart`, `pickers.dart`, `library_sheet.dart`, `form_parts.dart`, `look_picker.dart`, `link_sheet.dart`, `capture_scene.dart`, `type_it_page.dart`, `dialogs.dart`, `removed_page.dart`, `review_page.dart`, `suggestions_page.dart`, `sun_lighting_page.dart`, `test_run.dart`.
- `automations/diagram/diagram_editor.dart`, `diagram_view.dart`, `run_view.dart`.
- Off-token cleanup in `sentence_row.dart`, `token_field.dart`, `diagram/diagram_nodes.dart`.

### Batch 3: Settings, onboarding, add, shell

- `settings/settings_screen.dart`, `appearance_page.dart`, `alerts_page.dart`, `away_lighting_page.dart`, `phone_access.dart`, `home_location_page.dart`, `places_page.dart`, `hub_page.dart`, `hubs_page.dart`, `backup_page.dart`, `whats_new.dart`, `rooms_page.dart`, `variables_page.dart`, `developer_page.dart`, `agent_access.dart`, `shake_scene.dart`.
- `onboarding/home_setup.dart`, `start_options.dart`, `home/first_run.dart`.
- `add/add_page.dart`, `add_by_hand_page.dart`, `add_phone_page.dart`, `guided_steps_page.dart`, `name_sheet.dart`, `pair_sheet.dart`, `room_field.dart`.
- `shell/shell.dart`, `shell/tabs.dart` (FAB visibility rule).

`home/first_run.dart` sits in batch 3 with the other step flows even though it lives under `home/`. Batch 1 must not touch it.

## 4. Code-level UI bugs

Ranked most severe first. All confirmed by reading the code path unless marked suspected. None is listed as open in `docs/ROADMAP.md`. Edge to edge with real insets, an item of the earlier UI and UX audit, is the general goal that bug 1 breaks.

1. **High. Sheet content sits under the system navigation bar.** `design/sheet.dart:18` passes `useSafeArea: true`, which Flutter implements as `SafeArea(bottom: false, ...)` (`flutter/lib/src/material/bottom_sheet.dart:1167`), and `OmniSheet` (`design/sheet.dart:53-60`) pads only the keyboard inset plus 16. The app runs edge to edge (`shell/shell.dart:146`), so on a phone with 3-button navigation the last button of every sheet (Save, Pair, Write it, Remove) sits behind the 48 dp bar. Fix: add `MediaQuery.paddingOf(context).bottom` to the sheet's bottom padding. Confidence: confirmed by reading both sources, not seen on a device.
2. **Medium. Variables FAB covers the last row.** `settings/variables_page.dart:189` ends the list with `SizedBox(height: OmniSpace.xl)` (24) while `:193` adds an extended FAB (56 + 16 margin). The last variable's row and its Clear button sit under the FAB. Fix: `OmniInsets.fabClearance(context)` bottom padding, or move Add to the header per the FAB rule.
3. **Medium. No way to start a new rule from the Automations tab when only scenes exist.** `shell/tabs.dart` hides the New FAB with `automationsAreEmpty` (`automations/automations_screen.dart:638-643`), true when there is no non-scene automation. But `_list` shows the empty state with its New button only when both rules and scenes are empty (`:111`). With scenes and no rules the list shows "No rules yet." (`:261`) and neither button. Fix: hide the FAB only when the empty state is the thing on screen (same condition as `:111`).
4. **Medium. Remove device and Remove room are not marked destructive.** `devices/device_sections.dart:140` (`'Its history is deleted.'`) and `settings/rooms_page.dart:37` call `confirm` without `destructive: true`, so the button is the normal accent, unlike every other Remove (the README rule in `design/README.md`, "red when destructive"). Fix: pass `destructive: true`.
5. **Medium. Raw sheet opened in the tab navigator.** `devices/device_sections.dart:126` uses `showModalBottomSheet` with the default `useRootNavigator: false`, so the Pins and Link sheets open inside the Devices tab navigator: the tab bar stays visible and tappable under the scrim, the sheet takes Material's default colour and shape rather than `OmniPalette.sheet` and the 28 radius, and there is no `useSafeArea`. `PinSheet` and `LinkSheet` draw their own handle, so it is not missing, but the frame differs from every other sheet. Fix: `showOmniSheet`.
6. **Medium. Primary buttons, row values and status dots ignore the Appearance palette.** `design/buttons.dart:60-63` hard-codes `OmniColors.accent` / `accentInk` / `raised` for the primary `OmniButton`, `design/list_row.dart:102` and `:20` use `OmniColors.accent` for the row value and online dot, and `design/sheet.dart:71` uses `OmniColors.line` for the handle. Section header actions use `OmniPalette.of(context).accent` (`design/headers.dart:51`, `:60`). With "Wallpaper colours" chosen on `settings/appearance_page.dart`, primary buttons and values stay teal while headers and the hero follow the wallpaper. Screens add 56 more static `OmniColors.accent` uses. Fix: read the palette in the components first, then sweep screens. Confidence: confirmed that the palette varies (`theme.dart:11`) and that these read the constant; how far off it looks is not seen.
7. **Medium. Device, sensor and phone pages render blank while loading.** `devices/device_page.dart:89` and `devices/sensor_page.dart:47` return `OmniPage(body: SizedBox())` when `liveDevice` is null, and `settings/phone_access.dart:408` does the same while `phoneAccessStateProvider` loads. The user sees a title over an empty page with no skeleton and, for a removed device, no "not here any more" message (that copy exists only in `devices/open_device.dart:47`). Fix: DetailPage's skeleton and not-found state.
8. **Low. Automation and rule pages show the raw id as the title while loading.** `automations/automation_page.dart:64` (`title: widget.id`) when opened without a summary (notifications, search, deep links via `shell/tabs.dart` `AutomationLink`), and `automations/rule_editor.dart:397` (`widget.id ?? 'New automation'`) every time the editor loads, including when pushed from `automation_page.dart`. Fix: pass the summary name through or use "Automation" until loaded.
9. **Low. Your activity error has no retry and points elsewhere.** `fun/your_home_page.dart:67-70` shows "OmniFlow did not answer. Pull Home down to try again." on a page that has no pull-to-refresh and no button. Fix: error banner with Try again that invalidates the provider.
10. **Low. TV load errors say "from the TV" on a phone.** `tv/tv_widgets.dart:341` builds `'$what could not be read from the TV: $reason'`, and `tv/tv_files.dart:515`, `tv_apps.dart:155`, `tv_settings.dart:115` use it on `TvPage(phone: true)` too. Fix: use `tv.noun` as `tv_system.dart:177` does.
11. **Low. Home's engine-error state drops the tab header.** `home/home_screen.dart:65-71` returns a raw `Scaffold` with only `EngineSilent`, so Search, Needs you and help disappear and the page has no title, unlike Devices and Automations which keep their `OmniTabPage` on error. Fix: TabPage error state.
12. **Low. Places shows an empty 52 px gap while zones load.** `settings/places_page.dart:238`. Fix: two skeleton rows.
13. **Low. Home setup's Back and Skip scroll away.** `onboarding/home_setup.dart:228-247` puts them at the end of the `ListView`, so on a long step (permissions) they are below the fold and the bottom of the page has no action. Fix: StepFlow bottom bar.
14. **Low. Home setup draws its own step bar.** `onboarding/home_setup.dart:441-486` duplicates `OmniStepBar` (`design/progress.dart:45`) with a hard-coded radius 2 and its own colours, so the two setup flows look different. Fix: use `OmniStepBar`.
15. **Low. Three private skeletons.** `automations/automations_screen.dart:604-633` (radius 6 literal, static `OmniColors.raised`, no shimmer), `add/add_page.dart:282`, `tags/tag_page.dart:405`. Fix: `OmniListSkeleton` / `OmniPageSkeleton`.
16. **Low. Two more empty-state components.** `fun/breathing_mark.dart:58` `FunEmptyState` and `fun/your_home_page.dart:78` `_Quiet`, plus plain caption `Text` empties in `automations/automations_screen.dart:225-235` and `:250-265`. Fix: `OmniEmptyState` (compact for filtered lists).
17. **Low. TV tabs load with a spinner where the rest of the app uses skeletons.** `tv/tv_widgets.dart:350` `TvLoading` in `tv_files.dart:521` and `tv_settings.dart:117`, `:636`, while `tv_apps.dart:157` uses `OmniListSkeleton`. Fix: skeleton.
18. **Low. Text prompts are dialogs in six places and sheets in two.** `AlertDialog` + `TextField` at `home/energy_card.dart:261`, `home/house_switcher.dart:123`, `settings/places_page.dart:120`, `automations/dialogs.dart:14`, `devices/device_sections.dart:545`, `tv/tv_widgets.dart:379`; sheets at `add/name_sheet.dart:14`, `add/room_field.dart:106`. Fix: `PromptSheet`.
19. **Polish. Two searches on the Devices tab.** `devices/devices_screen.dart:229-235` header search opens the global Search page, while `:203` adds an inline filter field under the segmented control. Automations' header search (`automations_screen.dart:69-77`) filters in place instead. Fix: the TabPage search rule.
20. **Polish. Block page has no Done while the Keep page does.** `automations/rule_blocks.dart:626` (If, Together, Try, Repeat, Wait) edits in place and relies on back, `:925` (Keep) has a Done bar. Fix: FormPage Done on both.
21. **Polish. Diagram canvas is inset 14 dp each side.** `automations/rule_editor.dart:428` uses `OmniPage` with the default `padded: true`, so the `DiagramViewer` canvas (`diagram_editor.dart:166`) gets screen padding and loses width. Fix: EditorPage pads the sentence view only.
22. **Polish. Hard-coded FAB spacers in Automations.** `automations/automations_screen.dart:286` `SizedBox(height: 88)` and `:172` `right: 88` instead of `OmniInsets.fabClearance` (96 with insets). It clears the FAB today, but it does not follow the token. Fix: template bottom padding.
23. **Polish. TV files hard-codes its insets and bar.** `tv/tv_files.dart:482` padding `14, 0, 14, 96/24`, `:534` `Positioned(left: 12, right: 12, bottom: 14)` selection bar instead of `OmniSpace` and a bottom-bar slot. Fix: tokens, and the selection bar as `OmniPage.bottom`-style slot on the TV tab body.
24. **Polish. Off-scale and raw text styles.** 13 pt (not on the `OmniText` scale) at `automations/sentence_row.dart:73`, `design/step_row.dart:86`, `automations/diagram/diagram_nodes.dart:184`, `boards/add_pin_page.dart:355`, `tv/tv_widgets.dart:207`, `tv/tv_remote.dart:446` (13 / 18); raw `TextStyle` in the design layer itself at `design/banner.dart:111`, `:190`, `:201` (empty state 17 / 22 / 14) and `design/headers.dart:63`. Fix: add a `OmniText` style where 13 is wanted on purpose, use tokens elsewhere.
25. **Polish. Off-token radii.** `tv/tv_mouse.dart:426` (10), `:518` (16), `tv/tv_files.dart:694` (16), `tv/tv_screen.dart:315` (12), `tv/tv_system.dart:213` (4), `boards/add_pin_page.dart:341` (8), `automations/sun_lighting_page.dart:362` (2), `devices/sensor_page.dart:168` (2), `automations/automations_screen.dart:626` (6). Each value exists on `OmniShape`, so these are direct swaps.

Count: 25 (1 high, 6 medium, 11 low, 7 polish).

Suspected, not counted: the `OmniPage` `bottom` bar sits inside `SafeArea` and above the keyboard through the Scaffold's resize, which looks right from source but was not seen on a device with a tall keyboard and the Test run + Save row.

## What is good

- Two scaffolds already carry nearly every screen, with collapsing titles, 48 dp targets and semantics headers built in, so templates are thin wrappers rather than a rewrite.
- `OmniInsets.fabClearance` exists and Home and Devices use it correctly. The shell owns the FAB and hides it when an empty state carries the same action.
- `OmniPage.bottom` is already the sticky bar for the rule editor, scene editor, review, add-by-hand, add pin and rooms, which is the FormPage pattern.
- `confirm` is the single yes or no dialog, and most destructive steps already pass `destructive: true`.
- `library_sheet.dart` is a complete searchable picker with suggestions and sections, ready to become PickerSheet.
- Loading, empty and error are handled on almost every page. The gaps are shape consistency, not missing states.
