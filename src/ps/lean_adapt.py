#!/usr/bin/env python3
"""Two-level frame-adaptive MCS loop (QPSK <-> 16QAM) on the lean OFDM core.

Single-board centralised loop (plan section 23.1): RX quality counters -> PS
policy -> TX MCS for the next burst.  Each window sends one burst; the policy
uses window EVM and PER with hysteresis and a minimum dwell.  Thresholds are
initial values and must be calibrated from fixed-mode sweeps.

  lean_adapt.py --windows 600 --frames 16 --len 1024 --log adapt.jsonl
  lean_adapt.py --fixed 0 ...   # fixed QPSK reference on the same channel trajectory
  lean_adapt.py --policy pred_olla --calibration lean_calibration_flat.json ...
  lean_adapt.py --policy ts --calibration lean_calibration_flat.json --seed 1 ...

Policies (docs/innovation/a_link_adaptation_design.md):
  threshold  original EVM/PER rule with dwell (default, unchanged)
  pred_olla  EVM -> model SNR, Holt prediction with downside margin, OLLA offset learned
             from 16QAM payload CRC, expected-goodput comparison with hysteresis
  ts         contextual Thompson sampling over {QPSK, 16QAM} in 2 dB SNR bins
  joint      (NC build) per-group metrics -> joint (modulation, masked groups) choice with
             A's OLLA offset and no prediction (docs/innovation/joint_adaptation_design.md 7.1)
  joint2     (NC build) joint + impairment gate, conservative masked estimate, slow unmask,
             failure lockout and zero-delivery escalation (stage-2 board findings, BRINGUP-026)

NC options (image VERSION >= 0x20261025, RX backoff >= 16, checked before any burst):
  --mask M              fixed TX group mask (11 bits, <= 3 groups) for every window
  --nc-metrics          read the per-carrier metric banks after each window (implied by joint)
  --allow-fft-saturation  record FFT saturation increments instead of aborting (tone tests)
  --sense               (joint2) listen before transmitting: one RX capture with TX idle, FFT,
                        narrowband lines >= --sense-db above the median floor -> initial mask
  --tone-on W --tone-off W --tone-scale S  switch the TX2 DDS tone (frequency set beforehand)
                        to scale S before window W_on and to 0 before window W_off (between bursts)
Without these options the behaviour is that of the stage-0 version (the config line also lists
the new arguments with their defaults; window records are unchanged).
"""
import argparse
import hashlib
import json
import math
import os
import random
import sys
import time

from lean_ctl import Core, measurement, start_burst, wait_done, phy_read, phy_write, tx_data_select
import lean_nc

FS = 122.88e6


def payload_symbols(length, mode):
    """V0.1 payload symbol count for 88 data carriers (docs/interfaces/ofdm_interface_v0_1.md)."""
    return max(1, math.ceil(8 * (length + 4) / (88 * (4 if mode else 2))))


def window_time_estimate(frames, length, mode, overhead_s=2.5e-3):
    """Structural window time: training+header+payload symbols plus a fixed overhead (estimate)."""
    return frames * (4 + payload_symbols(length, mode)) * 160 / FS + overhead_s


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
    """Mode-specific EVM(%) -> model SNR(dB) map and pessimistic-monotone PER(SNR) table."""

    def __init__(self, path):
        raw = open(path, 'rb').read()
        self.path, self.sha256 = os.path.abspath(path), hashlib.sha256(raw).hexdigest()
        cal = json.loads(raw.decode('utf-8'))
        self.evm_to_snr, self.per = {}, {}
        for mode, key in ((0, 'QPSK'), (1, '16QAM')):
            c = cal[key]
            snr, per = c['snr_db'], c['per_monotone']
            if len(snr) != len(per) or len(snr) < 2 or len(c['evm_pct']) != len(c['evm_map_snr_db']):
                raise ValueError('calibration table lengths differ: ' + key)
            if any(b <= a for a, b in zip(snr, snr[1:])):
                raise ValueError('calibration SNR axis not increasing: ' + key)
            if any(b > a for a, b in zip(per, per[1:])) or not all(0 <= p <= 1 for p in per):
                raise ValueError('calibration PER not monotone in [0, 1]: ' + key)
            pairs = sorted(zip(c['evm_pct'], c['evm_map_snr_db']))
            self.evm_to_snr[mode] = ([p[0] for p in pairs], [p[1] for p in pairs])
            self.per[mode] = (snr, per)

    def snr(self, mode, evm_pct):
        xs, ys = self.evm_to_snr[mode]
        return _interp(evm_pct, xs, ys)

    def per_at(self, mode, snr_db):
        xs, ys = self.per[mode]
        return min(1.0, max(0.0, _interp(snr_db, xs, ys)))


