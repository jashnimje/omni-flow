# OmniFlow Universal Tinkerer Node Firmware for Raspberry Pi Pico W (MicroPython)
# Supports: BLE Proximity Beacon + USB Serial NDJSON + 940nm NEC IR Blaster + GPIO Sensors

import sys
import time
import ujson
import uselect
import bluetooth
from machine import Pin, PWM, ADC

NODE_ID = "pico_desk_hub_01"

# --- 1. BLE Proximity Beacon Setup (100ms interval for fast Kalman convergence) ---
ble = bluetooth.BLE()
ble.active(True)

def build_ble_adv_payload(name):
    payload = bytearray()
    # Flags: LE General Discoverable + BR/EDR Not Supported
    payload += bytearray([2, 0x01, 0x06])
    # Complete Local Name
    name_bytes = name.encode("utf-8")
    payload += bytearray([len(name_bytes) + 1, 0x09]) + name_bytes
    return payload

ble.gap_advertise(100_000, adv_data=build_ble_adv_payload("OMNI_PICO_DESK"))

# --- 2. 940nm NEC Infrared (IR) Blaster on GPIO 15 (38kHz Carrier) ---
ir_pwm = PWM(Pin(15))
ir_pwm.freq(38000)
ir_pwm.duty_u16(0)

def ir_mark(duration_us):
    ir_pwm.duty_u16(21845)  # ~33% duty cycle at 38kHz
    time.sleep_us(duration_us)
    ir_pwm.duty_u16(0)

def ir_space(duration_us):
    ir_pwm.duty_u16(0)
    time.sleep_us(duration_us)

def send_nec_ir(hex_str):
    code = int(hex_str, 16)
    # NEC Header: 9ms mark + 4.5ms space
    ir_mark(9000)
    ir_space(4500)
    # 32 data bits (MSB to LSB)
    for i in range(31, -1, -1):
        ir_mark(560)
        if (code >> i) & 1:
            ir_space(1690)
        else:
            ir_space(560)
    # Stop bit
    ir_mark(560)
    ir_space(2000)

# --- 3. Physical Desk Button (GPIO 14) & Analog Dimmer Knob (ADC0 / GPIO 26) ---
desk_button = Pin(14, Pin.IN, Pin.PULL_UP)
dimmer_knob = ADC(Pin(26))
last_btn_state = 1
last_knob_pct = -1

# Non-blocking USB Serial stdin poller
poller = uselect.poll()
poller.register(sys.stdin, uselect.POLLIN)

def emit_ndjson(payload_dict):
    payload_dict["node"] = NODE_ID
    sys.stdout.write(ujson.dumps(payload_dict) + "\n")

emit_ndjson({"event": "boot", "status": "ready", "capabilities": ["ble_beacon", "nec_ir", "button", "adc_knob"]})

while True:
    # A. Check physical macro button
    current_btn = desk_button.value()
    if current_btn == 0 and last_btn_state == 1:
        emit_ndjson({"event": "button_press", "gpio": 14})
        time.sleep_ms(50)  # Hardware debounce
    last_btn_state = current_btn

    # B. Check analog knob (maps 0..65535 -> 0..100% with 3% hysteresis)
    raw_adc = dimmer_knob.read_u16()
    knob_pct = int((raw_adc / 65535) * 100)
    if abs(knob_pct - last_knob_pct) >= 3:
        last_knob_pct = knob_pct
        emit_ndjson({"event": "knob_change", "value": knob_pct})

    # C. Process incoming NDJSON commands from Mac Mini Hub over USB Serial
    if poller.poll(0):
        line = sys.stdin.readline().strip()
        if line:
            try:
                cmd_obj = ujson.loads(line)
                cmd_type = cmd_obj.get("cmd")
                if cmd_type == "ir_send":
                    hex_code = cmd_obj.get("hex", "0x20DF10EF")
                    send_nec_ir(hex_code)
                    emit_ndjson({"event": "ack", "cmd": "ir_send", "hex": hex_code})
                elif cmd_type == "gpio_write":
                    pin_num = int(cmd_obj.get("pin", 25))
                    val = int(cmd_obj.get("value", 1))
                    Pin(pin_num, Pin.OUT).value(val)
                    emit_ndjson({"event": "ack", "cmd": "gpio_write", "pin": pin_num, "value": val})
            except Exception as e:
                emit_ndjson({"event": "error", "message": str(e)})

    time.sleep_ms(20)
