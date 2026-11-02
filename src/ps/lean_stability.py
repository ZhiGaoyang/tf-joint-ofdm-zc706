#!/usr/bin/env python3
"""Timed, finite-burst wired soak. No boot changes or automatic RF initialization."""
import argparse
import json
import time
from pathlib import Path
from lean_ctl import Core, phy_read
from lean_adapt import Policy, window


def phase(elapsed, seconds):
    return min(2, int(elapsed * 3 / seconds))


def empty():
    return dict(sent=0, ok=0, bit_errors=0, compared_bits=0, elapsed_s=0.0)


def accumulate(total, row):
    for key in total:
        total[key] += row[key]


def check_counts(total):
    if not total['sent'] or not total['compared_bits']:
        raise RuntimeError('no transmitted/compared data')
    if 1 - total['ok'] / total['sent'] > .01:
        raise RuntimeError('good-channel PER exceeds 1 percent')
    if total['bit_errors'] / total['compared_bits'] > 1e-4:
        raise RuntimeError('good-channel compared-bit BER exceeds 1e-4')


def health():
    paths = sorted(Path('/sys/bus/platform/devices').glob('*jesd204*/status'))
    if len(paths) != 3:
        raise RuntimeError('expected three JESD status files')
    return dict(temperature_mc=int(phy_read('in_temp0_input')),
                links={str(p): p.read_text() for p in paths})


def check_health(value):
    if not -40000 < value['temperature_mc'] < 90000:
        raise RuntimeError('temperature outside project load limit')
    if not value['links'] or any('Link status: DATA' not in s or
                               'SYSREF alignment error: No' not in s
                               for s in value['links'].values()):
        raise RuntimeError('JESD status/alignment failure')


def run(seconds, log):
    core = Core()
    def emit(kind, **values):
        log.write(json.dumps(dict(type=kind, wall_time=time.time(), **values)) + '\n')
        log.flush()
    if core.rd(0) != 0x4f464442 or core.rd(4) != 0x20261022 or core.rd(8) != 3:
        raise RuntimeError('unexpected core or RX/PRBS/loopback configuration')
    if core.rd(0x38) != 2 or core.rd(0x24) != 0:
        raise RuntimeError('expected TX gain2/RX gain0')
    if phy_read('out_altvoltage0_TRX_LO_frequency') != '3000000000' or float(phy_read('out_voltage0_hardwaregain').split()[0]) != 0:
        raise RuntimeError('expected accepted 3GHz/0dB operating point')
    policy = Policy()
    totals = [empty() for _ in range(3)]
    block = empty()
    first, mcs, old_phase = 1, 0, -1
    initial = core.snapshot()
    start = time.monotonic()
    next_health = start
    first_snapshot = initial
    temperatures = []
    emit('start', duration_s=seconds, initial=initial, thresholds=dict(per=.01, ber=1e-4, temperature_mc=90000))
    try:
        while time.monotonic() - start < seconds:
            now = time.monotonic()
            p = phase(now - start, seconds)
            if p != old_phase:
                if old_phase >= 0:
                    check_counts(totals[old_phase])
                emit('phase', index=p, elapsed_s=now-start)
                old_phase = p
            if now >= next_health:
                h = health()
                emit('health', elapsed_s=now-start, health=h, block=block,
                     totals=totals, before=first_snapshot, after=core.snapshot())
                check_health(h)
                temperatures.append((now, h['temperature_mc']))
                if len(temperatures) >= 31 and h['temperature_mc'] - temperatures[-31][1] > 2000:
                    raise RuntimeError('temperature rose over2C across approximately5min')
                temperatures = temperatures[-31:]
                if block['sent']:
                    check_counts(block)
                block = empty()
                first_snapshot = core.snapshot()
                next_health = now + 10
            current_mcs = p if p < 2 else mcs
            r = window(core, current_mcs, 32, 4096, first)
            if r['ok'] == 32 and (r['after']['last_id'] != (first+31) & 0xFFFFFFFF or r['after']['last_mcs'] != current_mcs):
                raise RuntimeError('last received frame identity mismatch')
            accumulate(totals[p], r)
            accumulate(block, r)
            if r['ok'] != 32 or r['bit_errors']:
                emit('impaired_window', phase=p, result=r)
            if p == 2:
                mcs, reason = policy.update(r)
                if reason:
                    emit('switch', reason=reason, next_mcs=mcs, first=first)
            first = (first + 32) & 0xFFFFFFFF
        h = health()
        emit('final_health', health=h)
        check_health(h)
        if block['sent']:
            check_counts(block)
        for total in totals:
            check_counts(total)
        emit('complete', elapsed_s=time.monotonic()-start, totals=totals, final=core.snapshot())
    except BaseException as exc:
        emit('failure', error=repr(exc), elapsed_s=time.monotonic()-start,
             totals=totals, final=core.snapshot())
        # Stop new work and reset the finite TX path on a detected failure.
        core.wr(8, core.rd(8) | 8)
        raise


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seconds', type=float, default=1800)
    ap.add_argument('--log', required=True)
    a = ap.parse_args()
    if not 30 <= a.seconds <= 1800:
        ap.error('duration must be30..1800 seconds')
    with open(a.log, 'x') as log:
        run(a.seconds, log)


if __name__ == '__main__':
    main()
