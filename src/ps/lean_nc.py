#!/usr/bin/env python3
"""Board-side support for group masking (NC build, VERSION 0x20261025 and later).

Registers (docs/innovation/b_subcarrier_mask_design.md section 4, rtl/ofdm_nc/lean):
  0x048 NC_TX_CFG [10:0] TX group mask, latched at TX_GO
  0x04C NC_RX_CFG [24] blind candidate, [25] metric enable, [26] metric freeze
  0x050 NC_HDR_THR, 0x054 NC_METRIC_CTRL ([0] clear, [8] busy, [9] read timeout), 0x058/0x05C symbols
  0x060 NC_RX_LAST, 0x064 NC_RX_CNT, 0x068 NC_TX_STATUS, 0x06C NC_LAST_MASK
  0x200/0x400/0x600 + 4d: header / payload error sums and erased instances, d = 0..87
The joint (modulation, mask) decision ports build/innovation_joint/joint_policy.py
(reviewed host reference) and adds the OLLA offset of design A without the
prediction term (joint design section 7.1).  Python 3.9, no board access on import.
"""
import math

NC_VERSION = 0x20261025
GROUPS, PER_GROUP, DATA_CARRIERS, MAX_MASKED = 11, 8, 88, 3
UNIT = 65536                         # metric units per unit constellation energy
SATURATED = 0xFFFFFFFF
FS = 122.88e6
BITS = {0: 2, 1: 4}
CAL_LEN = 4096
DESTROYED_DB = -100.0
ERASE_LIMIT = 0.01
MODEL_OFFSET_DB = 0.9
PILOTS = (-43, -31, -19, -7, 7, 19, 31, 43)
# Data carriers in signed-frequency order (-48..-1, 1..48 without pilots); group = index // 8.
DATA_SIGNED = [k for k in list(range(-48, 0)) + list(range(1, 49)) if k not in PILOTS]


def check_mask(mask):
    if not isinstance(mask, int) or not 0 <= mask < (1 << GROUPS) or bin(mask).count('1') > MAX_MASKED:
        raise ValueError('mask must be an 11-bit integer with at most 3 groups set')
    return mask


def l_max(mask, mode):
    groups = GROUPS - bin(check_mask(mask)).count('1')
    return min(4096, 187 * groups * BITS[mode] - 4)


class NcRegs:
    """Thin register helper over lean_ctl.Core (or any object with rd/wr)."""

    def __init__(self, core):
        self.core = core

    def is_nc(self):
        return self.core.rd(0x004) >= NC_VERSION

    def set_tx_mask(self, mask):
        self.core.wr(0x048, check_mask(mask))

    def rx_cfg(self, blind=True, metric=False, freeze=False):
        self.core.wr(0x04C, (int(blind) << 24) | (int(metric) << 25) | (int(freeze) << 26))

    def clear_metrics(self, polls=1000):
        # bit 0 clears the banks, bit 9 clears the sticky read-timeout flag
        self.core.wr(0x054, 0x201)
        for _ in range(polls):
            if not self.core.rd(0x054) & 0x100:
                return
        raise RuntimeError('metric clear did not finish')

    def read_metrics(self):
        """Raw banks and counters; the caller freezes accumulation around the read."""
        rd = self.core.rd
        raw = dict(hdr=[rd(0x200 + 4 * d) for d in range(DATA_CARRIERS)],
                    pay=[rd(0x400 + 4 * d) for d in range(DATA_CARRIERS)],
                    erase=[rd(0x600 + 4 * d) & 0xFFFF for d in range(DATA_CARRIERS)],
                    syms_hdr=rd(0x058), syms_pay=rd(0x05C),
                    rx_last=rd(0x060), rx_cnt=rd(0x064), tx_status=rd(0x068), last_mask=rd(0x06C))
        if rd(0x054) & 0x200:
            # A window read timed out and returned 0: these banks are not trustworthy.
            raise RuntimeError('metric read timed out (NC_METRIC_CTRL bit 9)')
        return raw

    def frozen_metrics(self, blind=True):
        self.rx_cfg(blind=blind, metric=True, freeze=True)
        try:
            raw = self.read_metrics()
        except BaseException:
            # Keep the read error.  A failed unfreeze leaves the banks frozen until the next NC run
            # reaches its window preparation and successfully writes rx_cfg(freeze=False).
            try:
                self.rx_cfg(blind=blind, metric=True, freeze=False)
            except Exception:
                pass
            raise
        self.rx_cfg(blind=blind, metric=True, freeze=False)
        return raw


