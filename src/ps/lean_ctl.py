#!/usr/bin/env python3
"""Board-side control of the route-B lean OFDM core (Kuiper Linux, root).

Register map: docs/interfaces/lean_core_registers_2026-10-21.md.
Examples:
  lean_ctl.py id
  lean_ctl.py rx --enable 1 --gain 2 --floor 524288
  lean_ctl.py burst --frames 32 --len 256 --mcs 0 --first 1
  lean_ctl.py run --bursts 40 --frames 32 --len 4096 --mcs 0      # sustained BER/PER
  lean_ctl.py stats
"""
import argparse
import json
import mmap
import os
import struct
import sys
import time

BASE = 0x43C30000
SPAN = 0x1000
SNAP_NAMES = [
    "tx_issued", "tx_queued", "tx_samples", "detections", "rx_frames", "train_ok",
    "train_reject", "header_fail", "crc_ok", "crc_fail", "truncated", "bit_err_lo",
    "bit_err_hi", "cmp_lo", "cmp_hi", "ring_overruns", "fft_saturations", "candidate_drops",
    "long_plateaus", "cpe_undefined", "rx_samples", "last_id", "last_info", "last_ber",
    "last_step", "last_start", "ok_qpsk", "ok_16qam", "dropped_symbols",
    "evm_cum", "carriers_cum", "last_evm"]


class Core:
    def __init__(self):
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.mem = mmap.mmap(fd, SPAN, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)
        os.close(fd)

    def rd(self, off):
        return struct.unpack_from("<I", self.mem, off)[0]

    def wr(self, off, value):
        struct.pack_into("<I", self.mem, off, value & 0xFFFFFFFF)

    def snapshot(self):
        self.wr(0x040, 1)
        s = {n: self.rd(0x080 + 4 * i) for i, n in enumerate(SNAP_NAMES)}
        s["bit_errors"] = s.pop("bit_err_lo") | (s.pop("bit_err_hi") << 32)
        s["compared_bits"] = s.pop("cmp_lo") | (s.pop("cmp_hi") << 32)
        info = s["last_info"]
        s["last_len"], s["last_mcs"], s["last_reason"] = (info >> 4) & 0x1FFF, (info >> 17) & 1, (info >> 20) & 0xF
        step = s["last_step"] - (1 << 32) if s["last_step"] & 0x80000000 else s["last_step"]
        s["last_cfo_subcarriers"] = step * 128 / 2 ** 32
        s["status"] = self.rd(0x044)
        return s


# Official axi_adrv9009_tx transport core.  The developer route feeds its
# DMA-side input (dac_data_0/1), so channels 0/1 must select DAC_DATA_SEL=2
# (input data); the IIO driver leaves them on DDS (0) or zero (3) unless a
# TX buffer is enabled, and writing an IIO DDS attribute may switch them back.
# Channels 2/3 (TX2, unused here) are set to ZERO (3): the default 40 MHz DDS
# tone on TX2 couples into RX1 (BRINGUP-016).
TX_TPL_BASE = 0x44A04000


def tx_data_select(value, unused=3):
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=TX_TPL_BASE)
    os.close(fd)
    for ch in range(4):
        struct.pack_into("<I", m, 0x418 + 0x40 * ch, value if ch < 2 else unused)
    return [struct.unpack_from("<I", m, 0x418 + 0x40 * ch)[0] & 0xF for ch in range(4)]


def phy_dir():
    for d in sorted(os.listdir("/sys/bus/iio/devices")):
        path = os.path.join("/sys/bus/iio/devices", d)
        try:
            if open(os.path.join(path, "name")).read().strip() == "adrv9009-phy":
                return path
        except OSError:
            pass
    raise RuntimeError("adrv9009-phy not found")


def phy_read(attr):
    return open(os.path.join(phy_dir(), attr)).read().strip()


def phy_write(attr, value):
    with open(os.path.join(phy_dir(), attr), "w") as f:
        f.write(str(value))


def set_lo(hz):
    """Retune TRX LO and re-run the init calibrations there (the boot-time ones
    were made at the device-tree LO).  The DDS driver may reselect DAC sources,
    so tx_data_select() must follow."""
    phy_write("out_altvoltage0_TRX_LO_frequency", hz)
    time.sleep(0.5)
    for attr in ("calibrate_rx_qec_en", "calibrate_tx_qec_en", "calibrate_tx_lol_en"):
        phy_write(attr, 1)
    phy_write("calibrate", 1)
    return {"lo_hz": int(phy_read("out_altvoltage0_TRX_LO_frequency")), "calibrated": True}


def evm_percent(evm_sum, carriers):
    """evm_sum = sum |e|^2 (F14) >> 16; unit constellation energy is 2^28."""
    return None if carriers == 0 else 100 * (evm_sum / (carriers * 4096.0)) ** 0.5


def cmd_rx(core, a):
    ctrl = core.rd(0x008)
    if a.enable is not None:
        ctrl = (ctrl & ~1) | (a.enable & 1)
    if a.prbs is not None:
        ctrl = (ctrl & ~2) | ((a.prbs & 1) << 1)
    if a.gain is not None:
        core.wr(0x024, a.gain)
    if a.floor is not None:
        core.wr(0x028, a.floor)
    if a.min_energy is not None:
        core.wr(0x02C, a.min_energy)
    if a.reset:
        core.wr(0x008, ctrl | 4)
        time.sleep(0.001)
    core.wr(0x008, ctrl & ~4)


