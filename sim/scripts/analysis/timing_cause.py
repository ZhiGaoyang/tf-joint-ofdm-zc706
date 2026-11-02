"""Cause check: fill masked carriers of the two header symbols (power restored) vs zero."""
import sys
sys.path.insert(0, '.')
import numpy as np
from models.ofdm import core, v02
from models.ofdm.streaming_rx import detect, RxConfig
from models.ofdm_nc import nc
cfg = RxConfig()
data, _, _ = core.carrier_bins()
for mask in [0, 0x007, 0x003, 0x124, 0x700]:
    res = {}
    for variant in ('zero', 'filled_header', 'scaled_header'):
        rng = np.random.default_rng(1)
        offs = []
        for k in range(40):
            fid = int(rng.integers(0, 2**31)); L = int(rng.integers(0, 500)); mod = ['QPSK', '16QAM'][k % 2]
            g = nc.encode_frame(v02.prbs_payload(fid, L), mod, fid, 0, mask).grid.copy()
            masked = [b for b in data if mask >> nc.group_of_bin(b) & 1]
            if variant == 'filled_header' and masked:
                fill = (1 + 1j) / np.sqrt(2) * np.exp(1j * np.pi / 2 * rng.integers(0, 4, len(masked)))
                g[2, masked] = fill; g[3, masked] = fill
            if variant == 'scaled_header' and masked:
                g[2:4] *= np.sqrt(96 / (96 - len(masked)))
            r = np.concatenate([np.zeros(500), core.grid_to_samples(g), np.zeros(800)])
            d = detect(r, cfg)
            offs.append(d[0].start - 500)
        res[variant] = '%d..%d mean %.1f' % (min(offs), max(offs), np.mean(offs))
    print('mask %03x' % mask, res)
