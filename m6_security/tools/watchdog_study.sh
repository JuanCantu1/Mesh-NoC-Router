#!/usr/bin/env bash
# Choosing the watchdog limit: both sides of the trade-off, measured.
#
#  (a) FALSE ALARMS. How long do HONEST tiles ever leave a flit waiting at
#      their ejection port with no credit? Coherence endpoints legitimately
#      stall (a home can't accept a request until it has room for the snoop
#      it owes). Protocol traffic, 3 VNs, every outstanding-transaction
#      level from M5's study x 8 seeds; the routers report the longest
#      starvation any watchdog counted. The limit must sit well above it.
#  (b) DAMAGE WINDOW. Until the watchdog fires, a black hole is free to
#      back traffic up. The center tile turns black hole at cycle 1000 --
#      the start of the measurement window, mid-operation -- under uniform
#      traffic at 0.30 offered load, for several limits and unprotected:
#      victim latency vs. limit.
#
# Usage: tools/watchdog_study.sh   (~6 min)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p sim results
JOBS=${JOBS:-16}
RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/vc_router.sv rtl/vc_mesh.sv"
LOGDIR=sim/wd_logs
rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"
LIMITS="32 64 128 256 512 1024"
SWEEP_CFG="-DSWEEP_VCS_PER_VN=4 -DSWEEP_BUFFER_DEPTH=2 -DSWEEP_SA_ITERS=2"

iverilog -g2012 -DPROTO_NUM_VNS=3 -o sim/wd_proto.vvp $RTL tb/protocol_tb.sv
for w in $LIMITS; do
  iverilog -g2012 $SWEEP_CFG -DSWEEP_WD_LIMIT=$w -o sim/wd_sweep_$w.vvp $RTL tb/latency_sweep_tb.sv
done
iverilog -g2012 $SWEEP_CFG -DSWEEP_SECURE=0 -o sim/wd_sweep_open.vvp $RTL tb/latency_sweep_tb.sv

{
  for o in 2 4 8 16 32 64; do for s in 1 2 3 4 5 6 7 8; do echo "a $o $s"; done; done
  echo "b none x"
  echo "b open x"
  for w in $LIMITS; do echo "b $w x"; done
} | xargs -P "$JOBS" -n 3 bash -c '
  L='"$LOGDIR"'
  if [ "$0" = a ]; then
    vvp sim/wd_proto.vvp +NODUMP +CYCLES=5000 +OUTSTANDING=$1 +SEED=$2 > $L/a_o$1_s$2.log 2>&1
  elif [ "$1" = none ]; then
    vvp sim/wd_sweep_256.vvp +NODUMP +PATTERN=0 +RATE=300 > $L/b_none.log 2>&1
  elif [ "$1" = open ]; then
    vvp sim/wd_sweep_open.vvp +NODUMP +PATTERN=0 +RATE=300 +BLACKHOLE=4 +BH_START=1000 +EXPECT_COMPROMISE > $L/b_open.log 2>&1
  else
    vvp sim/wd_sweep_$1.vvp +NODUMP +PATTERN=0 +RATE=300 +BLACKHOLE=4 +BH_START=1000 > $L/b_$1.log 2>&1
  fi'

OUT=results/watchdog_study.csv
echo "part,outstanding_or_limit,seed,max_honest_stall,victim_avg_latency,victim_p99_latency,victim_lost,detection_delay,discarded,verdict" > "$OUT"
bad=0
for o in 2 4 8 16 32 64; do for s in 1 2 3 4 5 6 7 8; do
  f=$LOGDIR/a_o${o}_s$s.log
  st=$(grep -oE 'longest honest ejection stall seen [0-9]+' "$f" | grep -oE '[0-9]+$' || echo -1)
  v=$(grep -oE '^(PASS|FAIL)' "$f" || echo MISSING)
  [ "$v" = PASS ] || { echo "  honest run failed: $f"; bad=$((bad + 1)); }
  echo "a,$o,$s,$st,,,,,,$v" >> "$OUT"
done; done
base=$(grep '^CSV,' $LOGDIR/b_none.log | cut -d, -f10,13 | tr , /)
for w in open $LIMITS; do
  f=$LOGDIR/b_$w.log
  csv=$(grep '^CSV,' "$f")
  atk=$(grep '^ATTACK,' "$f")
  v=$(grep -oE '^ATTACK-(PASS|FAIL)' "$f" || echo MISSING)
  [ "$v" = ATTACK-PASS ] || { echo "  unexpected outcome: $f"; bad=$((bad + 1)); }
  avg=$(echo "$csv" | cut -d, -f10); p99=$(echo "$csv" | cut -d, -f13)
  lost=$(echo "$atk" | cut -d, -f10); qc=$(echo "$atk" | cut -d, -f14); disc=$(echo "$atk" | cut -d, -f12)
  if [ "$qc" -ge 0 ]; then delay=$((qc - 1000)); else delay=never; fi
  echo "b,$w,,,$avg,$p99,$lost,$delay,$disc,$v" >> "$OUT"
done

echo "Wrote $OUT"
echo
echo "(a) Longest honest ejection stall (protocol traffic, 3 VNs, 8 seeds per level):"
awk -F, '$1 == "a" { if ($4 > m[$2]) m[$2] = $4; if (!($2 in seen)) { seen[$2] = 1; o[++n] = $2 } }
  END { for (i = 1; i <= n; i++) printf "    %2d outstanding per requester: %4d cycles\n", o[i], m[o[i]] }' "$OUT"
echo
echo "(b) Center tile turns black hole at cycle 1000, 0.30 load (victims with no attack: avg/p99 latency $base cycles)"
awk -F, '$1 == "b" {
    nm = ($2 == "open") ? "unprotected" : "WD_LIMIT " $2
    printf "    %-14s detected after %5s cycles; victim latency avg %8s, p99 %5s; victim packets lost %5s; %4s discarded\n", nm, $8, $5, $6, $7, $9
  }' "$OUT"
echo
if [ "$bad" -ne 0 ]; then echo "WATCHDOG STUDY FAILED: $bad run(s)"; exit 1; fi
echo "WATCHDOG STUDY PASSED"
