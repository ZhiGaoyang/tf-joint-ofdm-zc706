"""Candidate MCS policies for offline trace replay (design-study code, not board code).

Every policy exposes update(window_record) -> next mcs (0 QPSK, 1 16QAM), where
window_record has the keys produced by lean_ctl.measurement()/lean_adapt.window():
ok, sent, per, evm (percent or None), elapsed_s, mcs.

  BASELINE_threshold      : unchanged lean_adapt.Policy (imported, default args)
  ABL_threshold_fast      : same rule, up_windows=1, dwell=1 (dwell ablation)
  PRIMARY_pred_olla       : EVM -> effective SNR, Holt one-step prediction with
                            variance margin, OLLA offset learned from 16QAM CRC,
                            expected-goodput comparison with hysteresis
  ABL_pred_no_olla        : primary without OLLA (offset fixed 0)
  ABL_olla_no_pred        : primary without prediction margin/trend (k=0, phi=0)
  CMP_context_ts          : contextual Thompson sampling over {QPSK,16QAM}
                            (2 dB effective-SNR bins, Beta(1,1) frame-success priors)
"""
import json
import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CAL_DEFAULT = pathlib.Path(__file__).resolve().parent / "results" / "calibration.json"
LEN_BITS = 4096 * 8
# Structural window time estimate (估计): 16 frames x samples / 122.88 MSPS + 2.5 ms overhead.
T_INIT = {0: 16 * 191 * 160 / 122.88e6 + 2.5e-3, 1: 16 * 98 * 160 / 122.88e6 + 2.5e-3}


def _interp(x, xs, ys):
    if x <= xs[0]:
        return ys[0]
    if x >= xs[-1]:
        return ys[-1]
    for i in range(1, len(xs)):
        if x <= xs[i]:
            t = (x - xs[i - 1]) / (xs[i] - xs[i - 1])
            return ys[i - 1] + t * (ys[i] - ys[i - 1])
    return ys[-1]


class Calibration:
    """Mode-specific EVM(%) -> model-SNR(dB) map and PER(SNR) table from sim summary."""

    def __init__(self, path=CAL_DEFAULT):
        cal = json.loads(pathlib.Path(path).read_text())
        self.evm_to_snr, self.per = {}, {}
        for m, key in ((0, "QPSK"), (1, "16QAM")):
            c = cal[key]
            # evm is decreasing in snr; store ascending evm for interpolation
            pairs = sorted(zip(c["evm_pct"], c["evm_map_snr_db"]))
            self.evm_to_snr[m] = ([p[0] for p in pairs], [p[1] for p in pairs])
            self.per[m] = (c["snr_db"], c["per_monotone"])

    def snr(self, mode, evm_pct):
        xs, ys = self.evm_to_snr[mode]
        return _interp(evm_pct, xs, ys)

    def per_at(self, mode, snr_db):
        xs, ys = self.per[mode]
        return min(1.0, max(0.0, _interp(snr_db, xs, ys)))


class PredOlla:
    def __init__(self, cal, alpha=0.5, beta=0.3, phi=0.5, k=1.0, hyst=0.05, target=0.1,
                 step_down=0.25, olla=True, delta_min=-6.0, delta_max=3.0, relax=0.97, outage_mode=0):
        self.cal, self.alpha, self.beta, self.phi, self.k = cal, alpha, beta, phi, k
        self.hyst, self.target, self.step_down, self.olla = hyst, target, step_down, olla
        self.step_up = step_down * target / (1 - target)
        self.dmin, self.dmax, self.relax = delta_min, delta_max, relax
        self.level = self.trend = None
        self.var = 1.0  # dB^2, also the reset value
        self.delta = 0.0
        self.t = dict(T_INIT)
        self.mcs = 0
        self.outage_mode = outage_mode
        self.log = []

    @staticmethod
    def _payload_fail(r):
        return r.get("crc_fail", 0) + r.get("truncated", 0)

    def predicted_snr(self):
        return self.level + self.phi * self.trend - self.k * math.sqrt(self.var)

    def update(self, r):
        used = r.get("mcs", self.mcs)
        self.t[used] = 0.8 * self.t[used] + 0.2 * r["elapsed_s"]
        if r["ok"] == 0 or r["evm"] is None:
            # safety rule identical to the baseline: link lost -> QPSK
            # Only payload failures (header valid, CRC failed or truncated) are charged to
            # 16QAM; header loss is MCS-independent because header/training are always QPSK.
            if used == 1 and self.olla:
                self.delta = max(self.dmin, self.delta - self.step_down * self._payload_fail(r))
            # outage_mode=1 is a decomposition ablation only: header/training are QPSK in
            # both modes, so a shorter 16QAM window still probes header recovery.
            self.level, self.trend, self.var = None, None, 1.0   # stale state after loss
            self.mcs = self.outage_mode
            self.log.append((None, self.delta, self.mcs))
            return self.mcs
        g = self.cal.snr(used, r["evm"])
        if self.level is None:
            self.level, self.trend = g, 0.0
        else:
            pred = self.level + self.phi * self.trend
            err = g - pred
            # downside semi-variance: only observations worse than predicted widen the margin
            self.var = 0.8 * self.var + 0.2 * (err * err if err < 0 else 0.0)
            new_level = self.alpha * g + (1 - self.alpha) * pred
            self.trend = self.beta * (new_level - self.level) + (1 - self.beta) * self.phi * self.trend
            self.level = new_level
        if self.olla:
            if used == 1:
                n_ok, n_fail = r["ok"], self._payload_fail(r)
                self.delta += self.step_up * n_ok - self.step_down * n_fail
                self.delta = min(self.dmax, max(self.dmin, self.delta))
            else:
                self.delta *= self.relax
        s = self.predicted_snr() + self.delta
        thr = {m: (1 - self.cal.per_at(m, s)) * LEN_BITS / self.t[m] for m in (0, 1)}
        if self.mcs == 0:
            self.mcs = 1 if thr[1] > thr[0] * (1 + self.hyst) else 0
        else:
            self.mcs = 1 if thr[1] > thr[0] * (1 - self.hyst) else 0
        self.log.append((round(s, 2), round(self.delta, 2), self.mcs))
        return self.mcs


