# OmniFlow roadmap

> Status: active, version 1.0.0. What works today, what still has to be proven on real hardware, and what is planned. The design behind each item is [engine-design.md](engine-design.md).

Android is the only app target. The Mac runs the `omni` CLI for development and, optionally, the always-on hub.

## What works today

- **The engine and the CLI.** Every action is a core API command, reached from the app, the `omni` CLI and MCP alike. Data in SQLite, secrets in the macOS keychain or the Android keystore, daily backups while the hub runs, and export and import of a whole home.
- **Devices.** 26 built-in drivers: Philips WiZ (scenes, colour, white channels), Tuya plugs and lights (protocol 3.3, with 3.4 and 3.5 framing), Shelly Plus and Gen1, Philips Hue lights on a bridge, Home Assistant entities and sensors, MQTT devices (Tasmota, Zigbee2MQTT, plain topics), Roku, Sonos, Android TV and Fire TV over ADB, LG webOS and Samsung Tizen TVs, Android phones over Wireless debugging, Mac and Linux hosts over SSH, OmniFlow boards and the weather. Discovery by UDP broadcast, mDNS, SSDP, Tuya announcements, USB serial and board hellos, and address healing for devices that move.
- **Things beyond devices.** The phone, people, places and NFC tags are things, so presence by Wi-Fi, a scanned tag or a phone event works like any device state. The phone feeds its battery, Wi-Fi, notifications, the app in front, calls, media, the calendar, Bluetooth, the screen, Do Not Disturb, shake and face down.
- **Automations.** Links, rules (when, only if, then, with waits, branches, groups, asks, web requests and keep steps), scenes and raw flow graphs, all compiled to one flow engine. The app edits rules as stacked blocks or as a diagram that lights up with a run. Test runs, Try as if, the run log, why a run was skipped, versions, Recently removed, conflicts and habit suggestions.
- **Home helpers.** Houses (several homes in one engine), house modes, timers, alerts, energy from plugs that report it, lights that follow the sun, away lighting and the weather.
- **The TV control centre.** Remote, apps, settings, files, a console and the screen for Android TV, and the same for a second Android phone.
- **Boards.** One firmware for ESP32, ESP8266, Pico W and Uno, pins named at runtime, IR, 433 MHz RF and NFC readers, and flashing from the phone's USB for ESP32, ESP8266 and Uno.
- **The hub and agents.** `omni hub` on a Mac mini with phones as clients over SSH, and `omni mcp` for AI agents at the access level the user picks, with approval for anything high risk.
- **The app.** The design system in [DESIGN.md](../DESIGN.md), light and dark themes, text up to 200 %, and a foreground service that keeps automations running with the screen off.

## Waiting on real hardware

These are built and pass against loopback fakes, the native virtual board or the emulator, but have not run on the real thing:

- A physical board: a pin round trip over USB and Wi-Fi, an IR send a receiver decodes, an RC522 or PN532 reading real tags, and flashing from the phone.
- An LG or Samsung TV, a Hue bridge, Home Assistant, an MQTT broker, Roku and Sonos.
- Tuya protocol 3.4 and 3.5 on a real device, and energy figures from a real plug.
- On a phone: NFC reading and writing, the calendar, alarms, headphones, Do Not Disturb, a Wi-Fi leave and return with the phone in a pocket, and a full day of battery use.
- The hub on a real Mac mini with launchd, Remote Login and a phone pairing on the LAN.
- A Wireless debugging phone on the LAN, and TV address healing and volume through an HDMI-CEC soundbar.

## Planned

- **Presence.** BLE scanning on the phone with scan filters, presence for several people in one place at once, and presence from a hub (a phone on the LAN, a computer idle or locked).
- **Editing.** A canvas editor for raw flow graphs, run errors worded with step names, variables picked from the ones automations use, and typed setup fields with help text.
- **More devices.** Hue groups, scenes and push, Home Assistant push over its WebSocket, Google Cast, Matter through a sidecar, ESPHome's native API, IR learning, Wake-on-LAN and SSDP discovery for LG and Samsung TVs, and a Windows host over SSH.
- **Boards.** Pico W flashing from the phone, over-the-air updates for ESP32 and Pico W once their security design is done, and custom sketches compiled on a computer and flashed from the phone.
- **The CLI and hub on Linux**, such as a Raspberry Pi, with its own secret store and a systemd unit.
- **Agents.** An architect in the app that shows a diff for approval before it saves, device state as MCP resources, and JSON Schemas for driver manifests and flows.
- **Accounts and sync**, deferred: sign-in, an encrypted change log in the user's own cloud drive, and a rule for which device runs an automation when several see the trigger.
- **Clean-up.** The `flow.*`, `link.*` and `zone.*` command names move to `automation.*` and `place` names one release after the app stops calling them.