def start_burst(core, frames, length, mcs, first, epoch=0):
    if not (1 <= frames <= 32 and 0 <= length <= 4096 and mcs in (0, 1)):
        raise ValueError("invalid frames (1..32), length (0..4096), or MCS (0/1)")
    if not (0 <= first <= 0xFFFFFFFF and 0 <= epoch <= 0xFFFF):
        raise ValueError("frame ID or epoch out of range")
    core.wr(0x010, frames)
    core.wr(0x014, first)
    core.wr(0x018, length)
    core.wr(0x01C, mcs)
    core.wr(0x020, epoch)
    core.wr(0x00C, 1)


def wait_done(core, timeout=2.0):
    if timeout <= 0:
        raise ValueError("timeout must be positive")
    t0 = time.monotonic()
    st = 0
    while time.monotonic() - t0 < timeout:
        st = core.rd(0x044)
        # done/aborted/fault belong to this burst only once the TX FSM is in
        # T_RUN (3); before that they may still show the previous burst.
        if (st >> 13) & 7 == 3:
            if st & ((1 << 5) | (3 << 6) | (1 << 8) | (1 << 10) | (1 << 11)):
                raise RuntimeError("burst abort/fault: status=0x%08x" % st)
            if st & (1 << 4):
                return st
        time.sleep(0.0005)
    raise TimeoutError("burst completion timeout: status=0x%08x" % st)


def measurement(before, after, frames, length, elapsed):
    """Short-window modular counters; resets/multiple wraps invalidate a window."""
    if frames <= 0 or elapsed <= 0:
        raise ValueError("positive frame count and elapsed time required")
    d = lambda k, width=32: (after[k] - before[k]) & ((1 << width) - 1)
    ok, failed, truncated = d('crc_ok'), d('crc_fail'), d('truncated')
    bits, errors = d('compared_bits', 64), d('bit_errors', 64)
    if ok + failed + truncated > frames or errors > bits or bits > frames * length * 8:
        raise ValueError("inconsistent counters: reset, overlap, or unexpected frames")
    return dict(sent=frames, ok=ok, crc_fail=failed, header_fail=d('header_fail'),
                truncated=truncated, per=1 - ok / frames,
                compared_bits=bits, bit_errors=errors, ber=errors / bits if bits else None,
                evm=evm_percent(d('evm_cum'), d('carriers_cum')),
                goodput_mbps=ok * length * 8 / elapsed / 1e6, elapsed_s=elapsed)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("id")
    i = sub.add_parser("init", help="TX1 I/Q (DAC channels 0/1) of the official TX core <- its DMA input (this core); TX2 -> zero")
    i.add_argument("--lo", type=int, help="TRX LO in Hz; re-runs RX/TX QEC and TX LOL init calibration (BRINGUP-017: 3000000000)")
    i.add_argument("--tx-atten", type=float, help="TX1 attenuation in dB (0..41.95)")
    i.add_argument("--tx-gain", type=int, choices=(0, 1, 2, 3), help="core TX digital gain <<n (0x038)")
    i.add_argument("--rx-gain", type=int, help="core RX gain shift (0x024)")
    sub.add_parser("stats")
    r = sub.add_parser("rx")
    r.add_argument("--enable", type=int)
    r.add_argument("--prbs", type=int)
    r.add_argument("--gain", type=int)
    r.add_argument("--floor", type=int)
    r.add_argument("--min-energy", type=int)
    r.add_argument("--reset", action="store_true")
    for name in ("burst", "run"):
        b = sub.add_parser(name)
        b.add_argument("--frames", type=int, default=32)
        b.add_argument("--len", type=int, default=256)
        b.add_argument("--mcs", type=int, default=0)
        b.add_argument("--first", type=int, default=1)
        if name == "run":
            b.add_argument("--bursts", type=int, default=10)
    a = ap.parse_args()
    core = Core()
    if a.cmd == "init":
        out = {}
        if a.lo is not None:
            out.update(set_lo(a.lo))
        if a.tx_atten is not None:
            phy_write("out_voltage0_hardwaregain", "%.2f" % -abs(a.tx_atten))
            out["tx_hardwaregain"] = phy_read("out_voltage0_hardwaregain")
        if a.tx_gain is not None:
            core.wr(0x038, a.tx_gain)
        if a.rx_gain is not None:
            core.wr(0x024, a.rx_gain)
        out.update(tx_data_sel=tx_data_select(2), tx_gain=core.rd(0x038), rx_gain=core.rd(0x024))
        print(json.dumps(out))
    elif a.cmd == "id":
        print(json.dumps({"id": hex(core.rd(0x000)), "version": hex(core.rd(0x004)), "status": hex(core.rd(0x044))}))
    elif a.cmd == "stats":
        print(json.dumps(core.snapshot()))
    elif a.cmd == "rx":
        cmd_rx(core, a)
        print(json.dumps({"ctrl": core.rd(0x008), "status": hex(core.rd(0x044))}))
    else:
        bursts = 1 if a.cmd == "burst" else a.bursts
        before = core.snapshot()
        t0 = time.monotonic()
        sent = 0
        for k in range(bursts):
            start_burst(core, a.frames, a.len, a.mcs, a.first + k * a.frames)
            st = wait_done(core)
            sent += a.frames
            if st & (1 << 5) or st & (3 << 6):
                print(json.dumps({"burst": k, "error_status": hex(st)}))
                break
        time.sleep(0.01)
        after = core.snapshot()
        elapsed = time.monotonic() - t0
        d = measurement(before, after, sent, a.len, elapsed)
        d.update(crc_ok=d['ok'], evm_percent=d['evm'], before=before, after=after,
                 last_cfo_subcarriers=after["last_cfo_subcarriers"], status=hex(after["status"]))
        print(json.dumps(d))


if __name__ == "__main__":
    sys.exit(main())
