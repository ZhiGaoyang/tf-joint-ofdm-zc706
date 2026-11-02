"""Generate host-simulation scenarios for ofdm_rxs_core (protocol V0.2).

Each scenario directory holds stream.mem ($readmemh, Q high / I low), a
manifest with the transmitted frames, and the expected per-frame outcome.
Usage: python -m scripts.model.rxs_vectors --output build/route_b/vectors01
"""
import argparse
import json
import pathlib

import numpy as np

from models.ofdm import core, v02
from scripts.model.m0_sync_sweep import CHANNELS, impair


def stream(rng, plan, lead, scale, snr_db=None, cfo=0.0, channel="flat", corrupt=None):
    """plan: list of (frame_id, length, modulation, gap_after)."""
    parts, frames, pos = [np.zeros(lead, dtype=complex)], [], lead
    for fid, length, mod, gap in plan:
        payload, tx = v02.encode_test_frame(fid, length, mod)
        frames.append(dict(frame_id=fid, length=length, mcs=1 if mod == "16QAM" else 0, start=pos,
                           samples=len(tx), expect="OK"))
        parts.append(tx); pos += len(tx)
        if gap:
            parts.append(np.zeros(gap, dtype=complex)); pos += gap
    parts.append(np.zeros(1500, dtype=complex))
    x = np.concatenate(parts)
    if snr_db is not None or cfo or channel != "flat":
        y = impair(x, rng, 200.0 if snr_db is None else snr_db, cfo, CHANNELS[channel])
    else:
        y = x
    for kind, index in corrupt or []:
        f = frames[index]
        if kind == "header":       # destroy both header symbols
            a, b = f["start"] + 320, f["start"] + 640
            f["expect"] = "HEADER"
        else:                      # destroy the second half of the payload
            a, b = f["start"] + 640 + (f["samples"] - 640) // 2, f["start"] + f["samples"]
            f["expect"] = "PAYLOAD"
        y[a:b] = 0.03 * (rng.standard_normal(b - a) + 1j * rng.standard_normal(b - a))
    return v02.to_words(y, scale), frames


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", required=True)
    ap.add_argument("--seed", type=int, default=20261021)
    args = ap.parse_args()
    out = pathlib.Path(args.output); out.mkdir(parents=True, exist_ok=False)
    rng = np.random.default_rng(args.seed)
    lengths = [0, 1, 18, 22, 64, 256, 1000]
    scenarios = {}
    # 1. clean mixed QPSK/16QAM, unknown lead, zero and random gaps, small CFO
    plan = [(100 + n, lengths[n % len(lengths)], "16QAM" if n % 3 == 2 else "QPSK",
             0 if n % 2 else int(rng.integers(1, 400))) for n in range(14)]
    scenarios["clean_mixed"] = dict(args=stream(rng, plan, 733, 1.0, cfo=0.1), gain=0)
    # 2. impaired: 22 dB, CFO -0.3, short CP-internal multipath, QPSK/16QAM
    plan = [(200 + n, [18, 64, 256, 700][n % 4], "16QAM" if n % 4 == 3 else "QPSK", 0 if n % 3 else 150)
            for n in range(12)]
    scenarios["impaired"] = dict(args=stream(rng, plan, 517, 1.0, snr_db=22, cfo=-0.3, channel="cp_short"), gain=0)
    # 3. bad frames and recovery: header destroyed, payload destroyed, good frames after each
    plan = [(300 + n, [64, 256, 100, 300, 22, 500, 18, 64][n], "QPSK", [0, 0, 200, 0, 0, 0, 90, 0][n])
            for n in range(8)]
    scenarios["bad_frames"] = dict(args=stream(rng, plan, 601, 1.0, snr_db=30, cfo=0.05,
                                               corrupt=[("header", 1), ("payload", 4), ("header", 6)]), gain=0)
    # 4. dense minimum frames, zero gap
    plan = [(400 + n, [0, 1, 18][n % 3], "QPSK", 0) for n in range(24)]
    scenarios["dense_min"] = dict(args=stream(rng, plan, 450, 1.0, snr_db=30, cfo=0.2), gain=0)
    # 5. maximum payloads, both modulations, zero gap
    plan = [(500, 4096, "QPSK", 0), (501, 4096, "16QAM", 0), (502, 1, "QPSK", 0)]
    scenarios["max_frames"] = dict(args=stream(rng, plan, 300, 1.0, snr_db=30, cfo=0.15), gain=0)
    # 6. RF-like low input level (-20 dB) compensated by the x4 ingress gain
    plan = [(600 + n, [22, 256, 0, 64][n % 4], "16QAM" if n == 5 else "QPSK", 0 if n % 2 else 300)
            for n in range(8)]
    scenarios["low_level"] = dict(args=stream(rng, plan, 980, 0.1, snr_db=28, cfo=-0.12), gain=2)
    index = {}
    for name, sc in scenarios.items():
        words, frames = sc["args"]
        d = out / name; d.mkdir()
        (d / "stream.mem").write_text("".join(f"{int(w):08x}\n" for w in words))
        (d / "expected.json").write_text(json.dumps(dict(frames=frames, nsamp=len(words), gain=sc["gain"]), indent=1))
        index[name] = dict(nsamp=len(words), frames=len(frames), gain=sc["gain"])
    (out / "index.json").write_text(json.dumps(index, indent=1))
    print(json.dumps(index))


if __name__ == "__main__":
    main()
