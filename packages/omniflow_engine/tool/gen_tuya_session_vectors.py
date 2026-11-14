"""Generate Tuya v3.4 and v3.5 golden frames with tinytuya, the reference implementation.

Run with a Python that has tinytuya installed (kept outside the repo):
    python -I tool/gen_tuya_session_vectors.py > test/fixtures/tuya_v34_v35_vectors.json

The key, device id, nonces, IVs and timestamp are made up. Each frame is
checked by unpacking it with tinytuya before it is written, and the client
frames for v3.4 come from tinytuya's own encoder and session handshake.
"""

import hmac
import json
import struct
from hashlib import sha256

import tinytuya
from tinytuya.core import command_types as CT
from tinytuya.core import header as H
from tinytuya.core.crypto_helper import AESCipher
from tinytuya.core.message_helper import MessagePayload, TuyaMessage, pack_message, unpack_message

KEY = b"0123456789abcdef"
DEV_ID = "bf0000000000000000test"
LOCAL_NONCE = b"client-nonce-016"
REMOTE_NONCE = b"device-nonce-016"
T = 1700000000


def compact(obj):
    return json.dumps(obj, separators=(",", ":")).encode()


def device(version):
    d = tinytuya.Device(DEV_ID, "127.0.0.1", KEY.decode(), version=version)
    d.real_local_key = KEY
    d.local_key = KEY
    d.local_nonce = LOCAL_NONCE
    d.seqno = 1
    return d


def device_reply_55aa(seq, cmd, key, plain):
    payload = struct.pack(">I", 0) + AESCipher(key).encrypt(plain, False)
    return pack_message(
        TuyaMessage(seq, cmd, None, payload, 0, True, H.PREFIX_55AA_VALUE, None), hmac_key=key
    )


def frame_6699(seq, cmd, key, plain, iv, retcode=None):
    msg = TuyaMessage(seq, cmd, retcode, plain, 0, True, H.PREFIX_6699_VALUE, iv)
    return pack_message(msg, hmac_key=key)


def v34():
    d = device(3.4)
    step1 = d._encode_message(MessagePayload(CT.SESS_KEY_NEG_START, LOCAL_NONCE))
    step2_plain = REMOTE_NONCE + hmac.new(KEY, LOCAL_NONCE, sha256).digest()
    step2 = device_reply_55aa(1, CT.SESS_KEY_NEG_RESP, KEY, step2_plain)
    parsed = unpack_message(step2, hmac_key=KEY)
    assert parsed.crc_good
    step3_msg = d._negotiate_session_key_generate_step_3(parsed)
    assert step3_msg
    step3 = d._encode_message(step3_msg)
    d._negotiate_session_key_generate_finalize()
    session = d.local_key

    control_body = {"protocol": 5, "t": T, "data": {"dps": {"1": True}}}
    control = d._encode_message(MessagePayload(CT.CONTROL_NEW, compact(control_body)))
    query = d._encode_message(MessagePayload(CT.DP_QUERY_NEW, compact({})))

    push_body = {"protocol": 4, "t": T, "data": {"dps": {"1": True, "2": 0}}}
    push = device_reply_55aa(0, CT.STATUS, session, H.PROTOCOL_34_HEADER + compact(push_body))
    parsed_push = unpack_message(push, hmac_key=session)
    assert parsed_push.crc_good
    assert d._decode_payload(parsed_push.payload)["dps"] == {"1": True, "2": 0}

    for frame, key in ((step1, KEY), (step3, KEY), (control, session), (query, session)):
        assert unpack_message(frame, hmac_key=key, no_retcode=True).crc_good

    return {
        "localNonceHex": LOCAL_NONCE.hex(),
        "remoteNonceHex": REMOTE_NONCE.hex(),
        "sessionKeyHex": session.hex(),
        "step1": {"seq": 1, "cmd": 3, "frameHex": step1.hex()},
        "step2": {"seq": 1, "cmd": 4, "frameHex": step2.hex()},
        "step3": {"seq": 2, "cmd": 5, "frameHex": step3.hex()},
        "control": {"seq": 3, "cmd": 13, "body": control_body, "frameHex": control.hex()},
        "query": {"seq": 4, "cmd": 16, "body": {}, "frameHex": query.hex()},
        "push": {"seq": 0, "cmd": 8, "body": push_body, "frameHex": push.hex()},
    }


def v35():
    d = device(3.5)
    iv = b"client-iv-12"
    device_iv = b"device-iv-12"
    step1 = frame_6699(1, CT.SESS_KEY_NEG_START, KEY, LOCAL_NONCE, iv)
    step2_plain = REMOTE_NONCE + hmac.new(KEY, LOCAL_NONCE, sha256).digest()
    step2 = frame_6699(1, CT.SESS_KEY_NEG_RESP, KEY, step2_plain, device_iv, retcode=0)
    parsed = unpack_message(step2, hmac_key=KEY)
    assert parsed.crc_good and parsed.retcode == 0
    step3_msg = d._negotiate_session_key_generate_step_3(parsed)
    assert step3_msg
    step3 = frame_6699(2, CT.SESS_KEY_NEG_FINISH, KEY, step3_msg.payload, iv)
    d._negotiate_session_key_generate_finalize()
    session = d.local_key

    control_body = {"protocol": 5, "t": T, "data": {"dps": {"1": True}}}
    control = frame_6699(
        3, CT.CONTROL_NEW, session, H.PROTOCOL_35_HEADER + compact(control_body), iv
    )
    push_body = {"protocol": 4, "t": T, "data": {"dps": {"1": True, "2": 0}}}
    push = frame_6699(
        7, CT.STATUS, session, H.PROTOCOL_35_HEADER + compact(push_body), device_iv, retcode=0
    )

    for frame, key in ((step1, KEY), (step3, KEY), (control, session)):
        assert unpack_message(frame, hmac_key=key, no_retcode=True).crc_good
    parsed_push = unpack_message(push, hmac_key=session)
    assert parsed_push.crc_good
    assert d._decode_payload(parsed_push.payload)["dps"] == {"1": True, "2": 0}

    return {
        "localNonceHex": LOCAL_NONCE.hex(),
        "remoteNonceHex": REMOTE_NONCE.hex(),
        "clientIvHex": iv.hex(),
        "deviceIvHex": device_iv.hex(),
        "sessionKeyHex": session.hex(),
        "step1": {"seq": 1, "cmd": 3, "frameHex": step1.hex()},
        "step2": {"seq": 1, "cmd": 4, "frameHex": step2.hex()},
        "step3": {"seq": 2, "cmd": 5, "frameHex": step3.hex()},
        "control": {"seq": 3, "cmd": 13, "body": control_body, "frameHex": control.hex()},
        "push": {"seq": 7, "cmd": 8, "body": push_body, "frameHex": push.hex()},
    }


vectors = {
    "generator": "tinytuya " + tinytuya.__version__,
    "localKey": KEY.decode(),
    "devId": DEV_ID,
    "v34": v34(),
    "v35": v35(),
}
print(json.dumps(vectors, indent=2))
