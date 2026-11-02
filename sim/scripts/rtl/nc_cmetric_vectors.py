"""Vectors and fixed-point reference for ofdm_rxs_cmetric (tb_nc_cmetric.sv).

  python -I -B scripts/rtl/nc_cmetric_vectors.py <out_dir>

Stimulus (stim.mem, one word per cycle):
  [31:0] data, then a control word per cycle:
  ctrl bits: 0 valid, 7:1 ord, 8 qam, 9 null, 10 hdr, 11 usable, 12 sym_last,
             13 clear, 14 freeze, 15 rd_req, 24:16 rd_addr
Expected (expect.mem): for every AXI read in issue order the 32-bit value the
reference holds at the time the request is accepted, then the final 384 words
of banks 0..2 and the two symbol counters.  Reads are only issued when the
address is not pending in the pipeline (the bench never reads an ord within 8
cycles of an update to it), so the expected value is well defined.
"""
import json
import sys
from pathlib import Path

import numpy as np

QPSK, LOW, HIGH, THR = 11585, 5181, 15543, 10362
CLEAR_CYCLES = 385


def term(i, q, qam, null, hdr):
    def err(a):
        if null and not hdr:
            ref = 0
        elif qam and not hdr:
            ref = LOW if a < THR else HIGH
        else:
            ref = QPSK
        return a - ref
    return (err(abs(i)) ** 2 + err(abs(q)) ** 2) >> 12


def main():
    out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=False)
    rng = np.random.default_rng(20261025)
    mem = [0] * 384
    syms = [0, 0]
    data_w, ctrl_w, expect_reads = [], [], []
    last_touch = {}
    cycle = 0
    clearing_until = CLEAR_CYCLES + 2            # reset clear
    pending = []                                  # (apply_cycle, addr, kind, value)

    def emit(data, ctrl):
        data_w.append(data & 0xFFFFFFFF); ctrl_w.append(ctrl)

    def flush(upto):
        nonlocal pending
        keep = []
        for c, addr, kind, val in pending:
            if c <= upto:
                if kind == 'erase':
                    mem[addr] = min(0xFFFF, mem[addr] + 1)
                else:
                    mem[addr] = min(0xFFFFFFFF, mem[addr] + val)
            else:
                keep.append((c, addr, kind, val))
        pending = keep

    for _ in range(clearing_until):
        emit(0, 0); cycle += 1
    freeze = False
    total = 30000
    directed = [27000, 27600]                                 # clear coincident with a counter update
    while cycle < total:
        flush(cycle)
        if directed and cycle >= directed[0]:
            # independent review F2: a symbol-last element followed two cycles later by clear makes the
            # clear and the symbol-counter update happen on the same edge; the clear must win.
            hdr = directed[0] == 27000
            directed.pop(0)
            freeze = False
            emit(0, 1 | (5 << 1) | (hdr << 10) | (1 << 11) | (1 << 12))
            emit(0, 0)
            emit(0, 0)
            emit(0, 1 << 13)
            cycle += 4
            mem = [0] * 384; syms = [0, 0]; pending = []
            for _ in range(CLEAR_CYCLES + 2):
                emit(0, 0); cycle += 1
            continue
        r = rng.random()
        if r < 0.002 and 2000 < cycle < 26000:               # random clear (none after the directed ones)
            emit(0, 1 << 13)
            flush(cycle + 10)
            mem = [0] * 384; syms = [0, 0]; pending = []
            cycle += 1
            for _ in range(CLEAR_CYCLES + 2):
                emit(0, 0); cycle += 1
            continue
        if r < 0.004:
            freeze = not freeze
        ctrl = (1 << 14) if freeze else 0
        if rng.random() < 0.6:
            ordv = int(rng.integers(0, 88))
            hdr = rng.random() < 0.25
            qam = rng.random() < 0.5
            null = rng.random() < 0.15
            usable = rng.random() > 0.08
            last = rng.random() < 0.05
            # occasional extreme values and saturation-prone large errors
            scale = 40000 if rng.random() < 0.02 else 20000
            i = int(np.clip(rng.normal(0, scale), -32768, 32767))
            q = int(np.clip(rng.normal(0, scale), -32768, 32767))
            if last_touch.get(ordv, -100) > cycle - 6:        # keep same-ord spacing realistic (>=6)
                emit(0, ctrl); cycle += 1; continue
            ctrl |= 1 | (ordv << 1) | (qam << 8) | (null << 9) | (hdr << 10) | (usable << 11) | (last << 12)
            emit(((q & 0xFFFF) << 16) | (i & 0xFFFF), ctrl)
            if not freeze:
                last_touch[ordv] = cycle
                bank = 2 if not usable else (0 if hdr else 1)
                if not usable:
                    pending.append((cycle + 5, bank * 128 + ordv, 'erase', 1))
                else:
                    pending.append((cycle + 5, bank * 128 + ordv, 'err', term(i, q, qam, null, hdr)))
                if last:
                    syms[0 if hdr else 1] += 1
        else:
            # AXI read of an ord not touched in the last 10 cycles (all banks)
            if rng.random() < 0.3:
                bank = int(rng.integers(0, 3)); ordv = int(rng.integers(0, 88))
                if last_touch.get(ordv, -100) <= cycle - 10:
                    flush(cycle)
                    ctrl |= (1 << 15) | ((bank * 128 + ordv) << 16)
                    expect_reads.append(mem[bank * 128 + ordv])
                    emit(0, ctrl); cycle += 1
                    for _ in range(6):                          # bench waits for rd_valid
                        emit(0, (1 << 14) if freeze else 0); cycle += 1
                    continue
            emit(0, ctrl)
        cycle += 1
    for _ in range(20):
        emit(0, 0)
    flush(10 ** 9)
    final = mem + [syms[0], syms[1]]
    (out / 'stim.mem').write_text(''.join('%08x\n%08x\n' % (d, c) for d, c in zip(data_w, ctrl_w)))
    (out / 'expect.mem').write_text(''.join('%08x\n' % v for v in expect_reads + final))
    info = dict(cycles=len(data_w), reads=len(expect_reads), final_words=len(final))
    (out / 'info.json').write_text(json.dumps(info))
    print(json.dumps(info))


if __name__ == '__main__':
    main()
