"""Board command file for v2.2 (QPSK release probe, faster sensing): identical to the sensing run
(make_s2_sense.py) with tags s2s3*.  Original header follows.


Part A  no tone: T2/T3 (shift -2.0 dB), S6 vs SJ2S (joint2 --sense), 5 rounds, alternating order.
Part B  TX2 tone at +17 (16.32 MHz) and +22.5 (21.6 MHz), the five E2 levels; per level the
        tone-only power is captured, then ABBA QJS QJ2 Q0 Q0 QJ2 QJS (QJS = joint2 --sense),
        60 windows x 16 frames x 2048 B, --allow-fft-saturation, OLLA target 0.05.

  python -I -B build/stage2/make_s2_sense.py            # writes board_s2_sense_v22.commands
  python -I -B build/stage2/make_s2_sense.py --check    # parse every lean_adapt call with the real CLI
"""
import argparse
import os
import shlex
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import make_s2_e2 as e2  # noqa: E402
import make_s2_v2 as v2  # noqa: E402  (T2/T3, HELPER, freq(), adapt(), positions, levels)

CAL = 'lean_calibration_flat.json'
TGT = ' --olla-target 0.05'
E1 = {'S6': '--policy pred_olla --calibration ' + CAL + ' --pred-k 0 --pred-phi 0' + TGT,
      'SJ2S': '--policy joint2 --calibration ' + CAL + TGT + ' --sense'}
ARMS = {'QJS': '--policy joint2 --calibration ' + CAL + TGT + ' --sense',
        'QJ2': '--policy joint2 --calibration ' + CAL + TGT,
        'Q0': '--fixed 0'}
ABBA = ['QJS', 'QJ2', 'Q0', 'Q0', 'QJ2', 'QJS']


def lines():
    pre = [l for l in e2.PRE if 'TONESETUP_RC' not in l]
    out = list(pre) + [v2.HELPER, "cd /root/lean; sha256sum lean_adapt.py lean_nc.py; echo SCRIPTSHA_RC=$?"]
    for rnd in range(1, 6):
        order = ['S6', 'SJ2S'] if rnd % 2 else ['SJ2S', 'S6']
        for tname, (levels, hold) in (('T2', v2.T2), ('T3', v2.T3)):
            n = len(levels.split()) * hold
            for s in order:
                out.append(v2.adapt('s2s3e1_r%d_%s_%s' % (rnd, tname, s), E1[s], n,
                                    ' --attenuation %s --hold-windows %d' % (levels, hold)))
        out.append(e2.CHECK)
    for pos, hz in v2.POSITIONS:
        out.append(v2.freq(hz))
        for i, (att, scale) in enumerate(v2.LEVELS, 1):
            tag0 = 's2s3e2_%s_L%d' % (pos, i)
            out.append(e2.SET % (e2.fmt(att), scale, scale) +
                       'echo LEVEL %s L%d att %s scale %s; sleep 0.3; '
                       'iio_readdev -u local: -b 1048576 -s 1048576 axi-adrv9009-rx-hpc voltage0_i voltage0_q > /tmp/e2.bin 2>/dev/null; '
                       'python3 /tmp/tone_meas2.py /tmp/e2.bin %d; echo %s_TONE_RC=$?' % (pos, i, e2.fmt(att), scale, hz, tag0))
            seen = {}
            for arm in ABBA:
                seen[arm] = seen.get(arm, 0) + 1
                out.append(v2.adapt('%s_%s_%d' % (tag0, arm, seen[arm]), ARMS[arm], 60, ' --allow-fft-saturation'))
            out.append(e2.CHECK)
        out.append('for f in $tx/out_altvoltage*_scale; do echo 0 > $f; done; echo SCALES_OFF_RC=$?')
    out.append(e2.OFF)
    out.append("python3 -c 'from lean_stability import health,check_health; h=health(); print(\"TEMP\",h[\"temperature_mc\"]); check_health(h)'; echo HEALTH_RC=$?")
    return out


def check(path):
    sys.path.insert(0, str(ROOT / 'scripts' / 'board'))
    import lean_adapt
    seen = []
    lean_adapt.run = lambda a, policy, log: seen.append((a, type(policy).__name__))
    calls = [l.split('python3 lean_adapt.py ', 1)[1].split(' > ', 1)[0]
             for l in path.read_text(encoding='ascii').splitlines() if 'python3 lean_adapt.py ' in l]
    cwd = os.getcwd()
    with tempfile.TemporaryDirectory() as tmp:
        shutil.copy(ROOT / 'scripts' / 'board' / CAL, tmp)
        os.chdir(tmp)
        try:
            for cmd in calls:
                sys.argv = ['lean_adapt.py'] + shlex.split(cmd)
                lean_adapt.main()
        finally:
            os.chdir(cwd)
    assert len(seen) == len(calls) == 20 + 2 * 5 * 6
    assert sum(a.sense for a, _ in seen) == 10 + 2 * 5 * 2
    for a, _ in seen:
        assert a.len == 2048 and a.frames == 16 and (a.fixed == 0 or a.olla_target == 0.05)
    print('check ok', len(seen), 'lean_adapt calls;', sorted({p for _, p in seen}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', type=Path, default=HERE / 'board_s2_sense_v22.commands')
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    if a.check:
        return check(a.out)
    if a.out.exists():
        raise SystemExit('refusing to overwrite ' + str(a.out))
    body = lines()
    a.out.write_text('\n'.join(body) + '\n', encoding='ascii', newline='\n')
    print('lines', len(body), '->', a.out)


if __name__ == '__main__':
    main()
