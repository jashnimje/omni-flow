# omniflow_app

Flutter client for OmniFlow, Android only. Design: `../../docs/DESIGN.md`.

The engine runs in a `connectedDevice` foreground service (`flutter_foreground_task`), so flows keep firing with the screen off and after the app is swiped away. The service's task runs in its own Flutter engine and isolate, and it is the only place that opens the database. The UI reaches it only through `EngineClient`: `ServiceEngineClient` sends JSON command and event messages over the plugin's data channel (`lib/service/`). The notification's Stop button stops the service, and the app then shows a Start screen.

While the service runs it holds a Wi-Fi multicast lock (`MulticastLockBridge.kt`, channel `omniflow/multicast`) so broadcast replies and board hellos arrive, plus the plugin's partial wake lock and Wi-Fi lock. The service restarts at boot and after an app update.

A device whose driver pairs in the app (an Android, LG or Samsung TV, a Hue light) has a Pair item in its menu, which shows the engine's prompt and runs `device.pair`. Home Assistant pairs by storing a token, and the app has no secret entry yet, so it has no Pair item. A scan lists a Hue bridge or Home Assistant instance that another device already uses, labelled with that device, so the next light or entity behind it can be added. Board pin sheets pick GPIOs from `board.describe`, show its strapping pin warnings when they open, and have an active-low switch for relays.

```sh
flutter analyze
flutter test
flutter run            # on a connected Android phone
```

Not yet proven on a phone: the APK build (the Android SDK is not installed), the service surviving a swipe, an hour with the screen off and a reboot, plugins (path_provider, flutter_secure_storage) inside the service isolate, the multicast lock channel, and battery drain.
