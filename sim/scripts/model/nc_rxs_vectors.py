"""Host-simulation scenarios for the NC (group-masked) streaming RX core.

Same format as scripts/model/rxs_vectors.py (stream.mem, expected.json,
index.json); each expected frame also carries its mask, and expect may be
OK, HEADER, PAYLOAD or ANY (no outcome required, but never a false OK).
Index entries carry plusargs: GAIN, BLIND (candidate enable), HDRTHR.
expected.json may list allow_stats: statistics that are expected to be nonzero
(the tone scenario: a continuous tone keeps the lag-160 metric high in idle
gaps, counted as long plateaus; design B D8 energy-floor recalibration).
Usage: python -m scripts.model.nc_rxs_vectors --output <dir> [--only name ...]
"""
import argparse
import json
import pathlib
import struct

import numpy as np

from models.ofdm import core, framing, v02
from models.ofdm_nc import nc
from scripts.model.m0_sync_sweep import CHANNELS, impair

HDR_THR = 185360


def nc_frame(fid, length, mod, mask):
    return nc.encode_frame(v02.prbs_payload(fid, length), mod, fid, 0, mask).samples


def overlong_frame(fid, mask, mod='QPSK', length=4096, payload_symbols=6):
    """Valid header announcing more than 191 symbols for its mask; short body."""
    header = nc.encode_header(fid, mod, length, 0, mask)
    groups = 11 - bin(mask).count('1')
    hbits = np.pad(core.bytes_to_bits(header), (0, 16 * groups - 128))
    hgrid = nc.bits_to_grid(hbits, 'QPSK', mask)
    body = framing.scrambler_bits(payload_symbols * 8 * groups * core.bits_per_symbol(mod))  # whitened, as TX
    t = framing.training_grid()
    grid = np.vstack((t, t, hgrid, hgrid, nc.bits_to_grid(body, mod, mask)))
    return core.grid_to_samples(grid)


def stream(rng, plan, lead, scale, snr_db=None, cfo=0.0, channel='flat', tone=None):
    """plan: (frame_id, length, modulation, mask, gap_after, expect); tone: (bin offset, JSR dB)."""
    parts, frames, pos = [np.zeros(lead, dtype=complex)], [], lead
    for fid, length, mod, mask, gap, expect in plan:
        tx = overlong_frame(fid, mask) if expect == 'HEADER_LONG' else nc_frame(fid, length, mod, mask)
        frames.append(dict(frame_id=fid, length=length, mcs=1 if mod == '16QAM' else 0, mask=mask, start=pos,
                           samples=len(tx), expect='HEADER' if expect == 'HEADER_LONG' else expect))
        parts.append(tx); pos += len(tx)
        if gap:
            parts.append(np.zeros(gap, dtype=complex)); pos += gap
    parts.append(np.zeros(1500, dtype=complex))
    x = np.concatenate(parts)
    y = impair(x, rng, 200.0 if snr_db is None else snr_db, cfo, CHANNELS[channel]) \
        if (snr_db is not None or cfo or channel != 'flat') else x.copy()
    if tone is not None:
        offset, jsr_db = tone
        ps = np.mean(np.abs(x[np.abs(x) > 0]) ** 2)
        n = np.arange(len(y))
        y = y + np.sqrt(ps * 10 ** (jsr_db / 10)) * np.exp(2j * np.pi * offset * n / core.NFFT + 1j * rng.uniform(0, 6.3))
    return v02.to_words(y, scale), frames


