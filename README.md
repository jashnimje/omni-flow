# omni-flow

## Purpose

OmniFlow is a local-first automation studio. It controls LAN smart devices, desktop hosts and microcontrollers directly, and wires them together with flows that run on the phone itself. Design: `docs/DESIGN.md`. Plan and status: `docs/ROADMAP.md`.

## Contents

- `packages/omniflow_engine/` - pure Dart engine and the `omni` CLI (from M0)
- `packages/omniflow_app/` - Android app (from M0)
- `drivers/` - built-in driver manifests (from M1)
- `schemas/` - JSON Schemas for manifests and flows (from M1)
- `firmware/` - Pico W MicroPython and the Arduino sketch
- `docs/` - design (`DESIGN.md`) and roadmap with checks (`ROADMAP.md`)

## Conventions

Personal project: local git only, no remote, personal commit identity, conventional commits. `.dart_tool/` cannot be moved out of the synced tree, so it stays gitignored. Flutter `build/` output goes outside the tree where the command allows it.
