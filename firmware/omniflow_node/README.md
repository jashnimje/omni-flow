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
- `{"cmd":"rf.pin","pin":5}` sets the 433 MHz transmitter's data pin, or `-1` for none, with the same rules as `ir.pin`. It cannot be the IR pin.
- `{"cmd":"wifi.status"}` reports the IP once connected

After that the board announces itself on Wi-Fi with a hello broadcast to UDP 38951 as soon as it joins, again at once after every rejoin, and every 30 seconds, and registers `_omniflow._udp` over mDNS under its node name. `node.set` restarts mDNS under the new name and sends a hello at once. `wifi.set` and `wifi.clear` stop mDNS, and it starts again on the next join. A running `omni hub`, or the app while it is open, picks up the hello and offers the board as `board.found`. `omni device discover --driver omniflow_board` finds it at any time. It answers only hosts on its own subnet, and sends events to up to three hosts that sent `describe` in the last 90 seconds.

## Pins

`describe` lists every pin the board offers with its capabilities (`in`, `pullup`, `out`, `pwm`, `servo`, `adc`), whether IR and RF pins are set (`"ir"`, `"rf"`), how many pins it can watch (`watches`), and the pins that have a mode now (`set`). `pin.mode` with mode `none` releases a pin to a plain input and stops its watch.

`pin.mode` with mode `out` takes an optional `"value"` of 0 or 1, the level the pin drives from the instant it becomes an output, so an active-low relay is given 1 and never clicks on during setup. The board sets the output latch while the pin is still an input, then switches it to output. Sending the same `out` mode again with a value changes the level only while no `pin.write` has set it since the mode was set, so a resent setup never undoes a level the host chose. The ack carries `"value"` (the level now) whenever a value was sent. A value with any other mode is refused.

## IR and RF

`{"cmd":"ir.send","address":4,"command":8}` (or `"hex":"0x20DF10EF"`) sends one NEC frame on the IR pin. `{"cmd":"rf.send","code":5393,"bits":24,"protocol":1,"repeat":10}` sends an OOK code on the RF pin the way RCSwitch's `send()` does: the code most significant bit first, then the sync pulse, the whole frame `repeat` times. `code` is a whole number 0 to 4294967295 that fits in `bits` (1 to 32), `protocol` is 1 to 3 (default 1) and `repeat` 1 to 20 (default 10). Both acks come after the signal has gone out; ten repeats of a 24-bit code take about 0.45 s.

| Protocol | Pulse | Sync (high, low) | Zero | One |
| --- | --- | --- | --- | --- |
| 1 | 350 us | 1, 31 | 1, 3 | 3, 1 |
| 2 | 650 us | 1, 10 | 1, 2 | 2, 1 |
| 3 | 100 us | 30, 71 | 4, 11 | 9, 6 |

How each board makes the signals:

| Board | IR carrier | Marks, spaces and RF pulses |
| --- | --- | --- |
| ESP32 | RMT carrier, 38 kHz at 33% | RMT, 1 us ticks, so Wi-Fi and task switches cannot bend them |
| Uno, IR on pin 3 | Timer2 PWM on OC2B, 38.1 kHz at 33%, connected for each mark (the IRremote way) | busy-wait on `micros()` |
| Uno, any other pin | cycle-counted loop, 421 cycles = 38.0 kHz at 33% | busy-wait on `micros()` |
| ESP8266 | busy-wait on the CPU cycle counter with direct register writes, 38.0 kHz at 33% | the same |
| Pico W | busy-wait on the SysTick cycle counter with `gpio_put`, 38.0 kHz at 33% | the same |

The busy-wait boards keep one absolute timeline per frame, so the time a pin write or an interrupt takes never adds up. On the Uno, Timer2 also drives the PWM on pin 11, which pauses while an IR frame on pin 3 is sent, and the Timer0 interrupt stays on, so the cycle-counted carrier runs about 0.5% low. Whether real receivers accept each board's signals is unproven until they are tested on hardware. On the Uno, servos take Timer1, so pins 9 and 10 offer no servo, and PWM on them is refused while any servo is attached.

## Check

`./check.sh` runs the native core tests twice (once with the Uno's limits), builds and smoke-tests the virtual board (`host/host_board.cpp`, which the engine tests compile again from the same sources), and compiles the sketch for all four boards. A failed compile or a warning in the sketch's own files fails it.
