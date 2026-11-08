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

After changing anything in `../../drivers/`, run `dart run tool/embed_drivers.dart` (a test fails until you do). After changing `lib/src/storage/database.dart`, run `dart run build_runner build`.

Flows. Save the sample flow from `docs/DESIGN.md` (Flows, Schema v1) to a file first. Its id is `flow_arrive_desk_evening`.

```sh
omni flow save arrive_desk.flow.json       # validated against your devices and zones
omni flow dry-run flow_arrive_desk_evening --at 2026-11-06T19:00
omni var set HomeSsids '["HomeNet"]'
omni hub                                   # runs every enabled flow until Ctrl-C or SIGTERM
```

Every `omni` command, `omni hub` and `omni mcp` included, holds the database lock while it runs, so only one of them can use a data directory at a time.
