# Controlling Another Android Phone

> Status: approved, 2026-11-12. Building.

## Problem

OmniFlow controls an Android TV over ADB: screen, recording, apps, files, system, settings, permissions and a console. People want the same for a second phone, such as a partner's phone or an old phone kept as a wall display. Phones differ from TVs in one way that matters: on Android 11 and later, ADB over the network is Wireless Debugging, which pairs with a six-digit code over TLS, and the TV's classic port 5555 is off unless a computer turns it on over USB.

## Requirements

1. From one phone, see another phone's screen, record it, tap and swipe on it, and press Back, Home and Recents.
2. List its apps, open, stop, back up, and (as the user) install and uninstall them, and manage their permissions.
3. Browse its storage, and download and upload files both ways.
4. Read its system state, and read and change its settings through the same catalog the TV uses.
5. Works both ways between two phones, and from the Mac mini hub.
6. The other phone's owner agrees on their own screen, and can revoke it there.
7. Nothing new listens on either phone, and no home-made authentication.

## How connecting works

| | Wireless Debugging [Approved] | Classic port 5555 [Approved, fallback] |
| --- | --- | --- |
| Turned on by | The phone itself, in Developer options | A computer over USB (`adb tcpip 5555`) |
| Survives a reboot | No, turned on again by hand | No |
| Agreement | Six-digit pairing code shown on that phone | The "Allow USB debugging?" prompt |
| Encryption | TLS 1.3 | None |
| Found by | mDNS `_adb-tls-pairing._tcp` and `_adb-tls-connect._tcp` | mDNS `_adb._tcp`, or the address |

Pairing is the AOSP protocol: TLS 1.3 to the pairing port, SPAKE2 over edwards25519 keyed by the code and 64 bytes of TLS exporter material, then each side's RSA public key sent under AES-128-GCM. Connecting is classic ADB to the connect port, upgraded with `STLS` to TLS 1.3, with OmniFlow's ADB key as the client certificate. Both listeners are Android's own adbd, so requirement 7 holds. The Dart TLS exporter was already proven against OpenSSL; SPAKE2 is built from the AOSP and BoringSSL sources and proven against a real Wireless Debugging pairing on the emulator.

- **[Rejected] An OmniFlow server app on the other phone.** It would be a new listener with our own authentication, and an app cannot read another app's screen or files without the same powers ADB already grants.
- **[Rejected] Shizuku.** It controls the phone it runs on, not another one.

## What the other phone gets

The TV's control centre becomes the Android device page, picked by driver:

- New driver `android_phone_adb` on the same ADB channel as `android_tv_adb`. It has no wake-on-LAN, HDMI or TV power, and its keys are Back, Home, Recents, volume, power and the notification shade.
- The engine's `tv.*` commands already accept any ADB device. They get `android.*` names, with `tv.*` kept as aliases so nothing breaks.
- The app shows Screen, Apps and Files as tabs on a phone, with System, Settings, Remote and Console under More. The screen view is portrait.
- Agent policy is unchanged: shell, install, uninstall, delete and raw setting writes are the user's only, and automatic reads never start a pairing.

## Limits

- Wireless Debugging turns itself off on a reboot and on some phones when Wi-Fi changes, so the other phone's owner turns it on again. The device page says so instead of failing silently.
- Both phones need to be on the same Wi-Fi, or both on the tailnet through the hub.
- Banking and DRM apps show a black screen in screenshots and recordings. That is Android's protection, not a bug.
- Testing is done against the emulator only. The user's own phone gets read-only checks with their go-ahead.