def group_metrics(raw, masked=0):
    """Per-group mean normalised payload error M_g (EVM^2; masked groups: (I+N)/S) and
    erasure rate E_g (B design 1.3).  When no payload symbol was measured (headers lost),
    unmasked groups fall back to the header copies (QPSK reference) and masked groups,
    whose header carriers are zero, are unknown.  None = not measured, inf = saturated."""
    sp, sh, st = raw['syms_pay'], raw['syms_hdr'], raw['syms_hdr'] + raw['syms_pay']
    bank, syms = ('pay', sp) if sp else ('hdr', sh)
    m_g, e_g = [], []
    for g in range(GROUPS):
        ds = range(PER_GROUP * g, PER_GROUP * (g + 1))
        if syms == 0 or (bank == 'hdr' and masked >> g & 1):
            m_g.append(None)
        elif any(raw[bank][d] == SATURATED for d in ds):
            m_g.append(math.inf)
        else:
            m_g.append(sum(raw[bank][d] for d in ds) / (PER_GROUP * UNIT * syms))
        e_g.append(None if st == 0 else sum(raw['erase'][d] for d in ds) / (PER_GROUP * st))
    return m_g, e_g


# ------------------------------------------------------------------ joint decision (port)
def payload_symbols(length, mode, n_active):
    return max(1, math.ceil(8 * (length + 4) / (n_active * BITS[mode])))


def airtime_s(length, mode, n_active, frames):
    return frames * (4 + payload_symbols(length, mode, n_active)) * 160 / FS


def group_snr_from_metrics(cal, measured_mode, m_g, erase_g, masked, offset_db=0.0):
    out = []
    for g, (m, e) in enumerate(zip(m_g, erase_g)):
        if (e is not None and e > ERASE_LIMIT) or m == math.inf:
            out.append(DESTROYED_DB)
        elif m is None:
            out.append(None)
        elif m <= 0:
            out.append(cal.per[measured_mode][0][-1] + offset_db)
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
    known = sorted((s, g) for g, s in enumerate(snrs) if s is not None)
    return [frozenset(g for _, g in known[:k]) for k in range(MAX_MASKED + 1)]


def mask_bitmap(mask):
    return sum(1 << g for g in mask)


def groups_for_tones(tones, span=1.5, limit=MAX_MASKED):
    """Pre-transmission sensing -> initial mask: groups with a data carrier within `span`
    subcarriers of a detected line, strongest line first, at most `limit` groups.
    tones: [(frequency_hz, level_db_above_floor)] in the RX baseband (subcarrier k at k*FS/128)."""
    out = []
    for f, _ in sorted(tones, key=lambda t: -t[1]):
        k = f / (FS / 128)
        for d, c in enumerate(DATA_SIGNED):
            g = d // PER_GROUP
            if abs(c - k) <= span and g not in out:
                if len(out) >= limit:
                    return out
                out.append(g)
    return out


class JointPolicy:
    """Same decision rule as the host reference (hysteresis 5% for a modulation change,
    1% for a mask-only change; outage -> QPSK, mask kept)."""

    def __init__(self, cal, length=4096, frames=16, t_fixed_s=2.5e-3, hyst=0.05, hyst_mask=0.01):
        self.cal, self.length, self.frames = cal, length, frames
        self.t_fixed_s, self.hyst, self.hyst_mask = t_fixed_s, hyst, hyst_mask
        self.mode, self.mask = 0, frozenset()

    def score(self, snrs, mode, mask):
        return goodput(self.cal, mode, snrs, mask, self.length, self.frames, self.t_fixed_s)

    def legal(self, mode, mask):
        return self.length <= l_max(mask_bitmap(mask), mode)

    def decide(self, frames_ok, snrs):
        # Only a missing metric is an outage; frames_ok == 0 with a valid metric (a tone that
        # breaks every payload CRC) must still be able to mask.  Every return path yields a
        # (mode, mask) whose L_max carries the frame length.
        if all(s is None for s in snrs):
            self.mode = 0
            if not self.legal(0, self.mask):
                self.mask = frozenset()
            return self.mode, self.mask, 'link_lost'
        # Only (mode, mask) pairs that carry the frame length: others make the framer fault.
        best = max(((self.score(snrs, m, msk), m, msk) for m in (0, 1) for msk in candidates(snrs)
                    if self.legal(m, msk)),
                   key=lambda x: (x[0], -len(x[2]), -x[1]))
        current = self.score(snrs, self.mode, self.mask)
        if best[0] <= 0 and current <= 0:
            # No candidate is expected to deliver anything (e.g. four destroyed groups):
            # QPSK with the most protective mask the length allows.
            self.mode = 0
            self.mask = next(msk for msk in reversed(candidates(snrs)) if self.legal(0, msk))
            return self.mode, self.mask, 'no_viable'
        threshold = self.hyst if best[1] != self.mode else self.hyst_mask
        if (best[1], best[2]) != (self.mode, self.mask) and best[0] > (1 + threshold) * current:
            self.mode, self.mask = best[1], best[2]
            return self.mode, self.mask, 'switch'
        return self.mode, self.mask, 'hold'


