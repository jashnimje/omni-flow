# AGENTS.md - omni-flow

<!-- Per-repo agent contract (workspace-hardening R17.1, R25.4). -->

OmniFlow, a local-first automation studio: driver manifests, transports and a flow engine in pure Dart, with a Flutter app on top and one firmware for ESP32, ESP8266, Pico W and Uno boards. Design: `docs/DESIGN.md`.

## What this repo is

The engine (`packages/omniflow_engine/`) owns all logic and has no Flutter dependency. The app (`packages/omniflow_app/`) is Android only. The engine runs in a `connectedDevice` foreground service (`lib/service/`), and the UI talks to it only through command and event messages with `ServiceEngineClient`. The phone's NFC reader, battery and Wi-Fi live in the app and reach the engine as commands (`nfc.scanned`, `phone.battery`, `phone.wifi`), and notifications, apps, calls, media, the calendar and motion do the same (BLE scanning is not built). Either way the app holds no logic, and every command the app sends is named in a calls class in `lib/api/` (`engine_calls.dart` and its siblings). The `omni` CLI exposes the same core API. `docs/ROADMAP.md` tracks milestones and status. The original spec set is folded into `docs/DESIGN.md`.

## Rules for agents

- Read `docs/DESIGN.md` before changing behaviour, and update it when a decision changes. Tick items and add a log line in `docs/ROADMAP.md` as work lands.
- No logic in the Flutter app. Device protocols, rendering, flow rules and validation belong in the engine. Words for a rule come from `SentenceContext` (`lib/src/api/automation_view.dart`), and the app's editor reads them through `rule.words`. A pure engine function the app needs (`daysWords`, `typedValue`, `ruleMissing`, `keepStepsLast`) is exported from `omniflow_engine.dart` and imported, never copied.
- Nothing is hardcoded to one household's devices. Device ids, addresses and keys come from the user's data, and tests use fixtures.
- Never put secrets (Tuya local keys, SSH or ADB keys, TV pairing keys, Hue usernames, Home Assistant tokens) in manifests, flows, tests, logs or commits. They go through `SecretStore`.
- Commands to a device shell (ADB) are built only from validated params, never from free text. Pairing and SSH host keys are the user's steps: MCP refuses them with `needs_user`.
- Agent-written content is untrusted. Rules and flows from MCP are saved untrusted. What else an agent may do is the user's access level (`agent_policy.dart`): `read` by default, `setup` once the user allows it, and the user-only list at every level. No MCP tool stores a secret, pairs, removes or moves a thing, writes an NFC tag, reports a scan, sets a board peripheral or flashes a board.
- A new command goes in the command table in `omni_engine.dart`, with an entry in `agent_policy.dart` and its CLI verb in `lib/src/cli/` (`omni_command_runner.dart` or a `*_cli.dart` beside it, with help text). After a schema change in `lib/src/storage/`, run `dart run build_runner build --delete-conflicting-outputs`.
- Tests stay on loopback: fake TVs, a fake adbd, a fake mDNS client, `InMemorySecretStore`. Pass `mdns:` to `OmniEngine.open` in a test that discovers or heals.
- Live tests (`dart test --tags live`) drive real devices on the LAN. Run them only when asked.
- Commit format, identity, and workspace-wide behavior: see the global rules (`dotfiles/agents/rules/`) - not restated here.

## Key paths

- `packages/omniflow_engine/lib/src/` - engine modules
- `packages/omniflow_engine/bin/omni.dart` - CLI
- `packages/omniflow_engine/lib/src/api/` - the core API, one file per concern. `omni_engine.dart` builds the command table and opens the channels. `automation_commands.dart`, `add_commands.dart` with `thing_setup.dart`, `nfc_tags.dart` and `things_runtime.dart` hold the unified model
- `packages/omniflow_engine/lib/src/dag/` - flows, the node types, the rule compiler (`rules.dart`, `rule_shorthand.dart`) and the migration of retired node types (`migrate.dart`)
- `packages/omniflow_engine/lib/src/devices/` - channels, with `adb/`, `tv/` and `discovery/` (mDNS, Tuya UDP)
- `drivers/` - built-in manifests, embedded into `lib/src/manifest/built_in_drivers.g.dart` by `dart run tool/embed_drivers.dart`
- `firmware/omniflow_node/` - the one board firmware (ESP32, ESP8266, Pico W, Uno) and its native virtual board; `./check.sh` tests and compiles it
- Workspace map and sibling repos: `dotfiles/agents/rules/workspace-map.md`
