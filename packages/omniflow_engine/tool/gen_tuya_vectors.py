"""Generate Tuya v3.3 golden frames with tinytuya, the reference implementation.

Run with a Python that has tinytuya installed (kept outside the repo):
    python -I tool/gen_tuya_vectors.py > test/fixtures/tuya_v33_vectors.json

The key, device id and timestamp are made up. Bodies are compact JSON with
keys in the order the Dart test builds them, because the ciphertext covers
the exact bytes.
"""

import binascii
import json
import struct

import tinytuya
from tinytuya.core import header as H
from tinytuya.core.crypto_helper import AESCipher
from tinytuya.core.message_helper import TuyaMessage, pack_message, unpack_message

KEY = b"0123456789abcdef"
DEV_ID = "bf0000000000000000test"
T = "1700000000"


def compact(obj):
    return json.dumps(obj, separators=(",", ":")).encode()


def client_frame(seq, cmd, body, with_version_header):
    cipher = AESCipher(KEY)
    payload = cipher.encrypt(compact(body), use_base64=False)
    if with_version_header:
        payload = H.PROTOCOL_33_HEADER + payload
    return pack_message(TuyaMessage(seq, cmd, None, payload, 0, True, H.PREFIX_55AA_VALUE, None))


def device_frame(seq, cmd, retcode, body):
    """A device reply: header, return code, encrypted body, CRC, suffix."""
    cipher = AESCipher(KEY)
    payload = struct.pack(">I", retcode) + cipher.encrypt(compact(body), use_base64=False)
    length = len(payload) + 8
    data = struct.pack(">4I", H.PREFIX_55AA_VALUE, seq, cmd, length) + payload
    crc = binascii.crc32(data) & 0xFFFFFFFF
    frame = data + struct.pack(">2I", crc, H.SUFFIX_VALUE)
    parsed = unpack_message(frame)
    assert parsed.crc_good and parsed.retcode == retcode
    assert json.loads(AESCipher(KEY).decrypt(parsed.payload, use_base64=False)) == body
    return frame


control_body = {"devId": DEV_ID, "uid": DEV_ID, "t": T, "dps": {"1": True}}
query_body = {"gwId": DEV_ID, "devId": DEV_ID, "uid": DEV_ID, "t": T}
status_reply = {"devId": DEV_ID, "dps": {"1": True, "2": 0}}

vectors = {
    "generator": "tinytuya " + tinytuya.__version__,
    "localKey": KEY.decode(),
    "control": {
        "seq": 1,
        "cmd": 7,
        "body": control_body,
        "frameHex": client_frame(1, 7, control_body, True).hex(),
    },
    "statusQuery": {
        "seq": 2,
        "cmd": 10,
        "body": query_body,
        "frameHex": client_frame(2, 10, query_body, False).hex(),
    },
    "statusReply": {
        "seq": 2,
        "cmd": 10,
        "retcode": 0,
        "body": status_reply,
        "frameHex": device_frame(2, 10, 0, status_reply).hex(),
    },
}
print(json.dumps(vectors, indent=2))
