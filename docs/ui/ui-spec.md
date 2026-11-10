# OmniFlow App Design

> Status: active. Direction A ("Home and automations") approved and built 2026-11-08. The visual spec is `docs/ui/mockups.html`; this file is the written spec the rebuild is checked against.

## Goals

- A person who has never seen OmniFlow can control a device, see who is home and build an automation without help.
- Daily use (tap a light, run a scene, glance at what is on) takes one tap from the home screen.
- Power features (the TV console, raw settings, packets, drivers) are one level down and never clutter daily screens.
- Everything the app does goes through the engine's core API, so the CLI and Claude can do the same.

## Navigation

Four tabs in a bottom navigation bar, each keeping its own back stack:

1. **Home**: overview, scenes, favourites, rooms. A search button opens search and commands.
2. **Automations**: every rule and link, written as sentences.
3. **Devices**: every thing, by room or by type, each opening its device page.
4. **Settings**: places and people, rooms, tags, scenes, background running, permissions, hubs, Claude, developer tools.

The Add button (a floating button on Home and Devices) opens the add flow from anywhere. A notification tap opens what it names (a failed run opens its run, an approval request opens the review).

Retired from the top level: the permanent command bar (now search on Home), the Flows tab (now Automations) and the Packets tab (now Settings, Developer).

## Design system

- **Colours**: the existing tokens in `lib/ui/theme.dart`. Background `#0D0F12`, bars `#14171C`, cards `#1A1E24`, raised `#222831`, lines `#2A313B`, text `#E8ECF1`, muted `#8B95A3`. Accent (actions and "on") `#00F5D4` with ink `#00382F`. WHEN orange `#FF9F1C`, ONLY IF purple (lightened to `#B18CFF` for contrast on dark), flow control pink, warning amber `#FFB547`, error `#FF6B6B`. Every text and icon pair meets WCAG AA contrast.
- **Type**: Material 3 scale. Screen titles 22/650, section titles 13/650, body 14, captions 12. Numbers use tabular figures.
- **Shape and spacing**: 4 pt grid. Cards and tiles 18 radius, sheets 22, chips fully rounded. Screen padding 14, gaps 10.
- **Icons**: Material Symbols (rounded), never emoji in the shipped UI. Each capability type and driver category has one icon.
- **Motion**: 150 to 250 ms standard easing for state changes and sheets, none when the system asks for reduced motion.
- **Touch**: every target at least 48 dp, with semantics labels for screen readers.
- **Components**: tile, list row, card, sentence chip (WHEN, ONLY IF, THEN colours), segmented control, filter chip, slider with label and value, switch, bottom sheet, banner (info, warning, error), progress bar, empty state, step row with drag handle.

## Screens

Each screen lists what it shows, the engine calls behind it, its states and its interactions. "States" always covers loading, empty, offline and error.

### 1.1 Home

- **Shows**: a greeting with the person's name; a status line (things on, automations active); status chips (presence, what the TV plays, problems such as an offline device); scenes; favourites as tiles; then one tile grid per room.
- **Engine**: `device.list` with capabilities and state, live `device.stateChanged` events; presence from the person thing (`jade.home`); scenes and favourites (new, see Engine additions); `automation.list` for the count.
- **Tile**: icon by capability, name, one-line state ("80% · warm", "Netflix · vol 35", "Offline"). On-state tiles use the accent gradient; offline tiles are dimmed. Tap toggles a device with a power capability, otherwise opens it. Long press opens the quick sheet.
- **States**: loading shows tile skeletons; empty shows 8.2; a problem chip appears when any device is offline.

### 1.2 Quick control sheet

- **Shows**: the device name, its room and driver, a power switch, and the controls its capabilities need (brightness, warmth, colour swatches; for a TV: power, volume, mute and a five-key mini remote), plus "Open device".
- **Engine**: `device.invoke` per control. Sliders send on release, not on every move.

### 1.3 Search and commands

- **Shows**: one field. As the user types: a "Do it" result from the command interpreter, then matching things, automations and settings, then suggestions.
- **Engine**: `command.interpret` for the top result; local filtering over the loaded lists.
- **Interactions**: Enter runs the top result and shows what happened; a tap on a thing or automation opens it.

### 2.1 Automations list

- **Shows**: filter chips (All, Rules, Links, Off, Needs you); a warning banner when an agent-made automation waits for review; one card per automation with its name, an enable switch, its sentence in WHEN, ONLY IF and THEN chips, and the last run (time, step count, or a plain failure with Retry).
- **Engine**: `automation.list`, `automation.enable`, `automation.log` for the last run, `automation.run` for Retry.
- **New**: a sheet offering a rule, a quick link, or a template (arrive home, motion light, tag toggle, bedtime, leave home all off).

