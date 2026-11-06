# OmniFlow Roadmap

> Status: active. M1 code is complete and tested against emulated devices, except MQTT (deferred) and Tuya v3.4 or v3.5 (waiting on the scan). Next: the M1 live exit test on real hardware, then M2. Design: `docs/DESIGN.md`.

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
- [ ] Transports: UDP with request and retry, Wake-on-LAN, directed broadcast and the packet tap (done), WiZ push registration renewed every 20 s with `syncPilot` routed by MAC (done), the Tuya v3.3 codec with frame splitting, matching tinytuya golden frames (done), the Tuya TCP channel with a persistent connection per device (done), v3.4 or v3.5 if the scan below needs them, HTTP (done, with Shelly Gen2 RPC checked against Shelly's docs), MQTT (deferred until a device needs it: none of the current hardware speaks MQTT, and it needs a broker to test against), local argv execution and POSIX quoting for SSH (done), the SSH executor with host keys pinned on first use (done, live test opt-in: `OMNI_SSH_HOST`, `OMNI_SSH_USER`, `OMNI_SSH_KEY`), the NDJSON line decoder with streaming UTF-8 and a line cap (done), serial port access through stty, with reads via cat so a close never blocks (done, tested over a pseudo-terminal).
- [x] Device runtime: per-device queue, timeouts and retries, address healing, poll and push state, optimistic state, liveness check. Scheduling the polls lands with `omni hub` in M2.
- [x] Discovery: UDP probe to 255.255.255.255 and a /24 broadcast per interface, matched by JSONPath, with the stable id read for address healing. USB serial boards found by sending `describe` to each `/dev/cu.usbmodem*` or `/dev/ttyACM*` port. Both behind `omni device discover`. mDNS waits for a device that needs it (WiZ does not use it, Shelly works by IP).
- [ ] Built-in drivers: WiZ (done), Tuya plug on DP 1 (done; bulb DPs after the scan), macOS host (done), Linux host (done), Shelly Plus switch (done), MCU node over UDP and over USB serial (done), Android TV ADB (moved to M4 with the rest of ADB: the TV is not available and the AOSP protocol reference could not be fetched).
- [x] Firmware v1: Pico pin allowlist, `describe`, request ids, onboard LED, UDP NDJSON channel with `config.json`. Arduino: bounded buffer, `describe`, request ids. Pico code passes a Python syntax check and its NEC bit logic passes a host test (`firmware/pico_w/test_nec.py`). The Arduino sketch is not compiled yet (no `arduino-cli`). Neither has run on a board.
- [x] CLI: `omni driver list|validate|register`, `omni device add|discover|list|get|invoke|refresh|remove`, `omni secret set`, `omni watch [--packets]` (which replaces the planned `omni sniff`).
- Exit: from the CLI, the real WiZ goes to 80% at 3000K, the real Tuya plug toggles, the Pico acknowledges an IR send over serial and over UDP, and the Mac changes volume over SSH.

## M2 - Flow engine running headless

- [ ] Flow model, schema v1, validator.
- [ ] Node type registry and the node set in `docs/DESIGN.md`.
- [ ] Variables (`$Global`, `%flow`, `msg`) and the Wi-Fi bindings.
- [ ] Zones as entities, with the Kalman filter (time-scaled Q), silence tick and hysteresis, fed by recorded traces in tests.
- [ ] Executor: run modes, concurrent branches, cooldown armed at the first action, gates, traces to the execution log, dry run with an injectable clock.
- [ ] CLI: `omni flow validate|run|dry-run`, `omni zone`, `omni hub`.
- Exit: the evening-desk flow passes end to end on fakes, and runs live from `omni hub` with a Pico button press as the trigger.

## M3 - Android app

- [ ] Foreground service owning the engine and database, the app's engine client over the service channel, and Riverpod providers over the event stream.
- [ ] Dashboard generated from capability types, plus the command bar.
- [ ] Flow editor: card tree and vyuh_node_flow canvas over one flow JSON, inline validation errors, live run highlighting.
- [ ] Packet inspector over the transport taps, with capture-to-node and the BLE RSSI chart.
- Exit: build and run the evening flow from the phone, and see its packets in the inspector.

## M4 - Background runtime, presence, ADB

- [ ] Platform bridges: multicast lock, Wi-Fi changes, notification listener, app foreground, charging, screen lock, boot.
- [ ] BLE scanning on demand with scan filters, the NFC trigger.
- [ ] ADB over 5555 in Dart, with the `adb` binary as the desktop fallback. Live test once the TV is available.
- Exit: walking up to the desk with the phone in a pocket turns the lamp warm and wakes the Mac, with no laptop process running.

## M5 - MCP, AI architect, firmware generator

- [ ] Tool registry with full validation and MCP error results, plus device-state resources, and the manifest and flow JSON Schemas in `schemas/` for MCP clients.
- [ ] `omni mcp` over stdio.
- [ ] Approval flow in the app for high-risk manifests, flows and imports.
- [ ] In-app architect on the command bar, with a diff and approval before anything is saved.
- [ ] Firmware templates for Pico and Arduino.

## M6 - Optional

- [ ] Accounts and sync as recorded in `docs/DESIGN.md`: Google sign-in, an encrypted change log in the user's Drive, and first-wins flow claims over home Wi-Fi.
- [ ] Hue CLIP v2 SSE, LG webOS, Samsung Tizen, Home Assistant, Zigbee2MQTT, a Matter sidecar, ARP presence in hub mode, 433 MHz RF firmware.

## Checks

### Before M1: hardware, network and accounts (manual)

1. **Router.** Phone, Mac, bulbs and plugs on the same subnet. AP or client isolation off, because it blocks phone-to-device traffic. Most WiZ and Tuya devices are 2.4 GHz only. A DHCP reservation per device is optional, since address healing covers IP changes.
2. **WiZ.** Find the bulb's IP in the router or the WiZ app. From the Mac, `echo '{"method":"getPilot","params":{}}' | nc -u -w1 <ip> 38899` should print a JSON reply. Note the `moduleName` from `getSystemConfig`.
3. **Tuya and Wipro.** Check that the Wipro devices pair with the Smart Life app, since OEM apps can lock devices to their own cloud. Create a Tuya IoT developer project, link the Smart Life account, then run `python -m tinytuya wizard` (mise python) for the local keys and `python -m tinytuya scan` for each device's protocol version. The versions decide whether v3.5 is in M1. Close the vendor app while testing, because the device takes one local connection.
4. **Mac.** System Settings, General, Sharing, Remote Login on, and note the username. Over SSH from another machine, try `osascript -e 'output volume of (get volume settings)'`, `caffeinate -u -t 2` with the display asleep, and `shortcuts run <name>`. The last two may need a logged-in GUI session, and the result decides which `macos_host` capabilities work from the phone.
5. **Pico W.** MicroPython version on the board, `mpremote` installed (mise python), IR LED on GPIO 15 through a transistor driver, button on GPIO 14, potentiometer on GPIO 26.
6. **Arduino.** Board model, `arduino-cli` installed, button on pin 2, relay on pin 4.
7. **Phone.** Model, Android version and maker, because some makers kill background services beyond what stock Android does. Developer options and USB debugging on, for installing builds.
8. **Android TV, when available.** Developer options, network or ADB debugging on, the IP noted, and whether port 5555 stays open after a reboot.

### Early spikes (short throwaway tests to retire design risks)

1. **WiZ push.** Send `registration` per pywizlight, then confirm `syncPilot` arrives on 38900 when the bulb is changed from its own app. Measure how long until it stops without renewal.
2. **Tuya frames.** Generate v3.3 (and v3.4 or v3.5 if the scan needs them) control and status frames with tinytuya for a fixed key, sequence number and timestamp, and save them as golden test vectors.
3. **Android BLE in the background.** With a foreground service running and the screen off for 30 minutes, check that a filtered scan for the Pico's advertised name keeps reporting, and at what rate. Check what happens to an unfiltered scan, and to restarting scans often. Record an RSSI trace while walking to the desk, sitting, and leaving, and keep it as a test fixture to tune the zone thresholds.
4. **Service isolate plugins.** Check that universal_ble, network_info_plus and the multicast lock work inside the flutter_background_service isolate, and measure round-trip time on the service channel.
5. **Phone LAN.** With the multicast lock held, confirm the phone receives WiZ discovery replies to a subnet-directed broadcast.
6. **Mac CLI privacy.** Check whether `omni` run from Terminal gets a Local Network permission prompt for UDP broadcast and mDNS.
7. **SSH from the phone.** dartssh2 4.x with an ed25519 key generated in the app, the host-key callback, and exec with argv quoting.
8. **Canvas on a phone.** vyuh_node_flow 0.32 pan, zoom and port dragging with touch on a phone-sized screen.

### Per-milestone acceptance checks

- **M1:** a command with a param out of range sends nothing. A string param containing `; rm -rf ~` reaches the target as one literal argument (check with a script that echoes its argv). Dropping a WiZ reply triggers a retry. Changing the bulb's IP triggers address healing. A grep of the logs, the packet capture and an export finds no local key or SSH key.
- **M2:** validator rejects a cycle, a dangling edge, an unknown port and an unreachable action. A trigger during a delay behaves per each run mode. A trigger that fails the condition does not arm the cooldown. `time_window` 18:00-05:00 matches at 23:00 and 02:00 and not at 12:00. A schedule across a DST change fires once. The recorded RSSI trace produces exactly one enter and one exit, and silence alone produces an exit.
- **M3:** card view round-trips the example flow without changes. A graph that is not a tree shows read-only cards. Edits in either view show in the other.
- **M4:** flows still fire after the app is swiped away, after an hour with the screen off, and after a reboot (connectedDevice service only, until the app is opened). Battery drain over 24 hours on home Wi-Fi is measured and recorded here. BLE scanning stops when the phone leaves home Wi-Fi.
- **M5:** an MCP call that registers an `exec` driver leaves it disabled until approved in the app. An invalid flow from MCP returns an error result listing every validation error.

### Security checks (every milestone)

- No listening sockets: `lsof -nP -iTCP -sTCP:LISTEN` on the Mac while the app and `omni hub` run, and the same check on the phone over `adb shell`.
- No secrets in the repo: a grep for key-shaped strings before each commit, and fixtures use made-up keys.
- High-risk content from MCP, the architect and imports waits for approval.

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
| ADB legacy protocol (CNXN, AUTH token types, OPEN, WRTE) | AOSP `protocol.txt` | Not checked. Every mirror tried returned 404. Checked before the ADB work in M4 |

## Verification

- Engine: `dart analyze`, `dart format --set-exit-if-changed .`, `dart test`. Live tests: `dart test --tags live`, opt-in, against real devices.
- App: `flutter analyze`, `flutter test`, then runs on a real Android phone, with screenshots.
- Firmware: `python3 -I firmware/pico_w/test_nec.py` on the host, then `mpremote` on the Pico W with a `describe` and `ir_send` round trip, and `arduino-cli compile` for the sketch.

## Log

- 2026-11-06: M0 started. Repo created, specs consolidated into `docs/DESIGN.md`, archive deleted. The mermaid diagram in `docs/DESIGN.md` passes `lint-mermaid.py`, but has not been parse-checked because `mmdc` is not installed.
- 2026-11-06: Workspace scaffolded. Engine: `dart analyze` clean, `dart format` clean, 2 tests pass, `dart run omniflow_engine:omni --version` prints `omni 0.1.0`. App: `flutter analyze` clean, 1 widget test passes. No device build yet (needs the Android SDK).
- 2026-11-06: Design review. Added the command and event core API, single database owner, protocol coverage, device runtime (queue, retries, address healing, polling), zones as entities, time-scaled Kalman Q, run modes, sensors on demand, the UI section, and Android service types verified against the Android 15 behaviour changes. Original spec files removed after every piece of their content was folded into `docs/DESIGN.md` or into a decision there. Repo identity moved from a repo-local setting to `includeIf`.
- 2026-11-06: Scope set to Android only, with no accounts. Sync choices (Google sign-in, encrypted Drive change log, first-wins claims over home Wi-Fi) recorded in `docs/DESIGN.md` as deferred.
- 2026-11-06: M1 engine batches landed: template renderer, manifests, registry, UDP, Tuya codec and channel, host exec, SSH, NDJSON, device runtime, storage, core API, CLI and WiZ discovery. 130 tests pass. The first `omni device discover --driver philips_wiz_udp` on the real LAN found no bulbs, not yet diagnosed (bulb power, network, or the Mac Local Network permission for the terminal).
- 2026-11-06: Checked the build against primary references (tinytuya, pywizlight, SB-Projects NEC, pico-sdk, RFC 9535, Android and macOS docs, dartssh2 source). Two fixes landed: the WiZ discovery probe and NEC bit order. Findings are in the table above.
- 2026-11-06: M1 completed in code: WiZ push, engine events and `omni watch`, the HTTP channel with Shelly and Linux drivers, USB serial with discovery. 148 engine tests pass. Live hardware test still to run.
