#!/bin/sh
# Live demo for the contest video (NC image, BRINGUP-026 wiring: TX1->RF1, TX2->RF2, COM->RX1).
#   Part A: fixed QPSK without masking (reference), tone switched on and off during the run
#   Part B: joint policy v2.2 + pre-transmission sensing, tone switched on and off during the run
#   Part C: joint policy v2.2 + pre-transmission sensing, tone already on before the first frame
# In parts A and B lean_adapt.py switches the TX2 tone between bursts; demo_view.py prints a readable
# status line about every 0.3 s from the log lean_adapt.py writes.  Nothing is simulated.
#   cd /root/lean && sh demo_live.sh            (ASCII=1 sh demo_live.sh for English labels)
# Optional: FREQ (Hz, default 21600000 = +22.5 subcarriers), ATT2 (dB, default 17.95), SCALE (default 0.1)
set -u
cd /root/lean || exit 1
FREQ=${FREQ:-21600000}
ATT2=${ATT2:-17.95}
SCALE=${SCALE:-0.1}
VIEW="python3 demo_view.py"
[ -n "${ASCII:-}" ] && VIEW="python3 demo_view.py --ascii"

tx=; phy=
for d in /sys/bus/iio/devices/iio:device*; do
    n=$(cat "$d/name" 2>/dev/null)
    [ "x$n" = xaxi-adrv9009-tx-hpc ] && tx=$d
    [ "x$n" = xadrv9009-phy ] && phy=$d
done
[ -n "$tx" ] && [ -n "$phy" ] || { echo "IIO devices not found"; exit 1; }

safe_off() {
    for f in "$tx"/out_altvoltage*_scale; do echo 0 > "$f"; done
    python3 -c 'import lean_ctl as L; L.tx_data_select(2, 3)' > /dev/null
    echo -41.95 > "$phy/out_voltage0_hardwaregain"
    echo -41.95 > "$phy/out_voltage1_hardwaregain"
    python3 -c 'from lean_ctl import Core; Core().wr(0x008, 10)'
}
trap safe_off EXIT INT TERM

python3 -c 'from lean_stability import health; t=health()["temperature_mc"]; print("temperature %.1f C" % (t/1000)); assert t < 70000, "too hot, check the fan"' || exit 1
python3 lean_ctl.py init --lo 3000000000 --tx-atten 4 --tx-gain 2 --rx-gain 1 > /dev/null || exit 1
echo -41.95 > "$phy/out_voltage1_hardwaregain"
python3 -c 'from lean_ctl import Core; c=Core(); c.wr(0x008, 3); c.wr(0x030, (16 << 20) | (720 << 8) | 12)'
python3 lean_ctl.py rx --enable 1 --prbs 1 --reset > /dev/null || exit 1
# Every DDS tone off first (the TX2 F2 tone keeps its boot default otherwise), then the demo tone (F1).
for f in "$tx"/out_altvoltage*_scale; do echo 0 > "$f"; done
echo "$FREQ" > "$tx/out_altvoltage4_TX2_I_F1_frequency"; echo 90000 > "$tx/out_altvoltage4_TX2_I_F1_phase"
echo "$FREQ" > "$tx/out_altvoltage6_TX2_Q_F1_frequency"; echo 0 > "$tx/out_altvoltage6_TX2_Q_F1_phase"
echo "-$ATT2" > "$phy/out_voltage1_hardwaregain"

# $1 title, $2 windows, $3 tone-on window, $4 tone-off window ("-" = no schedule, tone already on), rest: policy
run_part() {
    title=$1; n=$2; on=$3; off=$4; shift 4
    mkdir -p demo_logs; log=demo_logs/demo_$(date +%H%M%S)_$$.jsonl
    if [ "$on" = - ]; then sched=""; vopt="--tone-on-always"
    else sched="--tone-on $on --tone-off $off --tone-scale $SCALE"; vopt=""; fi
    python3 lean_adapt.py --windows "$n" --frames 16 --len 2048 --allow-fft-saturation $sched "$@" --log "$log" > "$log.out" 2>&1 &
    pid=$!
    $VIEW "$log" --pid "$pid" --title "$title" $vopt
    wait "$pid" || { echo "lean_adapt.py exit $? (see $log.out)"; tail -2 "$log.out"; }
}

J="--policy joint2 --calibration lean_calibration_flat.json --olla-target 0.05 --sense"
if [ -n "${ASCII:-}" ]; then
    TA="A. Reference: fixed QPSK, no masking"
    TB="B. Joint v2.2 + sensing, tone on/off during the run"
    TC="C. Joint v2.2 + sensing, tone on before the first frame"
else
    TA="A. 对照：固定 QPSK，不屏蔽"
    TB="B. 联合策略 v2.2 + 发射前频谱感知：运行中开关单音"
    TC="C. 联合策略 v2.2 + 发射前频谱感知：首帧前单音已存在"
fi
run_part "$TA" 2500 800 1700 --fixed 0
sleep 2
run_part "$TB" 1000 300 700 $J
sleep 2
echo "$SCALE" > "$tx/out_altvoltage4_TX2_I_F1_scale"; echo "$SCALE" > "$tx/out_altvoltage6_TX2_Q_F1_scale"
python3 -c 'import lean_ctl as L; L.tx_data_select(2, 0)' > /dev/null
run_part "$TC" 300 - - $J
