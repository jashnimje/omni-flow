# OmniFlow node firmware for Raspberry Pi Pico W (MicroPython).
# Speaks the OmniFlow MCU protocol (NDJSON v1, docs/DESIGN.md) over USB serial
# and over UDP on Wi-Fi. Also advertises a BLE beacon for presence, sends NEC IR
# on GPIO 15, and reports a button on GPIO 14 and a knob on ADC0 (GPIO 26).
#
# Copy main.py and nec.py to the board. Settings come from config.json on the
# board (copy config.example.json).

import sys
import time

import bluetooth
import network
import socket
import ujson
import uselect
from machine import ADC, PWM, Pin

from nec import nec_bits, nec_bits_msb

FIRMWARE = "omniflow-pico/1"

# GPIO 23, 24, 25 and 29 belong to the CYW43 radio (25 is its SPI chip
# select). Writing them can break Wi-Fi and BLE, so they are never writable.
RADIO_PINS = (23, 24, 25, 29)
IR_PIN = 15
BUTTON_PIN = 14
KNOB_PIN = 26


def load_config():
    defaults = {
        "node_id": "pico_node",
        "ble_name": "OMNI_PICO",
        "ssid": "",
        "password": "",
        "udp_port": 38950,
        "out_pins": [16, 17, 18],
    }
    try:
        with open("config.json") as f:
            defaults.update(ujson.load(f))
    except OSError:
        pass
    reserved = RADIO_PINS + (IR_PIN, BUTTON_PIN, KNOB_PIN)
    defaults["out_pins"] = [p for p in defaults["out_pins"] if p not in reserved]
    return defaults


CONFIG = load_config()
NODE_ID = CONFIG["node_id"]
OUT_PINS = CONFIG["out_pins"]
CAPABILITIES = ["ble_beacon", "nec_ir", "button", "adc_knob", "gpio_out", "led"]

# --- Outputs: serial always, UDP to the host that last sent describe -------

udp_sock = None
event_peer = None


def send_serial(payload):
    sys.stdout.write(ujson.dumps(payload) + "\n")


def send_udp(payload, peer):
    if udp_sock is not None and peer is not None:
        try:
            udp_sock.sendto(ujson.dumps(payload), peer)
        except OSError:
            pass


def emit(payload, reply_peer=None):
    """Send an event. A reply goes back to the UDP sender, an unsolicited
    event to the registered event peer. Serial gets everything."""
    payload["node"] = NODE_ID
    send_serial(payload)
    send_udp(payload, reply_peer if reply_peer is not None else event_peer)


# --- BLE beacon (100 ms interval so the phone's filter converges fast) -----

ble = bluetooth.BLE()
ble.active(True)


def adv_payload(name):
    name_bytes = name.encode("utf-8")
    return bytes([2, 0x01, 0x06, len(name_bytes) + 1, 0x09]) + name_bytes


ble.gap_advertise(100_000, adv_data=adv_payload(CONFIG["ble_name"]))

# --- NEC IR on GPIO 15 (38 kHz carrier, ~33% duty) ---------------------------

ir_pwm = PWM(Pin(IR_PIN))
ir_pwm.freq(38000)
ir_pwm.duty_u16(0)


def ir_mark(us):
    ir_pwm.duty_u16(21845)
    time.sleep_us(us)
    ir_pwm.duty_u16(0)


def ir_space(us):
    time.sleep_us(us)


def send_ir_bits(bits):
    """One NEC frame: 9 ms burst, 4.5 ms space, then a 560 us burst per bit
    followed by a 1690 us space for 1 or 560 us for 0, and a final burst."""
    ir_mark(9000)
    ir_space(4500)
    for bit in bits:
        ir_mark(560)
        ir_space(1690 if bit else 560)
    ir_mark(560)
    ir_space(2000)


# --- Inputs and the onboard LED -------------------------------------------

button = Pin(BUTTON_PIN, Pin.IN, Pin.PULL_UP)
knob = ADC(Pin(KNOB_PIN))
led = Pin("LED", Pin.OUT)

# --- Wi-Fi and the UDP channel ---------------------------------------------

wlan = network.WLAN(network.STA_IF)


def start_wifi():
    if not CONFIG["ssid"]:
        return
    wlan.active(True)
    wlan.connect(CONFIG["ssid"], CONFIG["password"])


def ensure_udp():
    global udp_sock
    if udp_sock is not None or not wlan.isconnected():
        return
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", CONFIG["udp_port"]))
    s.setblocking(False)
    udp_sock = s
    emit({"event": "wifi", "ip": wlan.ifconfig()[0], "udp_port": CONFIG["udp_port"]})


# --- Commands ---------------------------------------------------------------


def describe():
    return {
        "event": "describe",
        "fw": FIRMWARE,
        "capabilities": CAPABILITIES,
        "pins": {"out": OUT_PINS},
        "commands": ["describe", "ir_send", "gpio_write", "led"],
    }


def handle(line, peer=None):
    global event_peer
    try:
        cmd = ujson.loads(line)
    except ValueError:
        emit({"event": "error", "message": "not JSON"}, peer)
        return
    req_id = cmd.get("id")
    name = cmd.get("cmd")

    def reply(payload):
        if req_id is not None:
            payload["id"] = req_id
        emit(payload, peer)

    try:
        if name == "describe":
            if peer is not None:
                event_peer = peer
            reply(describe())
        elif name == "ir_send":
            if cmd.get("protocol", "NEC") != "NEC":
                raise ValueError("only NEC is supported")
            if "address" in cmd:
                send_ir_bits(nec_bits(int(cmd["address"]), int(cmd["command"])))
                reply({"event": "ack", "cmd": "ir_send", "address": cmd["address"], "command": cmd["command"]})
            else:
                hex_code = cmd["hex"]
                send_ir_bits(nec_bits_msb(int(hex_code, 16)))
                reply({"event": "ack", "cmd": "ir_send", "hex": hex_code})
        elif name == "gpio_write":
            pin = int(cmd["pin"])
            if pin not in OUT_PINS:
                raise ValueError("pin not allowed")
            value = 1 if cmd.get("value") else 0
            Pin(pin, Pin.OUT).value(value)
            reply({"event": "ack", "cmd": "gpio_write", "pin": pin, "value": value})
        elif name == "led":
            value = 1 if cmd.get("value") else 0
            led.value(value)
            reply({"event": "ack", "cmd": "led", "value": value})
        else:
            raise ValueError("unknown command")
    except KeyError as e:
        reply({"event": "error", "message": "missing " + str(e)})
    except Exception as e:
        reply({"event": "error", "message": str(e)})


# --- Main loop --------------------------------------------------------------

serial_poll = uselect.poll()
serial_poll.register(sys.stdin, uselect.POLLIN)

start_wifi()
emit({"event": "boot", "fw": FIRMWARE})

last_button = 1
last_knob = -1

while True:
    ensure_udp()

    pressed = button.value()
    if pressed == 0 and last_button == 1:
        emit({"event": "button_press", "gpio": BUTTON_PIN})
        time.sleep_ms(50)
    last_button = pressed

    knob_pct = int(knob.read_u16() * 100 / 65535)
    if abs(knob_pct - last_knob) >= 3:
        last_knob = knob_pct
        emit({"event": "knob_change", "value": knob_pct})

    if serial_poll.poll(0):
        line = sys.stdin.readline().strip()
        if line:
            handle(line)

    if udp_sock is not None:
        try:
            data, peer = udp_sock.recvfrom(512)
            handle(data.decode().strip(), peer)
        except OSError:
            pass

    time.sleep_ms(20)
