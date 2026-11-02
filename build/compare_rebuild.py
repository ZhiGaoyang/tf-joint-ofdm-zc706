"""Compare a rebuild from the contest package with the board-tested results shipped in prebuilt/.

  python -I -B build/vivado_pkg/compare_rebuild.py <package root> <work dir>
Checks: core utilization (LUT/FF/BRAM/DSP), routed WNS/WHS/WPWS/TNS, routed utilization, route status, and the
bitstream configuration data with the .bit header (design name, date, time) stripped.
"""
import re
import sys
from pathlib import Path


def util(p):
    t = Path(p).read_text(encoding='utf-8', errors='replace')
    out = {}
    for name in ('Slice LUTs', 'CLB LUTs', 'Slice Registers', 'CLB Registers', 'Block RAM Tile', 'DSPs'):
        m = re.search(r'^\|\s*%s\*?\s*\|\s*([\d.]+)' % re.escape(name), t, re.M)
        if m:
            out[name] = m.group(1)
    return out


def timing(p):
    t = Path(p).read_text(encoding='utf-8', errors='replace')
    i = t.index('Design Timing Summary')
    row = [l for l in t[i:].splitlines()[1:12] if re.match(r'\s*-?\d', l)][0].split()
    return dict(WNS=row[0], TNS=row[1], WHS=row[4], THS=row[5], WPWS=row[8], TPWS=row[9])


def bit_payload(p):
    b = Path(p).read_bytes()
    k = 13                                   # fixed preamble of the .bit header
    while True:
        key = b[k:k + 1]
        k += 1
        if key == b'e':
            n = int.from_bytes(b[k:k + 4], 'big')
            return b[k + 4:k + 4 + n]
        n = int.from_bytes(b[k:k + 2], 'big')
        k += 2 + n


def main(pkg, work):
    pkg, work = Path(pkg), Path(work)
    rows = [('core utilization', util(pkg / 'prebuilt/core/utilization.rpt'), util(work / 'core/utilization.rpt'))]
    if (work / 'impl/routed_timing.rpt').exists():
        rows += [('routed timing', timing(pkg / 'prebuilt/impl/routed_timing.rpt'), timing(work / 'impl/routed_timing.rpt')),
                 ('routed utilization', util(pkg / 'prebuilt/impl/routed_utilization.rpt'),
                  util(work / 'impl/routed_utilization.rpt'))]
        for name in ('route_status.rpt', 'summary.tsv'):
            a = (pkg / 'prebuilt/impl' / name).read_text(encoding='utf-8', errors='replace')
            b = (work / 'impl' / name).read_text(encoding='utf-8', errors='replace')
            print('%-20s %s' % (name, 'IDENTICAL' if a.split('\n')[-12:] == b.split('\n')[-12:] or a == b else 'DIFFERENT'))
            if name == 'summary.tsv':
                print('  prebuilt:', a.strip().replace('\n', ' | '))
                print('  rebuild :', b.strip().replace('\n', ' | '))
    if (work / 'impl/system_top.bit').exists():
        same = bit_payload(pkg / 'prebuilt/impl/system_top.bit') == bit_payload(work / 'impl/system_top.bit')
        rows.append(('bitstream data', 'identical', 'identical' if same else 'different'))
    ok = True
    for name, a, b in rows:
        same = a == b
        ok &= same
        print('%-20s %s\n  prebuilt %s\n  rebuild  %s' % (name, 'MATCH' if same else 'DIFF', a, b))
    print('RESULT', 'MATCH' if ok else 'DIFF')


if __name__ == '__main__':
    main(*sys.argv[1:])