def scenarios(rng):
    sc = {}
    # 1. mask switching, clean with small CFO: each new mask's first frame needs the blind candidate.
    masks = [0, 0, 0x080, 0x080, 0x180, 0x180, 0x003, 0x400, 0x400, 0, 0x124, 0x124, 0x007, 0x700, 0]
    plan = [(1100 + n, [0, 1, 18, 100, 256, 700][n % 6], '16QAM' if n % 3 == 2 else 'QPSK', m,
             0 if n % 2 else int(rng.integers(1, 400)), 'OK') for n, m in enumerate(masks)]
    sc['nc_switch'] = dict(args=stream(rng, plan, 733, 1.0, cfo=0.1), gain=0, blind=1)
    # 2. impaired channel (22 dB, CFO -0.3, short multipath) with masks.
    masks = [0x080, 0x080, 0x001, 0x001, 0x7 << 4, 0x7 << 4, 0x400, 0x200, 0x200, 0]
    plan = [(1200 + n, [18, 64, 256, 700][n % 4], '16QAM' if n % 4 == 3 else 'QPSK', m, 0 if n % 3 else 150, 'OK')
            for n, m in enumerate(masks)]
    sc['nc_impaired'] = dict(args=stream(rng, plan, 517, 1.0, snr_db=22, cfo=-0.3, channel='cp_short'), gain=0, blind=1)
    # 3. tone at +17 subcarriers (group 7), JSR -25 dB: masked frames must pass; unmasked ones are ANY.
    plan = [(1300 + n, [256, 64, 700, 18][n % 4], 'QPSK' if n % 2 else '16QAM', m, 120 if n % 2 else 0,
             'OK' if m else 'ANY')
            for n, m in enumerate([0, 0x080, 0x080, 0, 0x080, 0x080, 0x080, 0x080])]
    sc['nc_tone'] = dict(args=stream(rng, plan, 640, 1.0, snr_db=30, cfo=0.05, tone=(17.0, -25.0)), gain=0, blind=1,
                         allow_stats=['long_plateaus'])
    # 4. maximum lengths per mask and a header announcing too many symbols (HEADER).
    plan = [(1400, nc.l_max(8, 'QPSK'), 'QPSK', 0x007, 0, 'OK'), (1401, 4096, '16QAM', 0x007, 0, 'OK'),
            (1402, nc.l_max(10, 'QPSK'), 'QPSK', 0x100, 0, 'OK'), (1403, 4096, 'QPSK', 0x007, 200, 'HEADER_LONG'),
            (1404, 64, 'QPSK', 0x007, 0, 'OK'), (1405, 1, 'QPSK', 0, 0, 'OK')]
    sc['nc_lmax'] = dict(args=stream(rng, plan, 300, 1.0, snr_db=30, cfo=0.15), gain=0, blind=1)
    # 5. blind candidate disabled: frames with a new mask cannot be decoded (HEADER).
    plan = [(1500 + n, 100, 'QPSK', m, 100, e) for n, (m, e) in enumerate(
        [(0, 'OK'), (0x080, 'HEADER'), (0x080, 'HEADER'), (0, 'OK'), (0x003, 'HEADER'), (0, 'OK')])]
    sc['nc_noblind'] = dict(args=stream(rng, plan, 500, 1.0, snr_db=30), gain=0, blind=0)
    return sc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--output', required=True)
    ap.add_argument('--seed', type=int, default=20261025)
    ap.add_argument('--only', nargs='*')
    args = ap.parse_args()
    out = pathlib.Path(args.output); out.mkdir(parents=True, exist_ok=False)
    rng = np.random.default_rng(args.seed)
    index = {}
    for name, s in scenarios(rng).items():
        if args.only and name not in args.only:
            continue
        words, frames = s['args']
        d = out / name; d.mkdir()
        (d / 'stream.mem').write_text(''.join(f'{int(w):08x}\n' for w in words))
        (d / 'expected.json').write_text(json.dumps(dict(frames=frames, nsamp=len(words), gain=s['gain'],
                                                       allow_stats=s.get('allow_stats', [])), indent=1))
        index[name] = dict(nsamp=len(words), frames=len(frames), gain=s['gain'], blind=s['blind'], hdrthr=HDR_THR)
    (out / 'index.json').write_text(json.dumps(index, indent=1))
    print(json.dumps(index))


if __name__ == '__main__':
    main()