class JointOllaPolicy:
    """Joint policy driven by the per-group metrics, with A's OLLA offset (no prediction).

    update(window_result, metrics) -> (mode, mask_bitmap, reason).  The offset learns from
    payload CRC outcomes of 16QAM windows exactly as PredOllaPolicy does in lean_adapt."""

    def __init__(self, cal, frames, length, target=.1, step_down=.25, delta_min=-6.0, delta_max=3.0,
                 hyst=.05, hyst_mask=.01, t_fixed_s=2.5e-3):
        if not (0 < target < 1 and step_down >= 0 and delta_min <= 0 <= delta_max):
            raise ValueError('invalid OLLA parameters')
        self.cal = cal
        self.joint = JointPolicy(cal, length, frames, t_fixed_s, hyst, hyst_mask)
        self.step_down, self.step_up = step_down, step_down * target / (1 - target)
        self.dmin, self.dmax, self.delta = delta_min, delta_max, 0.0
        self.snrs = None

    def update(self, r, metrics, used_mask):
        used = r['mcs']
        fail = r.get('crc_fail', 0) + r.get('truncated', 0)
        if used == 1 and r['sent']:
            self.delta = min(self.dmax, max(self.dmin, self.delta + self.step_up * r['ok'] - self.step_down * fail))
        m_g, e_g = group_metrics(metrics, used_mask)
        masked = {g for g in range(GROUPS) if used_mask >> g & 1}
        header_only = metrics['syms_pay'] == 0
        # Header copies are QPSK whatever the payload modulation was.
        self.snrs = group_snr_from_metrics(self.cal, 0 if header_only else used, m_g, e_g,
                                           set() if header_only else masked, self.delta)
        if header_only and any(s is not None for s in self.snrs):
            # A masked group cannot be measured without payload: keep it masked.
            self.snrs = [DESTROYED_DB if g in masked else s for g, s in enumerate(self.snrs)]
        mode, mask, reason = self.joint.decide(r['ok'], self.snrs)
        return mode, mask_bitmap(mask), reason

    def state(self):
        return dict(delta_db=round(self.delta, 4),
                    snr_db=None if self.snrs is None else [None if s is None else round(s, 3) for s in self.snrs])