def _payload_fail(result):
    """Header loss is MCS-independent (header/training are QPSK); only payload failures count."""
    return result.get('crc_fail', 0) + result.get('truncated', 0)


class PredOllaPolicy:
    """Primary policy of design A §2.2 (reference build/innovation_a/policies.py:PredOlla)."""

    def __init__(self, cal, frames, length, alpha=.5, beta=.3, phi=.5, k=1.0, hyst=.05, target=.1,
                 step_down=.25, delta_min=-6.0, delta_max=3.0, relax=.97):
        if not (0 < alpha <= 1 and 0 <= beta <= 1 and 0 <= phi <= 1 and k >= 0 and 0 <= hyst < 1
                and 0 < target < 1 and step_down >= 0 and delta_min <= 0 <= delta_max and 0 < relax <= 1):
            raise ValueError('invalid pred_olla parameters')
        self.cal, self.length = cal, length
        self.alpha, self.beta, self.phi, self.k, self.hyst = alpha, beta, phi, k, hyst
        self.step_down, self.step_up = step_down, step_down * target / (1 - target)
        self.dmin, self.dmax, self.relax = delta_min, delta_max, relax
        self.t = {m: window_time_estimate(frames, length, m) for m in (0, 1)}
        self.level = self.trend = None
        self.var, self.delta, self.mcs = 1.0, 0.0, 0
        self.s_obs = self.s_hat = None
        self.thr = {}

    def update(self, r):
        used = r['mcs']
        self.t[used] = .8 * self.t[used] + .2 * r['elapsed_s']
        before = self.mcs
        if r['ok'] == 0 or r['evm'] is None:
            if used == 1:
                self.delta = max(self.dmin, self.delta - self.step_down * _payload_fail(r))
            self.level = self.trend = self.s_obs = self.s_hat = None
            self.var, self.mcs, self.thr = 1.0, 0, {}
            return self.mcs, 'link_lost' if before else ''
        g = self.s_obs = self.cal.snr(used, r['evm'])
        if self.level is None:
            self.level, self.trend = g, 0.0
        else:
            pred = self.level + self.phi * self.trend
            err = g - pred
            self.var = .8 * self.var + .2 * (err * err if err < 0 else 0.0)
            new = self.alpha * g + (1 - self.alpha) * pred
            self.trend = self.beta * (new - self.level) + (1 - self.beta) * self.phi * self.trend
            self.level = new
        if used == 1:
            self.delta += self.step_up * r['ok'] - self.step_down * _payload_fail(r)
            self.delta = min(self.dmax, max(self.dmin, self.delta))
        else:
            self.delta *= self.relax
        s = self.s_hat = self.level + self.phi * self.trend - self.k * math.sqrt(self.var) + self.delta
        self.thr = {m: (1 - self.cal.per_at(m, s)) * 8 * self.length / self.t[m] for m in (0, 1)}
        if self.mcs == 0 and self.thr[1] > (1 + self.hyst) * self.thr[0]:
            self.mcs = 1
        elif self.mcs == 1 and self.thr[1] < (1 - self.hyst) * self.thr[0]:
            self.mcs = 0
        return self.mcs, ('up' if self.mcs > before else 'down' if self.mcs < before else '')

    def state(self):
        rd = lambda x: None if x is None else round(x, 4)
        return dict(s_obs_db=rd(self.s_obs), s_hat_db=rd(self.s_hat), level_db=rd(self.level),
                    trend_db=rd(self.trend), var_db2=rd(self.var), delta_db=rd(self.delta),
                    t_qpsk_s=rd(self.t[0]), t_16qam_s=rd(self.t[1]),
                    thr_qpsk_mbps=rd(self.thr[0] / 1e6) if self.thr else None,
                    thr_16qam_mbps=rd(self.thr[1] / 1e6) if self.thr else None)


