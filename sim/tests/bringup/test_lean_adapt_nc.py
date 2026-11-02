"""Host tests for the NC options of scripts/board/lean_adapt.py (no board access)."""
import io
import json
import pathlib
import sys
from types import SimpleNamespace

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT.parent / 'src' / 'ps'))
import lean_adapt as adapt  # noqa: E402
import lean_nc  # noqa: E402

CAL = ROOT.parent / 'src' / 'ps' / 'lean_calibration_flat.json'
NC_RANGE = range(0x048, 0x070)


class FakeCore:
    """Register file with NC version/backoff and metric banks; records accesses."""

    def __init__(self, version=0x20261025, backoff=16, tone_group=None):
        self.regs = {0x004: version, 0x030: (backoff << 20) | (720 << 8) | 12, 0x008: 3}
        self.tone_group, self.writes, self.reads = tone_group, [], []
        self.set_banks()

    def set_banks(self):
        self.regs[0x058], self.regs[0x05C] = 32, 40
        for d in range(88):
            bad = self.tone_group is not None and d // 8 == self.tone_group
            self.regs[0x400 + 4 * d] = int((0.6 if bad else 0.0004) * 65536 * 40)
            self.regs[0x600 + 4 * d] = 0

    def rd(self, off):
        self.reads.append(off)
        return self.regs.get(off, 0)

    def wr(self, off, value):
        self.writes.append((off, value))
        if off != 0x054:              # NC_METRIC_CTRL bits are commands (clear), not stored values
            self.regs[off] = value

    def snapshot(self):
        return {}


def window_result(core, mcs, frames, length, first, *rest):
    tone = core.tone_group is not None and not (core.regs.get(0x048, 0) >> core.tone_group & 1)
    ok = 0 if tone else frames
    return dict(sent=frames, ok=ok, crc_fail=frames - ok, header_fail=0, truncated=0, per=1 - ok / frames,
                compared_bits=8 * length * ok, bit_errors=0, ber=0.0, evm=4.0 if ok else None,
                goodput_mbps=1.0, elapsed_s=6e-3, mcs=mcs, first=first, length=length, status='0x621e')


def namespace(**kw):
    a = dict(fixed=None, windows=4, frames=16, len=2048, attenuation=None, hold_windows=1, policy='threshold',
             evm_up=6.0, evm_down=8.0, per_down=.05, up_windows=5, dwell=10, mask=None, nc_metrics=False,
             allow_fft_saturation=False)
    a.update(kw)
    return SimpleNamespace(**a)


def run(monkeypatch, core, a, policy):
    monkeypatch.setattr(adapt, 'Core', lambda: core)
    monkeypatch.setattr(adapt, 'window', window_result)
    log = io.StringIO()
    adapt.run(a, policy, log)
    return [json.loads(x) for x in log.getvalue().splitlines()]


@pytest.mark.parametrize('core,msg', [(FakeCore(version=0x20261022), 'VERSION'), (FakeCore(backoff=10), 'backoff')])
def test_nc_preflight_fails_before_any_burst(monkeypatch, core, msg):
    monkeypatch.setattr(adapt, 'Core', lambda: core)
    monkeypatch.setattr(adapt, 'window', lambda *x: pytest.fail('burst sent'))
    with pytest.raises(RuntimeError, match=msg):
        adapt.run(namespace(nc_metrics=True), adapt.Policy(), io.StringIO())
    assert core.writes == []


def test_joint_run_masks_the_tone_group_and_logs_metrics(monkeypatch):
    core = FakeCore(tone_group=7)
    cal = adapt.Calibration(str(CAL))
    rows = run(monkeypatch, core, namespace(policy='joint', windows=4), lean_nc.JointOllaPolicy(cal, 16, 2048))
    masks = [v for off, v in core.writes if off == 0x048]
    assert len(masks) == 5 and masks[-1] == 0                  # 4 windows, then restored to 0
    assert masks[0] == 0 and masks[3] == 1 << 7
    wins = [r for r in rows if r['type'] == 'window']
    assert wins[0]['nc']['mask'] == 0 and wins[0]['next_mask'] == 1 << 7 and wins[-1]['nc']['mask'] == 1 << 7
    assert wins[-1]['ok'] == 16 and 'policy_state' in wins[0] and len(wins[0]['nc']['m_g']) == 11
    assert rows[0]['version'] == '0x20261025' and len(rows[0]['lean_nc_sha256']) == 64
    # Every window: mask written, metrics enabled and cleared before the burst, frozen read after.
    assert core.writes.count((0x054, 0x201)) == 4 and (0x04C, 0x07000000) in core.writes


