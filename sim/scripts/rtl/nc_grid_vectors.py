"""Vectors for tb_nc_grid.sv: frame commands, payloads and the expected
frequency-domain words at ofdm_frame_grid_v2 output (training + header + body).

  python -I -B scripts/rtl/nc_grid_vectors.py <out_dir> [--mask0-only]

Word stream (one 32-bit hex word per line, vectors.mem):
  n_cases, then per case:
  {mask[26:16], expect_fault[14], mcs[13], length[12:0]} (see pack())
  frame_id, epoch, nsym, length payload words (one byte each), nsym*128 expected words.
Expected words: Q[31:16], I[15:0], W16/F14 rounding of the reference model grid.
"""
import argparse
import hashlib
import json
import random
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from models.ofdm import core, framing     # noqa: E402
from models.ofdm_nc import nc             # noqa: E402

SEED = 20261025


def pack(mask, fault, mcs, length):
    return (mask << 16) | (fault << 14) | (mcs << 13) | length


def words(grid):
    i = np.rint(grid.real * 16384).astype(np.int64)
    q = np.rint(grid.imag * 16384).astype(np.int64)
    assert np.all(abs(i) <= 32767) and np.all(abs(q) <= 32767)
    return (((q & 0xFFFF) << 16) | (i & 0xFFFF)).reshape(-1)


def cases(mask0_only):
    rng = random.Random(SEED)
    out = []
    masks = [0, 0x001, 0x400, 0x020, 0x080, 0x180, 0x003, 0x481, 0x700, 0x007, 0x124, 0x2A0]
    for mask in masks:
        groups = 11 - bin(mask).count('1')
        for mcs, mod in enumerate(framing.MODULATIONS):
            top = nc.l_max(groups, mod)
            lengths = [0, 1, 15, 16, 17, rng.randrange(18, 600)]
            if mask in (0, 0x007, 0x180):
                lengths.append(top)
            for length in lengths:
                out.append((mask, mcs, length, 0))
    # Illegal: length beyond L_max (geometry fault) and more than 3 masked groups.
    out += [(0x007, 0, nc.l_max(8, 'QPSK') + 1, 1), (0x001, 0, nc.l_max(10, 'QPSK') + 1, 1),
            (0x00F, 0, 10, 1), (0x7FF, 1, 10, 1)]
    if mask0_only:
        out = [c for c in out if c[0] == 0]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out', type=Path)
    ap.add_argument('--mask0-only', action='store_true')
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=False)
    rng = np.random.default_rng(SEED)
    stream, meta = [], []
    for n, (mask, mcs, length, fault) in enumerate(cases(a.mask0_only)):
        payload = bytes(rng.integers(0, 256, length, dtype=np.uint8))
        frame_id, epoch = 0x1000 + n, (n * 37) & 0xFFFF
        if fault:
            nsym, expected = 0, []
        else:
            f = nc.encode_frame(payload, framing.MODULATIONS[mcs], frame_id, epoch, mask)
            nsym, expected = len(f.grid), list(words(f.grid))
        stream += [pack(mask, fault, mcs, length), frame_id, epoch, nsym] + list(payload) + expected
        meta.append(dict(mask=mask, mcs=mcs, length=length, fault=fault, nsym=nsym))
    stream = [len(meta)] + stream
    body = '\n'.join('%08x' % w for w in stream) + '\n'
    (a.out / 'vectors.mem').write_text(body, encoding='ascii', newline='\n')
    info = dict(seed=SEED, cases=meta, words=len(stream),
                sha256=hashlib.sha256(body.encode()).hexdigest())
    (a.out / 'vectors.json').write_text(json.dumps(info, indent=1), encoding='ascii')
    print('cases', len(meta), 'words', len(stream), 'sha256', info['sha256'])


if __name__ == '__main__':
    main()
