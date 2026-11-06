"""A board on a pseudo-terminal, for the serial channel test.

Prints the slave tty path, then answers each NDJSON command with an ack that
carries its id, sends one unsolicited button_press after the first command,
and answers gpio_write on pin 25 with an error. Exits after 10 s of silence.
"""

import json
import os
import pty
import select
import sys

master, slave = pty.openpty()
print(os.ttyname(slave), flush=True)
buffer = b""
first = True
while True:
    ready, _, _ = select.select([master], [], [], 10)
    if not ready:
        sys.exit(0)
    buffer += os.read(master, 1024)
    while b"\n" in buffer:
        line, buffer = buffer.split(b"\n", 1)
        line = line.strip()
        if not line:
            continue
        cmd = json.loads(line)
        if cmd.get("cmd") == "describe":
            reply = {"event": "describe", "fw": "omniflow-pico/1", "capabilities": ["nec_ir", "led"]}
        elif cmd.get("cmd") == "gpio_write" and cmd.get("pin") == 25:
            reply = {"event": "error", "message": "pin not allowed"}
        else:
            reply = {"event": "ack", "cmd": cmd.get("cmd")}
        reply.update({"node": "pty_board", "id": cmd.get("id")})
        os.write(master, (json.dumps(reply) + "\n").encode())
        if first:
            first = False
            os.write(master, b'{"node":"pty_board","event":"button_press","gpio":14}\n')