class ContextTS:
    def __init__(self, cal, rng, bin_db=2.0, prior=(1.0, 1.0), model_prior=0, safety=True):
        """model_prior>0: Beta prior of that many pseudo-frames from the model PER table.
        safety=True: same outage rule as baseline/primary (link lost -> QPSK, no sampling)."""
        self.cal, self.rng, self.bin_db, self.prior, self.n0 = cal, rng, bin_db, prior, model_prior
        self.safety = safety
        self.ab = {}
        self.t = dict(T_INIT)
        self.ctx = -1  # -1 = link lost / no observation yet
        self.mcs = 0

    def update(self, r):
        used = r.get("mcs", self.mcs)
        self.t[used] = 0.8 * self.t[used] + 0.2 * r["elapsed_s"]
        a, b = self.ab.get((self.ctx, used), self._prior(self.ctx, used))
        self.ab[(self.ctx, used)] = (a + r["ok"], b + r["sent"] - r["ok"])
        if r["ok"] == 0 or r["evm"] is None:
            self.ctx = -1
            if self.safety:
                self.mcs = 0
                return 0
        else:
            self.ctx = int(self.cal.snr(used, r["evm"]) // self.bin_db)
        score = {}
        for m in (0, 1):
            a, b = self.ab.get((self.ctx, m), self._prior(self.ctx, m))
            score[m] = self.rng.betavariate(a, b) * LEN_BITS / self.t[m]
        self.mcs = 1 if score[1] > score[0] else 0
        return self.mcs


def _ts_prior(self, ctx, m):
    if self.n0 <= 0 or ctx < 0:
        return self.prior
    p = self.cal.per_at(m, (ctx + 0.5) * self.bin_db)
    return (self.prior[0] + self.n0 * (1 - p), self.prior[1] + self.n0 * p)


ContextTS._prior = _ts_prior


class BaselineWrap:
    """Adapter for the unchanged lean_adapt.Policy (returns (mcs, reason))."""

    def __init__(self, **kw):
        sys.path.insert(0, str(ROOT.parent / "src" / "ps"))
        from lean_adapt import Policy  # noqa: E402  (imports lean_ctl; no /dev/mem access at import)
        self.p = Policy(**kw)

    def update(self, r):
        return self.p.update(r)[0]


def candidates(rng, cal_path=CAL_DEFAULT):
    cal = Calibration(cal_path)
    return {
        "BASELINE_threshold": BaselineWrap(),
        "ABL_threshold_fast": BaselineWrap(up_windows=1, dwell=1),
        "PRIMARY_pred_olla": PredOlla(cal),
        "ABL_pred_no_olla": PredOlla(cal, olla=False),
        "ABL_olla_no_pred": PredOlla(cal, k=0.0, phi=0.0),
        "CMP_context_ts": ContextTS(cal, rng),
        "CMP_context_ts_modelprior": ContextTS(cal, rng, model_prior=8),
        "ABL_pred_olla_outage16": PredOlla(cal, outage_mode=1),
    }
