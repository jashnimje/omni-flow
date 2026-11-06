# AGENTS.md - omni-flow

<!-- Per-repo agent contract (workspace-hardening R17.1, R25.4). -->

OmniFlow, a local-first automation studio: driver manifests, transports and a flow engine in pure Dart, with a Flutter app on top and firmware for Pico W and Arduino. Design: `docs/DESIGN.md`.

## What this repo is

The engine (`packages/omniflow_engine/`) owns all logic and has no Flutter dependency. The app (`packages/omniflow_app/`) is Android only. It runs the engine inside a foreground service, talks to it only through command and event messages, and supplies the plugin-only sensors (BLE, NFC, Wi-Fi, notifications) through engine interfaces. The `omni` CLI exposes the same core API. `docs/ROADMAP.md` tracks milestones and status. The original spec set is folded into `docs/DESIGN.md`.

## Rules for agents

- Read `docs/DESIGN.md` before changing behaviour, and update it when a decision changes. Tick items and add a log line in `docs/ROADMAP.md` as work lands.
- No logic in the Flutter app. Device protocols, rendering, flow rules and validation belong in the engine.
- Nothing is hardcoded to one household's devices. Device ids, addresses and keys come from the user's data, and tests use fixtures.
- Never put secrets (Tuya local keys, SSH or ADB keys) in manifests, flows, tests, logs or commits. They go through `SecretStore`.
- Live tests (`dart test --tags live`) drive real devices on the LAN. Run them only when asked.
- Commit format, identity, and workspace-wide behavior: see the global rules (`dotfiles/agents/rules/`) - not restated here.

## Key paths

- `packages/omniflow_engine/lib/src/` - engine modules
- `packages/omniflow_engine/bin/omni.dart` - CLI
- `drivers/`, `schemas/` - built-in manifests and JSON Schemas
- `firmware/pico_w/main.py`, `firmware/arduino_serial_bridge/` - board firmware
- Workspace map and sibling repos: `dotfiles/agents/rules/workspace-map.md`
