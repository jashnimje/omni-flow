# OmniFlow node firmware

One Arduino sketch for ESP32, ESP8266, Raspberry Pi Pico W and Arduino Uno. It speaks protocol v2 (`docs/engine-design.md`, "Universal board runtime"): every usable pin is offered with its capabilities, and the app decides at runtime what each pin does. You never edit or reflash it to add a button, relay, servo or sensor.

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

Plug the board in over USB and run `omni board setup <port>`. These commands set the board up, are kept in flash, and are taken only over USB:

- `{"cmd":"wifi.set","ssid":"...","password":"..."}` joins Wi-Fi (not on the Uno). The password is empty for an open network, 8 to 63 characters, or 64 hex digits.
- `{"cmd":"wifi.clear"}` forgets the network
- `{"cmd":"node.set","name":"desk_board"}` names the board: a lower case letter, then up to 22 lower case letters, digits, `_` or `-`
- `{"cmd":"periph.set","type":"ir","pins":{"tx":4}}` and `{"cmd":"periph.clear","type":"ir"}` attach and remove a peripheral (see Peripherals)
- `{"cmd":"ir.pin","pin":4}` and `{"cmd":"rf.pin","pin":5}` are the older form of `periph.set` for IR and RF, still taken for boards already set up: `-1` clears, and the ack is `{"event":"ack","cmd":"ir.pin","pin":4}`.
- `{"cmd":"wifi.status"}` reports the IP once connected

After that the board announces itself on Wi-Fi with a hello broadcast to UDP 38951 as soon as it joins, again at once after every rejoin, and every 30 seconds, and registers `_omniflow._udp` over mDNS under its node name. `node.set` restarts mDNS under the new name and sends a hello at once. `wifi.set` and `wifi.clear` stop mDNS, and it starts again on the next join. A running `omni hub`, or the app while it is open, picks up the hello and offers the board as `board.found`. `omni device discover --driver omniflow_board` finds it at any time. It answers only hosts on its own subnet, and sends events to up to three hosts that sent `describe` in the last 90 seconds.

## Pins

`describe` lists every pin the board offers with its capabilities (`in`, `pullup`, `out`, `pwm`, `servo`, `adc`), whether IR and RF pins are set (`"ir"`, `"rf"`), how many pins it can watch (`watches`), the peripherals attached (`periph`) and the types this firmware can take (`periphTypes`), and the pins that have a mode now (`set`). A peripheral's pins, its bus pins included, are left out of the list and refused by every pin command. `pin.mode` with mode `none` releases a pin to a plain input and stops its watch.

`pin.mode` with mode `out` takes an optional `"value"` of 0 or 1, the level the pin drives from the instant it becomes an output, so an active-low relay is given 1 and never clicks on during setup. The board sets the output latch while the pin is still an input, then switches it to output. Sending the same `out` mode again with a value changes the level only while no `pin.write` has set it since the mode was set, so a resent setup never undoes a level the host chose. The ack carries `"value"` (the level now) whenever a value was sent. A value with any other mode is refused.

## Peripherals

A peripheral is a part wired to fixed pins: an IR LED, a 433 MHz transmitter or an NFC reader. It is attached over USB and kept in flash:

```json
{"cmd":"periph.set","type":"nfc_rc522","pins":{"ss":8,"rst":9},"id":1}
{"node":"desk_board","event":"ack","cmd":"periph.set","type":"nfc_rc522","id":1}
{"cmd":"periph.clear","type":"nfc_rc522","id":2}
{"node":"desk_board","event":"ack","cmd":"periph.clear","type":"nfc_rc522","id":2}
```

| Type | `pins` | Also takes |
| --- | --- | --- |
| `ir` | `tx`, the IR LED | nothing |
| `rf` | `tx`, the 433 MHz transmitter's data pin | nothing |
| `nfc_rc522` | `ss` (chip select), and `rst` if wired; without it the board resets the chip in software | the SPI bus |
| `nfc_pn532` | none, so `"pins":{}` or no `pins` | the I2C bus |

