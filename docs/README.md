# OmniFlow docs

Start with the four files at the repo root: [README.md](../README.md) for what OmniFlow is, [ARCHITECTURE.md](../ARCHITECTURE.md) for how the code fits together, [DESIGN.md](../DESIGN.md) for the app's design system and [CONTRIBUTING.md](../CONTRIBUTING.md) for setup and the checks every change passes. The docs below go deeper.

## Engine and plan

- [engine-design.md](engine-design.md) - the full design of the engine: driver manifests, transports, flows, rules, presence, storage, MCP, security and platform support, with every decision and the options it beat.
- [ROADMAP.md](ROADMAP.md) - what works today, what still waits on real hardware, and what is planned.

## Feature designs

- [design/houses-design.md](design/houses-design.md) - several homes in one engine, each with its own things, rooms and automations, sharing the people and phones.
- [design/hub-design.md](design/hub-design.md) - a Mac mini as the always-on hub, with phones as clients over SSH.
- [design/phone-control-design.md](design/phone-control-design.md) - controlling a second Android phone over Wireless debugging, the way the TV is controlled.
- [design/flow-diagram-design.md](design/flow-diagram-design.md) - the automation diagram: a rule drawn as a decision graph that can be edited and that lights up with a run.
- [design/home-mesh-design.md](design/home-mesh-design.md) - deferred: a standby device that takes over when the hub goes quiet.

## App UI

- [ui/design-v2.md](ui/design-v2.md) - the current look: device tiles, automation cards and stacked blocks, the Material 3 and WCAG parameters, the collapsed section and the token changes.
- [ui/page-templates.md](ui/page-templates.md) - the eight page templates and the screen inventory they were chosen from.
- [ui/ui-spec.md](ui/ui-spec.md) - the earlier written screen spec: what each screen shows and which engine calls it makes.

## Images

- [screenshots/](screenshots/) - the app on the Android emulator, in light and dark, with demo data.
- [brand/](brand/) - the logo source, the app mark and the store icon.