def test_fixed_mask_run_writes_that_mask_every_window(monkeypatch):
    core = FakeCore()
    rows = run(monkeypatch, core, namespace(mask=0x080, fixed=0), adapt.Policy())
    assert [v for off, v in core.writes if off == 0x048] == [0x080] * 4 + [0]
    assert all(r['nc']['mask'] == 0x080 for r in rows if r['type'] == 'window')


def test_without_nc_options_no_nc_register_is_touched(monkeypatch):
    core = FakeCore(version=0x20261022)          # old image is fine without NC options
    rows = run(monkeypatch, core, namespace(), adapt.Policy())
    assert not [o for o in core.reads if o in NC_RANGE or o >= 0x200] and not core.writes
    assert 'version' not in rows[0] and all('nc' not in r for r in rows if r['type'] == 'window')


@pytest.mark.parametrize('args', [
    ['--mask', '0xF'],                                         # 4 groups
    ['--mask', '0x7', '--len', '4096', '--fixed', '0'],       # QPSK L_max 2988
    ['--mask', '0x1', '--len', '3800'],                       # adaptive: QPSK L_max 3736
    ['--mask', '0x1', '--policy', 'joint', '--calibration', str(CAL)],
])
def test_invalid_nc_arguments_fail_before_board_access(monkeypatch, tmp_path, args):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, 'argv', ['lean_adapt.py'] + args)
    monkeypatch.setattr(adapt, 'Core', lambda: pytest.fail('board touched'))
    with pytest.raises(SystemExit) as exc:
        adapt.main()
    assert exc.value.code == 2 and not list(tmp_path.iterdir())


def test_fft_saturation_aborts_by_default_and_is_recorded_on_request(monkeypatch):
    snaps = iter([{'fft_saturations': 5}, {'fft_saturations': 9}] * 2)
    base = dict(tx_issued=16, tx_queued=16, ring_overruns=0, candidate_drops=0, dropped_symbols=0)

    class Core:
        def snapshot(self):
            return dict(base, **next(snaps))
    monkeypatch.setattr(adapt, 'start_burst', lambda *a: None)
    monkeypatch.setattr(adapt, 'wait_done', lambda c: 0x621e)
    monkeypatch.setattr(adapt.time, 'sleep', lambda s: None)
    monkeypatch.setattr(adapt, 'measurement', lambda b, a, f, l, dt: dict(sent=f))
    with pytest.raises(RuntimeError, match='fft_saturations'):
        adapt.window(Core(), 0, 16, 256, 1)
    r = adapt.window(Core(), 0, 16, 256, 1, allow_fft_saturation=True)
    assert r['fft_saturations_delta'] == 4


def test_nc_run_leaves_tx_mask_zero_even_after_a_failure(monkeypatch):
    # A later run without NC options does not write 0x048, so it must not inherit a mask.
    core = FakeCore(tone_group=7)
    cal = adapt.Calibration(str(CAL))
    run(monkeypatch, core, namespace(policy='joint', windows=3), lean_nc.JointOllaPolicy(cal, 16, 2048))
    assert core.regs[0x048] == 0
    core = FakeCore()
    calls = iter([window_result, None])

    def failing(*args):
        f = next(calls)
        if f is None:
            raise RuntimeError('invalid measurement window: ring_overruns')
        return f(*args)
    monkeypatch.setattr(adapt, 'Core', lambda: core)
    monkeypatch.setattr(adapt, 'window', failing)
    with pytest.raises(RuntimeError):
        adapt.run(namespace(mask=0x080, fixed=0, windows=3), adapt.Policy(), io.StringIO())
    assert core.regs[0x048] == 0