Every pin a peripheral takes must have no mode and must not belong to another peripheral, and its own pins must be output pins. `periph.set` for a type already set moves it to the new pins. One NFC reader at a time: setting the other type is refused until `periph.clear` removes the first. `periph.clear` for a type that is not set still acks. Both commands are refused over Wi-Fi.

`describe` reports each one with every pin it holds, bus pins included:

```json
"periph":[{"type":"ir","pins":{"tx":4}},{"type":"nfc_rc522","pins":{"ss":8,"rst":9,"sck":13,"miso":12,"mosi":11,"hw_ss":10}}],
"periphTypes":["ir","rf","nfc_rc522"]
```

| Board | SPI (`sck`, `miso`, `mosi`) | I2C (`sda`, `scl`) | `periphTypes` |
| --- | --- | --- | --- |
| ESP32 | 18, 19, 23 | 21, 22 | all four |
| ESP8266 | 14, 12, 13 | 4, 5 | all four |
| Pico W | 18, 16, 19 | 4, 5 | all four |
| Uno | 13, 12, 11, and 10 as `hw_ss` | not used | `ir`, `rf`, `nfc_rc522` |

An AVR SPI master leaves master mode when its SS pin goes low as an input, so the Uno keeps pin 10 as an output while the RC522 is on. It shows as `hw_ss` unless 10 is `ss` itself. The Uno has no PN532: the Wire library's buffers take 182 bytes of RAM, and with them the sketch's globals (1055 bytes now) would pass the 1100-byte budget that leaves room for the stack. A `periph.set` for it on an Uno answers `this board's firmware has no driver for that type`, and `periphTypes` leaves it out.

The settings layout is version 4 (`OMN4`). A board flashed with this firmware keeps its version 2 or 3 settings and reads them with no NFC reader.

## NFC readers

While a reader is attached the board looks for a tag every 100 ms and reports each presentation once:

```json
{"node":"desk_board","event":"nfc.scanned","uid":"04a1b2c3d4e5f6"}
```

The UID is 4, 7 or 10 bytes, in lower case hex. A tag held on the reader is reported when it arrives and not again. The same tag is reported again only after the reader has not seen it for 1 s, so a read missed while it is held never counts as a new tap. A different tag is reported at once. Only ISO 14443 type A tags are read (NTAG, MIFARE Classic and Ultralight), one at a time. With two tags in the field the RC522 reads none, and the PN532 reads one of them.

Neither reader needs a library beyond the SPI and Wire libraries every board core ships with:

- **RC522** over SPI at 4 MHz, driven register by register (MFRC522 datasheet). Each look sends WUPA, runs the anticollision and select cascade for up to three levels, checks the BCC and CRC_A, then halts the tag so the next WUPA finds it again while it stays. A look with no tag waits at most for the chip's 10 ms timer. A reader that does not answer (version register 00 or FF) is tried again every 2 s.
- **PN532** over I2C at 100 kHz, address 0x24, with its mode switches set to I2C. The board sends SAMConfiguration (normal mode) and limits passive activation to one try, then asks `InListPassiveTarget` for one 106 kbps type A target. It checks the reader's ready bit at most every 5 ms instead of waiting, so the loop and pin watches keep running while the PN532 answers. A reader that stops answering is set up again after 2 s.

Whether real readers and tags behave this way is unproven until they are tested on hardware. The protocol logic (CRC_A, the cascade, PN532 frames and replies, the debounce) is covered by the core tests with a simulated tag.

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

`./check.sh` runs the native core tests twice (once with the Uno's limits), builds and smoke-tests the virtual board (`host/host_board.cpp`, which the engine tests compile again from the same sources), and compiles the sketch for all four boards. A failed compile or a warning in the sketch's own files fails it. No library beyond `Servo` is installed: SPI and Wire come with each core.

The virtual board takes either NFC type. `{"cmd":"sim.nfc","uid":"04a1b2c3d4e5f6","ms":500}` holds a tag on its reader for 500 ms, or for one read without `ms`, and the board reports it through the same debounce as a real reader. It answers an error when no reader is attached.
