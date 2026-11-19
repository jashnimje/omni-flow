# omniflow_app

Flutter client for OmniFlow. Design: `../../docs/engine-design.md`.

On iOS, macOS, Windows and Linux the engine runs in the app's own isolate while it is open (`lib/service/in_app_runtime.dart`), and `DeviceFeatures` (`lib/state/device_features.dart`) hides what only Android has. The rest of this page is the Android app.

On Android the engine runs in a `connectedDevice` foreground service (`flutter_foreground_task`), so automations keep running with the screen off and after the app is swiped away. The service's task runs in its own Flutter engine and isolate, and it is the only place that opens the database. The UI reaches it only through `EngineClient`: `ServiceEngineClient` sends JSON command and event messages over the plugin's data channel (`lib/service/`). The notification's Stop button asks first and says how to start again. A watchdog alarm (`ServiceKeeper.kt`) starts a service Android killed, and a widget, tile or shortcut tap starts a stopped one.

The service holds its locks only while something needs them: the CPU wake lock during a run and around time triggers, and the multicast lock (`MulticastLockBridge.kt`) during a run, while a board on Wi-Fi is in the home and while a screen shows. Time triggers wake the phone with exact alarms. `DESIGN.md` (Platform support) has the details.

The app holds no logic. Every engine command it sends is named in a calls class in `lib/api/`: `EngineApi` in `engine_calls.dart`, and `tv_calls.dart`, `rule_calls.dart`, `diagram_calls.dart`, `smart_home_calls.dart`, `house_calls.dart`, `screen_calls.dart` and their siblings. The rule editor's words come from the engine (`rule.words`), so a part reads the same in the editor, on the automation card and in the diagram. What keeps Save off, how typed values read ("on" and "yes" are true) and the keep step order are the engine's (`ruleMissing`, `typedValue`, `keepStepsLast`). Undo after removing an automation is `automation.unremove`, and Find it on the network is `device.move`.

Rules are built in the rule editor, as a sentence or as a diagram of one draft: WHEN, ONLY IF and THEN, with nested groups on their own pages. Test run and Try as if send the rule to `automation.dry_run`, and the diagram lights the last run, a test run or a live one. A rule an agent wrote waits for approval, is saved untrusted, and opens its review page, so the editor never approves it. The rule JSON is the engine's stored rule form (`lib/rules/rule_spec.dart`), and `test/real_rules_test.dart` checks it against the engine's normalizer.

The Add button lists what `thing.add` finds and follows its `next` steps: pair with `device.pair`, secrets with `secret.set` in masked fields, settings with `thing.configure` (each with the driver's help text), a board's pins in the pin sheet. Setup steps in a device's menu resumes from `thing.next`.

The phone's inputs reach the engine as `phone.*` commands from the Kotlin bridges: battery and Wi-Fi (`PhoneSensorsBridge.kt`), notifications, the app in front, calls, media and the calendar (`NotificationTriggers.kt`), and shake and face down (`MotionSensor.kt`). Phone actions run in `PhoneActionsBridge.kt`. NFC uses `nfc_manager` in reader mode while the app is in front and sends each tag as `nfc.scanned`. A tag written from a tag's page gets the records `tag.write_payload` returns, and the `NDEF_DISCOVERED` filter opens the app for it (`MainActivity.kt`), which reads the tag again through `Ndef.connect` before passing it on. A board on the phone's USB is set up and flashed through `UsbSerialBridge.kt`.

```sh
flutter analyze
flutter test
flutter run            # on a connected Android phone
```

Release builds run on a Nothing A059 (Android 17) and the Android 17 emulator. Not proven on a phone: a full day of battery drain, and the phone inputs `ROADMAP.md` lists as not yet run on a device.
