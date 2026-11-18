# OmniFlow app: design v2

> Status: design, not built. Mockups: `~/scratch/design_v2/mockups.html` with PNG renders beside it. Builds on `page-templates.md` (the eight templates and the screen inventory) and `design/tokens.dart` as on disk 2026-11-19.

## Problem

Today's screens put everything in front. The device page shows a "Recent" list of raw changes under the controls, including lines such as "2:43 PM sceneId 0 by you" and "2:43 PM speed null by you" (`RecentSection` in `devices/device_sections.dart`, placed by `DevicePage.build` in `devices/device_page.dart`). The TV page opens with three rows of keys, a number pad and a hint line. Automations open with five filter chips, a "Type what you want" row and coloured token chips on every card. Settings is one long list of fifteen rows. The Add button on Home floats over the last tile row.

The goal is a calm app that a new user understands at first look: big controls for the common action, plain words, and everything else one tap away behind a labelled section.

## Direction

Three layouts were mocked on the same six screens (Home, a light's page, the TV, the Automations list, the automation editor, Settings), dark and light:

| Layout | Home and devices | Automations | Main risk |
| --- | --- | --- | --- |
| A. Tiles throughout | Large tonal tiles, list groups in rounded cards | Cards with a sentence, editor as When, Only if and Then lists | The editor reads as a form, so the order of steps is hard to see |
| B. Colour cards throughout | A bold colour on every card | Colour cards, editor as stacked blocks | Colour on every device fights the state colours (on, warm, not answering) and Home gets loud |
| C. Tiles for devices, cards for automations | As A | As B | Two visual languages, kept apart by tab |

**Decision: C.** Home, devices, the TV and Settings are places you glance at and tap, and calm tonal tiles keep the on and not-answering colours readable. An automation is a sequence you build, and stacked blocks show that sequence directly. The blocks map one to one onto When, Only if and Then, and they reuse the trigger, condition and action colours the tokens already define. The two styles never share a screen, so the app still feels like one product.

A [Rejected]: the list editor hides the step order, which is the thing a user most needs to see in an automation.
B [Rejected]: per-device colour removes the only signal that a tile is on or not answering.

## Design parameters

### Material 3

- **Touch targets.** Every tappable thing is at least 48 x 48 dp, even when the visual is smaller (a 40 dp chip keeps a 48 dp hit area). Primary controls (power, D-pad keys, scene buttons, Save) are 56 dp or more. Source: m3.material.io, Foundations -> Accessibility -> Designing for accessibility (touch and pointer targets).
- **Type scale.** Sizes come from the M3 scale (display, headline, title, body, label). Body text is Body Large 16. Page titles are Headline Large 32 and collapse to Title Large 22 as the page scrolls. Source: m3.material.io, Styles -> Typography -> Type scale tokens.
- **Shape scale.** Corners come from the M3 corner scale: 4, 8, 12, 16, 20, 28 and full. Tiles and cards use 24 (between Large and Extra Large), buttons and chips use full. Source: m3.material.io, Styles -> Shape -> Corner radius scale.
- **Tonal elevation.** Depth is a lighter surface tone, not a shadow. Screen on surface, cards on surface container, raised parts on container high. Shadows stay only on the floating button and sheets. Source: m3.material.io, Styles -> Elevation.
- **Spacing.** All padding and gaps sit on the 4 dp grid with 8 dp as the main step. Screen margins are 16 dp on a compact phone. Source: m3.material.io, Foundations -> Layout -> Spacing.
- **Navigation bar.** 80 dp tall, four destinations, a 64 x 32 active pill, labels always shown. Source: m3.material.io, Components -> Navigation bar.
- **List rows.** One line 56 dp, two lines 72 dp. Source: m3.material.io, Components -> Lists.

### Text size, targets and wording

- **Targets.** At least 44 x 44 pt. The 48 dp rule already covers it, and the shared minimum is 48.
- **Dynamic Type.** Every text style scales with the system text size. Nothing uses a fixed height that clips text, rows grow instead.
- **Clarity and deference.** The content (a device's state, the step of an automation) is the loudest thing on screen. Chrome, borders and decoration stay quiet. One accent colour marks what is on or selected.
- **Plain language.** Short, direct labels in the words a person uses.
- **Progressive disclosure.** Show the common action, hide the advanced ones behind a clear label.

### Accessibility (WCAG 2.2 AA)

- **Contrast.** Text is at least 4.5:1 on its surface (1.4.3). Icons, switch tracks and field edges are at least 3:1 (1.4.11). Every pair in the mockups was checked with `~/scratch/design_v2/contrast.py`: dark text on its surface is 16.2:1, muted on a card 5.5:1, the dark accent on its ink 9.3:1, the light-theme accent 6.5:1, white on each bold card colour 6.0 to 8.2:1.
- **Labels.** Every icon-only button has a spoken label ("Bedroom light power", "Search"). Each collapsed section is a button that says its state ("Activity, 5 changes today, collapsed"), which in Flutter is `Semantics(button: true, expanded: open)`.
- **Large text.** Layouts hold at 200 % font scale (1.4.4). Tiles become one column above 130 %, segmented controls wrap their labels, and no text is truncated in front.
- **Not colour alone.** "Not answering" carries a word and an icon as well as the red tint. On and off carry the word.
- **Reduced motion.** The section open animation follows `OmniMotion.of`, so it is instant when the system asks for less motion.

## The collapsed section

One new design component, `OmniDisclosure`, carries all secondary information. It is a card (radius 24, container surface) with a 72 dp header row: an icon in a 40 dp box, a label, a one-line summary that already answers the first question ("5 changes today", "Used in 2", "1.2 kWh today"), and a chevron that turns when open. Tapping anywhere on the header opens it. Its open state is kept per page in `PageStorage`, so coming back to a page keeps what you opened. A disclosure can hold another one (Developer details inside More settings).

Standard labels, used the same on every screen:

- **Activity**: what happened, newest first, in plain words. Never shows raw keys or values.
- **Automations**: what uses this device. Summary "Used in N" or "Not used yet".
- **More settings**: room, name, rarely changed options, Remove.
- **Developer details**: ids, raw changes, packets. Only inside More settings or For developers.
- **More buttons** and **TV tools** on the TV page.
- **Options** in the automation editor.
- **Ideas for you** and **Recently removed** on the Automations list.

## Per-screen layout

### Home

- In front: house switcher, search and Add (a + in the top bar, replacing the floating button so it no longer covers tiles), the greeting, mode and presence chips, at most one notice that needs you, Favourites as large tiles, Scenes as 56 dp run buttons, Rooms as tiles.
- Behind a section: Activity (what ran and changed today), Energy (today's use per plug). The "OmniFlow on Living room TV" chip, the "Save how things are now" scene card and the "Star a device" hint move out of the front. Saving the current state moves to the Scenes "All" page.

### Devices list

- In front: rooms as headers, each device a tile with name and state.
- Behind a section: devices not answering are grouped under "Not answering" at the end, collapsed when there is more than one.

### Light page

- In front: name and room, the state card with the 72 dp power button, Brightness, the White, Colour and Effects switch, Warmth, four named presets (Candle, Warm, Neutral, Daylight). Kelvin values show only on the slider.
- Behind a section: Automations, Activity, More settings (Room, Name and address, Follow the sun, Developer details, Remove).

### Every device page (plug, sensor, phone, weather, generic)

- In front: the state card, the device's main controls, and for an offline device the one recovery step (Try again) with "Find it on the network" next to it.
- Behind a section: the same three sections as the light page, in the same order. **Activity is always collapsed and always below the controls, on every device page. The device history is never in front.**
- Activity lists only changes that read as plain words ("Turned on by you", "Brightness 60% by you", "Turned off by Good night"). Entries without a plain description (a key with no capability label, a null value) are dropped from Activity and shown under Developer details -> Raw changes.
- The high-risk warning banner ("Some controls run commands on...") moves to a one-time confirm on the first such command.

### TV page

- In front: power, the now-playing card with volume, the Remote, Apps and Screen switch, the D-pad (232 dp, OK 100 dp), and six large keys (Back, Home, Mute, Vol -, Play, Vol +).
- Behind a section: More buttons (numbers, colours, Input, Menu, voice), TV tools (System, Files, TV settings, Console), Automations, Activity. The "Keys: Buttons" chip and the swipe hint go away. The More tab stops being a tab and becomes TV tools.

### Automations list

- In front: search, the All, Rules and Scenes switch, then each automation as a colour card (name, one-line summary, On or Asks tag). A scene card runs on tap. The New button stays as the floating button, since this is the one tab where creating is the main job.
- Behind a section: Ideas for you (suggestions), Recently removed. The Quick links and Off filters fold into search. "Type what you want" moves into the New sheet as its first choice.

### Automation editor

- In front: the icon and name, then the steps as stacked blocks (When, Only if, Then) joined by a thin line, each block saying its step as a sentence with the changeable words highlighted. One "Add a step" block at the end. Test run and Save pinned at the bottom.
- Behind a section: Options (Ask before running, Notify when it runs, Colour and icon, See it as a diagram), Activity (last runs, why a run was skipped). The Sentence and Diagram switch at the top moves into Options. An empty Only if block is not shown. "Add a step" offers it.

### Scenes

- In front: the scene's name and its steps as Then blocks, Run and Save.
- Behind a section: Options (colour and icon, shake to run), Activity.

### Settings

- In front: three groups. Your home (Rooms, Places and people, House mode), This phone (Appearance, Alerts), Your data (Backup and restore). About at the end.
- Behind a section: More settings (NFC tags, Variables, Follow the sun, Away lighting, Energy, Home location, Home runs on, Shake to run a scene, Boards on USB), For developers (Developer, Agents). "Set up your home" shows in front only until it is done.

### Add

- In front: the devices found on the network, each with one Add button, and "Add by hand".
- Behind a section: the guided steps per kind, phone access, firmware for a board.

## What moves behind a section

| Screen | Moves behind | Into section |
| --- | --- | --- |
| Home | Run history, energy card, TV status chip, "Save how things are now" | Activity, Energy, Scenes page |
| Devices list | Offline devices (more than one) | Not answering |
| Every device page | Recent list (device history) | Activity |
| Every device page | Automations that use it | Automations |
| Every device page | Room, name and address, Follow the sun, Remove | More settings |
| Every device page | Id, hardware id, See what was sent, raw changes | Developer details |
| Sensor page | Reading history chart | Activity |
| Phone page | Events list | More buttons |
| TV page | Numbers, colours, input, voice, media keys beyond the first six | More buttons |
| TV page | System, Files, TV settings, Console | TV tools |
| TV page | Keys chip, swipe hint | removed |
| Automations list | Suggestions, Recently removed | Ideas for you, Recently removed |
| Automations list | Quick links and Off filters, "Type what you want" | search, the New sheet |
| Automation editor | Ask before running, Notify, Colour and icon, Diagram view | Options |
| Automation editor | Runs page, test run history | Activity |
| Settings | Nine rarely used rows | More settings |
| Settings | Developer, Agents | For developers |
| NFC tag page | Tag id, write history | Developer details, Activity |

## Token changes

All in `design/tokens.dart` unless noted.

**Spacing (`OmniSpace`).** `gap` 10 -> removed, callers use `md` 12. `screen` 14 -> 16. `target` 48 stays. New `targetLarge` 56 for primary controls. New `row` 56 and `rowTwoLine` 72. Everything else (4, 8, 12, 16, 24, 40) stays. That puts every value on the 4 dp grid. `OmniSpace.gap` and `OmniSpace.screen` have 69 uses today.

**Radii (`OmniRadii`).** `tile` 16 -> 24. `card` 16 -> 24. New `section` 24 for `OmniDisclosure`. `button` 12 -> full. `segmented` 12 -> full, `segment` 8 -> full. `banner` 12 -> 16. `step` 12 -> 20 for editor blocks. `hero` 28, `sheet` 28, `fab` 16, `iconBox` 12, `chip` full stay.

**Type (`OmniText`).**

- `body` 14 -> 16 (Body Large). The old 14 becomes `bodySmall` for dense lists inside sections.
- `caption` 12 -> 14 (Body Medium). Subtitles and summaries in front never go below 14. 12 stays only for navigation labels and tags on cards.
- `largeTitle` 28 -> 32 (Headline Large) on tab roots and pushed pages alike, collapsing to 22.
- `reading` 22 -> 28 (Headline Medium) for the state card ("On · 60%").
- `section` 14 -> 18 w600, the section header above a group. New `cardTitle` 18 w600 for automation card names. 18 is the one size off the M3 scale, chosen so a two-word name fits one line on a 184 dp card at 100 % and wraps cleanly at 200 %.
- `step` 13 -> 18 w500 with 28 line height for editor block text, retiring the off-scale 13.
- New `button` 16 w600 for button labels.
- Every style drops its baked-in `color: OmniColors.text`, so text takes its colour from the theme. That is what makes a light theme possible.

**Colour.** Dark stays exactly as today. A light palette is added as `OmniPalette.tealLight` and a light `ColorScheme` in `theme.dart`: background `#F5FAF8`, bar `#EBF1EF`, card `#E3EAE8`, raised `#D7DFDD`, line `#C5CFCC`, text `#161D1C`, muted `#3F4947`, accent `#006A60` on `#FFFFFF`, accent soft `#A5F2E3` on `#00201C`, trigger `#6E3F00` on `#FFDDB8`, condition `#5A3EB0` on `#E8DDFF`, bad `#BA1A1A` on `#FFDAD6`. The slider fill is `#186A60` dark and `#A5F2E3` light. Automation cards use seven fixed colours that pass 4.5:1 with white in both themes: violet `#5B45C9`, orange `#A8430C`, teal `#00706A`, blue `#1E58C2`, pink `#A1235A`, green `#2B6E30`, slate `#45505E`.

**Elevation (`OmniDepth`).** Tiles and cards drop the shadow and the sheen (`lifted: false` by default) and rely on tone. The shadow stays on the floating button and sheets.

The light theme cannot ship by changing tokens alone. 310 references to `OmniColors.*` across 60 files read the dark colours directly. Each batch below replaces those in its own files with `OmniPalette.of(context)` or `Theme.of(context).colorScheme`, and Appearance got its System, Light and Dark choice once all three batches landed. System is the default.

## Plain-language rules

1. Say what happened, then who. "Turned off by Good night", not "11:30 PM switch false by rule_7".
2. Never show a raw key, id, `null`, `true` or `false` in front. Those belong in Developer details.
3. Name things the way the user named them. Use the device and automation names, never ids or hosts.
4. Verbs on buttons: "Try again", "Add", "Run", "Save". No "OK" except on the D-pad.
5. One idea per line. A subtitle fits on one line at 100 % text size, roughly 40 characters.
6. Sentence case everywhere. No capitalised words mid-label.
7. Times as "2:43 PM" or "Yesterday 11:30 PM", following the phone's 12 or 24 hour setting. Percent with no space ("60%"), other units with one ("2700 K", "1.2 kWh").
8. Explain a problem with the likely cause and the next step. "Not answering. It may be off at the wall" and a Try again button.
9. Words to avoid outside Developer details: capability, payload, packet, host, catalog, driver, engine, id, rule path.
10. A section's summary answers the first question about it ("5 changes today", "Used in 2"), so most people never need to open it.

## Migration plan

Batch 0 lands first because every other batch imports it. It is small and one builder does it. Batches 1, 2 and 3 then run in parallel on disjoint files. No batch renames a public widget another batch calls. Batch 1 adds `DeviceActivitySection` next to `RecentSection` and keeps `UsedInSection` working for `settings/rooms_page.dart` (batch 3).

### Batch 0: design layer

- New: `design/disclosure.dart` (`OmniDisclosure`, with a widget test for open, closed, the `PageStorage` restore, semantics and reduced motion).
- Change: `design/tokens.dart` (the token changes above, `OmniPalette.tealLight`, text styles without baked colour), `ui/theme.dart` (light `ColorScheme`, `omniTheme(brightness:)`), `design/tile.dart`, `design/card.dart`, `design/list_row.dart` (72 dp two-line rows), `design/buttons.dart` (full radius, 56 dp primary), `design/chips.dart`, `design/slider.dart` (56 dp), `design/headers.dart` (32 -> 22 title on pushed pages too), `design/banner.dart`, `design/sheet.dart`, `design/power_button.dart` (72 dp), `design/templates/detail_page.dart` (a `sections` slot rendered after the body as disclosures), `design/design.dart` (export), `design/README.md`.
- Gate: existing a11y and golden tests green, the new disclosure test, `flutter analyze` clean.

### Batch 1: Home, devices and the TV

- `home/home_screen.dart`, `home_hero.dart`, `home_notices.dart`, `home_presence.dart`, `run_section.dart`, `room_tile.dart`, `energy_card.dart`, `search_page.dart`, `house_switcher.dart`, `mode_picker.dart`, `quick_sheet.dart`, `empty_home.dart`, `timer_strip.dart`, `suggestion_card.dart`, `tile_look.dart`, `home_data.dart`, `home_helpers.dart`. Not `home/first_run.dart`.
- `devices/device_page.dart`, `device_sections.dart` (`DeviceActivitySection` with the plain-words filter, `RecentSection` kept until its last caller moves), `device_controls.dart`, `light_panels.dart`, `capability_control.dart`, `device_text.dart`, `devices_screen.dart`, `sensor_page.dart`, `weather_page.dart`, `smart_home_sections.dart`, `open_device.dart`, `host_key_sheet.dart`.
- `tv/tv_page.dart`, `tv_remote.dart`, `tv_widgets.dart`, `tv_apps.dart`, `tv_screen.dart`, `tv_mouse.dart`, `tv_system.dart`, `tv_files.dart`, `tv_settings.dart`, `tv_console.dart`, `tv_frame.dart`, `tv_controller.dart`, `phone_remote.dart`.
- Gate: a widget test per device kind that Activity is collapsed on first open and shows no entry without a plain description.

### Batch 2: Automations, scenes and the editor

- `automations/automations_screen.dart`, `automation_page.dart`, `rule_editor.dart`, `rule_blocks.dart`, `sentence_row.dart`, `token_field.dart`, `form_parts.dart`, `new_automation.dart`, `type_it_page.dart`, `scenes.dart`, `capture_scene.dart`, `library_sheet.dart`, `link_sheet.dart`, `look_picker.dart`, `pickers.dart`, `trigger_pickers.dart`, `condition_pickers.dart`, `phone_pickers.dart`, `step_forms.dart`, `step_library.dart`, `timer_forms.dart`, `rules_core_forms.dart`, `test_run.dart`, `review_page.dart`, `removed_page.dart`, `suggestions_page.dart`, `sun_lighting_page.dart`, `waiting_page.dart`, `automation_insights.dart`, `dialogs.dart`, `next_run_line.dart`, `web_headers.dart`.
- `automations/diagram/diagram_editor.dart`, `diagram_view.dart`, `diagram_nodes.dart`, `diagram_layout.dart`, `run_view.dart`.
- The word files (`rule_words.dart`, `rules_core_words.dart`, `run_words.dart`, `phone_words.dart`) change only where a plain-language rule asks.
- Gate: editor widget tests for block order, an empty Only if staying hidden, and Options collapsed on open.

### Batch 3: Settings, Add, onboarding, shell and the rest

- `settings/settings_screen.dart`, `appearance_page.dart` (Light choice behind a flag until all batches land), `alerts_page.dart`, `away_lighting_page.dart`, `backup_page.dart`, `home_location_page.dart`, `places_page.dart`, `rooms_page.dart`, `variables_page.dart`, `phone_access.dart`, `hub_page.dart`, `developer_page.dart`, `inspector.dart`, `agent_access.dart`, `shake_scene.dart`, `whats_new.dart`.
- `add/add_page.dart`, `add_by_hand_page.dart`, `add_phone_page.dart`, `guided_steps_page.dart`, `name_sheet.dart`, `pair_sheet.dart`, `room_field.dart`, `driver_kinds.dart`.
- `onboarding/home_setup.dart`, `start_options.dart`, `home/first_run.dart`.
- `shell/shell.dart`, `shell/tabs.dart` (the floating button only on Automations), `hub_banner.dart`, `links.dart`.
- `boards/*`, `tags/*`, `fun/*`, `help/*`.
- Gate: Settings shows three groups and two collapsed sections, the shell test confirms no floating button on Home and Devices.

Sizes today: batch 1 is about 12,700 lines, batch 2 about 16,900, batch 3 about 11,800.

## Open items

- The Home Add button moves from the floating button to the top bar. That changes `shell/tabs.dart` (batch 3) and the Home top bar (batch 1). Batch 3 owns the floating button rule, and batch 1 adds the + action.
