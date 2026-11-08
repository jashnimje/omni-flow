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
| ESP8266 (NodeMCU, Wemos D1 mini) | `esp8266:esp8266:nodemcuv2` |
| Raspberry Pi Pico W | `rp2040:rp2040:rpipicow` |
| ESP32 dev board | `esp32:esp32:esp32` |

```sh
arduino-cli compile --fqbn <fqbn> --upload --port /dev/cu.usbmodem1101 firmware/omniflow_node
```

## Set up

Plug the board in over USB and run `omni board setup <port>` (or use Add board in the app). It sends these commands, which are kept in flash:

- `{"cmd":"wifi.set","ssid":"...","password":"..."}` joins Wi-Fi (not on the Uno)
- `{"cmd":"node.set","name":"desk_board"}` names the board
- `{"cmd":"ir.pin","pin":4}` sets the IR LED pin, or `-1` for none
- `{"cmd":"wifi.status"}` reports the IP once connected

After that the board announces itself on Wi-Fi with a hello broadcast and mDNS (`_omniflow._udp`), and OmniFlow finds it by itself.

## Check

`./check.sh` runs the native core tests, builds the virtual board used by the engine tests, and compiles the sketch for all four boards.
