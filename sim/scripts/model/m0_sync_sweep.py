"""M0 sweep for the route-B streaming receiver algorithm (float, no EDA).

Usage: python -m scripts.model.m0_sync_sweep --output build/route_b/m0_sweep01
"""
import argparse
import json
import pathlib
import time

import numpy as np

from models.ofdm import core, framing, streaming_rx as srx

CHANNELS = {
    "flat": np.array([1.0 + 0j]),
    "cp_short": np.array([0.65 * np.exp(0.7j), 0, 0, 0, 0.18j, 0, 0, 0, -0.07]),
    "cp_long": np.r_[0.8, np.zeros(11), 0.45j, np.zeros(7), -0.25],   # 21 taps, inside CP32
}
LENGTHS = (0, 1, 18, 22, 64, 256)


def build_stream(rng, frames, gap_mode, mods=("QPSK",)):
    parts, truth, expected = [], [], {}
    pos = 0
    lead = int(rng.integers(500, 900))
    parts.append(np.zeros(lead, dtype=complex)); pos += lead
    for fid in range(frames):
        plen = int(rng.choice(LENGTHS))
        payload = rng.integers(0, 256, plen, dtype=np.uint8).tobytes()
        mod = mods[fid % len(mods)]
        tx = framing.encode_frame(payload, mod, frame_id=1000 + fid, whiten=True).samples
        truth.append((pos, 1000 + fid, len(tx)))
        expected[1000 + fid] = payload
        parts.append(tx); pos += len(tx)
        gap = 0 if gap_mode == "zero" else int(rng.integers(0, 400))
        if gap:
            parts.append(np.zeros(gap, dtype=complex)); pos += gap
    parts.append(np.zeros(1200, dtype=complex))
    return np.concatenate(parts), truth, expected


def impair(x, rng, snr_db, cfo, channel):
    y = np.convolve(x, channel)[: len(x)]
    n = np.arange(len(y))
    y = y * np.exp(2j * np.pi * cfo * n / core.NFFT) * np.exp(1j * rng.uniform(0, 2 * np.pi))
    # Signal power over the transmitted (non-idle) samples, per plan section 16.
    ps = np.mean(np.abs(y[np.abs(x) > 0]) ** 2)
    sigma2 = ps / 10 ** (snr_db / 10)
    noise = np.sqrt(sigma2 / 2) * (rng.standard_normal(len(y)) + 1j * rng.standard_normal(len(y)))
    return y + noise


def score(results, truth, expected):
    starts = {s: fid for s, fid, _ in truth}
    good_ids, hdr_ids, timing, cfo_err = set(), set(), [], []
    false_det = false_hdr = 0
    bit_err = bits = 0
    for r in results:
        match = [s for s in starts if abs(r.start - s) <= 40]
        if not match:
            false_det += 1
            if r.header_ok:
                false_hdr += 1
            continue
        timing.append(r.start - match[0])
        if r.header_ok:
            if r.header["frame_id"] != starts[match[0]]:
                false_hdr += 1
                continue
            hdr_ids.add(r.header["frame_id"])
            if r.bit_errors is not None:
                bit_err += r.bit_errors; bits += r.compared_bits
            if r.payload_crc_ok:
                good_ids.add(r.header["frame_id"])
    n = len(truth)
    return dict(frames=n, detected_header=len(hdr_ids), good=len(good_ids),
                per=1 - len(good_ids) / n, header_fail=n - len(hdr_ids),
                false_detections=false_det, false_header_accepts=false_hdr,
                bit_errors=bit_err, compared_bits=bits,
                timing_mean=float(np.mean(timing)) if timing else None,
                timing_min=int(min(timing)) if timing else None,
                timing_max=int(max(timing)) if timing else None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", required=True)
    ap.add_argument("--frames", type=int, default=24)
    ap.add_argument("--seed", type=int, default=20261021)
    ap.add_argument("--timings", default="plateau,peak,matched")
    ap.add_argument("--backoffs", default="8,12,16")
    ap.add_argument("--mods", default="QPSK")
    args = ap.parse_args()
    out = pathlib.Path(args.output); out.mkdir(parents=True, exist_ok=False)
    rng = np.random.default_rng(args.seed)
    rows = []
    t0 = time.time()
    snrs = list(range(0, 31, 3))
    mods = tuple(args.mods.split(","))
    backoffs = [int(b) for b in args.backoffs.split(",")]
    for timing in args.timings.split(","):
        for backoff in backoffs:
            if timing != "plateau" and backoff != backoffs[len(backoffs) // 2]:
                continue
            cfg = srx.RxConfig(timing=timing, backoff=backoff)
            for chan in CHANNELS:
                for cfo in (0.0, 0.1, -0.25, 0.35):
                    for snr in snrs:
                        for gap in ("zero", "random"):
                            x, truth, exp = build_stream(rng, args.frames, gap, mods)
                            y = impair(x, rng, snr, cfo, CHANNELS[chan])
                            res = srx.receive(y, cfg, exp)
                            row = dict(mods=args.mods, timing=timing, backoff=backoff, channel=chan, cfo=cfo,
                                       snr_db=snr, gap=gap, **score(res, truth, exp))
                            rows.append(row)
    # Noise-only false-alarm check and identical-payload-symbol hazard.
    cfg = srx.RxConfig()
    noise = (rng.standard_normal(2_000_000) + 1j * rng.standard_normal(2_000_000)) * 0.01
    fa = srx.detect(noise, cfg)
    zero_payload = framing.encode_frame(bytes(1024), "QPSK", frame_id=7, whiten=True).samples
    zp = np.r_[np.zeros(600), zero_payload, np.zeros(1200)]
    zres = srx.receive(zp, cfg, {7: bytes(1024)})
    summary = dict(elapsed_s=round(time.time() - t0, 1), noise_only_samples=len(noise),
                   noise_only_detections=len(fa),
                   zero_payload_detections=[(r.start - 600, r.reason) for r in zres])
    (out / "rows.json").write_text(json.dumps(rows, indent=1))
    (out / "summary.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
