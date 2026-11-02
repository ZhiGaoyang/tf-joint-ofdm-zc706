"""Host tests for scripts/board/lean_nc.py (no board access)."""
import math
import pathlib
import random
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT.parent / 'src' / 'ps'))
import lean_adapt as adapt  # noqa: E402
import lean_nc as nc  # noqa: E402

CAL = ROOT.parent / 'src' / 'ps' / 'lean_calibration_flat.json'


class FakeCore:
    def __init__(self, regs=None):
        self.regs, self.writes = dict(regs or {}), []

    def rd(self, off):
        return self.regs.get(off, 0)

    def wr(self, off, value):
        self.writes.append((off, value))
        self.regs[off] = value


@pytest.fixture(scope='module')
def cal():
    return adapt.Calibration(str(CAL))


@pytest.fixture(scope='module')
def reference():
    sys.path.insert(0, str(ROOT / 'reference' / 'innovation_joint'))
    import joint_policy
    return joint_policy


def test_mask_rules_and_l_max():
    assert nc.l_max(0, 0) == 4096 and nc.l_max(0x007, 0) == 2988 and nc.l_max(0x001, 0) == 3736
    for bad in (-1, 1 << 11, 0x00F, 2.0):
        with pytest.raises(ValueError):
            nc.check_mask(bad)
    core = FakeCore()
    nc.NcRegs(core).set_tx_mask(0x480)
    assert core.writes == [(0x048, 0x480)]
    with pytest.raises(ValueError):
        nc.NcRegs(core).set_tx_mask(0x00F)


def test_rx_cfg_bits_and_frozen_read_order():
    core = FakeCore({0x058: 8, 0x05C: 52})
    raw = nc.NcRegs(core).frozen_metrics()
    assert core.writes == [(0x04C, 0x07000000), (0x04C, 0x03000000)]
    assert raw['syms_hdr'] == 8 and len(raw['pay']) == 88


def test_clear_waits_for_busy():
    class Busy(FakeCore):
        n = 0
        def rd(self, off):
            if off == 0x054:
                self.n += 1
                return 0x100 if self.n < 3 else 0
            return 0
    core = Busy()
    nc.NcRegs(core).clear_metrics()
    assert core.writes == [(0x054, 0x201)] and core.n == 3
    with pytest.raises(RuntimeError):
        nc.NcRegs(type('Stuck', (FakeCore,), {'rd': lambda self, off: 0x100})()).clear_metrics(polls=5)


def test_group_metrics_scaling_saturation_and_erasure():
    pay = [0] * 88
    for d in range(56, 64):
        pay[d] = nc.UNIT * 52 // 2          # M = 0.5 on group 7
    pay[3] = nc.SATURATED
    erase = [0] * 88
    erase[80] = 6                            # group 10: 6 / (8 * 60)
    m_g, e_g = nc.group_metrics(dict(pay=pay, erase=erase, hdr=[0] * 88, syms_hdr=8, syms_pay=52))
    assert m_g[7] == pytest.approx(0.5) and m_g[0] == math.inf and m_g[5] == 0
    assert e_g[10] == pytest.approx(6 / 480) and e_g[1] == 0
    assert nc.group_metrics(dict(pay=pay, erase=erase, hdr=[0] * 88, syms_hdr=0, syms_pay=0)) == ([None] * 11, [None] * 11)


def test_joint_port_matches_reference(cal, reference):
    ref_cal = reference.Calibration(str(CAL))
    rng = random.Random(20261025)
    a, b = nc.JointPolicy(cal), reference.JointPolicy(ref_cal)
    for _ in range(300):
        snrs = [rng.choice([None, nc.DESTROYED_DB, rng.uniform(5, 30)]) if rng.random() < 0.2 else rng.uniform(8, 30)
                for _ in range(11)]
        ok = rng.choice([0, 3, 16])
        assert a.decide(ok, snrs) == b.decide(0, None, ok, snrs=snrs)
        m_g = [None if rng.random() < 0.1 else rng.uniform(0.001, 0.5) for _ in range(11)]
        e_g = [rng.choice([0.0, 0.005, 0.02]) for _ in range(11)]
        masked = {g for g in range(11) if rng.random() < 0.15}
        mode = rng.choice([0, 1])
        assert nc.group_snr_from_metrics(cal, mode, m_g, e_g, masked) == \
            reference.group_snr_from_metrics(ref_cal, mode, m_g, e_g, masked)


