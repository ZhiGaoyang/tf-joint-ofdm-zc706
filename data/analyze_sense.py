"""Evaluate the sensing runs exactly as pre-registered in frozen_s2_sense.json.

  python -I -B build/stage2/analyze_sense.py <raw dir> [<tag prefix: s2se (first run) | s2sr (re-run)>]
"""
import glob
import json
import os
import statistics
import sys


def load(path):
    rows = [json.loads(l) for l in open(path)]
    wins = [r for r in rows if r.get('type') == 'window']
    sense = next((r for r in rows if r.get('type') == 'sense'), None)
    summ = rows[-1] if rows and rows[-1].get('type') == 'summary' else None
    return wins, sense, summ


def pool(paths):
    a = dict(ok=0, sent=0, bits=0, ws=0.0, valid=bool(paths), w0=[], sense=[])
    for p in paths:
        wins, sense, s = load(p)
        if s is None:
            a['valid'] = False
            continue
        a['ok'] += s['ok']
        a['sent'] += s['sent']
        a['bits'] += s['delivered_bits']
        a['ws'] += s['window_elapsed_s']
        a['w0'].append(wins[0]['ok'] if wins else None)
        if sense:
            a['sense'].append(sense)
    return a


per = lambda a: 1 - a['ok'] / a['sent']
thr = lambda a: a['bits'] / a['ws'] / 1e6


def main(raw, prefix='s2se'):
    f = lambda pat: sorted(glob.glob(os.path.join(raw, pat.lower())))   # raw file names are lower case
    secs = []
    print('== Part A (no tone)')
    bad = []
    for p in f(prefix + '1_*_SJ2S.jsonl'):
        wins, sense, _ = load(p)
        secs.append(sense['seconds'])
        if sense['groups'] or any(w.get('next_mask') for w in wins):
            bad.append((os.path.basename(p), sense['groups'], sense['lines']))
    print('H5s violations:', bad, '->', 'supported' if not bad else 'REFUTED')
    t = {s: pool(f(prefix + '1_r*_T2_%s.jsonl' % s)) for s in ('S6', 'SJ2S')}
    d = thr(t['SJ2S']) / thr(t['S6']) - 1
    print('T2 S6 %.3f SJ2S %.3f Mbit/s -> %+.2f%% -> H6s %s' % (thr(t['S6']), thr(t['SJ2S']), 100 * d,
                                                               'supported' if abs(d) <= .02 else 'REFUTED'))
    print('== Part B (tone)')
    qual_w0, tot = [], {'QJS': dict(ok=0, sent=0, bits=0, ws=0.0), 'QJ2': dict(ok=0, sent=0, bits=0, ws=0.0)}
    for pos in ('P17', 'P22'):
        for lv in range(1, 6):
            arms = {a: pool(f(prefix + '2_%s_L%d_%s_[12].jsonl' % (pos, lv, a))) for a in ('Q0', 'QJ2', 'QJS')}
            for s in arms['QJS']['sense']:
                secs.append(s['seconds'])
            line = '%s L%d' % (pos, lv)
            for a in ('Q0', 'QJ2', 'QJS'):
                x = arms[a]
                line += '  %s %s' % (a, 'INVALID' if not x['valid'] else 'PER %.3f thr %.2f w0 %s' % (per(x), thr(x), x['w0']))
            print(line, ' sensed', [(s['groups'], s['lines'][:2]) for s in arms['QJS']['sense']])
            if all(x['valid'] for x in arms.values()):
                for a in ('QJS', 'QJ2'):
                    for k in ('ok', 'sent', 'bits', 'ws'):
                        tot[a][k] += arms[a][k]
                if per(arms['Q0']) >= .5:
                    qual_w0.append(((pos, lv), arms['QJS']['w0']))
    h11 = all(all(w is not None and w >= 15 for w in w0) for _, w0 in qual_w0)
    print('H11 qualifying', qual_w0, '->', 'supported' if qual_w0 and h11 else ('not testable' if not qual_w0 else 'REFUTED'))
    pj, p2 = per(tot['QJS']), per(tot['QJ2'])
    tj, t2 = thr(tot['QJS']), thr(tot['QJ2'])
    print('H12 pooled QJS PER %.4f vs QJ2 %.4f; thr %.2f vs %.2f (%.1f%%) ->' % (pj, p2, tj, t2, 100 * (tj / t2 - 1)),
          'supported' if pj < p2 and tj >= .98 * t2 else 'REFUTED')
    if secs:
        print('sensing seconds: median %.3f max %.3f (n=%d)' % (statistics.median(secs), max(secs), len(secs)))
        print('H14 (v2.2 only) median <= 0.30 s ->', 'supported' if statistics.median(secs) <= .30 else 'REFUTED')
    imp = []
    for p in f(prefix + '*_*.jsonl'):
        _, sense, _ = load(p)
        if sense and sense.get('numpy_import_s') is not None:
            imp.append(sense['numpy_import_s'])
    if imp:
        print('numpy import seconds (per process, outside sensing): median %.3f max %.3f' % (statistics.median(imp), max(imp)))
    a = {x: pool(f(prefix + '2_P22_L1_%s_[12].jsonl' % x)) for x in ('QJS', 'QJ2')}
    if all(v['valid'] and v['sent'] for v in a.values()):
        print('H13 (v2.2 only) +22.5 L1 QJS PER %.4f vs QJ2 %.4f ->' % (per(a['QJS']), per(a['QJ2'])),
              'supported' if per(a['QJS']) <= per(a['QJ2']) else 'REFUTED')


if __name__ == '__main__':
    main(*sys.argv[1:])
