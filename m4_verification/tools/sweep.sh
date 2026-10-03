#!/usr/bin/env bash
# Latency / throughput sweep for mesh_credit.sv.
#
# Compiles tb/latency_sweep_tb.sv once, then runs it at every offered load
# in RATES (packets per tile per 1000 cycles) for all four traffic
# patterns, in parallel, and collects results/latency_sweep.csv.
#
# Every sweep point is also a correctness run (misrouting, loss,
# duplication, reordering, RTL invariants, drain-after-load deadlock
# check). This script exits non-zero if ANY point reports an error or
# fails to produce a result -- a sweep that "looks fine" on a plot but
# silently dropped packets somewhere is worse than no sweep.
#
# Usage: tools/sweep.sh
#   JOBS=N          parallel simulations (default 16)
#   DEPTH=N         input FIFO depth (default 4). Non-default depths write
#                   results/latency_sweep_depth<N>.csv, leaving the
#                   baseline CSV (the one plot_sweep.py reads) untouched.
#   PATTERNS="0 2"  subset of patterns (default all four)
#
# Example -- is uniform-random saturation buffer-limited?
#   DEPTH=8 PATTERNS=0 tools/sweep.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p sim results

DEPTH=${DEPTH:-4}
PATTERNS=${PATTERNS:-"0 1 2 3"}
RATES=$(seq 50 50 1000)
JOBS=${JOBS:-16}

RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/router.sv rtl/mesh_credit.sv"
VVP=sim/latency_sweep_tb_d$DEPTH.vvp
iverilog -g2012 -DSWEEP_BUFFER_DEPTH=$DEPTH -o "$VVP" $RTL tb/latency_sweep_tb.sv 2>/dev/null

LOGDIR=sim/sweep_logs/d$DEPTH
rm -rf "$LOGDIR"
mkdir -p "$LOGDIR"

echo "Running $(( $(echo $PATTERNS | wc -w) * $(echo $RATES | wc -w) )) sweep points (buffer depth $DEPTH) with $JOBS parallel jobs..."
for p in $PATTERNS; do for r in $RATES; do echo "$p $r"; done; done \
  | xargs -P "$JOBS" -n 2 bash -c \
      'vvp "'"$VVP"'" +PATTERN=$0 +RATE=$1 +NODUMP > "'"$LOGDIR"'/p$0_r$1.log" 2>&1'

if [ "$DEPTH" -eq 4 ]; then OUT=results/latency_sweep.csv; else OUT=results/latency_sweep_depth$DEPTH.csv; fi
echo "pattern,rate_permille,offered,accepted,avg_total_latency,avg_network_latency,p50_total_latency,p99_total_latency,max_total_latency,measured_delivered,saturated,errors" > "$OUT"
missing=0
for p in $PATTERNS; do
  for r in $RATES; do
    line=$(grep '^CSV,' "$LOGDIR/p${p}_r${r}.log" | sed 's/^CSV,//' || true)
    if [ -z "$line" ]; then
      echo "MISSING result for pattern=$p rate=$r -- see $LOGDIR/p${p}_r${r}.log"
      missing=$((missing + 1))
    else
      echo "$line" >> "$OUT"
    fi
  done
done

errors=$(awk -F, 'NR > 1 && $12 != 0' "$OUT" | wc -l)

echo
echo "Wrote $OUT"
echo
# Summary. "Knee" uses the common practical definition of saturation: the
# highest offered load whose average latency stays within 3x the
# zero-load latency (measured at the lowest sweep point). The TB's own
# `saturated` column is stricter/blunter (accepted < 95% of offered, or
# measured packets never drained) and can lag the visible knee -- latency
# often explodes well before throughput visibly falls short of offered.
awk -F, '
  BEGIN { split("uniform transpose bit-complement hotspot", name, " ") }
  NR == 1 { next }
  {
    p = $1 + 1
    if (!(p in zero)) zero[p] = $5
    if ($4 > peak[p]) peak[p] = $4
    if (!past[p] && $5 <= 3 * zero[p]) { knee[p] = $3; knee_lat[p] = $5 }
    else past[p] = 1
  }
  END {
    printf "%-15s %14s %28s %15s\n", "pattern", "zero-load lat", "knee (lat <= 3x zero-load)", "peak accepted"
    for (p = 1; p <= 4; p++)
      if (p in zero)
        printf "%-15s %11.2f cy %13.2f pkt/node/cy (%5.1f cy) %11.3f\n", name[p], zero[p], knee[p], knee_lat[p], peak[p]
  }' "$OUT"
echo

if [ "$missing" -ne 0 ] || [ "$errors" -ne 0 ]; then
  echo "SWEEP FAILED: $missing missing point(s), $errors point(s) reporting correctness errors"
  awk -F, 'NR > 1 && $12 != 0 { print "  pattern=" $1 " rate=" $2 " errors=" $12 }' "$OUT"
  exit 1
fi
echo "SWEEP PASSED: every point delivered every packet correctly, no invariant violations, network drained after load"