class JointOllaPolicyV2(JointOllaPolicy):
    """Joint policy v2 (stage-2 board findings, BRINGUP-026).  Same metrics, survival model,
    candidates and OLLA offset as JointOllaPolicy; adds:
      - impairment gate: masking is allowed only while some group is destroyed (erasures/
        saturation) or at least gate_db below the median group SNR, i.e. while a narrowband
        impairment is present; band tilt alone must not mask (H5).  With an impairment present
        every group is a candidate, as in v1 (the tone also degrades neighbouring groups);
      - conservative masked estimate: min(zero-carrier estimate, last estimate while the group
        carried data), because the two scales disagreed by 2-5 dB on the board; the data-carrying
        estimate expires after data_memory masked windows so that a group can be released;
      - slow unmask: a masked group is released only after unmask_windows consecutive windows
        in which the unconstrained choice drops it with > unmask_gain expected gain (releasing one
        group gains only ~3% window throughput at 2048 B with the fixed per-window time, so the
        threshold stays at v1's 1% and the protection comes from the votes and the lockout);
      - failure lockout: if the window after a release loses > fail_frac of its frames, the
        released groups are masked again and locked for lock_windows (doubling, <= lock_max);
      - zero-delivery escalation: a window with valid metrics and no frame delivered masks the
        worst non-destroyed unmasked group (locked), since decision-directed EVM saturates under a
        strong tone (destroyed groups are masked by the survival model); destroyed groups have
        priority over locked/kept groups for the 3-group budget (v2.1, after the v2 board run in
        which locks filled the budget and left destroyed group 7 unmasked for 10 windows);
      - QPSK release probe (v2.2): the window that releases a group is sent in QPSK, so a group
        whose zero-carrier estimate was optimistic (e.g. masked by pre-transmission sensing and
        never measured with data) costs at most a few QPSK frames instead of a lost 16QAM window;
        the probe yields its data-carrying estimate, and the next decision may return to 16QAM."""

    def __init__(self, cal, frames, length, target=.1, step_down=.25, delta_min=-6.0, delta_max=3.0,
                 hyst=.05, gate_db=4.0, unmask_windows=3, unmask_gain=.01, lock_windows=8,
                 lock_max=64, fail_frac=.05, data_memory=32, t_fixed_s=2.5e-3):
        super().__init__(cal, frames, length, target, step_down, delta_min, delta_max, hyst, .01, t_fixed_s)
        if not (gate_db >= 0 and unmask_windows >= 1 and unmask_gain >= 0 and 1 <= lock_windows <= lock_max
                and 0 <= fail_frac < 1 and data_memory >= 1):
            raise ValueError('invalid joint2 parameters')
        self.gate_db, self.unmask_windows, self.unmask_gain = gate_db, unmask_windows, unmask_gain
        self.lock_windows, self.lock_max, self.fail_frac = lock_windows, lock_max, fail_frac
        self.data_memory = data_memory
        self.data_snr = [None] * GROUPS          # last estimate while the group carried payload
        self.data_age = [0] * GROUPS             # masked windows since that estimate
        self.lock = [0] * GROUPS
        self.lock_len = [lock_windows] * GROUPS
        self.votes = [0] * GROUPS
        self.released = frozenset()              # groups unmasked by the previous decision
        self.events = []

    def seed(self, groups):
        """Initial mask from pre-transmission sensing (QPSK).  No estimate is invented for the
        seeded groups: their zero-carrier metric decides, and the normal release rule (votes)
        unmasks a group whose line turns out harmless."""
        mask = frozenset(groups)
        if len(mask) > MAX_MASKED or not self.joint.legal(0, mask):
            raise ValueError('seed mask not usable for this frame length')
        self.joint.mode, self.joint.mask = 0, mask
        return mask_bitmap(mask)

    def _lock(self, g):
        self.lock[g] = self.lock_len[g]
        self.lock_len[g] = min(self.lock_max, 2 * self.lock_len[g])

    def update(self, r, metrics, used_mask):
        used = r['mcs']
        fail = r.get('crc_fail', 0) + r.get('truncated', 0)
        if used == 1 and r['sent']:
            self.delta = min(self.dmax, max(self.dmin, self.delta + self.step_up * r['ok'] - self.step_down * fail))
        m_g, e_g = group_metrics(metrics, used_mask)
        masked = frozenset(g for g in range(GROUPS) if used_mask >> g & 1)
        header_only = metrics['syms_pay'] == 0
        snrs = group_snr_from_metrics(self.cal, 0 if header_only else used, m_g, e_g,
                                      set() if header_only else masked, self.delta)
        if header_only and any(s is not None for s in snrs):
            snrs = [DESTROYED_DB if g in masked else s for g, s in enumerate(snrs)]
        self.events = []
        for g in range(GROUPS):
            if not header_only and g not in masked and snrs[g] is not None:
                self.data_snr[g], self.data_age[g] = snrs[g], 0
            elif g in masked and self.data_snr[g] is not None:
                self.data_age[g] += 1
                if self.data_age[g] > self.data_memory:
                    self.data_snr[g] = None
        for g in masked:
            if snrs[g] is not None and self.data_snr[g] is not None:
                snrs[g] = min(snrs[g], self.data_snr[g])
        self.snrs = snrs
        self.lock = [max(0, x - 1) for x in self.lock]
        lost = r['sent'] - r['ok']
        forced = set()
        if self.released and r['sent'] and lost > self.fail_frac * r['sent']:
            for g in self.released:
                self._lock(g)
                forced.add(g)
            self.events.append('release_failed')
        self.released = frozenset()
        if all(s is None for s in snrs):
            mode, mask, reason = self.joint.decide(r['ok'], snrs)
            return mode, mask_bitmap(mask), reason
        destroyed = {g for g, s in enumerate(snrs) if s is not None and s <= DESTROYED_DB}
        if r['sent'] and r['ok'] == 0:
            # Destroyed groups are masked by the survival model anyway; escalate on the worst of the rest.
            free = [g for g in range(GROUPS) if g not in masked and g not in forced
                    and snrs[g] is not None and snrs[g] > DESTROYED_DB]
            if free:
                worst = min(free, key=lambda g: snrs[g])
                self._lock(worst)
                forced.add(worst)
                self.events.append('escalate_%d' % worst)
        valid = sorted(s for s in snrs if s is not None)
        med = valid[len(valid) // 2] if len(valid) % 2 else (valid[len(valid) // 2 - 1] + valid[len(valid) // 2]) / 2
        impaired = {g for g, s in enumerate(snrs) if s is not None and (s <= DESTROYED_DB or s <= med - self.gate_db)}
        if impaired or masked:
            impaired = {g for g, s in enumerate(snrs) if s is not None}
        locked = {g for g in range(GROUPS) if self.lock[g] > 0}
        cur_mode, cur_mask = self.joint.mode, self.joint.mask
        # Unconstrained (gated) best: decides which masked groups vote for release.
        free_best = self._best(snrs, impaired, set())
        current = self.joint.score(snrs, cur_mode, cur_mask)
        approved = set()
        for g in range(GROUPS):
            if g in cur_mask and g not in locked and free_best is not None and g not in free_best[2] \
                    and free_best[0] > (1 + self.unmask_gain) * current:
                self.votes[g] += 1
                if self.votes[g] >= self.unmask_windows:
                    approved.add(g)
            else:
                self.votes[g] = 0
        keep = (set(cur_mask) - approved) | locked | forced
        if len(keep | destroyed) > MAX_MASKED:
            # Budget: destroyed groups first, then the weakest of the kept/locked ones.
            keep = set(sorted(keep | destroyed, key=lambda g: (snrs[g] if snrs[g] is not None else DESTROYED_DB))[:MAX_MASKED])
        best = self._best(snrs, impaired, keep)
        if best is None or (best[0] <= 0 and current <= 0):
            self.joint.mode = 0
            options = [frozenset(keep)] + [m for m in reversed(candidates(snrs)) if keep <= m]
            self.joint.mask = next((m for m in options if self.joint.legal(0, m)), frozenset())
            reason = 'no_viable'
        else:
            score, mode, mask = best
            must_change = not set(cur_mask) <= set(mask) or not keep <= set(cur_mask)
            threshold = self.joint.hyst if mode != cur_mode else self.joint.hyst_mask
            if (mode, mask) != (cur_mode, cur_mask) and (must_change or score > (1 + threshold) * current):
                self.joint.mode, self.joint.mask = mode, mask
                reason = 'switch'
            else:
                reason = 'hold'
        self.released = frozenset(set(cur_mask) - set(self.joint.mask))
        for g in self.released:
            self.votes[g] = 0
        if self.released and self.joint.mode == 1:
            self.joint.mode = 0
            self.events.append('probe_qpsk')
        if self.events:
            reason = reason + ':' + ','.join(self.events)
        return self.joint.mode, mask_bitmap(self.joint.mask), reason

    def _best(self, snrs, impaired, keep):
        keep = frozenset(keep)
        extra = sorted((snrs[g], g) for g in impaired if g not in keep)
        masks = [keep | frozenset(g for _, g in extra[:k]) for k in range(MAX_MASKED - len(keep) + 1)]
        opts = [(self.joint.score(snrs, m, msk), m, msk) for m in (0, 1) for msk in masks
                if len(msk) <= MAX_MASKED and self.joint.legal(m, msk)]
        return max(opts, key=lambda x: (x[0], -len(x[2]), -x[1])) if opts else None

    def state(self):
        s = super().state()
        s.update(lock=list(self.lock), votes=list(self.votes), events=list(self.events))
        return s
