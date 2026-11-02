"""Float reference of the route-B streaming receiver (2026-10-21).

One sample stream, no TX side information.  Detection uses the lag-160 /
window-128 repetition metric of the two identical training symbols; timing is
the centre of the thresholded plateau; CFO is the angle of the plateau-summed
correlation.  Residual timing error inside the CP becomes a linear phase that
the per-frame training channel estimate absorbs.  This is an algorithm
reference for the RTL, not a bit-exact model.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import struct

import numpy as np

from . import core, framing

LAG = 160
WINDOW = 128
SYMBOL = core.NFFT + core.NCP
# Ideal plateau of the metric ending at n spans n in [s+287, s+319]; its
# centre would be s+303.  The thr_lo run of the real training waveform is
# measured (m0_sweep01/02, flat channel, 15..30 dB) to centre 9 samples
# earlier, so the calibrated start is centre-294.
PLATEAU_CENTRE = 294
MIN_FRAME_SAMPLES = 5 * SYMBOL
TRAIN = framing.training_grid()[0]
ACTIVE = np.array(sorted(int(k) % core.NFFT for k in core.ACTIVE_SIGNED))
DATA_BINS, PILOT_BINS, _ = core.carrier_bins()
# Adjacent active pairs in signed order, excluding the jump across DC.
_SIGNED = np.array(sorted(int(k) for k in core.ACTIVE_SIGNED))
ADJ_PAIRS = np.array([(a % 128, b % 128) for a, b in zip(_SIGNED[:-1], _SIGNED[1:]) if b - a == 1])


@dataclass
class RxConfig:
    thr_hi: float = 0.5        # enter plateau when |P|^2 >= thr_hi*max(E0,E1)^2
    thr_lo: float = 0.35       # stay in plateau while above thr_lo
    min_plateau: int = 12      # reject shorter runs
    backoff: int = 10          # FFT window starts this many samples inside the CP
    blank: int = 720           # ignore new plateaus within blank samples of s_hat
    train_q_min: float = 0.5   # frequency-domain training qualification
    energy_floor: float = 1e-12
    timing: str = "plateau"    # "plateau" or "peak" or "matched"
    h_floor: float = 0.05
    whiten: bool = True        # V0.2 payload whitening


@dataclass
class Detection:
    start: int
    cfo: float                 # normalized to subcarrier spacing
    plateau: tuple


@dataclass
class FrameResult:
    start: int
    cfo: float
    train_q: float
    header_ok: bool
    header: dict | None
    payload: bytes = b""
    payload_crc_ok: bool = False
    reason: str = ""
    evm: float | None = None
    bit_errors: int | None = None
    compared_bits: int = 0


def repetition_metric(r):
    """P[n], E0[n], E1[n] for windows ending at n (valid for n >= 287)."""
    n = len(r)
    prod = np.zeros(n, dtype=complex)
    prod[LAG:] = np.conj(r[:-LAG]) * r[LAG:]
    pw = np.abs(r) ** 2
    cp = np.concatenate(([0], np.cumsum(prod)))
    ce = np.concatenate(([0], np.cumsum(pw)))
    idx = np.arange(n)
    lo = np.maximum(idx - WINDOW + 1, 0)
    P = cp[idx + 1] - cp[lo]
    E1 = ce[idx + 1] - ce[lo]
    lo0 = np.maximum(idx - WINDOW + 1 - LAG, 0)
    hi0 = np.maximum(idx + 1 - LAG, 0)
    E0 = ce[hi0] - ce[lo0]
    P[: LAG + WINDOW - 1] = 0
    return P, E0, E1


def detect(r, cfg):
    """Streaming plateau detector; returns detections in arrival order."""
    P, E0, E1 = repetition_metric(r)
    # Normalise by the larger window energy: symmetric plateau edges when idle
    # input precedes the frame, and no blow-up when the later window is idle.
    den = np.maximum(E0, E1) ** 2
    p2 = np.abs(P) ** 2
    hi = (p2 >= cfg.thr_hi * den) & (den > cfg.energy_floor)
    lo = (p2 >= cfg.thr_lo * den) & (den > cfg.energy_floor)
    if cfg.timing == "matched":
        body = core.grid_to_samples(TRAIN[None, :])[core.NCP:]
        mf = np.abs(np.convolve(r, np.conj(body[::-1]), mode="full")[: len(r)]) ** 2
    out, n, blank_until = [], 287, -1
    N = len(r)
    while n < N:
        # A plateau is one run above thr_lo.  It must start after the blanking
        # interval (a run already in progress would give a truncated centre)
        # and must reach thr_hi somewhere.  Both run edges use thr_lo, so the
        # centre is unbiased for a symmetric metric.
        if lo[n] and not lo[n - 1]:
            n1 = n
            acc = 0j
            peak = False
            while n < N and lo[n]:
                acc += P[n]
                peak |= bool(hi[n])
                n += 1
            n2 = n - 1
            if n1 < blank_until or not peak or n2 - n1 + 1 < cfg.min_plateau:
                continue
            if cfg.timing == "plateau":
                centre = (n1 + n2) / 2
            elif cfg.timing == "peak":
                centre = n1 + int(np.argmax(p2[n1:n2 + 1] / np.maximum(den[n1:n2 + 1], 1e-30)))
            else:
                seg = mf[n1:n2 + 1 + 160]
                # Matched-filter peak of the second training body ends at s+319.
                centre = n1 + int(np.argmax(seg)) - (319 - 303) - (303 - PLATEAU_CENTRE)
            start = int(np.floor(centre + 0.5)) - PLATEAU_CENTRE
            cfo = float(np.angle(acc)) * core.NFFT / (2 * np.pi * LAG)
            out.append(Detection(start, cfo, (n1, n2)))
            blank_until = start + cfg.blank
        else:
            n += 1
    return out


def _fft_symbol(r, start, m, cfg, cfo):
    w0 = start + m * SYMBOL + core.NCP - cfg.backoff
    if w0 < 0 or w0 + core.NFFT > len(r):
        return None
    idx = np.arange(w0, w0 + core.NFFT)
    seg = r[idx] * np.exp(-2j * np.pi * cfo * (idx - start) / core.NFFT)
    return np.fft.fft(seg) / core.TX_GAIN


def _equalize(Y, H, usable):
    X = np.zeros(core.NFFT, dtype=complex)
    X[usable] = Y[usable] / H[usable]
    pil = PILOT_BINS[usable[PILOT_BINS]]
    corr = np.sum(X[pil] * core.PILOT_VALUES[np.isin(PILOT_BINS, pil)].real)
    if abs(corr) > 0:
        X = X * np.exp(-1j * np.angle(corr))
    return X


def decode_at(r, det, cfg, expected=None):
    """Decode one candidate. ``expected`` maps frame_id -> payload for BER only."""
    res = FrameResult(det.start, det.cfo, 0.0, False, None)
    Y0 = _fft_symbol(r, det.start, 0, cfg, det.cfo)
    Y1 = _fft_symbol(r, det.start, 1, cfg, det.cfo)
    if Y0 is None or Y1 is None:
        res.reason = "TRUNCATED"
        return res
    H = (Y0 + Y1) / 2 * TRAIN
    a, b = H[ADJ_PAIRS[:, 0]], H[ADJ_PAIRS[:, 1]]
    res.train_q = float(abs(np.sum(a * np.conj(b))) / max(np.sum(np.abs(H[ACTIVE]) ** 2), 1e-30))
    if res.train_q < cfg.train_q_min:
        res.reason = "TRAINING_REJECT"
        return res
    usable = np.zeros(core.NFFT, dtype=bool)
    usable[ACTIVE] = np.abs(H[ACTIVE]) >= cfg.h_floor * np.sqrt(np.mean(np.abs(H[ACTIVE]) ** 2))
    syms = [_fft_symbol(r, det.start, m, cfg, det.cfo) for m in (2, 3)]
    if any(s is None for s in syms):
        res.reason = "TRUNCATED"
        return res
    Xh = (_equalize(syms[0], H, usable) + _equalize(syms[1], H, usable)) / 2
    hbits = core.demap_symbols(Xh[DATA_BINS], "QPSK")
    try:
        res.header = framing.decode_header(core.bits_to_bytes(hbits[:128]))
        res.header_ok = True
    except ValueError:
        res.reason = "HEADER_INVALID"
        return res
    mod, plen = res.header["modulation"], res.header["payload_len"]
    cap = core.NDATA * core.bits_per_symbol(mod)
    body_bits = 8 * (plen + 4)
    nsym = (body_bits + cap - 1) // cap
    rows = []
    for m in range(4, 4 + nsym):
        Y = _fft_symbol(r, det.start, m, cfg, det.cfo)
        if Y is None:
            res.reason = "TRUNCATED"
            return res
        rows.append(_equalize(Y, H, usable))
    X = np.array(rows)
    raw = core.demap_symbols(X[:, DATA_BINS].reshape(-1), mod)
    if cfg.whiten:
        raw = raw ^ framing.scrambler_bits(len(raw))
    bits = raw[:body_bits]
    body = core.bits_to_bytes(bits)
    res.payload = body[:plen]
    res.payload_crc_ok = framing.crc32(res.payload) == struct.unpack("<I", body[plen:])[0]
    ref = core.map_bits(core.demap_symbols(X[:, DATA_BINS].reshape(-1), mod), mod)
    res.evm = float(np.sqrt(np.mean(np.abs(X[:, DATA_BINS].reshape(-1) - ref) ** 2) / np.mean(np.abs(ref) ** 2)))
    if expected is not None and res.header["frame_id"] in expected:
        want = core.bytes_to_bits(expected[res.header["frame_id"]])
        got = core.bytes_to_bits(res.payload)
        res.compared_bits = len(want)
        res.bit_errors = int(np.count_nonzero(want != got)) if len(got) == len(want) else len(want)
    res.reason = "OK" if res.payload_crc_ok else "PAYLOAD_CRC"
    return res


def receive(r, cfg=None, expected=None):
    cfg = cfg or RxConfig()
    return [decode_at(r, d, cfg, expected) for d in detect(r, cfg)]
