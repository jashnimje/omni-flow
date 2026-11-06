# NEC IR frame bits, shared by the firmware and its host test (no hardware imports).
#
# NEC sends four bytes, each least significant bit first: address, inverted
# address, command, inverted command. An address above 255 is the extended
# 16-bit form, sent low byte then high byte in place of the inverted address.


def nec_bits(address, command):
    """The 32 frame bits, in transmit order, from an address and command."""
    if not 0 <= command <= 0xFF:
        raise ValueError("command must be 0-255")
    if not 0 <= address <= 0xFFFF:
        raise ValueError("address must be 0-65535")
    if address <= 0xFF:
        frame = [address, address ^ 0xFF, command, command ^ 0xFF]
    else:
        frame = [address & 0xFF, address >> 8, command, command ^ 0xFF]
    bits = []
    for byte in frame:
        for i in range(8):
            bits.append((byte >> i) & 1)
    return bits


def nec_bits_msb(code):
    """The 32 bits of a code written most significant bit first, as in old
    Arduino-IRremote and LIRC code lists (IRremote's sendNECMSB)."""
    if not 0 <= code <= 0xFFFFFFFF:
        raise ValueError("code must fit in 32 bits")
    return [(code >> i) & 1 for i in range(31, -1, -1)]