def test_olla_policy_masks_a_destroyed_group_and_learns_only_on_16qam(cal):
    p = nc.JointOllaPolicy(cal, 16, 2048)
    pay = [int(0.0004 * nc.UNIT * 40)] * 88                 # EVM 2% everywhere
    for d in range(56, 64):
        pay[d] = int(0.6 * nc.UNIT * 40)                    # group 7 hit by a tone
    raw = dict(pay=pay, erase=[0] * 88, hdr=[0] * 88, syms_hdr=32, syms_pay=40)
    r = dict(mcs=0, sent=16, ok=0, crc_fail=16, truncated=0)
    mode, mask, reason = p.update(r, raw, 0)                 # every CRC lost, metric valid
    assert mask == 1 << 7 and reason == 'switch' and p.delta == 0.0      # QPSK window: no OLLA change
    p.update(dict(r, mcs=1, ok=8, crc_fail=8), raw, mask)
    assert p.delta == pytest.approx(8 * p.step_up - 8 * p.step_down)


def test_masked_group_is_released_when_the_tone_leaves(cal):
    # Unmasking one group gains only a few percent: needs the 1% mask-only hysteresis.
    p = nc.JointOllaPolicy(cal, 16, 2048)
    clean = [int(0.0004 * nc.UNIT * 40)] * 88
    hit = list(clean)
    for d in range(56, 64):
        hit[d] = int(0.6 * nc.UNIT * 40)
    r = dict(mcs=0, sent=16, ok=16, crc_fail=0, truncated=0)
    _, mask, _ = p.update(r, dict(pay=hit, erase=[0] * 88, hdr=[0] * 88, syms_hdr=32, syms_pay=40), 0)
    assert mask == 1 << 7
    released = [p.update(r, dict(pay=clean, erase=[0] * 88, hdr=[0] * 88, syms_hdr=32, syms_pay=40), mask)[1]
                for _ in range(2)]
    assert released[-1] == 0


def test_joint_never_selects_a_mask_the_frame_length_does_not_fit(cal):
    # 4096-byte QPSK frames do not fit with 3 masked groups (L_max 2988): such candidates
    # would make the framer fault.  Three destroyed groups must not lead to an illegal choice.
    p = nc.JointPolicy(cal, length=4096)
    snrs = [nc.DESTROYED_DB, nc.DESTROYED_DB, nc.DESTROYED_DB] + [12.0] * 8
    for _ in range(3):
        mode, mask, _ = p.decide(16, snrs)
        assert len(mask) == 0 or 4096 <= nc.l_max(nc.mask_bitmap(mask), mode)


def test_header_metric_fallback_when_no_payload_was_decoded(cal):
    # The tone also breaks the headers: no payload symbols measured, so unmasked groups are
    # judged from the header copies (QPSK reference); a masked group cannot be measured and
    # stays masked; with no metric at all the window is an outage.
    hdr = [int(0.0004 * nc.UNIT * 32)] * 88
    for d in range(16, 24):
        hdr[d] = int(0.8 * nc.UNIT * 32)                    # group 2 hit
    raw = dict(pay=[0] * 88, erase=[0] * 88, hdr=hdr, syms_hdr=32, syms_pay=0)
    m_g, _ = nc.group_metrics(raw, masked=1 << 7)
    assert m_g[2] == pytest.approx(0.8, rel=1e-3) and m_g[7] is None and m_g[0] == pytest.approx(0.0004, rel=1e-2)
    p = nc.JointOllaPolicy(cal, 16, 2048)
    mode, mask, reason = p.update(dict(mcs=0, sent=16, ok=0, crc_fail=0, header_fail=16, truncated=0), raw, 1 << 7)
    assert mask == (1 << 7) | (1 << 2) and reason == 'switch'
    none = dict(pay=[0] * 88, erase=[0] * 88, hdr=[0] * 88, syms_hdr=0, syms_pay=0)
    assert p.update(dict(mcs=0, sent=16, ok=0, crc_fail=0, header_fail=16, truncated=0), none, mask)[2] == 'link_lost'


