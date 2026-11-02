"""Model goodput (estimate) for typical impairment scenarios; writes scenario_table.json."""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import joint_policy as jp  # noqa: E402

cal = jp.Calibration(HERE.parent / "innovation_a/results/calibration.json")


def e(default, **groups):
    x = [default] * jp.GROUPS
    for k, v in groups.items():
        x[int(k[1:])] = v
    return x


SCENARIOS = {
    "clean": e(2.0),
    "one group destroyed": e(2.0, g7=60.0),
    "two groups destroyed": e(2.0, g7=60.0, g8=60.0),
    "uniform mid SNR": e(12.0),
    "mid SNR + one destroyed": e(12.0, g3=60.0),
    "weak tone (one group 4%)": e(2.0, g7=4.0),
}
rows = []
# Only (mode, mask) pairs whose L_max carries the frame length are legal (B section 3);
# 2048 bytes is the stage-2 experiment length (B section 10.4).
for length in (2048, 4096):
    print(f"frame length {length} B: fixed QPSK, fixed 16QAM, modulation only, mask only (16QAM), joint")
    for name, ev in SCENARIOS.items():
        s = jp.group_snr(cal, 0, ev)
        g = lambda m, mask: jp.goodput(cal, m, s, frozenset(mask), length, 16, 2.5e-3) / 1e6  # noqa: E731
        ok = lambda m, mask: length <= jp.l_max(len(mask), m)  # noqa: E731
        fixed_q, fixed_16 = g(0, []), g(1, [])
        mode, mask, _ = jp.JointPolicy(cal, length=length).decide(0, ev, 16)
        rows.append({"length": length, "scenario": name, "fixed_qpsk": fixed_q, "fixed_16qam": fixed_16,
                     "modulation_only": max(fixed_q, fixed_16),
                     "mask_only_16qam": max(g(1, m) for m in jp.candidates(s) if ok(1, m)),
                     "joint": max(g(m, k) for m in (0, 1) for k in jp.candidates(s) if ok(m, k)),
                     "joint_choice": {"mode": "16QAM" if mode else "QPSK", "masked_groups": sorted(mask)}})
        r = rows[-1]
        print(f"  {name:28s} {r['fixed_qpsk']:6.1f} {r['fixed_16qam']:6.1f} {r['modulation_only']:6.1f} "
              f"{r['mask_only_16qam']:6.1f} {r['joint']:6.1f}  {r['joint_choice']}")
(HERE / "scenario_table.json").write_text(json.dumps(rows, indent=1), encoding="utf-8")
