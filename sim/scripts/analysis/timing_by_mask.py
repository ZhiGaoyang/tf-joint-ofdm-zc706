"""Model plateau-detector timing offset per mask (noise-free, idle lead)."""
import sys
sys.path.insert(0, '.')
import numpy as np
from models.ofdm import v02
from models.ofdm.streaming_rx import detect, RxConfig
from models.ofdm_nc import nc
cfg = RxConfig()
rng = np.random.default_rng(1)
for mask in [0, 0x001, 0x002, 0x004, 0x007, 0x003, 0x400, 0x700, 0x060, 0x080, 0x124]:
    offs = []
    for k in range(40):
        fid = int(rng.integers(0, 2**31)); L = int(rng.integers(0, 500)); mod = ['QPSK', '16QAM'][k % 2]
        s = nc.encode_frame(v02.prbs_payload(fid, L), mod, fid, 0, mask).samples
        r = np.concatenate([np.zeros(500), s, np.zeros(800)])
        d = detect(r, cfg)
        offs.append(d[0].start - 500 if d else None)
    o = [x for x in offs if x is not None]
    print('mask %03x  n=%d  offset min %d max %d mean %.1f' % (mask, len(o), min(o), max(o), np.mean(o)))