# ---------------------------------------------------------------- independent review 2026-10-26 (F4, F7)
def test_outage_never_returns_an_illegal_length_combination(cal):
    # F4: 16QAM + mask 0x080 is legal at 4096 B; an outage must not return QPSK + 0x080 (L_max 3736).
    p = nc.JointPolicy(cal, length=4096)
    p.mode, p.mask = 1, frozenset({7})
    mode, mask, reason = p.decide(0, [None] * 11)
    assert reason == 'link_lost' and mode == 0 and 4096 <= nc.l_max(nc.mask_bitmap(mask), mode)
    q = nc.JointPolicy(cal, length=2048)
    q.mode, q.mask = 1, frozenset({7})
    assert q.decide(0, [None] * 11)[:2] == (0, frozenset({7}))       # legal at 2048 B: mask kept


@pytest.mark.parametrize('length', [2048, 4096])
def test_no_viable_candidate_falls_back_to_qpsk_with_a_legal_mask(cal, length):
    # F7: four destroyed groups give every candidate (and the current state) zero score; the
    # declared rule is QPSK, keeping the most protective mask that the length allows.
    p = nc.JointPolicy(cal, length=length)
    p.mode, p.mask = 1, frozenset()
    snrs = [nc.DESTROYED_DB] * 4 + [25.0] * 7
    mode, mask, reason = p.decide(16, snrs)
    assert (mode, reason) == (0, 'no_viable')
    assert length <= nc.l_max(nc.mask_bitmap(mask), 0)
    assert len(mask) == (3 if length == 2048 else 0) and mask <= {0, 1, 2, 3}


def test_metric_read_timeout_flag_invalidates_the_read():
    # Review F1 follow-up: the core flags a timed-out metric read (0x054 bit 9, sticky); the
    # window's metrics must then not be used.  clear_metrics also clears the flag.
    core = FakeCore({0x054: 0x200, 0x058: 8, 0x05C: 52})
    with pytest.raises(RuntimeError, match='timed out'):
        nc.NcRegs(core).frozen_metrics()
    assert core.writes[-1] == (0x04C, 0x03000000)               # freeze released even so
    core = FakeCore()
    nc.NcRegs(core).clear_metrics()
    assert core.writes == [(0x054, 0x201)]


def test_timeout_error_is_kept_when_unfreezing_also_fails():
    # re-review N3: the read error (timeout) must propagate even if releasing the freeze fails.
    class UnfreezeFails(FakeCore):
        def wr(self, off, value):
            if off == 0x04C and not value & (1 << 26):
                raise OSError('unfreeze failed')
            super().wr(off, value)
    core = UnfreezeFails({0x054: 0x200})
    with pytest.raises(RuntimeError, match='timed out'):
        nc.NcRegs(core).frozen_metrics()


# ---------------------------------------------------------------- joint2 (stage-2 board findings)
# Group metrics below are copied from the stage-2 board logs (BRINGUP-026 raw_s2a/raw_s2b).
E1_TILT = dict(m=[0.01272, 0.00912, 0.00868, 0.00951, 0.01099, 0.01322, 0.0128, 0.011, 0.00976, 0.0084, 0.00745],
               e=[0.0] * 11, sp=1504)                                          # s2e1_r2_T2_SJ window 55