class ContextTSPolicy:
    """Comparison policy of design A §2.3: contextual Thompson sampling with a model prior."""

    def __init__(self, cal, frames, length, seed, bin_db=2.0, prior_strength=8):
        if bin_db <= 0 or prior_strength < 0:
            raise ValueError('invalid ts parameters')
        self.cal, self.length, self.bin_db, self.n0 = cal, length, bin_db, prior_strength
        self.rng = random.Random(seed)
        self.t = {m: window_time_estimate(frames, length, m) for m in (0, 1)}
        self.ab, self.ctx, self.mcs, self.samples = {}, -1, 0, {}

    def _prior(self, ctx, mode):
        if self.n0 <= 0 or ctx < 0:
            return (1.0, 1.0)
        p = self.cal.per_at(mode, (ctx + .5) * self.bin_db)
        return (1.0 + self.n0 * (1 - p), 1.0 + self.n0 * p)

    def update(self, r):
        used, before = r['mcs'], self.mcs
        self.t[used] = .8 * self.t[used] + .2 * r['elapsed_s']
        a, b = self.ab.get((self.ctx, used), self._prior(self.ctx, used))
        self.ab[(self.ctx, used)] = (a + r['ok'], b + r['sent'] - r['ok'])
        if r['ok'] == 0 or r['evm'] is None:
            self.ctx, self.mcs, self.samples = -1, 0, {}
            return self.mcs, 'link_lost' if before else ''
        self.ctx = int(self.cal.snr(used, r['evm']) // self.bin_db)
        self.samples = {m: self.rng.betavariate(*self.ab.get((self.ctx, m), self._prior(self.ctx, m)))
                        for m in (0, 1)}
        score = {m: self.samples[m] * 8 * self.length / self.t[m] for m in (0, 1)}
        self.mcs = 1 if score[1] > score[0] else 0
        return self.mcs, ('up' if self.mcs > before else 'down' if self.mcs < before else '')

    def state(self):
        return dict(ctx=self.ctx, a_b_qpsk=self.ab.get((self.ctx, 0), self._prior(self.ctx, 0)),
                    a_b_16qam=self.ab.get((self.ctx, 1), self._prior(self.ctx, 1)),
                    sample_qpsk=self.samples.get(0), sample_16qam=self.samples.get(1))


def last_frame_info(before, after, first, frames):
    """Decode the last-frame registers 0x0D4/0x0D8/0x0FC and say whether they belong to this window."""
    mask = 0xFFFFFFFF
    fresh = ((after['rx_frames'] - before['rx_frames']) & mask) > 0 and \
        ((after['last_id'] - first) & mask) < frames
    length, mode, reason = after['last_len'], after['last_mcs'], after['last_reason']
    carriers = (8 * length + 32) // (4 if mode else 2)
    evm = None
    if reason in (0, 2) and carriers:
        evm = 100 * math.sqrt(after['last_evm'] / (4096 * carriers))
    return dict(fresh=fresh, len=length, mcs=mode, reason=reason,
                unusable_mod256=after['last_info'] >> 24, evm_frame_pct=evm)


class Policy:
    """Burst-level feedback: dwell gates upgrades; faults bypass dwell."""
    def __init__(self, evm_up=6.0, evm_down=8.0, per_down=.05, up_windows=5, dwell=10):
        if not (0 < evm_up < evm_down and 0 <= per_down <= 1 and up_windows > 0 and dwell > 0):
            raise ValueError('invalid adaptive thresholds or dwell')
        self.evm_up, self.evm_down, self.per_down = evm_up, evm_down, per_down
        self.up_windows, self.dwell = up_windows, dwell
        self.mcs, self.good_run, self.since_switch = 0, 0, 0

    def update(self, result):
        self.since_switch += 1
        evm, per = result['evm'], result['per']
        reason = ''
        if result['ok'] == 0 or evm is None:
            self.good_run = 0
            if self.mcs:
                self.mcs, self.since_switch, reason = 0, 0, 'link_lost'
        elif self.mcs == 0:
            self.good_run = self.good_run + 1 if evm < self.evm_up and per == 0 else 0
            if self.good_run >= self.up_windows and self.since_switch >= self.dwell:
                self.mcs, self.since_switch, self.good_run, reason = 1, 0, 0, 'up'
        elif evm > self.evm_down or per > self.per_down:
            self.mcs, self.since_switch, self.good_run, reason = 0, 0, 0, 'down'
        return self.mcs, reason


def window(core, mcs, frames, length, first, allow_fft_saturation=False):
    before = core.snapshot()
    t0 = time.monotonic()
    start_burst(core, frames, length, mcs, first)
    st = wait_done(core)
    time.sleep(0.002)
    after = core.snapshot()
    dt = time.monotonic() - t0
    if after['tx_issued'] != frames or after['tx_queued'] != frames:
        raise RuntimeError('TX issued/queued counts do not match requested frames')
    for name in ('ring_overruns', 'candidate_drops', 'dropped_symbols', 'fft_saturations'):
        if (after[name] - before[name]) & 0xFFFFFFFF:
            if name == 'fft_saturations' and allow_fft_saturation:
                continue
            raise RuntimeError('invalid measurement window: ' + name)
    r = measurement(before, after, frames, length, dt)
    if allow_fft_saturation:
        r['fft_saturations_delta'] = (after['fft_saturations'] - before['fft_saturations']) & 0xFFFFFFFF
    r.update(mcs=mcs, first=first, length=length, status=hex(st),
             before=before, after=after, rx_settle_s=.002)
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--windows", type=int, default=300)
    ap.add_argument("--frames", type=int, default=16)
    ap.add_argument("--len", type=int, default=1024)
    ap.add_argument("--fixed", type=int, choices=(0, 1), default=None, help="fixed MCS reference run")
    ap.add_argument("--evm-up", type=float, default=6.0, help="16QAM allowed when EVM below this (percent)")
    ap.add_argument("--evm-down", type=float, default=8.0, help="back to QPSK when EVM above this (percent)")
    ap.add_argument("--per-down", type=float, default=0.05)
    ap.add_argument("--up-windows", type=int, default=5)
    ap.add_argument("--dwell", type=int, default=10, help="minimum windows between switches")
    ap.add_argument("--log", default="adapt.jsonl")
    ap.add_argument('--attenuation', type=float, nargs='+', help='repeatable TX attenuation trajectory (cycled); same values for all three modes')
    ap.add_argument('--hold-windows', type=int, default=10, help='windows per attenuation step, identical for all modes')
    ap.add_argument('--policy', choices=('threshold', 'pred_olla', 'ts', 'joint', 'joint2'), default='threshold')
    ap.add_argument('--calibration', help='EVM/PER calibration JSON (required for pred_olla and ts)')
    ap.add_argument('--pred-alpha', type=float, default=.5)
    ap.add_argument('--pred-beta', type=float, default=.3)
    ap.add_argument('--pred-phi', type=float, default=.5)
    ap.add_argument('--pred-k', type=float, default=1.0)
    ap.add_argument('--hyst', type=float, default=.05)
    ap.add_argument('--olla-target', type=float, default=.1)
    ap.add_argument('--olla-step-down', type=float, default=.25)
    ap.add_argument('--olla-min', type=float, default=-6.0)
    ap.add_argument('--olla-max', type=float, default=3.0)
    ap.add_argument('--olla-relax', type=float, default=.97)
    ap.add_argument('--ts-prior', type=float, default=8)
    ap.add_argument('--ts-bin', type=float, default=2.0)
    ap.add_argument('--seed', type=int, help='random seed for ts (required for ts, logged)')
    ap.add_argument('--mask', type=lambda x: int(x, 0), help='fixed TX group mask (NC build)')
    ap.add_argument('--nc-metrics', action='store_true', help='read per-group metrics each window (NC build)')
    ap.add_argument('--gate-db', type=float, default=4.0, help='joint2: mask only groups this far below the median')
    ap.add_argument('--unmask-windows', type=int, default=3)
    ap.add_argument('--unmask-gain', type=float, default=.01)
    ap.add_argument('--lock-windows', type=int, default=8)
    ap.add_argument('--sense', action='store_true', help='joint2: pre-transmission spectrum sensing')
    ap.add_argument('--sense-db', type=float, default=20.0)
    ap.add_argument('--tone-on', type=int, help='window index before which the TX2 tone is switched on')
    ap.add_argument('--tone-off', type=int, help='window index before which the TX2 tone is switched off')
    ap.add_argument('--tone-scale', type=float, help='TX2 DDS scale while the tone is on (<= 0.5)')
    ap.add_argument('--allow-fft-saturation', action='store_true',
                    help='record FFT saturation increments instead of aborting (tone experiments)')
    a = ap.parse_args()
    if not (a.windows > 0 and a.hold_windows > 0 and 1 <= a.frames <= 32 and 0 <= a.len <= 4096):
        ap.error('invalid windows, frames or length')
    if a.attenuation and any(not 0 <= x <= 41.95 for x in a.attenuation):
        ap.error('attenuation must be 0..41.95 dB')
    if a.policy in JOINT_POLICIES and a.fixed is not None:
        ap.error('--fixed conflicts with --policy joint (joint chooses the modulation)')
    if a.sense and a.policy != 'joint2':
        ap.error('--sense needs --policy joint2')
    tone = (a.tone_on, a.tone_off, a.tone_scale)
    if any(x is not None for x in tone):
        if any(x is None for x in tone):
            ap.error('--tone-on, --tone-off and --tone-scale go together')
        if not (0 <= a.tone_on < a.tone_off <= a.windows and 0 < a.tone_scale <= 0.5):
            ap.error('need 0 <= tone-on < tone-off <= windows and 0 < tone-scale <= 0.5')
    if a.mask is not None:
        if a.policy in JOINT_POLICIES:
            ap.error('--mask is a fixed-mask run; joint chooses the mask itself')
        try:
            lean_nc.check_mask(a.mask)
        except ValueError as exc:
            ap.error(str(exc))
        modes = (a.fixed,) if a.fixed is not None else (0, 1)
        if any(a.len > lean_nc.l_max(a.mask, m) for m in modes):
            ap.error('--len exceeds L_max of mask 0x%03x' % a.mask)
    try:
        policy = make_policy(a)
    except (ValueError, OSError, KeyError) as exc:
        ap.error(str(exc))
    # Exclusive create prevents a repeated command from destroying old evidence.
    log = open(a.log, 'x')
    try:
        run(a, policy, log)
    except BaseException:
        # A failed close must not replace the primary error from run().
        try:
            log.close()
        except Exception as exc:
            print('log close failed after run error: %r' % (exc,), file=sys.stderr)
        raise
    log.close()


def make_policy(a):
    """Build the selected policy; raises ValueError before any register access."""
    if a.policy == 'threshold':
        return Policy(a.evm_up, a.evm_down, a.per_down, a.up_windows, a.dwell)
    if not a.calibration:
        raise ValueError('--calibration is required for policy ' + a.policy)
    cal = Calibration(a.calibration)
    if a.policy == 'joint':
        return lean_nc.JointOllaPolicy(cal, a.frames, a.len, a.olla_target, a.olla_step_down,
                                       a.olla_min, a.olla_max, a.hyst)
    if a.policy == 'joint2':
        return lean_nc.JointOllaPolicyV2(cal, a.frames, a.len, a.olla_target, a.olla_step_down,
                                         a.olla_min, a.olla_max, a.hyst, a.gate_db, a.unmask_windows,
                                         a.unmask_gain, a.lock_windows)
    if a.policy == 'pred_olla':
        return PredOllaPolicy(cal, a.frames, a.len, a.pred_alpha, a.pred_beta, a.pred_phi, a.pred_k,
                              a.hyst, a.olla_target, a.olla_step_down, a.olla_min, a.olla_max, a.olla_relax)
    if a.seed is None:
        raise ValueError('--seed is required for policy ts')
    return ContextTSPolicy(cal, a.frames, a.len, a.seed, a.ts_bin, a.ts_prior)


def policy_config(a, policy):
    # Callers that build their own argument namespace (tests, lean_stability) predate --policy.
    cfg = dict(policy=getattr(a, 'policy', 'threshold'))
    cal = getattr(policy, 'cal', None)
    if cal is not None:
        cfg.update(calibration_path=cal.path, calibration_sha256=cal.sha256)
    try:
        cfg['script_sha256'] = hashlib.sha256(open(__file__, 'rb').read()).hexdigest()
    except OSError:
        cfg['script_sha256'] = None
    return cfg


JOINT_POLICIES = ('joint', 'joint2')


def nc_active(a):
    return (getattr(a, 'policy', 'threshold') in JOINT_POLICIES or getattr(a, 'mask', None) is not None
            or getattr(a, 'nc_metrics', False))


def tx_dev_dir(name='axi-adrv9009-tx-hpc'):
    base = '/sys/bus/iio/devices'
    for d in sorted(os.listdir(base)):
        try:
            if open(os.path.join(base, d, 'name')).read().strip() == name:
                return os.path.join(base, d)
        except OSError:
            pass
    raise RuntimeError(name + ' not found')


SENSE_SAMPLES, SENSE_NFFT = 65536, 4096


def analyse_spectrum(raw, threshold_db=20.0, nfft=SENSE_NFFT, fs=lean_nc.FS, band_hz=47e6, dc_hz=0.5e6):
    """Narrowband lines in an interleaved int16 I/Q capture: averaged Hann FFT, median floor,
    local maxima >= threshold_db above it inside the occupied band, DC excluded; lines within one
    subcarrier of a stronger one (window side lobes) are merged.  [(freq_hz, level_db)], strongest first."""
    import numpy as np
    d = np.frombuffer(raw, dtype='<i2').astype(float)
    x = d[0::2] + 1j * d[1::2]
    m = len(x) // nfft
    if m == 0:
        raise RuntimeError('sense capture too short: %d samples' % len(x))
    w = np.hanning(nfft)
    p = (np.abs(np.fft.fft(x[:m * nfft].reshape(m, nfft) * w, axis=1)) ** 2).mean(axis=0)
    f = np.fft.fftfreq(nfft, 1 / fs)
    floor = float(np.median(p))
    if floor <= 0:
        raise RuntimeError('sense capture has no noise floor')
    lvl = 10 * np.log10(np.maximum(p, 1e-300) / floor)
    local_max = np.max(np.stack([np.roll(p, j) for j in range(-3, 4)]), axis=0)   # circular +-3 bins
    hit = (np.abs(f) > dc_hz) & (np.abs(f) < band_hz) & (lvl >= threshold_db) & (p >= local_max)
    lines = [(float(f[k]), float(lvl[k])) for k in np.nonzero(hit)[0]]
    merged = []
    for fk, lvl in sorted(lines, key=lambda t: -t[1]):
        if all(abs(fk - g) > fs / 128 for g, _ in merged):
            merged.append((fk, lvl))
    return merged


def sense_spectrum(threshold_db=20.0):
    """One RX capture (TX idle) through the IIO DMA path; returns (lines, seconds)."""
    import subprocess
    t0 = time.monotonic()
    raw = subprocess.run(['iio_readdev', '-u', 'local:', '-b', str(SENSE_SAMPLES), '-s', str(SENSE_SAMPLES),
                          'axi-adrv9009-rx-hpc', 'voltage0_i', 'voltage0_q'], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, check=True, timeout=10).stdout
    lines = analyse_spectrum(raw, threshold_db)
    return lines, time.monotonic() - t0


def set_tx2_tone(scale):
    """TX2 DDS tone scale (frequency/phase configured beforehand); DDS attribute writes may
    reselect sources, so the data select follows (TX1 OFDM core, TX2 DDS)."""
    d = tx_dev_dir()
    for attr in ('out_altvoltage4_TX2_I_F1_scale', 'out_altvoltage6_TX2_Q_F1_scale'):
        with open(os.path.join(d, attr), 'w') as f:
            f.write('%g' % scale)
    return tx_data_select(2, 0)


def nc_preflight(core):
    """NC image and RX backoff >= 16 (stage-1 report section 4) before any burst."""
    regs = lean_nc.NcRegs(core)
    if not regs.is_nc():
        raise RuntimeError('NC options need image VERSION >= 0x%08x, found 0x%08x'
                           % (lean_nc.NC_VERSION, core.rd(0x004)))
    backoff = (core.rd(0x030) >> 20) & 0x3F
    if backoff < 16:
        raise RuntimeError('NC frames need RX backoff >= 16, found %d' % backoff)
    return regs


def run(a, policy, log):
    core = Core()
    mcs = 0 if a.fixed is None else a.fixed
    nc = nc_active(a)
    regs = nc_preflight(core) if nc else None
    tx_mask = getattr(a, 'mask', None) or 0
    joint = getattr(a, 'policy', 'threshold') in JOINT_POLICIES
    tone_on, tone_off = getattr(a, 'tone_on', None), getattr(a, 'tone_off', None)
    tone_scale, tone_now, tone_touched = getattr(a, 'tone_scale', None), 0.0, False
    allow_sat = getattr(a, 'allow_fft_saturation', False)
    failed = False
    first, delivered, sent = 1, 0, 0
    window_seconds, ok_total, errors, compared = 0.0, 0, 0, 0
    switches, windows_16qam = 0, 0
    previous_att = None
    original_att = phy_read('out_voltage0_hardwaregain') if a.attenuation else None
    t0 = time.monotonic()
    cfg = dict(type='config', args=vars(a), **policy_config(a, policy),
               ctrl=core.rd(0x008), tx_gain=core.rd(0x038), rx_gain=core.rd(0x024))
    if nc:
        cfg.update(version=hex(core.rd(0x004)), rx_detect_cfg=hex(core.rd(0x030)),
                   nc_hdr_thr=core.rd(0x050), lean_nc_sha256=hashlib.sha256(
                       open(lean_nc.__file__, 'rb').read()).hexdigest())
    log.write(json.dumps(cfg) + '\n')
    log.flush()
    import_s = None
    if getattr(a, 'sense', False):
        # numpy is loaded once per process (~0.6 s on the board); reported apart from the sensing time.
        t_imp = time.monotonic()
        import numpy  # noqa: F401
        import_s = time.monotonic() - t_imp
    try:
        if getattr(a, 'sense', False):
            # Before the first burst (TX idle): lines -> initial mask; the sensing time is outside the windows.
            lines, seconds = sense_spectrum(a.sense_db)
            groups = lean_nc.groups_for_tones(lines)
            tx_mask = policy.seed(groups)
            mcs = 0
            log.write(json.dumps(dict(type='sense', lines=[(round(f), round(l, 1)) for f, l in lines[:8]],
                                      groups=groups, mask=tx_mask, seconds=round(seconds, 4),
                                      numpy_import_s=round(import_s, 4),
                                      threshold_db=a.sense_db)) + '\n')
            log.flush()
        for w in range(a.windows):
            att = a.attenuation[(w // a.hold_windows) % len(a.attenuation)] if a.attenuation else None
            changed = att is not None and att != previous_att
            if changed:
                phy_write('out_voltage0_hardwaregain', '%.2f' % -att)
                time.sleep(.02)
                if abs(float(phy_read('out_voltage0_hardwaregain').split()[0]) + att) > .06:
                    raise RuntimeError('attenuation readback mismatch')
                previous_att = att
            if tone_on is not None and w in (tone_on, tone_off):
                tone_now = tone_scale if w == tone_on else 0.0
                tone_touched = True
                set_tx2_tone(tone_now)
            if nc:
                regs.set_tx_mask(tx_mask)
                regs.rx_cfg(blind=True, metric=True)
                regs.clear_metrics()
            r = window(core, mcs, a.frames, a.len, first, allow_sat) if allow_sat else \
                window(core, mcs, a.frames, a.len, first)
            if nc:
                raw = regs.frozen_metrics()
                m_g, e_g = lean_nc.group_metrics(raw, tx_mask)    # as the policy sees them
                r['nc'] = dict(mask=tx_mask, m_g=[None if m is None else (m if m != math.inf else 'inf')
                                                  for m in m_g],
                               e_g=e_g, syms_hdr=raw['syms_hdr'], syms_pay=raw['syms_pay'],
                               last_mask=raw['last_mask'], rx_last=hex(raw['rx_last']),
                               rx_cnt=hex(raw['rx_cnt']), tx_status=hex(raw['tx_status']))
            if 'before' in r and 'after' in r:          # window() always records both snapshots
                r['last_frame'] = last_frame_info(r['before'], r['after'], first, a.frames)
            r['payload_fail'] = _payload_fail(r)
            first = (first + a.frames) & 0xFFFFFFFF
            windows_16qam += r['mcs']
            reason = ""
            if joint:
                before = (mcs, tx_mask)
                mcs, tx_mask, reason = policy.update(r, raw, tx_mask)
                switches += (mcs, tx_mask) != before
                r['policy_state'] = policy.state()
            elif a.fixed is None:
                mcs, reason = policy.update(r)
                switches += bool(reason)
                if hasattr(policy, 'state'):
                    r['policy_state'] = policy.state()
            delivered += r['ok'] * a.len * 8
            sent += a.frames
            ok_total += r['ok']
            errors += r['bit_errors']
            compared += r['compared_bits']
            window_seconds += r['elapsed_s']
            r.update(type='window', window=w, attenuation_db=att, attenuation_changed=changed,
                     t=round(time.time(), 3), next_mcs=mcs, switch=reason)
            if tone_on is not None:
                r['tone_scale'] = tone_now
            if nc:
                r['next_mask'] = tx_mask
            log.write(json.dumps(r) + "\n")
            log.flush()
            if reason or w % 20 == 0:
                print(json.dumps(r), flush=True)
        elapsed = time.monotonic() - t0
        log.write(json.dumps(dict(type='summary', completed=True, sent=sent,
                                 delivered_bits=delivered, elapsed_s=elapsed,
                                 ok=ok_total, per=1 - ok_total / sent,
                                 bit_errors=errors, compared_bits=compared,
                                 ber=errors / compared if compared else None,
                                 window_elapsed_s=window_seconds,
                                 window_goodput_mbps=delivered / window_seconds / 1e6,
                                 goodput_mbps=delivered / elapsed / 1e6,
                                 switches=switches, windows_16qam=windows_16qam)) + '\n')
    except BaseException as exc:
        failed = True
        # Diagnostics and logging are best-effort: the primary exception always propagates.
        record = dict(type='failure', error=repr(exc), first=first)
        try:
            record.update(status=hex(core.rd(0x044)), snapshot=core.snapshot())
        except Exception as diag:
            record['diagnostic_error'] = repr(diag)
        try:
            log.write(json.dumps(record) + '\n')
            log.flush()
        except Exception:
            pass
        raise
    finally:
        # Each cleanup step is attempted on its own; a cleanup error never hides the
        # original failure, and is raised only when the run itself succeeded.
        cleanup_errors = []
        if original_att is not None:
            try:
                phy_write('out_voltage0_hardwaregain', original_att.split()[0])
            except Exception as exc:
                cleanup_errors.append(('restore_attenuation', repr(exc)))
        if tone_touched:
            try:
                set_tx2_tone(0.0)
            except Exception as exc:
                cleanup_errors.append(('tone_off', repr(exc)))
        if regs is not None:
            try:
                # Later runs without NC options never write 0x048: do not leave a mask behind.
                regs.set_tx_mask(0)
            except Exception as exc:
                cleanup_errors.append(('clear_tx_mask', repr(exc)))
        if cleanup_errors:
            try:
                log.write(json.dumps(dict(type='cleanup_failure', errors=cleanup_errors)) + '\n')
                log.flush()
            except Exception as exc:
                cleanup_errors.append(('log_cleanup_failure', repr(exc)))
            if not failed:
                raise RuntimeError('cleanup failed: %r' % cleanup_errors)


if __name__ == "__main__":
    main()
