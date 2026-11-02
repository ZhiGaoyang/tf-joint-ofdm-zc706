"""Over-temperature guard (stop at >= 75 C) for board_s2_sense_v22.commands; same transform as
make_s2_sense_rerun.py.  Original header follows.

exceeded the 75 C stop rule.  Same commands; tags s2se* -> s2sr*; every level/round check stops the
remaining runs when the temperature is >= 75 C (marker /tmp/s2_stop), plus one check before Part A.

  python -I -B build/stage2/make_s2_sense_rerun.py
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
src = (HERE / 'board_s2_sense_v22.commands').read_text(encoding='ascii').splitlines()
out_path = HERE / 'board_s2_sense_v22_guarded.commands'
if out_path.exists():
    raise SystemExit('refusing to overwrite ' + str(out_path))
out, first_run = [], True
for line in src:
    line = line.replace('s2s3e1_', 's2s3e1_').replace('s2s3e2_', 's2s3e2_')
    if 'LEVELCHK_RC=$?' in line:
        line = line.replace('echo LEVELCHK_RC=$?', 'rc=$?; echo LEVELCHK_RC=$rc; [ $rc = 0 ] || touch /tmp/s2_stop')
        out.append(line)
        continue
    if 'python3 lean_adapt.py' in line or line.startswith('echo -') or 'tone_meas2.py /tmp/e2.bin' in line:
        if first_run:
            out.append('rm -f /tmp/s2_stop; echo STOPMARK_CLEARED')
            chk = [l for l in src if 'LEVELCHK_RC=$?' in l][0]
            out.append(chk.replace('echo LEVELCHK_RC=$?', 'rc=$?; echo LEVELCHK_RC=$rc; [ $rc = 0 ] || touch /tmp/s2_stop'))
            first_run = False
        line = 'if [ -e /tmp/s2_stop ]; then echo STOPPED_OVERTEMP; else ' + line + '; fi'
    out.append(line)
out_path.write_text('\n'.join(out) + '\n', encoding='ascii', newline='\n')
print('lines', len(out), '->', out_path)