L3_W0 = dict(m=[0.01114, 0.01071, 0.0102, 0.01136, 0.01001, 0.01333, 0.01352, 0.05885, 0.02213, 0.08944, 0.23049],
             e=[0, 0, 0, 0, 0, 0, 0, 0.0132, 0, 0, 0.01619], sp=470)           # s2e2_L3_QJ1 window 0, mask 0
L3_W1 = dict(m=[0.01484, 0.01259, 0.01269, 0.01229, 0.01321, 0.01436, 0.01456, 0.11262, 0.02194, 0.06487, 0.43083],
             e=[0, 0, 0, 0, 0, 0, 0, 0.02075, 0, 0, 0.02165], sp=2064)         # window 1, mask 0x680
L5_W0 = dict(m=[0.01163, 0.01447, 0.01467, 0.01366, 0.01406, 0.01566, 0.01944, 0.06885, 0.0217, 0.05774, 0.21016],
             e=[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.02787], sp=282)                # s2e2_L5_QJ1 window 0, mask 0
L5_W1 = dict(m=[0.01617, 0.01577, 0.01671, 0.01484, 0.01532, 0.01652, 0.02001, 0.06241, 0.01817, 0.05048, 0.24913],
             e=[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.03069], sp=412)                # window 1, mask 0x400


