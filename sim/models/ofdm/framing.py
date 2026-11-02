"""Frame encoding and aligned decoding; no packet detector or equalizer."""

from dataclasses import dataclass
import struct
import zlib

import numpy as np

from . import core


MAX_PAYLOAD_BYTES = 4096
HEADER_BYTES = 16
HEADER_STRUCT = struct.Struct("<BBIHHH")
MODULATIONS = ("QPSK", "16QAM")


@dataclass
class TransmittedFrame:
    header_bytes: bytes
    grid: np.ndarray
    samples: np.ndarray


@dataclass
class ReceivedFrame:
    header: dict
    payload: bytes
    payload_crc_ok: bool
    grid: np.ndarray


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def encode_header(frame_id, modulation, payload_len, config_epoch):
    frame_id = core.checked_int(frame_id, 0, 2**32-1, "frame_id")
    payload_len = core.checked_int(payload_len, 0, MAX_PAYLOAD_BYTES, "payload_len")
    config_epoch = core.checked_int(config_epoch, 0, 65535, "config_epoch")
    core.bits_per_symbol(modulation)
    prefix = HEADER_STRUCT.pack(1, MODULATIONS.index(modulation), frame_id, payload_len, config_epoch, 0)
    return prefix + struct.pack("<I", crc32(prefix))


def decode_header(data):
    if len(data) != HEADER_BYTES:
        raise ValueError("header must contain 16 bytes")
    if crc32(data[:12]) != struct.unpack("<I", data[12:])[0]:
        raise ValueError("header CRC mismatch")
    version, mcs, frame_id, payload_len, epoch, reserved = HEADER_STRUCT.unpack(data[:12])
    if version != 1 or mcs >= len(MODULATIONS) or reserved != 0 or payload_len > MAX_PAYLOAD_BYTES:
        raise ValueError("unsupported header version, modulation, reserved field or length")
    return {"version": version, "modulation": MODULATIONS[mcs], "frame_id": frame_id,
            "payload_len": payload_len, "config_epoch": epoch}


def training_grid():
    # PRBS7: a[n+7] = a[n+6] XOR a[n], initial a[0:7] = ones.
    sequence = [1]*7
    for n in range(len(core.ACTIVE_SIGNED)-7):
        sequence.append(sequence[n+6] ^ sequence[n])
    grid = np.zeros((1, core.NFFT), dtype=complex)
    grid[0, core.ACTIVE_SIGNED % core.NFFT] = 1 - 2*np.array(sequence)
    return grid


def scrambler_bits(count):
    """V0.2 payload whitening: x^7+x^4+1, all-ones seed, restarted every frame."""
    state = [1]*7
    out = np.empty(count, dtype=np.uint8)
    for n in range(count):
        bit = state[6] ^ state[3]
        out[n] = bit
        state = [bit] + state[:6]
    return out


def encode_frame(payload, modulation="QPSK", frame_id=0, config_epoch=0, whiten=False):
    if not isinstance(payload, bytes):
        raise ValueError("payload must be bytes")
    header = encode_header(frame_id, modulation, len(payload), config_epoch)
    header_bits = np.pad(core.bytes_to_bits(header), (0, 176-HEADER_BYTES*8))
    header_grid = core.bits_to_grid(header_bits, "QPSK")
    body = payload + struct.pack("<I", crc32(payload))
    bits = core.bytes_to_bits(body)
    capacity = core.NDATA * core.bits_per_symbol(modulation)
    bits = np.pad(bits, (0, (-len(bits)) % capacity))
    if whiten:
        bits = bits ^ scrambler_bits(len(bits))
    grid = np.vstack((training_grid(), training_grid(), header_grid, header_grid, core.bits_to_grid(bits, modulation)))
    return TransmittedFrame(header, grid, core.grid_to_samples(grid))


def decode_frame(samples):
    grid = core.samples_to_grid(samples)
    if len(grid) < 5:
        raise ValueError("frame requires training, repeated header and payload symbols")
    header_bits = core.grid_to_bits(np.mean(grid[2:4], axis=0, keepdims=True), "QPSK")
    header = decode_header(core.bits_to_bytes(header_bits[:HEADER_BYTES*8]))
    payload_len = header["payload_len"]
    body_bits = (payload_len + 4)*8
    capacity = core.NDATA * core.bits_per_symbol(header["modulation"])
    expected_symbols = 4 + (body_bits + capacity - 1)//capacity
    if len(grid) != expected_symbols:
        raise ValueError("frame length does not match the decoded header")
    bits = core.grid_to_bits(grid[4:], header["modulation"])
    body = core.bits_to_bytes(bits[:body_bits])
    payload = body[:payload_len]
    valid = crc32(payload) == struct.unpack("<I", body[payload_len:])[0]
    return ReceivedFrame(header, payload, valid, grid)
