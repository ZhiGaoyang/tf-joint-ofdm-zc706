"""Group-masked OFDM frames (design B sections 2-3).

88 data carriers in signed order form 11 groups of 8; a mask bit set to 1
switches the whole group off (sent as 0) in header and payload symbols.  The
16-byte header is carried on the first 64 unmasked carriers and its reserved
bytes 10..11 echo the mask.  Pilots, training and nulls are unchanged, and
mask=0 reproduces framing.encode_frame(whiten=True) bit for bit.
"""
from collections import namedtuple
import struct

import numpy as np

from models.ofdm import core, framing

NGROUPS = 11
GROUP_SIZE = 8
MAX_MASKED = 3
MAX_SYMBOLS = 191                      # rxs/ofdm_rxs_fetch.v MAX_SYMBOLS
DATA_SIGNED = [int(k) for k in core.ACTIVE_SIGNED if k not in core.PILOT_SIGNED]
_GROUP_OF_BIN = {k % core.NFFT: i // GROUP_SIZE for i, k in enumerate(DATA_SIGNED)}

Geometry = namedtuple('Geometry', 'groups carriers header_bytes_per_symbol body_bytes_per_symbol '
                                  'payload_symbols last_byte')


def check_mask(mask):
    mask = core.checked_int(mask, 0, (1 << NGROUPS) - 1, 'mask')
    if bin(mask).count('1') > MAX_MASKED:
        raise ValueError('at most %d groups may be masked' % MAX_MASKED)
    return mask


def group_of_bin(bin_index):
    return _GROUP_OF_BIN.get(int(bin_index))


def active_ords(mask):
    mask = check_mask(mask)
    return [d for d in range(len(DATA_SIGNED)) if not mask >> (d // GROUP_SIZE) & 1]


def active_bins(mask):
    return [DATA_SIGNED[d] % core.NFFT for d in active_ords(mask)]


def l_max(groups, modulation):
    body = groups * core.bits_per_symbol(modulation)               # bytes per payload symbol
    return min(framing.MAX_PAYLOAD_BYTES, (MAX_SYMBOLS - 4) * body - 4)


def geometry(length, modulation, mask):
    mask = check_mask(mask)
    length = core.checked_int(length, 0, framing.MAX_PAYLOAD_BYTES, 'payload_len')
    groups = NGROUPS - bin(mask).count('1')
    body = groups * core.bits_per_symbol(modulation)
    symbols = max(1, -(-(length + 4) // body))
    if 4 + symbols > MAX_SYMBOLS:
        raise ValueError('frame exceeds %d symbols' % MAX_SYMBOLS)
    return Geometry(groups, GROUP_SIZE * groups, 2 * groups, body, symbols, 4 * groups + body * symbols - 1)


def encode_header(frame_id, modulation, payload_len, config_epoch, mask):
    mask = check_mask(mask)
    v01 = framing.encode_header(frame_id, modulation, payload_len, config_epoch)
    prefix = v01[:10] + struct.pack('<H', mask)
    return prefix + struct.pack('<I', framing.crc32(prefix))


def decode_header(data, expected_mask):
    if len(data) != framing.HEADER_BYTES:
        raise ValueError('header must contain 16 bytes')
    if framing.crc32(data[:12]) != struct.unpack('<I', data[12:])[0]:
        raise ValueError('header CRC mismatch')
    version, mcs, frame_id, payload_len, epoch, echo = framing.HEADER_STRUCT.unpack(data[:12])
    if version != 1 or mcs >= len(framing.MODULATIONS) or payload_len > framing.MAX_PAYLOAD_BYTES:
        raise ValueError('unsupported header version, modulation or length')
    if echo != expected_mask:
        raise ValueError('mask echo does not match the candidate')
    return {'version': version, 'modulation': framing.MODULATIONS[mcs], 'frame_id': frame_id,
            'payload_len': payload_len, 'config_epoch': epoch, 'mask': echo}


def bits_to_grid(bits, modulation, mask):
    bits = core.checked_bits(bits)
    bins = active_bins(mask)
    capacity = len(bins) * core.bits_per_symbol(modulation)
    if not len(bits) or len(bits) % capacity:
        raise ValueError('grid input must contain complete OFDM symbols')
    _, pilots, _ = core.carrier_bins()
    grid = np.zeros((len(bits) // capacity, core.NFFT), dtype=complex)
    grid[:, bins] = core.map_bits(bits, modulation).reshape(-1, len(bins))
    grid[:, pilots] = core.PILOT_VALUES
    return grid


def encode_frame(payload, modulation, frame_id, config_epoch, mask):
    """V0.2 frame (whitened payload) with the given group mask."""
    if not isinstance(payload, bytes):
        raise ValueError('payload must be bytes')
    geo = geometry(len(payload), modulation, mask)
    header = encode_header(frame_id, modulation, len(payload), config_epoch, mask)
    header_bits = np.pad(core.bytes_to_bits(header), (0, 2 * geo.carriers - 8 * framing.HEADER_BYTES))
    header_grid = bits_to_grid(header_bits, 'QPSK', mask)
    body = core.bytes_to_bits(payload + struct.pack('<I', framing.crc32(payload)))
    capacity = geo.carriers * core.bits_per_symbol(modulation)
    body = np.pad(body, (0, (-len(body)) % capacity))
    body = body ^ framing.scrambler_bits(len(body))
    training = framing.training_grid()
    grid = np.vstack((training, training, header_grid, header_grid, bits_to_grid(body, modulation, mask)))
    assert len(grid) == 4 + geo.payload_symbols
    return framing.TransmittedFrame(header, grid, core.grid_to_samples(grid))


def decode_frame(samples, candidates=(0,)):
    """Aligned decode; the first candidate mask whose header passes CRC and echo wins."""
    grid = core.samples_to_grid(samples)
    if len(grid) < 5:
        raise ValueError('frame requires training, repeated header and payload symbols')
    hsum = np.mean(grid[2:4], axis=0)
    for mask in candidates:
        bins = active_bins(mask)
        bits = core.demap_symbols(hsum[bins], 'QPSK')
        try:
            header = decode_header(core.bits_to_bytes(bits[:8 * framing.HEADER_BYTES]), mask)
        except ValueError:
            continue
        geo = geometry(header['payload_len'], header['modulation'], mask)
        if len(grid) != 4 + geo.payload_symbols:
            raise ValueError('frame length does not match the decoded header')
        bits = core.demap_symbols(grid[4:, bins].reshape(-1), header['modulation'])
        bits = bits ^ framing.scrambler_bits(len(bits))
        n = header['payload_len']
        body = core.bits_to_bytes(bits[:8 * (n + 4)])
        valid = framing.crc32(body[:n]) == struct.unpack('<I', body[n:])[0]
        return framing.ReceivedFrame(header, body[:n], valid, grid)
    raise ValueError('no candidate mask produced a valid header')