def raw_from_groups(g, sh=32):
    st = sh + g['sp']
    pay = [int(g['m'][d // 8] * nc.UNIT * g['sp']) for d in range(88)]
    erase = [int(round(g['e'][d // 8] * st)) for d in range(88)]
    return dict(pay=pay, erase=erase, hdr=[0] * 88, syms_hdr=sh, syms_pay=g['sp'])


def res(ok, mcs=0, sent=16):
    return dict(mcs=mcs, sent=sent, ok=ok, crc_fail=sent - ok, truncated=0)


def test_joint2_band_tilt_alone_never_masks(cal):
    # H5 was refuted on the board: v1 masked the weakest groups of a ~2.5 dB band tilt.
    p = nc.JointOllaPolicyV2(cal, 16, 2048)
    mask = 0
    for _ in range(20):
        mode, mask, _ = p.update(res(16, mcs=mode if _ else 0), raw_from_groups(E1_TILT), mask)
        assert mask == 0


def test_joint2_holds_the_mask_instead_of_oscillating(cal):
    # Board L3: v1 alternated 0x680/0x480 every window because the masked (zero-carrier)
    # estimate of group 9 was 2-4 dB more optimistic than its data-carrying estimate.
    p = nc.JointOllaPolicyV2(cal, 16, 2048)
    _, mask, _ = p.update(res(0), raw_from_groups(L3_W0), 0)
    assert mask == 0x680
    for _ in range(30):
        _, mask, _ = p.update(res(16), raw_from_groups(L3_W1), mask)
        assert mask == 0x680


def test_joint2_zero_delivery_escalates_to_the_tone_group(cal):
    # Board L5: v1 masked only group 10 and lost every frame for up to 9 windows (group 7's
    # decision-directed EVM saturated at ~12.5 dB).  v2 masks group 7 after one lost window.
    p = nc.JointOllaPolicyV2(cal, 16, 2048)
    _, mask, _ = p.update(res(0), raw_from_groups(L5_W0), 0)
    assert mask >> 10 & 1 and mask >> 7 & 1
    q = nc.JointOllaPolicyV2(cal, 16, 2048)
    _, m2, reason = q.update(res(0), raw_from_groups(L5_W1), 0x400)
    assert m2 >> 7 & 1 and m2 >> 10 & 1 and 'escalate_7' in reason


def test_joint2_releases_slowly_and_locks_after_a_failed_release(cal):
    p = nc.JointOllaPolicyV2(cal, 16, 2048, unmask_windows=3, data_memory=16)
    hit = dict(m=[0.0004] * 7 + [0.6] + [0.0004] * 3, e=[0.0] * 11, sp=40)
    clean = dict(m=[0.0004] * 11, e=[0.0] * 11, sp=40)
    _, mask, reason = p.update(res(0), raw_from_groups(hit), 0)
    assert mask == 1 << 7 and 'escalate_7' in reason and p.lock[7] == 8
    seq = []
    for _ in range(19):
        _, mask, _ = p.update(res(16), raw_from_groups(clean), mask)
        seq.append(mask)
    # masked while the data-carrying estimate (0.6) is remembered (16 masked windows), then
    # three consecutive release votes: released in the 19th clean window
    assert seq == [1 << 7] * 18 + [0] and p.data_snr[7] is None
    _, mask, reason = p.update(res(4), raw_from_groups(clean), mask)    # the release failed
    assert mask == 1 << 7 and 'release_failed' in reason and p.lock[7] == 16   # second lock doubles
    for _ in range(15):
        _, mask, _ = p.update(res(16), raw_from_groups(clean), mask)
        assert mask == 1 << 7                              # locked
    assert p.lock_len[7] == 32


# v2 board run, +17 L3 run 1 windows 0 and 1 (raw_s2v2/s2v2e2_P17_L3_QJ21.jsonl)
V2_L3_W0 = dict(m=[0.00818, 0.00759, 0.00737, 0.00723, 0.00936, 0.00876, 0.00998, 0.07045, 0.02139, 0.08567, 0.20688],
                e=[0, 0, 0, 0, 0, 0, 0, 0.00324, 0, 0, 0.07669], sp=470)
V2_L3_W1 = dict(m=[0.01171, 0.00853, 0.00986, 0.00907, 0.01122, 0.01087, 0.01297, 0.06154, 0.01946, 0.04401, 0.40281],
                e=[0, 0, 0, 0, 0, 0, 0, 0.01952, 0, 0, 0.00062], sp=570)


def test_joint2_destroyed_group_is_not_crowded_out_by_locks(cal):
    # v2 on the board: mask 0x600 (9 locked, 10), window 1 lost everything with group 7 now
    # destroyed (erasures); v2 escalated on group 8 and kept 8+9+10 for 10 windows (0x700).
    p = nc.JointOllaPolicyV2(cal, 16, 2048)
    p.joint.mask, p.lock[9] = frozenset({9, 10}), 8
    _, mask, reason = p.update(res(0), raw_from_groups(V2_L3_W1), 0x600)
    assert mask == 0x680 and 'escalate_8' in reason            # 8 locked, but 7 and 10 take the budget
    # budget: three locked groups plus a destroyed one -> the destroyed one is masked
    q = nc.JointOllaPolicyV2(cal, 16, 2048)
    q.joint.mask = frozenset({0, 8, 9})
    q.lock[0] = q.lock[8] = q.lock[9] = 8
    _, mask, _ = q.update(res(0), raw_from_groups(V2_L3_W1), 0x301)
    assert mask >> 7 & 1 and bin(mask).count('1') == 3


def test_joint2_first_window_of_the_board_failure_masks_the_tone_group_within_two_windows(cal):
    p = nc.JointOllaPolicyV2(cal, 16, 2048)
    _, m0, _ = p.update(res(0), raw_from_groups(V2_L3_W0), 0)
    assert m0 >> 10 & 1
    _, m1, _ = p.update(res(0), raw_from_groups(V2_L3_W1), m0)
    assert m1 >> 7 & 1 and m1 >> 10 & 1


@pytest.mark.parametrize('length', [2048, 2988, 4096])
def test_joint2_always_returns_a_legal_mask(cal, length):
    rng = random.Random(20261028)
    p = nc.JointOllaPolicyV2(cal, 16, length)
    mask = 0
    for _ in range(400):
        m = [rng.choice([0.0004, 0.002, 0.01, 0.05, 0.2, 0.6]) for _ in range(11)]
        e = [rng.choice([0.0, 0.0, 0.0, 0.05]) for _ in range(11)]
        sp = rng.choice([0, 40, 400])
        raw = raw_from_groups(dict(m=m, e=e, sp=sp))
        if sp == 0:
            raw['hdr'] = [int(m[d // 8] * nc.UNIT * 32) for d in range(88)]
        mode, mask, _ = p.update(res(rng.randint(0, 16), mcs=rng.choice([0, 1])), raw, mask)
        assert bin(mask).count('1') <= 3 and length <= nc.l_max(mask, mode)


def test_joint2_rejects_invalid_parameters(cal):
    with pytest.raises(ValueError):
        nc.JointOllaPolicyV2(cal, 16, 2048, lock_windows=0)
    with pytest.raises(ValueError):
        nc.JointOllaPolicyV2(cal, 16, 2048, fail_frac=1.0)


# ---------------------------------------------------------------- pre-transmission sensing
def test_tone_lines_map_to_the_groups_of_nearby_data_carriers():
    sc = nc.FS / 128
    assert len(nc.DATA_SIGNED) == 88 and not set(nc.PILOTS) & set(nc.DATA_SIGNED)
    assert nc.groups_for_tones([(17 * sc, 50)]) == [7]                  # +17: carriers 16..18, group 7
    assert nc.groups_for_tones([(22.5 * sc, 50)]) == [7, 8]             # group 7/8 boundary
    assert nc.groups_for_tones([(-17 * sc, 50)]) == [3]
    assert nc.groups_for_tones([(60 * sc, 50)]) == []                    # outside the data carriers
    # strongest first, at most three groups
    four = [(-40 * sc, 30), (-17 * sc, 40), (17 * sc, 60), (40 * sc, 35)]
    assert nc.groups_for_tones(four) == [7, 3, 9]                       # +40 spans groups 9/10; budget ends at 9


def test_seeded_mask_is_kept_for_a_real_tone_and_released_for_a_harmless_line(cal):
    hit = dict(m=[0.0004] * 7 + [0.6] + [0.0004] * 3, e=[0.0] * 11, sp=40)   # zero-carrier metric: tone
    clean = dict(m=[0.0004] * 11, e=[0.0] * 11, sp=40)
    p = nc.JointOllaPolicyV2(cal, 16, 2048)
    assert p.seed([7]) == 1 << 7
    for _ in range(6):
        _, mask, _ = p.update(res(16), raw_from_groups(hit), 1 << 7)
        assert mask >> 7 & 1
    q = nc.JointOllaPolicyV2(cal, 16, 2048)
    mask = q.seed([7])
    seq = []
    for _ in range(3):
        _, mask, _ = q.update(res(16), raw_from_groups(clean), mask)
        seq.append(mask & (1 << 7))
    assert seq == [1 << 7, 1 << 7, 0]
    with pytest.raises(ValueError):
        nc.JointOllaPolicyV2(cal, 16, 4096).seed([0, 1, 2])             # QPSK 4096 B does not fit 3 groups


def test_joint2_release_is_probed_in_qpsk(cal):
    # Board (sensing re-run, +22.5 L1): a sensed-and-masked group was released straight into a
    # 16QAM window and that window lost all 16 frames.  v2.2 sends the releasing window in QPSK.
    p = nc.JointOllaPolicyV2(cal, 16, 2048)
    clean = dict(m=[0.0004] * 11, e=[0.0] * 11, sp=40)
    mask = p.seed([7])
    modes, reasons = [], []
    for _ in range(6):
        mode, mask, reason = p.update(res(16, mcs=p.joint.mode), raw_from_groups(clean), mask)
        modes.append((mode, mask))
        reasons.append(reason)
    rel = next(i for i, (_, m) in enumerate(modes) if m == 0)
    assert modes[rel][0] == 0 and 'probe_qpsk' in reasons[rel]
    assert any(m == 1 for m, _ in modes[:rel])                 # it was in 16QAM before the release
    assert modes[rel + 1][0] == 1                               # clean probe -> back to 16QAM
