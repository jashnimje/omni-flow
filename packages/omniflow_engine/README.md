# omniflow_engine

Pure Dart OmniFlow engine and the `omni` CLI. Design: `../../docs/DESIGN.md`.

```sh
dart test -x live                           # unit tests
OMNI_KEYCHAIN_TEST=1 dart test --tags live  # plus live tests (keychain, SSH when OMNI_SSH_* is set)
dart run omniflow_engine:omni --help
```

Data lives in `$OMNIFLOW_HOME` (default `~/.omniflow`), secrets in the macOS keychain under the `omniflow` service.

```sh
omni device add desk_lamp --driver philips_wiz_udp --host 192.168.1.40 --stable-id a8bb50aabbcc
omni device invoke desk_lamp color_temp value=3000 brightness=80

omni device add plug --driver tuya_plug --host 192.168.1.41 --set devId=bf...
omni secret set plug localKey < local_key.txt
omni device invoke plug power value=true
```

A Tuya plug takes its `devId` as its stable id, so it is found again by its UDP announcement when its address changes. A device that sends a secret (Hue, Home Assistant, MQTT, LG and Samsung TVs) does not follow a new address: give it a DHCP reservation, or add it again with the new host. TVs and Hue bridges are paired once. Pairing a Hue bridge stores its username for the lights already added on it, so add every light first. A light added later needs another `omni device pair` and another press of the button. `omni device pair` prints what to do on the device, then waits for it:

```sh
omni device add tv --driver android_tv_adb --host 192.168.1.60 --set mac=AA:BB:CC:DD:EE:FF
omni device pair tv                        # accept "Allow USB debugging?" on the TV
omni device add lamp --driver philips_hue_light --host 192.168.1.20 --set lightId=1
omni device pair lamp                      # press the bridge's link button first
omni device add hall --driver home_assistant_entity --host 192.168.1.5 --set entityId=light.hall --set domain=light
omni secret set hall token < ha_token.txt  # a long-lived access token
```

An Android TV over ADB is controlled with `omni tv`, the same `tv.*` commands the app's TV control centre calls. Transfers print progress to stderr, and a target that exists is refused unless `--overwrite` is given:

```sh
omni tv tv state                          # power, app in front, playback, volume
omni tv tv keys                           # the key catalog by group
omni tv tv remote home                    # also: --long, --repeat 1..20, or a keycode such as 244 (HDMI 2)
omni tv tv text 'stranger things'
omni tv tv volume 25
omni tv tv apps --filter user --launchable
omni tv tv apps open|stop|info|clear-cache|clear-data|disable|enable|uninstall com.netflix.ninja
omni tv tv apps install ./app.apk --replace
omni tv tv settings catalog               # curated, typed, by category
omni tv tv settings list global
omni tv tv settings get|delete global animator_duration_scale
omni tv tv settings set global animator_duration_scale 1.0
omni tv tv files ls|stat /sdcard/Download
omni tv tv files get /sdcard/Download/a.mp4 ./a.mp4 [--overwrite]
omni tv tv files put ./a.mp4 /sdcard/Download [--overwrite]
omni tv tv files cp|mv FROM TO [--overwrite]
omni tv tv files rm /sdcard/Download/old -r
omni tv tv files mkdir /sdcard/Download/new
omni tv tv files rename /sdcard/Download/a.mp4 b.mp4
omni tv tv shell getprop ro.build.version.sdk
omni device shell tv                      # an interactive shell that keeps its folder
```

Live TV tests run against a real TV with `dart test -t live --run-skipped test/devices/adb/tv_live_test.dart` (`OMNI_LIVE_HOME`, default `~/.cache/omniflow/tvhome`, and `OMNI_LIVE_TV`, default `tv`). They change only the volume by one step and back, Home when nothing plays, `animator_duration_scale` to 1 and back, and a test folder under `/sdcard/Download` they delete.

SSH host keys are pinned on first use. After a host is reinstalled, `omni device hostkey mac` shows the pinned and offered keys, `omni device hostkey mac --accept SHA256:...` pins the offered key when it is the one you checked, and `--clear` drops the pin. `omni board describe desk` shows what a board offers and the pins it has set.

Adding anything goes through one pipeline. `omni add` lists what every discovery method finds, adds the one picked and walks its setup steps (pair, secrets, settings) as the engine reports them. Secrets are read from stdin, never taken as arguments:

```sh
omni add                                  # list what is on the network
omni add --pick 2                         # add the second find and set it up
omni add --driver home_assistant_entity --host 192.168.1.5 --name Hall
omni add --resume hall                    # continue a setup left half way
```

Rules say when, only if, then, in the same words the app and Claude use:

```sh
omni rule add 'Welcome home' --when home:entered --only-if 'lamp.power!=true' --then lamp.power=true --then 'notify:Welcome home'
omni rule add 'Front door' --when nfc:front_door --then hall.power=true --then wait:2s --then 'set:$Door=open'
omni rule list
```

NFC tags, the phone's inputs by hand, and a reader on a board over USB:

```sh
omni tag add front_door 'Front door' --uid 04:A2:2B:1C
omni tag scan 04A22B1C                    # as if the phone read it
omni phone wifi HomeNet                   # the phone joined the home Wi-Fi
omni phone battery 15 unplugged
omni board periph /dev/cu.usbserial-110 nfc_rc522 --pin ss=8 --pin rst=9
```

After changing anything in `../../drivers/`, run `dart run tool/embed_drivers.dart` (a test fails until you do). After changing `lib/src/storage/database.dart`, run `dart run build_runner build --delete-conflicting-outputs`.

Flows. Save the sample flow from `docs/DESIGN.md` (Flows, Schema v1) to a file first. Its id is `flow_arrive_desk_evening`.

```sh
omni flow save arrive_desk.flow.json       # validated against your devices and zones
omni flow dry-run flow_arrive_desk_evening --at 2026-11-06T19:00
omni var set HomeSsids '["HomeNet"]'
omni hub                                   # runs every enabled flow until Ctrl-C or SIGTERM
```

While `omni hub` runs, other `omni` commands, `omni watch` and `omni mcp` reach it through its control socket `<home>/omni.sock` (mode 0600). With no hub running, each command opens the engine and holds the database lock while it runs. An MCP client such as Claude Desktop starts `omni mcp` on its own, so start `omni hub` before it. Otherwise `omni mcp` holds the lock and `omni hub` exits 75 with a message saying so.