# ---------------------------------------------------------------- independent review 2026-10-26 (F5, F6)
def test_cleanup_steps_are_independent_and_the_window_error_propagates(monkeypatch):
    # F5: the attenuation restore fails, yet the mask must still be cleared, the first error must
    # propagate and the cleanup failure must be logged.
    core = FakeCore()
    monkeypatch.setattr(adapt, 'Core', lambda: core)
    monkeypatch.setattr(adapt, 'window', lambda *a: (_ for _ in ()).throw(RuntimeError('window failure')))
    phy = {'out_voltage0_hardwaregain': '-0.000000 dB'}

    def phy_write(attr, value):
        if phy.get('restore'):
            raise OSError('restore failed')
        phy['restore'] = True
        phy[attr] = value
    monkeypatch.setattr(adapt, 'phy_read', lambda attr: phy.get(attr, '-10.000000 dB'))
    monkeypatch.setattr(adapt, 'phy_write', phy_write)
    monkeypatch.setattr(adapt.time, 'sleep', lambda s: None)
    log = io.StringIO()
    a = namespace(mask=0x080, fixed=0, attenuation=[10.0])
    with pytest.raises(RuntimeError, match='window failure'):
        adapt.run(a, adapt.Policy(), log)
    assert core.regs[0x048] == 0
    rows = [json.loads(x) for x in log.getvalue().splitlines()]
    assert any(r['type'] == 'cleanup_failure' and 'restore failed' in json.dumps(r) for r in rows)


def test_joint_with_fixed_modulation_is_rejected_before_board_access(monkeypatch, tmp_path):
    # F6: --fixed would be silently overridden by the joint policy.
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, 'argv', ['lean_adapt.py', '--policy', 'joint', '--calibration', str(CAL), '--fixed', '0'])
    monkeypatch.setattr(adapt, 'Core', lambda: pytest.fail('board touched'))
    with pytest.raises(SystemExit) as exc:
        adapt.main()
    assert exc.value.code == 2 and not list(tmp_path.iterdir())


def test_logged_group_metrics_use_the_mask_like_the_policy(monkeypatch):
    # Review log note: header-only windows must log masked groups as unknown, as the policy sees them.
    core = FakeCore()
    core.regs[0x05C] = 0                                        # no payload symbols measured
    for d in range(88):
        core.regs[0x200 + 4 * d] = int(0.0004 * 65536 * 32)
    rows = run(monkeypatch, core, namespace(mask=0x080, fixed=0, windows=1), adapt.Policy())
    w = [r for r in rows if r['type'] == 'window'][0]
    assert w['nc']['m_g'][7] is None and w['nc']['m_g'][0] is not None


# ---------------------------------------------------------------- re-review 2026-10-26 (N3)
class BrokenSnapshotCore(FakeCore):
    def snapshot(self):
        raise OSError('diagnostic read failed')


def test_failed_diagnostics_do_not_replace_the_window_error(monkeypatch):
    core = BrokenSnapshotCore()
    monkeypatch.setattr(adapt, 'Core', lambda: core)
    monkeypatch.setattr(adapt, 'window', lambda *a: (_ for _ in ()).throw(RuntimeError('window failure')))
    log = io.StringIO()
    with pytest.raises(RuntimeError, match='window failure'):
        adapt.run(namespace(mask=0x080, fixed=0), adapt.Policy(), log)
    rows = [json.loads(x) for x in log.getvalue().splitlines()]
    fail = [r for r in rows if r['type'] == 'failure']
    assert fail and 'diagnostic read failed' in fail[0]['diagnostic_error'] and core.regs[0x048] == 0


class CleanupLogFails(io.StringIO):
    def write(self, text):
        if 'cleanup_failure' in text:
            raise OSError('cleanup log write failed')
        return super().write(text)


def test_failed_cleanup_logging_does_not_replace_the_window_error(monkeypatch):
    core = FakeCore()
    monkeypatch.setattr(adapt, 'Core', lambda: core)
    monkeypatch.setattr(adapt, 'window', lambda *a: (_ for _ in ()).throw(RuntimeError('window failure')))
    state = {}

    def phy_write(attr, value):
        if state.get('set'):
            raise OSError('restore failed')
        state['set'] = True
    monkeypatch.setattr(adapt, 'phy_read', lambda attr: '-10.000000 dB')
    monkeypatch.setattr(adapt, 'phy_write', phy_write)
    monkeypatch.setattr(adapt.time, 'sleep', lambda s: None)
    with pytest.raises(RuntimeError, match='window failure'):
        adapt.run(namespace(mask=0x080, fixed=0, attenuation=[10.0]), adapt.Policy(), CleanupLogFails())
    assert core.regs[0x048] == 0