### 2.2 Rule editor

- **Shows**: the name; three blocks, each with its colour and heading: WHEN (any of these), ONLY IF (all of these), THEN (in order). Each row reads in plain words with a drag handle and a remove button. Branches (if/else) and parallel groups show as one row that opens its own sub-list. Test run and Save at the bottom.
- **Engine**: `automation.get` to open, `automation.save` (form rule, trusted, replace when reopened), `automation.dry_run` for the test.
- **States**: validation errors from the engine are shown on the row their rule path names (`then[2].do`). An agent rule opens with the review banner (2.5).

### 2.3 Pickers (trigger, condition, step)

- **Trigger picker**: grouped by Me (I get home or leave, an NFC tag is scanned), Things (each device with what it can report: pressed, turns on, goes above or below, an app opens), Time (at a time on chosen days, every few minutes, only when I run it). Each choice opens a short form in plain words ("goes above **28** °C").
- **Condition picker**: I am home or away, between two times, on chosen days, a thing is in a state or above or below a number, a variable.
- **Step picker**: do something on a device (its actions, with their params as proper controls), toggle, wait, wait until something happens (with a timeout and what to do then), if/else, do these together, keep a value while something holds, notify, set a variable, run another automation. TV and other high-risk steps (shell, uninstall) are marked and explain that they need approval.
- **Engine**: the lists come from `device.list` with capabilities and event capabilities, places and tags.

### 2.4 Test run and history

- **Shows**: a banner that nothing was sent; one row per node from the dry run with what it would do and whether it would pass or fail; below, the last real runs, each opening the same view for that run.
- **Engine**: `automation.dry_run` (trace labels), `automation.log`.

### 2.5 Review an agent automation

- **Shows**: who made it; the sentence; what it can do (devices it controls or reads) and what it cannot; Reject and Approve.
- **Engine**: `automation.get`, `automation.approve` with the revision, `automation.remove` for Reject.

### 3.1 Devices

- **Shows**: a segmented control (By room, By type, Problems with a count); list rows with icon, name, driver and state, and a status dot (online, offline, unpaired).
- **Engine**: `device.list`, state events.

### 3.2 Device page (simple devices)

- **Shows**: a hero with the main state and a large power button; the controls its capabilities need; "Used in" (automations that read or drive it); recent history; the device section (room, name, address, settings, remove). A star adds it to favourites.
- **Engine**: `device.get`, `device.invoke`, `automation.list` filtered by device, the device's state history (new), `device.remove`.

### 3.3 Sensor page

- **Shows**: the current value with its unit and age, a 24-hour chart with low and high, "Make an automation from this" (opens the rule editor with a crosses trigger), and "Used in".
- **Engine**: state history (new).

### 4. TV control centre (4.1 to 4.5)

A live header on every tab: the app in front with its playing state, a volume slider, mute, and power in the app bar. Tabs: Remote, Apps, Settings, Files, Console.

- **Remote**: top row power, input, home, assistant; the D-pad with OK; back, menu and info; volume and mute; previous, play/pause, next. Scrolling down: number pad, the four colour keys, channel up and down, HDMI 1 to 4, guide, captions, TV settings, sleep and wake, and a text box that types on the TV. Long press on a key sends a long press.
- **Apps**: search; filter chips (Installed, System, All) and Install APK; rows with the app's colour badge, label, package and version, and "running" for the app in front. A row opens a sheet: open, stop, clear cache, clear data, disable or enable, uninstall. Clear data, disable and uninstall ask first and say what is lost.
- **Settings**: search across all settings; curated categories with real controls and a one-line description each (Network with Private DNS, Power and sleep, Display and sound, Screensaver, HDMI-CEC, Bluetooth, Accessibility and captions, Developer); "All settings" lists every key per namespace with inline edit, and a raw write asks first.
- **Files**: a breadcrumb bar; folders first with item counts, files with size and date; long press to select, then a bottom action bar (copy, cut, download to the phone, rename, delete); paste appears in the folder the user moves to; a plus button adds a folder or uploads from the phone; transfers show progress and can be cancelled.
- **Console**: a warning that commands run directly on the TV and only the user can use it; a monospaced output area; a command field with history.
- **Engine**: the `tv.*` commands of the TV control centre build, with `tv.progress` events.

### 5.1 Board page

