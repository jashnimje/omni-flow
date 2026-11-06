"""Host test for nec.py: python3 -I firmware/pico_w/test_nec.py"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from nec import nec_bits, nec_bits_msb  # noqa: E402


def bits_to_bytes(bits):
    return [sum(bits[b * 8 + i] << i for i in range(8)) for b in range(4)]


def test_standard_frame_is_lsb_first_with_inverses():
    bits = nec_bits(0x04, 0x08)
    assert len(bits) == 32
    assert bits_to_bytes(bits) == [0x04, 0xFB, 0x08, 0xF7]
    assert bits[:8] == [0, 0, 1, 0, 0, 0, 0, 0]


def test_legacy_msb_code_matches_the_same_frame():
    # LG TV power: 0x20DF10EF in the old MSB-first form is address 4, command 8.
    assert nec_bits_msb(0x20DF10EF) == nec_bits(0x04, 0x08)


def test_extended_address_sends_low_then_high_byte():
    assert bits_to_bytes(nec_bits(0x1234, 0x56)) == [0x34, 0x12, 0x56, 0xA9]


def test_out_of_range_values_are_rejected():
    for args in [(0, 256), (-1, 0), (0x10000, 0)]:
        try:
            nec_bits(*args)
        except ValueError:
            continue
        raise AssertionError("accepted %r" % (args,))
    try:
        nec_bits_msb(1 << 32)
    except ValueError:
        pass
    else:
        raise AssertionError("accepted a 33-bit code")


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
