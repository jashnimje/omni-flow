# Mac Mini Hub and Several Phones

> Status: approved, 2026-11-12. Building. Supersedes the "[Rejected for now] A Mac Mini hub" line in DESIGN.md.

## Problem

OmniFlow runs one engine on one phone. Each engine has its own database, so a second phone, or the Mac mini, starts empty. Today the only way to move a home is `config.export` and `config.import`, by hand, and the backup carries no secrets or pairings, so every Tuya key and TV pairing is entered again. Two phones cannot see each other's presence, and an ask goes only to the phone that ran it.

## Requirements

1. Every phone that connects sees the same devices, rooms, automations, scenes and variables, with nothing to copy.
2. Automations run once, in one place, even when two phones see the same trigger.
3. Each phone still feeds what only a phone can sense: Wi-Fi and Bluetooth presence, NFC tags, app and notification triggers, the screen, Do Not Disturb.
4. Asks and notifications reach the right person's phone.
5. It works away from home without opening anything to the internet.
6. No new network listener and no home-made authentication.
7. Installing, updating and backing up are a few commands, and the hub restarts by itself.

## What exists today

- `omni hub` keeps one engine running on a Mac and serves `<home>/omni.sock`, a 0600 unix socket in a 0700 folder. The protocol is newline JSON: `{id, command, args}` answered by `{id, result}`, and `{id, subscribe: "events"}` streaming every event. Every `omni` command and `omni mcp` already talk to a running hub this way.
- The engine has an SSH client (dartssh2) with host keys pinned on first use and `device.hostkey` to review a changed key. dartssh2 can also run a remote command with its stdin and stdout as a byte stream.
- A phone thing names its `person`, and presence is kept per person, so two people in one home already fit the model.
- On the Mac, secrets live in the login keychain under the `omniflow` service.
- `config.export` and `config.import` move a whole home, without secrets, and say which things need their secrets again.

## Options

