# OmniFlow Roadmap

> Status: active. M1 and M2 are complete in code. M3 is in part: the app has device setup, approval and link screens, but no flow editing, canvas or inspector tabs. M5 has its tools, `omni mcp` and engine approval. The in-app architect, MCP resources and JSON Schemas are open. M7 (universal boards, links, MQTT) is complete and proven against emulated devices. M4 has the foreground service, the multicast lock and ADB in code, and the M6 TV and hub drivers are built, all proven against loopback fakes only. Nothing has run on a physical board, a TV, a Hue bridge, Home Assistant or a phone yet. Live hardware tests and an APK wait on hardware and the Android SDK. Milestones are listed in the order the work happened, so M7 comes before M6. Design: `docs/DESIGN.md`.

Android is the only app target. Headless-first vertical slices: the engine is proven from the CLI on the Mac before the app wraps it. Every milestone ends with a test that runs against real hardware where it is available. Live hardware: Philips WiZ, Tuya/Wipro, Pico W and Arduino. The Android TV is owned but not yet available, so ADB is tested against fixtures until it is.

## M0 - Foundations

- [x] git repo on `main`, personal identity routed by an `includeIf` stanza in `dotfiles/home/dot_gitconfig.tmpl`.
- [x] Spec set folded into `docs/DESIGN.md` with its defects corrected, then deleted. Firmware moved out of docx into `firmware/`. `99_Archived_Duplicates/` deleted.
- [x] Registered in `projects/README.md` and `dotfiles/workspace.conf`.
- [x] Flutter 3.47.9 / Dart 3.13.7 installed (Homebrew cask).
- [x] Pub workspace with `packages/omniflow_engine` (pure Dart, `omni` executable) and `packages/omniflow_app` (Android only).
- [x] Package versions checked against pub.dev and recorded in `docs/DESIGN.md`.
- [ ] Android SDK downloaded through Android Studio first-run setup, then `flutter doctor --android-licenses` (manual).

## M1 - Drivers and transports from the CLI

