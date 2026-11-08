# OmniFlow node firmware

One Arduino sketch for ESP32, ESP8266, Raspberry Pi Pico W and Arduino Uno. It speaks protocol v2 (`docs/DESIGN.md`, "Universal board runtime"): every usable pin is offered with its capabilities, and the app decides at runtime what each pin does. You never edit or reflash it to add a button, relay, servo or sensor.

## Flash

Install `arduino-cli` and the board cores once:

```sh
brew install arduino-cli
arduino-cli config init
arduino-cli config add board_manager.additional_urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli config add board_manager.additional_urls https://arduino.esp8266.com/stable/package_esp8266com_index.json
arduino-cli config add board_manager.additional_urls https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json
arduino-cli core update-index
arduino-cli core install arduino:avr esp8266:esp8266 rp2040:rp2040 esp32:esp32
arduino-cli lib install Servo
```

Then compile and upload for your board:

| Board | FQBN |
| --- | --- |
| Arduino Uno | `arduino:avr:uno` |
| Arduino Nano (ATmega328P) | `arduino:avr:nano` |
| ESP8266 (NodeMCU, Wemos D1 mini) | `esp8266:esp8266:nodemcuv2` |
| Raspberry Pi Pico W | `rp2040:rp2040:rpipicow` |
| ESP32 dev board (classic ESP32, not S2, S3, C3 or C6) | `esp32:esp32:esp32` |

```sh
arduino-cli compile --fqbn <fqbn> --upload --port /dev/cu.usbmodem1101 firmware/omniflow_node
```

## Set up

Plug the board in over USB and run `omni board setup <port>`. It sends these commands, which are kept in flash and taken only over USB:

- `{"cmd":"wifi.set","ssid":"...","password":"..."}` joins Wi-Fi (not on the Uno). The password is empty for an open network, 8 to 63 characters, or 64 hex digits.
- `{"cmd":"wifi.clear"}` forgets the network
- `{"cmd":"node.set","name":"desk_board"}` names the board: a lower case letter, then up to 22 lower case letters, digits, `_` or `-`
- `{"cmd":"ir.pin","pin":4}` sets the IR LED pin, or `-1` for none. The pin must have no mode, and it is kept from pin commands after that.
- `{"cmd":"wifi.status"}` reports the IP once connected

After that the board announces itself on Wi-Fi with a hello broadcast to UDP 38951 every 30 seconds and registers `_omniflow._udp` over mDNS. A running `omni hub`, or the app while it is open, picks up the hello and offers the board as `board.found`. `omni device discover --driver omniflow_board` finds it at any time. It answers only hosts on its own subnet, and sends events to up to three hosts that sent `describe` in the last 90 seconds.

## Pins

`describe` lists every pin the board offers with its capabilities (`in`, `pullup`, `out`, `pwm`, `servo`, `adc`), how many pins it can watch (`watches`), and the pins that have a mode now (`set`). `pin.mode` with mode `none` releases a pin to a plain input and stops its watch. On the Uno, servos take Timer1, so pins 9 and 10 offer no servo, and PWM on them is refused while any servo is attached.

## Check

`./check.sh` runs the native core tests twice (once with the Uno's limits), builds and smoke-tests the virtual board (`host/host_board.cpp`, which the engine tests compile again from the same sources), and compiles the sketch for all four boards. A failed compile or a warning in the sketch's own files fails it.
