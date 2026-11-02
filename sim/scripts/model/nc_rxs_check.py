"""Check an NC RX-core simulation log (tb_nc_rxs_core) against expected.json.

Usage: python -m scripts.model.nc_rxs_check <expected.json> <xsim log>
Same rules as scripts/model/rxs_check.py, plus: every OK frame's record must
carry the transmitted mask (absent in old vectors -> 0); expect ANY requires
no outcome but forbids a corrupted OK record; statistics listed in the
scenario's allow_stats may be nonzero.  Exit 0 only when all hold.
"""
import argparse
import json
import re
import sys

STATUS = re.compile(r'^RXS_STATUS (.*)$', re.M)
STATS = re.compile(r'^RXS_STATS (.*)$', re.M)


def fields(text):
    return {k: int(v) for k, v in re.findall(r'(\w+)=(-?\d+)', text)}


def check(exp, log):
    records = [fields(m) for m in STATUS.findall(log)]
    stats = STATS.findall(log)
    problems = []
    if 'RXS_DONE' not in log or len(stats) != 1:
        problems.append('simulation did not finish')
    if 'RXS_FAULT' in log:
        problems.append('fault asserted')
    stats = fields(stats[0]) if stats else {}
    for key in ('overruns', 'candidate_drops', 'busy_drops', 'long_plateaus'):
        if stats.get(key, 0) and key not in exp.get('allow_stats', []):
            problems.append(f'stat {key}={stats[key]}')
    by_id = {}
    for r in records:
        by_id.setdefault(r['id'], []).append(r)
    known = {f['frame_id'] for f in exp['frames']}
    ok = 0
    for f in exp['frames']:
        recs = by_id.get(f['frame_id'], [])
        good = [r for r in recs if r['reason'] == 0]
        mask = f.get('mask', 0)

        def complete(r):
            # Same full-field rule for OK and ANY: ANY only relaxes whether success is required.
            fields_ok = r['len'] == f['length'] and r['mcs'] == f['mcs'] and r['mask'] == mask
            if not fields_ok:
                problems.append(f"frame {f['frame_id']}: header fields {r} (mask {mask})")
            if r['ber'] != 0 or r['cmp'] != 8 * f['length']:
                problems.append(f"frame {f['frame_id']}: bit errors {r['ber']}/{r['cmp']}")
        if f['expect'] == 'OK':
            if len(good) != 1:
                problems.append(f"frame {f['frame_id']}: {len(good)} OK records ({recs})")
                continue
            complete(good[0])
            ok += 1
        elif f['expect'] == 'ANY':
            if len(good) > 1:
                problems.append(f"frame {f['frame_id']}: {len(good)} OK records ({recs})")
            for r in good:
                complete(r)
        elif good:
            problems.append(f"frame {f['frame_id']}: corrupted frame published as OK")
        elif f['expect'] == 'PAYLOAD' and not any(r['reason'] == 2 for r in recs):
            problems.append(f"frame {f['frame_id']}: no payload-CRC record")
    false_ok = [r for r in records if r['reason'] == 0 and r['id'] not in known]
    if false_ok:
        problems.append(f'false OK records {false_ok}')
    header_fail = sum(1 for r in records if r['reason'] == 1)
    need = sum(1 for f in exp['frames'] if f['expect'] == 'HEADER')
    if header_fail < need:
        problems.append(f'header failures {header_fail} < {need}')
    any_ok = sum(1 for f in exp['frames'] if f['expect'] == 'ANY'
                 and any(r['reason'] == 0 for r in by_id.get(f['frame_id'], [])))
    nc = re.findall(r'^RXS_NC (.*)$', log, re.M)
    return dict(ok=ok, expected_ok=sum(1 for f in exp['frames'] if f['expect'] == 'OK'),
                any_frames=sum(1 for f in exp['frames'] if f['expect'] == 'ANY'), any_ok=any_ok,
                records=len(records), header_fail=header_fail, stats=stats,
                nc=fields(nc[0]) if nc else None, problems=problems)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('expected')
    ap.add_argument('log')
    a = ap.parse_args()
    exp = json.load(open(a.expected))
    log = open(a.log, encoding='utf-8', errors='replace').read()
    summary = check(exp, log)
    print(json.dumps(summary))
    sys.exit(1 if summary['problems'] else 0)


if __name__ == '__main__':
    main()