| | A. Mac mini hub, phones as clients | B. Every device a full engine, synced | C. Phones talk to each other directly |
| --- | --- | --- | --- |
| Where config lives | Once, on the hub | A copy on every device, merged | A copy on every phone |
| Who runs an automation | The hub, always once | Whoever claims it first over the LAN | Unclear |
| Secrets | Only on the hub | Synced inside an encrypted log | Copied between phones |
| New listener | None (macOS's own SSH) | A signed UDP claim port on every device | A listener on every phone |
| Away from home | Tailscale to the hub | Each phone acts alone and can disagree | Needs a relay anyway |
| Works with the hub down | No, phones show it is down | Yes | Yes |
| Build size | Medium | Large (log, merge, claims, conflicts) | Large, and still needs B |

### A. The Mac mini is the hub, phones connect to it [Approved]

The Mac mini runs `omni hub` all the time and holds the only database, the secrets and the pairings. A phone in hub mode opens no engine of its own. Its app becomes a remote screen over the hub: every list, tile and editor reads from the hub, and every tap is a hub command. Its foreground service keeps listening to the phone's own sensors and sends them to the hub as `phone.*` inputs, tagged with that phone's id, so presence is per person. Phone to phone goes through the hub: one phone sees the other person arrive because both report to the same engine.

This meets every requirement. The weak point is that the home stops while the Mac mini is off.

### B. Every device runs its own engine and they sync [Rejected for now]

This is the deferred design in DESIGN.md: an encrypted change log in Google Drive and a signed "I will run this" claim on the LAN. It survives a hub outage, but it needs a merge for two edits made at once, a listener on every phone for the claims, secrets synced to every phone, and a rule for what an away phone does. It is several times the work of A, and the double-run risk never goes fully away. It stays the fallback if a single hub proves too fragile.

### C. Phones connect to each other directly [Rejected]

A phone would need a listener that other phones reach, which breaks requirement 6, keeps the radio awake, and still needs a relay when the phones are on different networks. Going through the hub gives the same result.

## How a phone reaches the hub

```mermaid
flowchart LR
  subgraph phone1["Phone, Jade"]
    app1["OmniFlow app"]
    sens1["Phone sensors"]
  end
  subgraph phone2["Phone, second person"]
    app2["OmniFlow app"]
  end
  subgraph mini["Mac mini"]
    sshd["macOS SSH, key only"]
    attach["omni hub attach"]
    hub["omni hub, the only engine"]
    db["Database and keychain"]
  end
  devices["Lights, plugs, TV, boards"]
  app1 -- "SSH, LAN or Tailscale" --> sshd
  sens1 --> app1
  app2 -- "SSH" --> sshd
  sshd -- "forced command" --> attach
  attach -- "omni.sock" --> hub
  hub --> db
  hub -- "Wi-Fi, ADB, USB" --> devices
  classDef new fill:#bbdefb,stroke:#1565c0,color:#0d47a1,stroke-width:2px
  class attach new
```

- **Transport: macOS Remote Login (OpenSSH).** It is an existing, maintained service with real authentication, so nothing new listens and no auth is invented.
- **A new `omni hub attach` command** copies stdin to `omni.sock` and the socket's replies to stdout, nothing else. Each phone's public key goes into `~/.ssh/authorized_keys` on the Mac mini as `restrict,command="/Users/<you>/.local/bin/omni hub attach" ssh-ed25519 AAAA... omniflow-<phone>`, optionally with `from="<LAN subnet>,100.64.0.0/10"`. `restrict` turns off shells, port forwarding, agent forwarding and terminals. A stolen phone key can then only do what the app can do, and removing that one line revokes the phone.
- **The phone side** is a new engine client in the app that speaks the same newline JSON over an SSH exec channel. The app already has two clients (in-process and the service port), so screens do not change. The phone keeps its SSH private key in the Android keystore and pins the Mac mini's host key the way device SSH already does.
- **A version check** on connect: the app reads `engine.status` and refuses a hub whose engine version differs in major or minor, with "Update the hub" or "Update the app", so command shapes never drift.

## What runs where

| Thing | Runs on |
| --- | --- |
| Devices, rooms, automations, scenes, variables, secrets, pairings | Hub |
| Schedules, sunrise, device polls, WiZ pushes, board hellos | Hub |
| TV over ADB, USB boards, MQTT, the Mac mini itself as a `macos_host` | Hub |
| Wi-Fi and Bluetooth presence, NFC scans, app and notification triggers, screen, Do Not Disturb | Each phone, sent to the hub |
| Notifications, asks, widgets, tiles, share sheet | Each phone, fed by hub events |

- **Asks:** the hub's `ask.request` event carries the automation's person when it has one. Each phone shows asks for its own person, plus asks with no person. The first answer wins, and `ask.closed` clears it on every phone.
- **Notify steps** gain an optional `to` (a person). With none, every connected phone shows it.
- **Two phones, one trigger:** each phone reports its own readings, and the engine decides per person, so "when I get home" fires once for the right person.

## When the hub is down

- The app shows "Hub not reachable" with the last known state, read-only, and keeps retrying.
- Phone readings taken while the hub was unreachable are dropped, except the latest presence, which is sent on reconnect so home and away are right again.
- No automatic fallback to a phone engine. Two engines with two databases is exactly the split that option A exists to avoid. The phone can still be moved back to "This phone" by hand from Settings, which imports the hub's latest backup.
- To keep outages rare: the Mac mini on Ethernet, on a UPS if possible, with Energy Saver set to start after a power failure and never sleep.

## Away from home

Install Tailscale on the Mac mini and on each phone, signed in to one tailnet. The phone uses the Mac mini's tailnet name as the hub address when the LAN address does not answer. Nothing is port-forwarded on the router, and SSH is never exposed to the internet. Tailscale's own identity plus the SSH key are the two checks. Lights and plugs keep working away from home, because the hub, not the phone, talks to them.

## Install

On the Mac mini, once:

1. Turn on Remote Login (System Settings, General, Sharing) for your user only, and set `PasswordAuthentication no` and `KbdInteractiveAuthentication no` in `/etc/ssh/sshd_config.d/omniflow.conf`.
2. Build `omni` on the dev Mac with `dart compile exe bin/omni.dart -o omni` (both Macs are arm64) and copy it to `~/.local/bin/omni` on the Mac mini.
3. Run `omni hub install`, which:
   - writes `~/Library/LaunchAgents/com.jashnm.omniflow.hub.plist` with `RunAtLoad` and `KeepAlive`, running `omni hub --quiet` and logging to `~/Library/Logs/OmniFlow/hub.log`, so the log holds starts and errors rather than every event
   - loads it with `launchctl bootstrap gui/$(id -u)`
   - sets up a daily `omni hub backup` (a second LaunchAgent at 03:30), which writes `config.export` to `~/OmniFlow/backups/omniflow-<date>.json` and keeps 30
   - prints the sshd settings for `/etc/ssh/sshd_config.d/omniflow.conf`, which you place with sudo
4. Allow `omni` in the macOS firewall prompt the first time, so WiZ pushes (UDP 38900) and board hellos (UDP 38951) arrive.

The hub runs as a LaunchAgent in your login session, not as a system daemon, because its secrets are in your login keychain, which is locked until you log in. With FileVault on, macOS turns off automatic login, so after a power cut the hub waits until someone logs in once. Planned restarts avoid this with `sudo fdesetup authrestart`.

On each phone:

1. Install the app as today.
2. Settings, Home runs on, Mac mini hub. The app finds the Mac mini over mDNS (`_ssh._tcp`, which Remote Login advertises), or takes an address.
3. The app makes a key pair and shows a one-line `omni hub allow <name> <key> --person <person>` command and a QR code. Run it on the Mac mini. It adds the restricted `authorized_keys` line and makes the phone thing `<name>` with that person, which the phone's readings name. So `<name>` is a thing id: lower-case letters, digits and `_`.
4. The app connects, shows the hub's host key fingerprint, and asks you to match it against `omni hub fingerprint` on the Mac mini.

## Moving today's home onto the hub

1. On the phone, Settings, Backup, export.
2. On the Mac mini, `omni config import backup.json --dry-run`, then without `--dry-run`. The reply lists `needsSecrets`.
3. Enter each secret on the Mac mini with `omni secret set`, and pair the TV again from the hub, because its ADB key is the hub's own.
4. Approve the automations that came back waiting.
5. Switch the phone to hub mode. Its own database stays on the phone, unused, until "Forget this phone's home" is tapped.

## Maintain

- **Updates:** both ends come from one repo commit and one version. Release the APK and the hub binary together. On the Mac mini, `omni hub update <binary>` replaces the binary and runs `launchctl kickstart -k`. A phone on the old version sees "Update the app" until it updates.
- **Health:** `omni hub status` shows uptime, version, connected phones, the last run and load issues. The app shows the same under Settings, Hub. A phone not seen for 7 days is listed there.
- **Backups:** the daily export on the Mac mini, plus the existing "Back up to Google Drive" from any phone, which now exports the hub's home. Secrets are in the Mac mini's keychain, which Time Machine already covers.
- **Revoke a phone:** `omni hub revoke <name>` deletes its `authorized_keys` line. The next connection from that phone fails. A session that is already open stays until it drops, so for a lost phone also restart Remote Login. The phone thing stays, with its history.
- **Config files:** `omni hub install` writes the launchd plists and prints the sshd snippet, from templates in this repo (`packages/omniflow_engine/tool/hub/`). They stay out of dotfiles, since OmniFlow is a personal project kept to its own repo.

## What gets built

1. `omni hub attach`, `install`, `allow`, `revoke`, `fingerprint`, `update` and `status`, with tests against a loopback hub.
2. The app's SSH engine client, "Home runs on" in Settings, hub discovery and the key and fingerprint steps.
3. Hub mode for the foreground service: no local engine, phone readings and NFC scans sent as `phone.*` inputs with the phone's id, asks and notifications from hub events, filtered by person.
4. `to` on notify steps and the person on asks.
5. The version check and the "Hub not reachable" state.
6. The Tailscale fallback address.

Each step goes through the builder-security skill where it touches SSH or a listener.

## Decisions

- **Hub down:** phones are read-only with the last known state until the hub is back. Option B stays the later route if outages matter.
- **FileVault:** stays on. After a power cut someone logs in once, and planned restarts use `fdesetup authrestart`.
- **Second person:** gets the full app on the same home.
