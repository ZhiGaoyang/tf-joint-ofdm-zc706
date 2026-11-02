"""Joint time-frequency decision core (host reference for the PS policy).

Per burst, choose modulation m in {0:QPSK, 1:16QAM} and a set M of masked
subcarrier groups (11 groups x 8 data carriers, at most 3 masked so that at
least 64 data carriers stay active for the header) to maximise expected
goodput.  Inputs are per-group decision EVM (percent) measured by the RX chain
while receiving, plus window statistics.  Model-based (estimate), not RTL.

Model:
  n_active      = 88 - 8|M|
  P(m, M)       = max(1, ceil(8 (L + 4) / (n_active * bits_m)))   payload symbols
  airtime       = frames * (4 + P) * 160 / Fs                      2 training + 2 header symbols
  snr_g         = Cal_{m_meas}(evm_g) + offset                      model SNR of group g
  survival(m,M) = prod_{g not in M} (1 - PER_m(snr_g)) ** (8 P(m,M) / (88 P_ref(m)))
  G(m, M)       = survival * frames * 8L / (t_fixed + airtime)
For a fixed |M| = k the rate cost is identical, so masking the k worst groups
maximises survival: 2 modes x 4 sizes = 8 candidates (checked against
exhaustive search in the tests).
"""
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "innovation_a"))
from policies import Calibration  # noqa: E402  (A's EVM->SNR and PER tables)

FS = 122.88e6
GROUPS = 11
PER_GROUP = 8
DATA_CARRIERS = 88
MAX_MASKED = 3
BITS = {0: 2, 1: 4}
CAL_LEN = 4096          # payload length behind the PER calibration table


def payload_symbols(length, mode, n_active):
    return max(1, math.ceil(8 * (length + 4) / (n_active * BITS[mode])))


def l_max(n_masked, mode):
    """Largest payload that fits 187 payload symbols (RX fetch limit 191) with n_masked groups."""
    return min(4096, 187 * (GROUPS - n_masked) * BITS[mode] - 4)


def airtime_s(length, mode, n_active, frames):
    return frames * (4 + payload_symbols(length, mode, n_active)) * 160 / FS


DESTROYED_DB = -100.0      # survival 0 for any modulation
ERASE_LIMIT = 0.01         # erased instances per measured instance above which a group is unusable
MODEL_OFFSET_DB = 0.9      # model SNR is ~0.8-1.0 dB above 10log10(1/EVM^2) (A design §1.4)


def group_snr(cal, measured_mode, evm_pct, offset_db=0.0):
    """Model SNR per group from EVM measured under `measured_mode`; None stays None."""
    return [None if e is None else cal.snr(measured_mode, e) + offset_db for e in evm_pct]


def group_snr_from_metrics(cal, measured_mode, m_g, erase_g, masked, offset_db=0.0):
    """Per-group model SNR from the B metric (B design §1.3).

    m_g[g]     mean normalised error energy M_g (= EVM^2) of group g, or None if unmeasured
    erase_g[g] erasure rate E_g of group g (erased instances / measured instances)
    masked     groups masked in the measured burst: their payload metric uses 0 as reference,
               so 1/M_g is the signal-to-(interference+noise) ratio seen on that group.
    """
    out = []
    for g, (m, e) in enumerate(zip(m_g, erase_g)):
        if (e is not None and e > ERASE_LIMIT) or m == math.inf:
            out.append(DESTROYED_DB)
        elif m is None:
            out.append(None)
        elif m <= 0:
            out.append(cal.per[measured_mode][0][-1] + offset_db)       # top of the table
        elif g in masked:
            out.append(10 * math.log10(1 / m) + MODEL_OFFSET_DB + offset_db)
        else:
            out.append(cal.snr(measured_mode, 100 * math.sqrt(m)) + offset_db)
    return out


def survival(cal, mode, snrs, masked, length):
    n_active = DATA_CARRIERS - PER_GROUP * len(masked)
    exposure = PER_GROUP * payload_symbols(length, mode, n_active) / (
        DATA_CARRIERS * payload_symbols(CAL_LEN, mode, DATA_CARRIERS))
    s = 1.0
    for g, snr in enumerate(snrs):
        if g in masked or snr is None:
            continue
        if snr <= DESTROYED_DB:
            return 0.0
        s *= (1.0 - cal.per_at(mode, snr)) ** exposure
    return s


def goodput(cal, mode, snrs, masked, length, frames, t_fixed_s):
    n_active = DATA_CARRIERS - PER_GROUP * len(masked)
    t = t_fixed_s + airtime_s(length, mode, n_active, frames)
    return survival(cal, mode, snrs, masked, length) * frames * 8 * length / t


def candidates(snrs):
    """Worst-k masks for k = 0..MAX_MASKED; unknown groups are never masked."""
    known = sorted((s, g) for g, s in enumerate(snrs) if s is not None)
    return [frozenset(g for _, g in known[:k]) for k in range(MAX_MASKED + 1)]


class JointPolicy:
    """Stateful wrapper: hysteresis on the chosen (mode, mask) and a safe outage rule."""

    def __init__(self, cal, length=4096, frames=16, t_fixed_s=2.5e-3, hyst=0.05, hyst_mask=0.01):
        # hyst applies to modulation changes.  A mask-only change needs just hyst_mask:
        # with the 2.5 ms window overhead, unmasking one group gains only ~4%, so a 5%
        # threshold would leave a group masked forever after the interferer has gone.
        self.cal, self.length, self.frames = cal, length, frames
        self.t_fixed_s, self.hyst, self.hyst_mask = t_fixed_s, hyst, hyst_mask
        self.mode, self.mask = 0, frozenset()

    def score(self, snrs, mode, mask):
        return goodput(self.cal, mode, snrs, mask, self.length, self.frames, self.t_fixed_s)

    def decide(self, measured_mode, group_evm_pct, frames_ok, offset_db=0.0, snrs=None):
        """Return (mode, mask, reason).  No metric at all -> QPSK, keep mask ("link_lost").

        frames_ok is not a veto: a tone that breaks every payload CRC still leaves a valid
        per-group metric, and masking is exactly the way out.  Pass `snrs` (e.g. from
        group_snr_from_metrics) to bypass the EVM conversion."""
        if snrs is None:
            snrs = group_snr(self.cal, measured_mode, group_evm_pct, offset_db)
        # Every return path yields a (mode, mask) whose L_max carries the frame length.
        if all(s is None for s in snrs):
            self.mode = 0
            if self.length > l_max(len(self.mask), 0):
                self.mask = frozenset()
            return self.mode, self.mask, "link_lost"
        # Only (mode, mask) pairs that carry the frame length: others make the framer fault.
        best = max(((self.score(snrs, m, msk), m, msk) for m in (0, 1) for msk in candidates(snrs)
                    if self.length <= l_max(len(msk), m)),
                   key=lambda x: (x[0], -len(x[2]), -x[1]))
        current = self.score(snrs, self.mode, self.mask)
        if best[0] <= 0 and current <= 0:
            # No candidate is expected to deliver anything: QPSK, most protective legal mask.
            self.mode = 0
            self.mask = next(m for m in reversed(candidates(snrs)) if self.length <= l_max(len(m), 0))
            return self.mode, self.mask, "no_viable"
        threshold = self.hyst if best[1] != self.mode else self.hyst_mask
        if (best[1], best[2]) != (self.mode, self.mask) and best[0] > (1 + threshold) * current:
            self.mode, self.mask = best[1], best[2]
            return self.mode, self.mask, "switch"
        return self.mode, self.mask, "hold"


def mask_bitmap(mask):
    return sum(1 << g for g in mask)
