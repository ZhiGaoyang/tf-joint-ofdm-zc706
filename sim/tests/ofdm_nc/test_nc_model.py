"""Reference model for group-masked (NC) OFDM frames, design B sections 2-3.

The model extends V0.2 without changing models/ofdm; mask=0 must reproduce
framing.encode_frame(whiten=True) exactly.
"""
import itertools
import random
import struct

import numpy as np
import pytest

from models.ofdm import core, framing, v02
from models.ofdm_nc import nc


def legal_masks():
    return [m for m in range(1 << 11) if bin(m).count('1') <= 3]


# ---------------------------------------------------------------- groups and masks
def test_groups_follow_signed_data_order():
    assert len(nc.DATA_SIGNED) == 88
    assert nc.DATA_SIGNED[:8] == [-48, -47, -46, -45, -44, -42, -41, -40]
    assert nc.DATA_SIGNED[40:48] == [-4, -3, -2, -1, 1, 2, 3, 4]          # group 5 spans DC
    assert nc.DATA_SIGNED[80:] == [40, 41, 42, 44, 45, 46, 47, 48]
    data, _, _ = core.carrier_bins()
    assert [k % 128 for k in nc.DATA_SIGNED] == list(data)


def test_group_of_bin_covers_data_bins_only():
    data, pilots, nulls = core.carrier_bins()
    assert [nc.group_of_bin(b) for b in data] == [d // 8 for d in range(88)]
    assert all(nc.group_of_bin(b) is None for b in list(pilots) + list(nulls))


@pytest.mark.parametrize('mask', [-1, 1 << 11, 0b1111, 0x7FF])
def test_illegal_masks_rejected(mask):
    with pytest.raises(ValueError):
        nc.check_mask(mask)


def test_number_of_legal_masks():
    assert len(legal_masks()) == 1 + 11 + 55 + 165


# ---------------------------------------------------------------- geometry
@pytest.mark.parametrize('groups,qpsk,qam', [(11, 4096, 4096), (10, 3736, 4096), (9, 3362, 4096), (8, 2988, 4096)])
def test_l_max_table_matches_design(groups, qpsk, qam):
    assert nc.l_max(groups, 'QPSK') == qpsk and nc.l_max(groups, '16QAM') == qam


def test_geometry_matches_v02_formula_when_unmasked():
    for length in range(0, 4097):
        for mod in framing.MODULATIONS:
            g = nc.geometry(length, mod, 0)
            cap = 88 * core.bits_per_symbol(mod)
            assert g.payload_symbols == max(1, -(-8 * (length + 4) // cap))
            assert g.last_byte == 44 + g.body_bytes_per_symbol * g.payload_symbols - 1


def test_geometry_example_from_design():
    g = nc.geometry(2048, 'QPSK', 0b1)                        # G=10
    assert (g.groups, g.payload_symbols, g.last_byte) == (10, 103, 2099)


@pytest.mark.parametrize('mod', framing.MODULATIONS)
def test_geometry_rejects_lengths_beyond_l_max(mod):
    for mask in (0, 1, 3, 7):
        groups = 11 - bin(mask).count('1')
        top = nc.l_max(groups, mod)
        nc.geometry(top, mod, mask)
        if top < 4096:
            with pytest.raises(ValueError):
                nc.geometry(top + 1, mod, mask)


# ---------------------------------------------------------------- header
def test_header_reserved_field_carries_mask():
    h = nc.encode_header(7, 'QPSK', 100, 3, 0x481)
    assert h[10:12] == struct.pack('<H', 0x481)
    assert nc.decode_header(h, 0x481)['mask'] == 0x481
    with pytest.raises(ValueError):
        nc.decode_header(h, 0x480)                             # echo mismatch
    with pytest.raises(ValueError):
        framing.decode_header(h)                               # old receiver rejects (fail-safe)


def test_header_mask0_identical_to_v01():
    assert nc.encode_header(9, '16QAM', 4096, 65535, 0) == framing.encode_header(9, '16QAM', 4096, 65535)


# ---------------------------------------------------------------- frames
@pytest.mark.parametrize('mod', framing.MODULATIONS)
@pytest.mark.parametrize('length', [0, 1, 15, 16, 17, 100, 4095, 4096])
def test_mask0_frame_is_bit_identical_to_v02(mod, length):
    payload = v02.prbs_payload(length, length)
    old = framing.encode_frame(payload, mod, 11, 2, whiten=True)
    new = nc.encode_frame(payload, mod, 11, 2, 0)
    assert new.header_bytes == old.header_bytes
    assert np.array_equal(new.grid, old.grid)


@pytest.mark.parametrize('mod', framing.MODULATIONS)
def test_masked_carriers_are_zero_and_pilots_unchanged(mod):
    mask = 0b10000100001
    f = nc.encode_frame(bytes(range(200)), mod, 1, 0, mask)
    _, pilots, nulls = core.carrier_bins()
    masked = [b for b in core.carrier_bins()[0] if mask >> nc.group_of_bin(b) & 1]
    assert len(masked) == 24
    assert np.all(f.grid[2:, masked] == 0)
    assert np.all(f.grid[2:, pilots] == core.PILOT_VALUES)
    assert np.all(f.grid[:, nulls] == 0)
    g = nc.geometry(200, mod, mask)
    assert len(f.grid) == 4 + g.payload_symbols


def test_header_occupies_first_64_unmasked_carriers():
    mask = 0b00000000011                                       # first 16 data carriers masked
    f = nc.encode_frame(b'', 'QPSK', 5, 0, mask)
    bins = nc.active_bins(mask)
    bits = core.demap_symbols(f.grid[2, bins], 'QPSK')
    assert core.bits_to_bytes(bits[:128]) == f.header_bytes
    assert not bits[128:].any()


def test_roundtrip_all_legal_masks_and_candidates():
    rng = random.Random(20261025)
    for mask in legal_masks():
        mod = framing.MODULATIONS[mask & 1]
        groups = 11 - bin(mask).count('1')
        length = rng.randrange(0, nc.l_max(groups, mod) + 1) if mask % 37 == 0 else rng.randrange(0, 300)
        payload = bytes(rng.randrange(256) for _ in range(length))
        f = nc.encode_frame(payload, mod, mask, 1, mask)
        rx = nc.decode_frame(f.samples, candidates=(0, mask))
        assert rx.payload == payload and rx.payload_crc_ok and rx.header['mask'] == mask


def test_wrong_candidates_fail_closed():
    f = nc.encode_frame(b'abc', 'QPSK', 1, 0, 0x100)
    with pytest.raises(ValueError):
        nc.decode_frame(f.samples, candidates=(0, 0x200))