- [x] Core API: command messages (`OmniEngine.handle`) and event messages (`OmniEngine.events`: `device.stateChanged`, `wiz.firstBeat`, `packet.captured`).
- [x] Manifest model and validator for schema v1, with typed param checks and static placeholder checks.
- [x] Driver registry with embedded built-ins (`tool/embed_drivers.dart`, checked by a test).
- [x] Structured template renderer with typed params and fallback chains.
- [x] drift database (schema v1: devices and user manifests, the flow tables come with M2), the database lock file, and `SecretStore` with the macOS keychain store for the CLI (its live test passed once, opt-in with `OMNI_KEYCHAIN_TEST=1`).
- [ ] Transports: UDP with request and retry, Wake-on-LAN, directed broadcast and the packet tap (done), WiZ push registration renewed every 20 s with `syncPilot` routed by MAC (done), the Tuya v3.3 codec with frame splitting, matching tinytuya golden frames (done), the Tuya TCP channel with a persistent connection per device (done), v3.4 or v3.5 if the scan below needs them, HTTP (done, with Shelly Gen2 RPC checked against Shelly's docs), MQTT (done in M7, tested against an in-test broker), local argv execution and POSIX quoting for SSH (done), the SSH executor with host keys pinned on first use (done, live test opt-in: `OMNI_SSH_HOST`, `OMNI_SSH_USER`, `OMNI_SSH_KEY`), the NDJSON line decoder with streaming UTF-8 and a line cap (done), serial port access through stty, with reads via cat so a close never blocks (done, tested over a pseudo-terminal).
- [x] Device runtime: per-device queue, timeouts and retries, address healing, poll and push state, optimistic state, and liveness as the `online` field in device JSON, shown on the app's device cards. Scheduling the polls lands with `omni hub` in M2.
- [x] Discovery: UDP probe to 255.255.255.255 and a /24 broadcast per interface, matched by JSONPath, with the stable id read for address healing. USB serial boards found by sending `describe` to each `/dev/cu.usbmodem*`, `/dev/cu.usbserial*`, `/dev/ttyACM*` or `/dev/ttyUSB*` port. Both behind `omni device discover`. mDNS and Tuya UDP discovery followed on 2026-11-07 (see M7).
- [ ] Built-in drivers: WiZ (done), Tuya plug on DP 1 (done; bulb DPs after the scan), macOS host (done), Linux host (done), Shelly Plus switch (done), MCU node over UDP and over USB serial (done in M1, replaced in M7 by `omniflow_board`), Android TV ADB (done in M4 as `android_tv_adb`, against a loopback fake).
- [x] Firmware v1 (retired in M7, kept here as history): a MicroPython Pico W firmware with a pin allowlist and `config.json`, and an Arduino sketch, both since replaced by `firmware/omniflow_node`.
- [x] CLI: `omni driver list|validate|register`, `omni device add|discover|list|get|invoke|refresh|remove`, `omni secret set`, `omni watch [--packets]` (which replaces the planned `omni sniff`).
- Exit: from the CLI, the real WiZ goes to 80% at 3000K, the real Tuya plug toggles, the Pico acknowledges an IR send over serial and over UDP, and the Mac changes volume over SSH.

## M2 - Flow engine running headless

- [x] Flow model, schema v1, validator (ids, ports, Kahn cycle check naming only the nodes on the cycle, reachability, per-type config and reference checks).
- [x] Node type registry with the built node set listed in `docs/DESIGN.md` (the planned triggers, the `hold` gate and the `exec`, HTTP and MQTT actions are not built), and the flow engine: device, zone, board, Wi-Fi, time-of-day (DST-safe) and interval triggers, high-risk flows waiting for approval, traces in the execution log.
- [x] Variables (`$Global` persisted, `%flow`, `msg`) and the Wi-Fi bindings (`$WifiSsid`, `$HomeWifiConnected` from `$HomeSsids`, `$Zone_<id>`).
- [x] Zones as entities: Kalman filter with Q per second (0.65, the spec's per-sample value at its 10 Hz beacon), silence tick, hysteresis with dwell, Wi-Fi input with a required flag, and the zones that need BLE scanning right now. Tested on synthetic noisy walks.
- [x] Executor: run modes, concurrent branches, cooldown armed at the first action, cooldown and debounce gates, delay, wait_for_event, bounded repeat, action error ports, per-node traces, dry run with an injectable clock.
- [x] CLI: `omni flow validate|save|list|get|remove|enable|disable|approve|run|dry-run|log`, `omni var`, `omni zone`, `omni sensor ble|wifi`, `omni hub`.
- Exit: the evening-desk flow passes end to end on fakes (done: zone entry on home Wi-Fi drives the emulated bulb through the real engine), and runs live from `omni hub` with a Pico button press as the trigger (needs the board).

## M3 - Android app

- [x] Engine client and Riverpod providers over the event stream, with the engine in the app process for now. The app starts the hub at launch, shows a banner when that fails and a Retry screen when the engine cannot open. The foreground service that owns the engine on Android, and its service-channel client, need the Android SDK and a phone to build and test (moved to M4).
- [x] Dashboard generated from capability types (switch, slider, button, d-pad, text, colour presets and hex, a params form for actions and exec), grouped by room, live from state events, with offline chips, a confirmation for host commands, plus the command bar interpreted by the engine.
- [x] Devices from the phone: Add device (driver, scan or address, name, room, and the driver's settings that are not secrets), rename or move, Pair, remove. Secrets still need the CLI.
- [ ] Flow editor: the read-only card view, flow list with enable, run, remove and an approval page that shows what would run and approves that revision (done). Editing on cards, the vyuh_node_flow canvas and live run highlighting are not built.
- [ ] Packet inspector: live list of packets (done). Capture-to-node and the BLE RSSI chart are not built.
- [x] No Android backup: `allowBackup="false"` and data extraction rules that exclude every domain. Not yet built into an APK.
- Exit: build and run the evening flow from the phone, and see its packets in the inspector.

## M4 - Background runtime, presence, ADB

- [x] Foreground service that owns the engine (`flutter_foreground_task`, `connectedDevice`, in its own isolate) and its service-channel client (`ServiceEngineClient`). Done in code and tested with widget and link tests. Not built into an APK or run on a phone.
- [ ] Platform bridges: multicast lock (done in code, held for the service's life), Wi-Fi changes, notification listener, app foreground, charging, screen lock, boot (the service starts on boot, in code).
- [ ] BLE scanning on demand with scan filters, the NFC trigger.
- [x] ADB over 5555 in Dart, with RSA pairing, a stored engine-wide key, validated shell commands and Wake-on-LAN, tested against a loopback fake adbd. The `adb` binary fallback is dropped, since the Dart client came first.
- [x] `device.pair` and `omni device pair` for Android TV, webOS, Tizen, Hue and Home Assistant, a Pair action in the app (not for Home Assistant, which pairs by storing a token). MCP invokes, hub polls and flow `device_capability` nodes never pair. A flow's `device_toggle` node, which toggle links use, still can.
- [ ] ADB live test on an Android TV or Fire TV.
- Exit: walking up to the desk with the phone in a pocket turns the lamp warm and wakes the Mac, with no laptop process running.

## M5 - MCP, AI architect, firmware generator

- [x] Tool registry over the core API with MCP error results carrying every validation issue (ten tools). Device-state resources and JSON Schema files for clients are not built yet.
- [x] `omni mcp` over stdio, tested against the real process. `omni` commands, `omni watch` and `omni mcp` run beside `omni hub` through its control socket (`<home>/omni.sock`, 0600).
- [x] Pairing and SSH host keys stay with the user: `pair_device` and `trust_ssh_host_key` always refuse with `needs_user` and the command the user runs (`omni device pair` or `omni secret set`), and an agent invoke never raises a pairing prompt. `describe_board` is read only. Thirteen tools.
- [x] Approval: in the engine (saves are untrusted unless they say `trusted: true`, high risk is transitive across `run_flow` and globals, `flow.approve` needs the reviewed revision, approval is revoked when risk rises, high-risk drivers are refused to agents) and the approval page in the app.
- [ ] In-app architect on the command bar, with a diff and approval before anything is saved.
- [x] Firmware: `generate_mcu_firmware` returns build instructions, not code: every board runs `firmware/omniflow_node`, so it returns the flash command, the `omni board setup` and `omni device add` commands, and the pins the board offers.

## M7 - Universal boards and links

The pass that makes OmniFlow the tool for microcontrollers and smart things: any board, any pin, any ecosystem, linked in one line. Design: "Universal board runtime" and "Links" in `docs/DESIGN.md`.

- [x] Protocol v2 core in plain C++ (`firmware/omniflow_node/omni_core.*`) with board profiles, and a native virtual board (`host/host_board.cpp`, stdin, `--pty` or UDP) for tests. Native core tests pass.
- [x] Arduino sketch for ESP32, ESP8266, Pico W and Uno over that core (serial, Wi-Fi UDP, hello broadcast, mDNS, Wi-Fi and IR setup kept in flash). `./check.sh` compiles it for all four with arduino-cli and fails on a compile error or a warning in the sketch's own files: Uno 937 of 2048 bytes RAM and 17136 bytes of flash after the 2026-11-07 hardening. Not yet run on a board.
- [x] Firmware hardening: a `pullup` cap, mode `none` to release a pin, `watches` and `set` in `describe`, events to up to three hosts that sent `describe` in the last 90 s, datagrams only from the board's subnet, `wifi.clear`, node-name and password rules, a reserved IR pin, parse errors with the request id and `value too long`, servos starting at 90 degrees, a 12-servo pool on the Uno with no servo on 9 and 10, the serial pins 1 and 3 dropped from the ESP32 profile, and classic-ESP32 and Uno or Nano build guards. Setup commands live in the shared core, so the virtual board runs them too. Compile-verified on the boards, tested natively.
- [ ] Pico W Wi-Fi join without blocking serial. The join no longer waits for DHCP, but arduino-pico 6.3.2 still blocks up to 15 s per attempt inside `CYW43::begin`. Retries back off from 30 s to 5 minutes.
- [x] ~~MicroPython Pico W firmware on protocol v2~~ dropped: the Arduino sketch runs on the Pico W, and the MicroPython v1 firmware and its two drivers were retired.
- [x] `omniflow_board` driver over the `omniflow` transport (serial or UDP by host): named pins become capabilities, pins are set up on add, on pin changes, at hub start and on a hello without setup, outputs are restored, `pin.changed` becomes state, a moved board is followed only when it answers as itself at the new address.
- [x] Releasing pins removed from a board device: setup reads `set` from `describe` and sends `pin.mode none` (audit follow-up, 2026-11-07).
- [x] Active-low outputs (`invert` on `out` pins, the start level in `pin.mode`), strapping pin warnings, `board.describe` with the last describe stored for offline boards, and `rf_send` for the firmware's `rf.send`. Tested on the virtual board.
- [x] Board discovery: describe broadcast and USB serial probe in `device discover`, `board.found` from hellos in the hub.
- [x] Engine end-to-end tests against the virtual board over a pseudo-terminal and UDP, and a CLI test from USB setup to named pins.
- [x] `omni board setup | pin | pins | provision`, with the Wi-Fi password read from stdin and masked in the packet inspector.
- [x] MQTT channel with `tasmota_mqtt`, `zigbee2mqtt_device`, `mqtt_switch` (ESPHome and Home Assistant style topics) and `mqtt_sensor`, tested against an in-test MQTT 3.1.1 broker, including a link from an MQTT sensor to a Tasmota plug. Not yet run against a real broker.
- [x] mDNS discovery for `_omniflow._udp`, Shelly, Hue and Home Assistant, and Tuya UDP discovery, in `device.discover` and address healing. Tested with a fake mDNS client and loopback Tuya announcements. ESPHome has no driver yet.
- [x] `device_toggle` node and links (`omni link add | list | remove`, `link.create`, MCP `link_devices` and `configure_board_pins`), tested across two virtual boards.
- [x] Link sheet (built from `link.options`), board pin sheet, sensor values and a new-board prompt in the app (widget tests). The prompt fires in the real app because the app starts the hub at launch, which a test proves with a hello datagram. Not yet run on a phone.
- [x] Full end-to-end pass on the Mac: engine, CLI binary, MCP, app tests and firmware compile, recorded in the log. On-hardware and on-phone runs remain.

## M6 - Optional

- [ ] Accounts and sync as recorded in `docs/DESIGN.md`: Google sign-in, an encrypted change log in the user's Drive, and first-wins flow claims over home Wi-Fi.
- [x] LG webOS and Samsung Tizen over WebSocket, with pairing keys and certificate pins stored per device. LG defaults to `wss` on 3001, and port 3000 is a plain-text downgrade for old firmware. Tested against loopback fake TVs.
- [x] Hue bridge (REST API v1, link-button pairing) and Home Assistant REST (entity and sensor) over HTTP with secrets. Tested against loopback fakes.
- [x] 433 MHz RF in the firmware (`rf.pin`, `rf.send`) and the `rf_send` capability. Compile-verified and tested on the virtual board.
- [ ] Hue CLIP v2 SSE, the Home Assistant WebSocket, a Matter sidecar, ARP presence in hub mode. Zigbee2MQTT shipped in M7.

## Checks

### Before M1: hardware, network and accounts (manual)

1. **Router.** Phone, Mac, bulbs and plugs on the same subnet. AP or client isolation off, because it blocks phone-to-device traffic. Most WiZ and Tuya devices are 2.4 GHz only. A DHCP reservation is optional for WiZ, Tuya, Shelly, Android TVs and boards, since address healing covers their IP changes. Reserve an address for the Hue bridge, Home Assistant, the MQTT broker and LG or Samsung TVs: a device that sends a secret does not follow a new address and has to be added again with it.
2. **WiZ.** Find the bulb's IP in the router or the WiZ app. From the Mac, `echo '{"method":"getPilot","params":{}}' | nc -u -w1 <ip> 38899` should print a JSON reply. Note the `moduleName` from `getSystemConfig`.
3. **Tuya and Wipro.** Check that the Wipro devices pair with the Smart Life app, since OEM apps can lock devices to their own cloud. Create a Tuya IoT developer project, link the Smart Life account, then run `python -m tinytuya wizard` (mise python) for the local keys and `python -m tinytuya scan` for each device's protocol version. The versions decide whether v3.5 is in M1. Close the vendor app while testing, because the device takes one local connection.
4. **Mac.** System Settings, General, Sharing, Remote Login on, and note the username. Over SSH from another machine, try `osascript -e 'output volume of (get volume settings)'`, `caffeinate -u -t 2` with the display asleep, and `shortcuts run <name>`. The last two may need a logged-in GUI session, and the result decides which `macos_host` capabilities work from the phone.
5. **Boards.** Flash `firmware/omniflow_node` (README there), then `omni board setup <port> --ssid <network> --name <name>`. Wiring is free: name each pin with `omni board pin`. On a Pico W keep off GPIO 23, 24, 25 and 29. Wire buttons and loads to strapping pins last: ESP8266 0, 2 and 15, ESP32 0, 2, 5, 12 and 15. An IR LED needs a transistor driver.
6. **Phone.** Model, Android version and maker, because some makers kill background services beyond what stock Android does. Developer options and USB debugging on, for installing builds.
7. **Android TV, when available.** Developer options, network or ADB debugging on, the IP noted, and whether port 5555 stays open after a reboot.

### Early spikes (short throwaway tests to retire design risks)

1. **WiZ push.** Send `registration` per pywizlight, then confirm `syncPilot` arrives on 38900 when the bulb is changed from its own app. Measure how long until it stops without renewal.
2. **Tuya frames.** Generate v3.3 (and v3.4 or v3.5 if the scan needs them) control and status frames with tinytuya for a fixed key, sequence number and timestamp, and save them as golden test vectors.
3. **Android BLE in the background.** With a foreground service running and the screen off for 30 minutes, check that a filtered scan for the Pico's advertised name keeps reporting, and at what rate. Check what happens to an unfiltered scan, and to restarting scans often. Record an RSSI trace while walking to the desk, sitting, and leaving, and keep it as a test fixture to tune the zone thresholds.
4. **Service isolate plugins.** Check that universal_ble, network_info_plus, path_provider, flutter_secure_storage and the `omniflow/multicast` channel work inside the flutter_foreground_task service's engine, and measure round-trip time on the service data channel.
5. **Phone LAN.** With the multicast lock held, confirm the phone receives WiZ discovery replies to a subnet-directed broadcast.
6. **Mac CLI privacy.** Check whether `omni` run from Terminal gets a Local Network permission prompt for UDP broadcast and mDNS.
7. **SSH from the phone.** dartssh2 4.x with an ed25519 key generated in the app, the host-key callback, and exec with argv quoting.
8. **Canvas on a phone.** vyuh_node_flow 0.32 pan, zoom and port dragging with touch on a phone-sized screen.

### Per-milestone acceptance checks

- **M1:** a command with a param out of range sends nothing. A string param containing `; rm -rf ~` reaches the target as one literal argument (check with a script that echoes its argv). Dropping a WiZ reply triggers a retry. Changing the bulb's IP triggers address healing. A grep of the logs, the packet capture and an export finds no local key or SSH key.
- **M2:** validator rejects a cycle, a dangling edge, an unknown port and an unreachable action. A trigger during a delay behaves per each run mode. A trigger that fails the condition does not arm the cooldown. `time_window` 18:00-05:00 matches at 23:00 and 02:00 and not at 12:00. A schedule across a DST change fires once. The recorded RSSI trace produces exactly one enter and one exit, and silence alone produces an exit.
- **M3:** card view round-trips the example flow without changes. A graph that is not a tree shows read-only cards. Edits in either view show in the other.
- **M4:** flows still fire after the app is swiped away, after an hour with the screen off, and after a reboot (connectedDevice service only, until the app is opened). Battery drain over 24 hours on home Wi-Fi is measured and recorded here. BLE scanning stops when the phone leaves home Wi-Fi.
- **M5:** an MCP call that registers an `exec` driver is refused with `needs_user`, and a high-risk flow from MCP is stored unapproved and not loaded until the user approves its revision. An invalid flow from MCP returns an error result listing every validation error.
- **M7:** on a real board, a pin round trip over USB and Wi-Fi, an IR send a receiver decodes, a servo that starts at 90 degrees, and a reboot that the hub notices and re-provisions.

### Security checks (every milestone)

- No TCP listeners: `lsof -nP -iTCP -sTCP:LISTEN` on the Mac while `omni hub` runs, and the same check on the phone over `adb shell` while the app runs.
- Only the expected UDP sockets: `lsof -nP -iUDP` shows the ephemeral command socket, 38900 and 38951 and nothing else, plus 6666, 6667 or 5353 only during a discovery window.
- The hub control socket: `lsof -U` shows `<home>/omni.sock`, and `stat` shows mode 600 in a 700 home.
- No secrets in the repo: a grep for key-shaped strings before each commit, and fixtures use made-up keys.
- High-risk drivers from MCP are refused, and high-risk flows from MCP and the architect wait for approval. Imports are not built yet.

## Checked against references

What the code and design assume, checked on 2026-11-06 against primary sources. "Confirmed" means the source says it. "Fixed" means the source disagreed and the code or design changed.

| Claim | Source | Result |
| --- | --- | --- |
| Tuya v3.3 frame: 0x55AA prefix, length covers CRC and suffix, CRC-32 over header and payload, version header only on some commands, 4-byte return code in replies | tinytuya 1.20 source (`message_helper.py`, `header.py`, `command_types.py`) | Confirmed. The codec matches tinytuya frames byte for byte |
| Tuya v3.5 uses the 0x6699 prefix and AES-GCM | tinytuya `pack_message` | Confirmed |
| A Tuya device allows one TCP connection, and the vendor app takes it | tinytuya README | Confirmed |
| A Tuya local key survives re-pairing | tinytuya README | Fixed. The key changes on every re-pair. Design says to fetch and store it again |
| WiZ discovery with a `getSystemConfig` probe matched on `result.moduleName` | pywizlight `discovery.py` | Fixed. pywizlight broadcasts `registration` with `register: false` and reads `result.mac`. The manifest now does the same |
| WiZ pushes need a `registration` call, renewed, to port 38900 | pywizlight `push_manager.py`, `bulb.py` | Confirmed: `phoneIp`, `register: true`, `phoneMac`, listen on 38900, renew every 20 s, no reply to `syncPilot` |
| WiZ dimming 10 to 100, RGB 0 to 255 | pywizlight `bulb.py` | Confirmed. Colour temperature is clamped to 1000 to 10000 K there, and the manifest's 2200 to 6500 K stays as an open item per bulb |
| NEC sends the 32-bit value most significant bit first | SB-Projects NEC page, Arduino-IRremote README | Fixed. NEC is LSB first per byte. The firmware now also takes `address` and `command`, and the `hex` form is documented as the older MSB convention (`sendNECMSB()`) |
| Pico W GPIO 23, 24, 25, 29 belong to the CYW43, and the LED is on the wireless chip | pico-sdk `boards/pico_w.h`, Raspberry Pi Pico docs | Confirmed: `WL_REG_ON` 23, data and host wake 24, `WL_CS` 25, `WL_CLOCK` 29, LED is `WL_GPIO0` |
| `$.1` is a valid JSONPath | RFC 9535 section 2.5.1.1 | Fixed earlier. A dotted name cannot start with a digit, so the plug uses `$['1']` |
| Android needs a multicast lock for broadcast and multicast | Android `WifiManager.MulticastLock` reference | Partly. The reference covers multicast only. Broadcast stays an on-phone check |
| Android stops unfiltered BLE scans with the screen off | Android `BluetoothLeScanner` reference | Confirmed. Filtered scans keep running |
| A filtered `PendingIntent` scan can wake the app when a beacon is in range | Android BLE background guide | Confirmed, and added to the design as the low-power wake-up |
| `neverForLocation` filters some beacons from results | Android Bluetooth permissions guide | Confirmed |
| `dataSync` services get 6 hours per day on Android 15, and `BOOT_COMPLETED` cannot start `dataSync` | Android 15 behaviour changes | Confirmed. The design uses `connectedDevice` and `location` |
| A `location` service cannot be created from the background | Android foreground service restrictions | Confirmed |
| dartssh2 accepts any host key when no verifier is passed | dartssh2 4.1 source (`ssh_transport.dart`) | Confirmed, so `SshExecutor` always passes one. The fingerprint is `SHA256:` plus base64, like `ssh-keygen -l` |
| macOS has local network privacy | macOS developer forums (points to TN3179) | Confirmed since macOS 15. Whether it applies to a CLI run from a terminal was not readable, and it is a candidate cause of the empty first discovery |
| ADB legacy protocol (CNXN, AUTH token types, OPEN, WRTE) | AOSP `protocol.txt` | Not checked against the reference, which could not be fetched. The client follows the legacy protocol and is proven against a loopback fake whose key parser and signature check share no code with it |
| Tuya UDP announcements: ports 6666 and 6667, key `md5("yGAdlopoPVldABfn")`, v3.5 0x6699 GCM | tinytuya 1.20.0 `udp_helper.py`, `message_helper.py` | Confirmed. Golden frames come from tinytuya's packer and decode with `decrypt_udp` |
| webOS registration: unsigned manifest, `pairingType` PROMPT, `client-key` | aiowebostv `handshake.py` | Confirmed. The mute reply field names are not |
| Tizen launch shape `ed.apps.launch` with `DEEP_LINK` or `NATIVE_LAUNCH` | samsungtvws `command.py`, `remote.py` | Confirmed |
| Home Assistant advertises a `uuid` TXT record | Home Assistant core `zeroconf/__init__.py` | Confirmed (2026-11-07) |
| A Hue bridge's id is the `bridgeid` TXT record | Home Assistant core `hue/config_flow.py` | Confirmed (2026-11-07) |
| A Shelly is identified by its mDNS instance name, not a TXT key | Home Assistant core `shelly/config_flow.py` (reads the MAC from the name) | Confirmed (2026-11-07). The driver reads the instance as the stable id |

## Verification

- Engine: `dart analyze`, `dart format --set-exit-if-changed lib test tool bin`, `dart run tool/embed_drivers.dart --check`, `dart test -x live`. Live tests: `dart test --tags live`, opt-in, against real devices.
- App: `flutter analyze`, `flutter test`, then runs on a real Android phone, with screenshots.
- Firmware: `firmware/omniflow_node/check.sh` (native core tests, the virtual board, and `arduino-cli compile` for Uno, ESP8266, Pico W and ESP32), then on a real board a `describe`, `omni board setup` and a pin round trip.

## Log

- 2026-11-06: M0 started. Repo created, specs consolidated into `docs/DESIGN.md`, archive deleted. The mermaid diagram in `docs/DESIGN.md` passes `lint-mermaid.py`, but has not been parse-checked because `mmdc` is not installed.
- 2026-11-06: Workspace scaffolded. Engine: `dart analyze` clean, `dart format` clean, 2 tests pass, `dart run omniflow_engine:omni --version` prints `omni 0.1.0`. App: `flutter analyze` clean, 1 widget test passes. No device build yet (needs the Android SDK).
- 2026-11-06: Design review. Added the command and event core API, single database owner, protocol coverage, device runtime (queue, retries, address healing, polling), zones as entities, time-scaled Kalman Q, run modes, sensors on demand, the UI section, and Android service types verified against the Android 15 behaviour changes. Original spec files removed after every piece of their content was folded into `docs/DESIGN.md` or into a decision there. Repo identity moved from a repo-local setting to `includeIf`.
- 2026-11-06: Scope set to Android only, with no accounts. Sync choices (Google sign-in, encrypted Drive change log, first-wins claims over home Wi-Fi) recorded in `docs/DESIGN.md` as deferred.
- 2026-11-06: M1 engine batches landed: template renderer, manifests, registry, UDP, Tuya codec and channel, host exec, SSH, NDJSON, device runtime, storage, core API, CLI and WiZ discovery. 130 tests pass. The first `omni device discover --driver philips_wiz_udp` on the real LAN found no bulbs, not yet diagnosed (bulb power, network, or the Mac Local Network permission for the terminal).
- 2026-11-06: Checked the build against primary references (tinytuya, pywizlight, SB-Projects NEC, pico-sdk, RFC 9535, Android and macOS docs, dartssh2 source). Two fixes landed: the WiZ discovery probe and NEC bit order. Findings are in the table above.
- 2026-11-06: M1 completed in code: WiZ push, engine events and `omni watch`, the HTTP channel with Shelly and Linux drivers, USB serial with discovery. 148 engine tests pass. Live hardware test still to run.
- 2026-11-07: M7 boards and links landed. One firmware core with board profiles, tested natively, and an Arduino sketch that compiles for Uno, ESP8266, Pico W and ESP32. The `omniflow_board` driver, board setup over USB, pin naming, hello handling and links are tested end to end against the firmware core built as a virtual board, over a pty and UDP. Fixed on the way: profile names clashing with core macros (`ESP8266`), Uno RAM at 101% (literals moved to flash), a provisioning future that awaited itself, a reboot missed by whole-second uptime (hello now reports `set`), and two links between the same ends sharing an id. The MicroPython firmware was retired. 245 engine tests pass. Nothing has run on a physical board yet.
- 2026-11-07: M7 full pass. MQTT with Tasmota, Zigbee2MQTT, switch and sensor drivers, toggles with device on/off words, app sheets for pins and links, sensor values and new-board prompts. Security pass (builder-security): the hub opens no TCP listener (`lsof`), its three UDP sockets take board traffic only from local addresses and known devices, and board setup commands are USB only. Follow links between on/off and numeric ends are refused. Results: 251 engine tests, 13 app tests, firmware core tests and arduino-cli builds for Uno, ESP8266, Pico W and ESP32, and a smoke run of the `omni` binary against the virtual board (add, pin, invoke, a refused out-of-range value, a refused radio pin, two links). Not proven: any physical board, a real MQTT broker, the phone.
- 2026-11-07: Full audit of engine, app, firmware and docs. 93 findings confirmed against source: 87 fixed in full and 6 in part, with the rest deferred (the flow `trusted` column, the Pico W join still blocking serial up to 15 s, no automated test for `omni hub` signal handling, a `dart_test.yaml` that skips live tests, a GPIO picker in the app, and the `.gitignore` `config.json` line). Engine: `hub.start`/`hub.stop`, `engine.status` and load issues, fail-closed trust with transitive high risk, revision-gated approval and revocation, hashed link ids and `link.options`, `run_flow` cycle and debounce-mode checks, unchanged flows and zones kept across reloads, safe device removal, MQTT watch and broker reset, Tuya heartbeat and refusals, WiZ push sender checks (the earlier security pass had missed that this socket took any sender), `matchMethod` and integer params, `tcp` and `adb` refused, SSH backslash refusal. App: hub start at launch, approval page, add, edit and remove devices, link sheet from `link.options`, offline chips, host-command confirmation, no Android backup. Firmware: the hardening item under M7. Docs: DESIGN and ROADMAP now separate built from planned. New open items found on the way: releasing removed board pins (engine and firmware disagree on where `describe` reports modes), provisioning stopping at the first failed command, rounding follow links into integer params, and the Pico W setup poll. Results: 338 engine tests, 51 app tests, firmware core tests in both builds and arduino-cli builds for all four boards.
- 2026-11-07: Audit follow-up across the fixers' boundaries. The engine read set-up pins from a field the firmware does not send, so a pin removed from the setting stayed set on the board: it now reads the firmware's `set` list, releases removed pins, and keeps going past a refused setup command, reporting all of them (e2e test). Follow links round into whole-number params. `board.setup` waits out the Pico W join stall (30 s default). `dart_test.yaml` now skips live tests by default, the stale `config.json` ignore is gone, and `board.found` carries a name. Results: 340 engine tests (2 live skipped), 51 app tests, firmware `check.sh` green, and the `omni` binary smoke run against the virtual board. Still unproven: physical boards, a real MQTT broker, the phone.
- 2026-11-07: TVs, hubs, discovery and the background runtime integrated. Engine: ADB over 5555 in Dart (`android_tv_adb`), LG webOS and Samsung Tizen over WebSocket with TLS pinned on first use, Hue v1 and Home Assistant REST over HTTP with secrets kept out of templates and the packet tap, mDNS and Tuya UDP discovery in `device.discover` and address healing (`idTxt`, `idInstance`, `idSetting`), a manifest `pairing` entry and `device.pair`, `device.hostkey` show, accept and clear, `board.describe` with stored describes, active-low outputs with the start level in `pin.mode`, strapping warnings, `rf_send` with `repeat`, schema 3 (the flow `trusted` column and `board_describes`), the hub control socket at `<home>/omni.sock` so the CLI and MCP run beside `omni hub`, and stty on a held descriptor for serial. An MCP invoke and a hub poll fail with `needs_user` instead of raising a TV prompt, and `pair_device` and `trust_ssh_host_key` refuse. Flow runs, agent-deployed ones included, still paired like a user command. CLI: `omni device pair`, `omni device hostkey`, `omni board describe`. App: the engine in a `flutter_foreground_task` service with the multicast lock, a Pair action, a GPIO picker from `board.describe`, the active-low switch, and settings fields in Add device. Results: 541 engine tests (2 live skipped), 80 app tests, firmware `check.sh` green, and mutation checks on the pairing guards, the secret-set reconnect, mDNS ids and the Tuya id backfill. A Tuya discovery test that rebound a freed ephemeral port, and so raced other test files for it, now checks that the sockets were closed. Proven only against loopback fakes and emulated boards. Not proven: nothing ran on a real Android TV, Fire TV, LG or Samsung TV, Hue bridge, Home Assistant, Shelly, Tuya device, board or phone, no APK was built (no Android SDK), the ADB wire format was not checked against AOSP `protocol.txt`, mDNS ran only through a fake client, and the DESIGN diagram was linted but not parse-checked (`mmdc` is not installed).
- 2026-11-07: Review fixes for the TV, hub and app work. Pairing: every flow run sends `allowPairing: false`, so an agent-deployed flow or a follow or threshold link driving an unpaired TV fails with `needs_user` and no key is offered. webOS and Tizen honour it for a stale stored key too, close at once and stop reconnecting for unattended commands until the user pairs. MCP pairing guidance names `omni device pair` or `omni secret set` on this computer. Secrets: a device whose driver has a secret setting, Tuya aside, no longer follows a discovery reply to a new host and fails with a timeout telling the user to re-add it. A refused WebSocket upgrade no longer puts the Tizen token in the error. LG defaults to `wss` on 3001. Other engine fixes: `device.remove` and a replacing add drop the TV session, `device.add` reports `missingSettings` and fills an empty `idSetting` from the stable id, discovery reports `unavailable` when no method can listen, an oversize hub request fails at once instead of hanging, `omni board pin` gained `--active-low` and keeps an existing `invert`, the certificate mismatch message offers re-adding the device, the database-in-use message says to start `omni hub` first, and closing the engine cuts off a pairing or ADB handshake still waiting. App: a scan lists hubs already in use so a second Hue light can be added, no Pair item for Home Assistant, validation issues in error messages, Done after a successful pairing, pin warnings when the sheet opens, and a restarted service's old task no longer closes the new client. Results: 561 engine tests (2 live skipped), `dart analyze` and `dart format` clean, 87 app tests and `flutter analyze` clean, each new test mutation-checked by reverting its fix. Firmware was not touched. Still open: a flow's `device_toggle` node (toggle links) can still pair, `device.remove` does not close a held ADB connection, a Hue light added after pairing needs another button press, Hue and Home Assistant lose self-healing after a DHCP change, and the app does not yet mark `missingSettings`. Not proven: all of it ran against loopback fakes only, with no real TV, Hue bridge, Home Assistant or phone.
