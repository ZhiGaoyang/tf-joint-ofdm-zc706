"""Protocol V0.2 helpers: whitened payload and the per-frame PRBS test payload.

V0.2 = V0.1 frame layout + payload whitening (framing.encode_frame(whiten=True)).
The PRBS test payload is shared by the PL generator/checker and this model.
"""
import numpy as np

from . import framing


def prbs_payload(frame_id, length):
    """xorshift32 seeded with frame_id ^ 0xA5A5A5A5 (0 -> 1); one byte per step."""
    x = (frame_id ^ 0xA5A5A5A5) & 0xFFFFFFFF or 1
    out = bytearray()
    for _ in range(length):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        out.append(x & 0xFF)
    return bytes(out)


def encode_test_frame(frame_id, length, modulation="QPSK", config_epoch=0):
    payload = prbs_payload(frame_id, length)
    return payload, framing.encode_frame(payload, modulation, frame_id, config_epoch, whiten=True).samples


def to_words(samples, scale):
    """Complex samples -> int16 I/Q with saturation -> uint32 words (Q high)."""
    i = np.clip(np.rint(samples.real * scale * 32768), -32768, 32767).astype(np.int64)
    q = np.clip(np.rint(samples.imag * scale * 32768), -32768, 32767).astype(np.int64)
    return ((q & 0xFFFF) << 16) | (i & 0xFFFF)
