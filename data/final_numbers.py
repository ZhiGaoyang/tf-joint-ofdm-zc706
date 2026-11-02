"""Recompute the board numbers of the technical report (final version: lean_adapt babb3986 / lean_nc 3d8b9919).
Sources: board/measurements raw_s2s3 (pre-registered in frozen_s2_v22.json), s2_s3_run.log and
raw_demo (2026-10-31 demo recording).
  python -I -B data/final_numbers.py
"""
import glob
import json
import os
import statistics
import tarfile
import io
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EV = os.path.join(ROOT, 'board', 'measurements')
RAW = os.path.join(EV, 'raw_s2s3')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyze_sense import load, pool, per, thr  # noqa: E402

f = lambda pat: sorted(glob.glob(os.path.join(RAW, pat.lower())))   # raw file names are lower case
out = {}

# Part A: no tone, T2/T3 trajectories, OLLA (S6) vs joint2 + sensing (SJ2S)
for tr in ('T2', 'T3'):
    for arm in ('S6', 'SJ2S'):
        a = pool(f('s2s3e1_r*_%s_%s.jsonl' % (tr, arm)))
        masked = sum(1 for p in f('s2s3e1_r*_%s_%s.jsonl' % (tr, arm)) for w in load(p)[0] if w.get('next_mask'))
        mcs16 = [w.get('mcs') for p in f('s2s3e1_r*_%s_%s.jsonl' % (tr, arm)) for w in load(p)[0]]
        out['e1_%s_%s' % (tr, arm)] = dict(runs=len(f('s2s3e1_r*_%s_%s.jsonl' % (tr, arm))), per=round(100 * per(a), 2),
                                          thr=round(thr(a), 2), masked_windows=masked,
                                          frac16=round(sum(1 for m in mcs16 if m == 1) / len(mcs16), 3))
lines = [load(p)[1] for p in f('s2s3e1_*_SJ2S.jsonl')]
out['e1_sense_lines'] = sum(len(s['lines']) for s in lines)
out['e1_sense_n'] = len(lines)

# Part B per level
secs = [s['seconds'] for s in lines]
w0 = {}
for pos in ('P17', 'P22'):
    for lv in range(1, 6):
        for arm in ('Q0', 'QJ2', 'QJS'):
            a = pool(f('s2s3e2_%s_L%d_%s_[12].jsonl' % (pos, lv, arm)))
            out['%s_L%d_%s' % (pos, lv, arm)] = [round(100 * per(a), 2), round(thr(a), 2), a['w0']]
            if arm == 'QJS':
                secs += [s['seconds'] for s in a['sense']]
out['sense_median_s'] = round(statistics.median(secs), 3)
out['sense_max_s'] = round(max(secs), 3)
out['sense_n'] = len(secs)

# no-interference zero-error run of the formal session (lean_ctl run before part A)
log = open(os.path.join(EV, 's2_s3_run.log'), encoding='ascii', errors='replace').read()
for l in log.splitlines():
    if l.startswith('{"sent": 12800'):
        import re
        out['ofdm_only_run'] = {k: float(re.search('"%s": ([0-9.e-]+)' % k, l).group(1))
                                for k in ('sent', 'ok', 'compared_bits', 'bit_errors', 'evm')}
        break

# demo recording (B part: tone switched on and off during the run)
tf = tarfile.open(os.path.join(EV, 'raw_demo', 'demo_record_20261031.tar.gz'))
logs = sorted(m for m in tf.getnames() if m.endswith('.jsonl'))
rows = [json.loads(l) for l in tf.extractfile(logs[1]).read().decode().splitlines()]
W = [r for r in rows if r.get('type') == 'window']
on = next(w['window'] for w in W if w.get('tone_scale'))
off = next(w['window'] for w in W if w['window'] > on and not w.get('tone_scale'))
lost = [(w['window'], w['sent'] - w['ok']) for w in W if w['ok'] < w['sent']]
rel = next(w['window'] for w in W if w['window'] >= off and not w['nc']['mask'])
out['demo_B_reaction'] = dict(windows=len(W), tone_on=on, tone_off=off, lost=lost, release_window=rel,
                     mean_window_ms=round(1000 * statistics.mean(w['elapsed_s'] for w in W), 2),
                     masks_on=sorted({hex(w['nc']['mask']) for w in W if on <= w['window'] < off}))
for i, m in enumerate(logs):
    rr = [json.loads(l) for l in tf.extractfile(m).read().decode().splitlines()]
    ww = [r for r in rr if r.get('type') == 'window']
    out['demo_%s' % 'ABC'[i]] = dict(windows=len(ww), ok=sum(w['ok'] for w in ww), sent=sum(w['sent'] for w in ww),
                                     bits=sum(w.get('compared_bits', 0) for w in ww),
                                     bit_errors=sum(w.get('bit_errors', 0) for w in ww if w.get('ok') == w.get('sent')))
# window throughput without tone (technical report table 3-4): A = fixed QPSK, B = joint policy (16QAM, no mask)
for i, m in enumerate(logs[:2]):
    rr = [json.loads(l) for l in tf.extractfile(m).read().decode().splitlines()]
    ww = [r for r in rr if r.get('type') == 'window' and not r.get('tone_scale')]
    t = sum(w['elapsed_s'] for w in ww)
    out['demo_%s_no_tone' % 'AB'[i]] = dict(windows=len(ww), mbit_s=round(sum(w['ok'] * w['length'] * 8 for w in ww) / t / 1e6, 2),
                                            window_ms=round(1000 * t / len(ww), 2))
print(json.dumps(out, indent=1))
