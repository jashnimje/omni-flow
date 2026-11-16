# Houses

> Status: approved, 2026-11-17. Building.

## Problem

People have more than one home: a main home in Mumbai and a work home in Bangalore. Today OmniFlow has one home, so devices, rooms, automations and scenes from both places sit in one list. While in Bangalore you see Mumbai's lights, and a scene could reach for a device in the other city.

## Requirements

1. Each home is a house with its own devices, rooms, places, automations, scenes, variables, house mode, timers, home location and weather.
2. The app shows one house at a time. Nothing from another house appears in lists, search, suggestions, Home or the editor's pickers.
3. Switching is one tap, and the app switches by itself when the phone arrives at a house it knows.
4. Every house's automations keep running whichever house is shown, so Mumbai's away lighting runs while you are in Bangalore.
5. You, your person and your phones are shared across houses.
6. An automation or scene can only use things from its own house.
7. A home made before houses existed becomes the first house with nothing lost.

## Options

| | A. Houses inside one engine | B. One engine and database per house |
| --- | --- | --- |
| Shared person and phones | Natural | Copied into each |
| Switching | A view filter | Close one engine, open another |
| Automations of the house not shown | Keep running | Stop, unless every engine runs at once |
| Backup | One file, or one per house | One per house |
| Hub per house later | A hub serves its house | Natural |

- **[Approved] A. Houses inside one engine.** Requirements 4 and 5 rule out B: with one engine per house, the other house's automations stop or need a second engine running, and the person and phones would be copied into each house.
- **[Rejected] B.** It is simpler to isolate but breaks requirements 4 and 5.

## How it works

- **Each item belongs to one house.** Every thing, room, automation, scene, link, variable, timer and mode carries a `house` id. People and phones belong to no house and show everywhere. Place things belong to their house, which is how the phone knows where it is.
- **The house in view is a setting of each client,** not of the engine. A phone shows one house, while a CLI on another Mac can look at another. Commands that list or create take `house`. When it is left out, they use the house in view.
- **Isolation is enforced at save.** An automation, scene or link that names a thing from another house is refused, with plain words. A device moved to another house turns off the automations that used it, the same way removing it does.
- **Switching by arrival.** When the phone's presence puts its person at a place of house X, the app switches to X and says "Now showing Bangalore". A manual switch sticks until the next arrival somewhere.
- **Per-house settings.** Home location, sunrise and sunset, weather, house mode and its follow-presence switch, sun-following lights, away lighting, energy price and alerts are kept per house. Day stats count per house.
- **Migration.** On first open the engine makes one house, "Home", and puts everything that exists into it. The person can rename it.
- **CLI and MCP.** `omni house list|add|rename|remove|use`, and every list and create verb takes `--house`. MCP tools take an optional `house`. Removing a house with things in it is refused until they are moved or removed.
- **Backups** export one house or all houses. Restore asks which house to restore into.

## The app

- **Switcher.** The house name sits at the top of Home ("Mumbai" with a down arrow) and opens the list of houses, with "Add a house".
- **One house everywhere.**
  - Devices, Automations, Scenes, Search, the Run grid, suggestions, room tiles and the editor's pickers show the house in view.
  - Settings, Your home becomes Settings, This house, with its location, mode and Wi-Fi place.
  - First-run setup and Add a house share the same steps.
- **Rewards leave Home.** The hero keeps the greeting, the house switcher and one status line. It no longer shows today's numbers, the streak or taps saved, and the achievements and confetti are gone from Home. Celebrations are off by default. The stats and achievements page stays under Settings, Your activity, for anyone who wants it.