- **Shows**: a hero (board type, online, name, address, firmware); Pins, each with an icon by role, its GPIO and role in plain words, and its live value or a switch; Extras (IR LED, RF, NFC reader) with their setup.
- **Engine**: `device.get`, `board.describe`, `board.pins`, `board.periph`.

### 5.2 Add a pin

- **Shows**: a name; "What is wired to it?" as plain choices (button or switch, relay or LED, dimmer, servo, analog sensor); a pin grid with only the pins that can do that job enabled, used pins marked and boot pins warned; options for the role (wired to ground, active low); Save.
- **Engine**: `board.describe` for pins and capabilities, `board.pins` to save, strapping warnings from the reply.

### 5.3 NFC tag

- **Shows**: when it was last scanned and by what; Write to a new tag; what happens when scanned (automations) with "Do something when scanned"; recent scans.
- **Engine**: `tag.list`, `tag.write_payload`, `automation.list` filtered by the tag.

### 6.1 and 6.2 Add

- **Found nearby**: a banner while discovery runs; candidates with icon, name, address and what they need ("needs pairing"); already added ones greyed; "Or add by hand" for tags, places and any driver.
- **Guided steps**: a step bar; one step per screen from the engine's `next` (pair with clear instructions and a countdown, a masked secret field saying where to find the secret, configure, done); name and room on the last step; a help link when nothing happens.
- **Engine**: `thing.add`, `thing.next`, `thing.configure`, `device.pair`, `secret.set`.

### 7.1 Settings

- **Home**: places and people, rooms, NFC tags, scenes.
- **This phone**: background running (on or off, battery optimisation state, with a fix button), permissions (location, nearby devices and local network, NFC, notifications, each with its state and a grant button), hubs.
- **Claude and agents**: automations waiting for approval.
- **Advanced**: Developer, About.

### 7.2 Places and people

- **Shows**: a hero (you are home, since when, seen by what); how OmniFlow knows (home Wi-Fi networks, a Bluetooth beacon, being seen by a hub), each with a switch; the wait before "away"; people.
- **Engine**: the place and person things, `zone.save` and their settings.

### 7.3 Developer

- **Tabs**: Packets (today's inspector, filterable), Run log, Drivers (built-in and user, register from a file), Engine (status, load issues, hub state).

### 8. First run, empty and error states

- **First run**: one screen that says what OmniFlow does and asks for the permissions it needs, each with why, then discovery.
- **Empty home**: what discovery found, with Add buttons.
- **Offline and errors**: a plain sentence on what happened and what to try (try again, find it on the network, see what was sent), and which automations are affected. No raw exception text anywhere in the UI.

## Engine additions

Built on 2026-11-08, all through the core API with CLI verbs. DESIGN.md (UI, Engine additions for the redesign) has the full contract.

- **Scenes**: `scene.save`, `scene.list`, `scene.run` and `scene.remove`, stored as automations with source `scene` (a manual trigger and a `together` step), so validation, approval, trust and the run log apply. `automation.save` and `automation.dry_run` take `form: scene`.
- **Favourites and room order**: `device.organize {id, name?, room?, favourite?, order?}`. Device rows carry `favourite`, `order`, `roomId`, `room`, `category` and `icon`.
- **State history**: `device.history {id, key?, limit?, since?}`, capped at 500 rows per device, each entry saying who changed it (`user` or the automation id).
- **Presence explanation**: the person thing's `homeSource` (`wifi`, `ble` or `manual`) and `homeSince`, and `presence.set` for I am home or away.
- **Rooms list**: `room.list`, `room.save`, `room.remove` and `room.order`, with a schema 5 migration from the old room names.
- **Automations list**: `automation.list` returns sentence chips, the last run, needs you and the things each automation uses, filtered by `device`, `tag` or `needsYou`. `automation.templates` gives the five templates and fills them.
- **Rules**: the keep step and `stopOnError`, with a failed step no longer stopping the rest of a rule.
- **Boards and tags**: `board.describe` reports `bootPins`, and a tag scan writes `last_source`.

Not built: the `hub` presence source, a stored wait before away for Wi-Fi, folder item counts in `tv.files.list`, and failed-run or approval notifications.

## Acceptance

- Every screen in `docs/ui/mockups.html` exists and matches it, checked side by side on the phone with screenshots.
- A new-user review by a fresh agent, given only "you have this app on your phone" and goals (turn on the desk lamp, make the TV turn on when you get home, find why the hall bulb is not working), succeeds without being told where things are.
- `flutter analyze` and `flutter test` pass, with a widget test for each screen and each destructive confirm.