# ---------------------------------------------------------------- round-3 review 2026-10-26 (M3)
class CloseFails(io.StringIO):
    def close(self):
        raise OSError('close flush failed')


def test_cli_log_close_failure_does_not_replace_the_run_error(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, 'argv', ['lean_adapt.py', '--windows', '1'])
    monkeypatch.setattr(adapt, 'open', lambda *a, **k: CloseFails(), raising=False)
    monkeypatch.setattr(adapt, 'run', lambda *a: (_ for _ in ()).throw(RuntimeError('primary run failure')))
    with pytest.raises(RuntimeError, match='primary run failure'):
        adapt.main()


def test_cli_log_close_failure_after_success_is_still_an_error(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, 'argv', ['lean_adapt.py', '--windows', '1'])
    monkeypatch.setattr(adapt, 'open', lambda *a, **k: CloseFails(), raising=False)
    monkeypatch.setattr(adapt, 'run', lambda *a: None)
    with pytest.raises(OSError, match='close flush failed'):
        adapt.main()


# ---------------------------------------------------------------- joint2 and the TX2 tone schedule
@pytest.mark.parametrize('args', [
    ['--policy', 'joint2', '--calibration', str(CAL), '--fixed', '0'],
    ['--policy', 'joint2', '--calibration', str(CAL), '--mask', '0x80'],
    ['--policy', 'joint2'],                                                  # calibration required
    ['--tone-on', '2', '--tone-off', '4'],                                   # incomplete schedule
    ['--windows', '10', '--tone-on', '5', '--tone-off', '5', '--tone-scale', '0.1'],
    ['--windows', '10', '--tone-on', '2', '--tone-off', '11', '--tone-scale', '0.1'],
    ['--windows', '10', '--tone-on', '2', '--tone-off', '4', '--tone-scale', '0.6'],
])
def test_invalid_joint2_and_tone_arguments_fail_before_board_access(monkeypatch, tmp_path, args):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, 'argv', ['lean_adapt.py'] + args)
    monkeypatch.setattr(adapt, 'Core', lambda: pytest.fail('board touched'))
    with pytest.raises(SystemExit) as exc:
        adapt.main()
    assert exc.value.code == 2 and not list(tmp_path.iterdir())


def test_joint2_run_masks_the_tone_group(monkeypatch):
    core = FakeCore(tone_group=7)
    cal = adapt.Calibration(str(CAL))
    rows = run(monkeypatch, core, namespace(policy='joint2', windows=4), lean_nc.JointOllaPolicyV2(cal, 16, 2048))
    wins = [r for r in rows if r['type'] == 'window']
    assert wins[0]['next_mask'] == 1 << 7 and wins[-1]['nc']['mask'] == 1 << 7 and wins[-1]['ok'] == 16
    assert 'lock' in wins[0]['policy_state'] and [v for off, v in core.writes if off == 0x048][-1] == 0


def test_tone_schedule_switches_between_bursts_and_is_switched_off_at_the_end(monkeypatch):
    core = FakeCore()
    calls = []
    monkeypatch.setattr(adapt, 'set_tx2_tone', lambda s: calls.append((len([w for w in core.writes if w[0] == 0x048]), s)))
    a = namespace(policy='threshold', windows=6, fixed=0, tone_on=2, tone_off=4, tone_scale=0.1, nc_metrics=True)
    rows = run(monkeypatch, core, a, adapt.Policy())
    # (mask writes so far = windows already prepared, scale): on before window 2, off before 4, off at cleanup
    assert calls == [(2, 0.1), (4, 0.0), (6, 0.0)]
    assert [r['tone_scale'] for r in rows if r['type'] == 'window'] == [0, 0, 0.1, 0.1, 0, 0]


def test_without_a_tone_schedule_the_tone_is_never_touched(monkeypatch):
    core = FakeCore()
    monkeypatch.setattr(adapt, 'set_tx2_tone', lambda s: pytest.fail('tone touched'))
    rows = run(monkeypatch, core, namespace(fixed=0, nc_metrics=True), adapt.Policy())
    assert all('tone_scale' not in r for r in rows if r['type'] == 'window')


