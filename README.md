# OmniFlow

OmniFlow is a local-first home automation app for Android. It controls lights, plugs, TVs, computers and microcontroller boards straight over your own network, with no vendor cloud, and runs your automations on the phone itself.

<p>
  <img src="docs/screenshots/home-light.png" width="200" alt="Home">
  <img src="docs/screenshots/light-page-dark.png" width="200" alt="A light's page with a section open">
  <img src="docs/screenshots/automations-light.png" width="200" alt="The Automations list">
  <img src="docs/screenshots/editor-dark.png" width="200" alt="The automation editor">
</p>

## Features

- **Local control.** Commands go from the phone to the device on the LAN, so they are quick and keep working when the internet is down.
- **Many kinds of device, one JSON file each.** 26 built-in drivers in `drivers/`: Philips WiZ, Tuya plugs and lights, Shelly, Philips Hue, Home Assistant, MQTT devices (Tasmota, Zigbee2MQTT and plain topics), Roku, Sonos, Android TV and Fire TV over ADB, LG webOS and Samsung Tizen TVs, Android phones over Wireless debugging, Macs and Linux hosts over SSH, OmniFlow boards and the weather. A new kind of device is a new manifest, not a new app release.
- **The phone, people, places and NFC tags are things too**, so "when I get home", "when this tag is scanned" or "when the battery drops below 15%" work like any device state.
- **Automations three ways.** A one-line link ("this button toggles that lamp"), a rule (when, only if, then) built as stacked blocks or as a diagram, or a raw flow graph. Scenes run several actions in one tap. Test runs, a run log and "why did it not run" show what happened.
- **A TV control centre** for Android TV: remote, apps, settings, files, a console and a screen view.
- **One firmware for every board** (ESP32, ESP8266, Pico W, Uno). Pins are named and given a job at runtime, IR, 433 MHz RF and NFC readers are set up from the app, and a board on the phone's USB is flashed from the app.
- **Several homes** in one app, each with its own devices and automations, and an optional Mac mini hub that runs everything while phones come and go.
- **AI agents through MCP.** `omni mcp` gives Claude and other MCP clients the same commands the app uses, at the access level you choose. What an agent writes waits for your approval when it is high risk.
- **A CLI for everything.** Every action in the app is also an `omni` command.

## Quick start

1. Install Flutter 3.47.9 (stable, Dart 3.13.7), for example with `mise use flutter@3.47.9`, and the Android SDK. [CONTRIBUTING.md](CONTRIBUTING.md) has the full setup.
2. Get the packages, from the repo root:

   ```sh
   dart pub get
   ```

3. Run the CLI on a Mac, from `packages/omniflow_engine`. It keeps its data in `~/.omniflow` (or `$OMNIFLOW_HOME`) and its secrets in the macOS keychain:

   ```sh
   dart run omniflow_engine:omni --help
   dart run omniflow_engine:omni add             # list what is on the network
   dart run omniflow_engine:omni add --pick 1    # add the first find and walk its setup
   dart run omniflow_engine:omni rule add 'Lamp at dusk' --when time:18:30 --then lamp.power=true
   ```

4. Build the app and install it on a phone or emulator, from `packages/omniflow_app`:

   ```sh
   flutter build apk --release
   adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```

The engine's own README, [packages/omniflow_engine/README.md](packages/omniflow_engine/README.md), has many more CLI examples.

## Repo layout

- `packages/omniflow_engine/` - the pure Dart engine with all the logic, the `omni` CLI (`bin/omni.dart`) and the MCP server.
- `packages/omniflow_app/` - the Flutter app, Android only. It runs the engine in a foreground service and holds no logic of its own.
- `drivers/` - the built-in driver manifests, embedded into the engine at build time.
- `firmware/omniflow_node/` - the one Arduino sketch for every board, with a native virtual board for tests.
- `tv_helper/` - a small Android TV app that draws a mouse pointer, installed on the TV by the app.
- `tool/` - repo scripts, such as `link_build_dirs.sh`.
- `docs/` - the engine design, the roadmap, the feature designs, the UI specs and the screenshots.

## Docs

- [ARCHITECTURE.md](ARCHITECTURE.md) - the packages, the engine and app layers, the main runtime flows, data on disk, the security model and how to add a driver, a rule step, a command or a screen.
- [DESIGN.md](DESIGN.md) - the app's design system: principles, tokens, page templates, writing rules and accessibility checks.
- [CONTRIBUTING.md](CONTRIBUTING.md) - setup, the checks every change passes, live hardware tests, commits and security reports.
- [docs/README.md](docs/README.md) - an index of the deeper docs: [the engine design](docs/engine-design.md), [the roadmap](docs/ROADMAP.md), the feature designs and the UI specs.

## Status

Version 1.0.0, in active development by one person. Android is the only app target, and the Mac runs the CLI and the optional hub. The app runs from release builds on an Android 17 phone and the Android 17 emulator. On real hardware so far: WiZ bulbs and an Android TV over ADB. Every other driver, and the firmware's board protocol, is proven against loopback fakes and the native virtual board, not yet against the real device. BLE scanning for presence, the graph canvas editor and accounts with sync are not built. [docs/ROADMAP.md](docs/ROADMAP.md) tracks each item and what has been proven. There is no published release and no licence file yet.