# ---------------------------------------------------------------- pre-transmission sensing (--sense)
def synthetic_capture(tones, n=65536, noise=3.0, seed=1):
    np = pytest.importorskip('numpy')
    rng = np.random.default_rng(seed)
    t = np.arange(n) / 122.88e6
    x = noise * (rng.standard_normal(n) + 1j * rng.standard_normal(n))
    for f, amp in tones:
        x = x + amp * np.exp(2j * np.pi * f * t)
    d = np.empty(2 * n, dtype='<i2')
    d[0::2], d[1::2] = np.round(x.real), np.round(x.imag)
    return d.tobytes()


def test_spectrum_analysis_finds_the_tone_merges_side_lobes_and_ignores_noise():
    lines = adapt.analyse_spectrum(synthetic_capture([(16.32e6, 300.0)]))
    assert len(lines) == 1 and abs(lines[0][0] - 16.32e6) < 40e3 and lines[0][1] > 40
    strong = adapt.analyse_spectrum(synthetic_capture([(21.6e6, 8000.0)]))
    assert len(strong) == 1 and abs(strong[0][0] - 21.6e6) < 40e3
    assert adapt.analyse_spectrum(synthetic_capture([])) == []
    assert adapt.analyse_spectrum(synthetic_capture([(0.1e6, 300.0)])) == []          # DC region excluded
    with pytest.raises(RuntimeError):
        adapt.analyse_spectrum(b'\x00' * 400)


def test_sense_needs_joint2(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, 'argv', ['lean_adapt.py', '--policy', 'joint', '--calibration', str(CAL), '--sense'])
    monkeypatch.setattr(adapt, 'Core', lambda: pytest.fail('board touched'))
    with pytest.raises(SystemExit) as exc:
        adapt.main()
    assert exc.value.code == 2 and not list(tmp_path.iterdir())


def test_sensed_tone_is_masked_before_the_first_burst(monkeypatch):
    core = FakeCore(tone_group=7)
    cal = adapt.Calibration(str(CAL))
    monkeypatch.setattr(adapt, 'sense_spectrum', lambda db: ([(16.32e6, 50.0)], 0.2))
    rows = run(monkeypatch, core, namespace(policy='joint2', windows=4, sense=True, sense_db=20.0),
               lean_nc.JointOllaPolicyV2(cal, 16, 2048))
    sense = [r for r in rows if r['type'] == 'sense']
    assert sense and sense[0]['groups'] == [7] and sense[0]['mask'] == 1 << 7
    wins = [r for r in rows if r['type'] == 'window']
    assert wins[0]['nc']['mask'] == 1 << 7 and wins[0]['ok'] == 16                 # no lost first window
    assert [v for off, v in core.writes if off == 0x048][0] == 1 << 7


def test_sensing_failure_is_logged_and_raised_before_any_burst(monkeypatch):
    core = FakeCore()
    cal = adapt.Calibration(str(CAL))

    def boom(db):
        raise RuntimeError('iio_readdev failed')
    monkeypatch.setattr(adapt, 'sense_spectrum', boom)
    monkeypatch.setattr(adapt, 'Core', lambda: core)
    monkeypatch.setattr(adapt, 'window', lambda *x: pytest.fail('burst sent'))
    log = io.StringIO()
    with pytest.raises(RuntimeError, match='iio_readdev'):
        adapt.run(namespace(policy='joint2', windows=2, sense=True, sense_db=20.0), lean_nc.JointOllaPolicyV2(cal, 16, 2048), log)
    rows = [json.loads(x) for x in log.getvalue().splitlines()]
    assert rows[-1]['type'] == 'failure' and [v for off, v in core.writes if off == 0x048][-1] == 0


def test_vectorised_spectrum_analysis_matches_the_reference_loop():
    import importlib.util
    ref = ROOT / 'build' / 'stage2' / 'before_v22' / 'lean_adapt.py'
    if not ref.exists():
        pytest.skip('reference loop implementation is kept in the development workspace only')
    spec = importlib.util.spec_from_file_location('adapt_before_v22', ref)
    old = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(old)
    for tones in ([(16.32e6, 300.0)], [(21.6e6, 8000.0), (39.99e6, 2000.0)], [], [(-30e6, 40.0), (5e6, 900.0)]):
        cap = synthetic_capture(tones, seed=7)
        new, ref = adapt.analyse_spectrum(cap), old.analyse_spectrum(cap)
        assert [round(f) for f, _ in new] == [round(f) for f, _ in ref]
        assert all(abs(a - b) < 1e-6 for (_, a), (_, b) in zip(new, ref))
