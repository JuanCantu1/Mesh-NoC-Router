#!/usr/bin/env bash
# Latency / throughput sweep for vc_mesh.sv across router configurations.
#
# For every configuration in CONFIGS, compiles tb/latency_sweep_tb.sv once,
# then runs it at every offered load in RATES for every pattern in
# PATTERNS, in parallel, and collects everything into one CSV. Every point
# is also a full correctness run; the script exits non-zero if any point
# reports an error or produces no result.
#
# Usage: tools/sweep.sh
#   CONFIGS="1:1:4 1:2:2:2" router configs, each NUM_VNS:VCS_PER_VN:BUFFER_DEPTH[:SA_ITERS]
#                           (SA_ITERS defaults to 1; default set: the VC study below)
#   PATTERNS="0 1 2 3"      traffic patterns (default: 0 = uniform random)
#   OUT=results/x.csv       output file (default results/vc_sweep.csv)
#   JOBS=N                  parallel simulations (default 16)
#
# Default configurations -- the virtual-channel study (all one VN, since
# sweep traffic is a single message class), each with a 1-pass and a
# 2-pass switch allocator:
#   1:1:4  baseline: M4's router (one 4-flit FIFO per port)
#   1:2:2  2 VCs x 2 flits  -- same storage as the baseline
#   1:1:8  1 VC  x 8 flits  -- double storage, spent on depth
#   1:2:4  2 VCs x 4 flits  -- double storage, spent on VCs
#   1:4:2  4 VCs x 2 flits  -- double storage, spent on more VCs
#   1:4:4  4 VCs x 4 flits  -- quadruple storage
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p sim results

DEFAULT_CONFIGS=""
for c in 1:1:4 1:2:2 1:1:8 1:2:4 1:4:2 1:4:4; do
  for it in 1 2; do DEFAULT_CONFIGS="$DEFAULT_CONFIGS $c:$it"; done
done
CONFIGS=${CONFIGS:-$DEFAULT_CONFIGS}
PATTERNS=${PATTERNS:-"0"}
RATES=$(seq 50 50 1000)
JOBS=${JOBS:-16}
OUT=${OUT:-results/vc_sweep.csv}
LOGDIR=sim/sweep_logs
RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/vc_router.sv rtl/vc_mesh.sv"

# "1:2:4" -> "1_2_4_1": file-name tag for a config (SA_ITERS defaults to 1)
tag() { IFS=: read -r a b c d <<< "$1"; echo "${a}_${b}_${c}_${d:-1}"; }

rm -rf "$LOGDIR"
mkdir -p "$LOGDIR"

for c in $CONFIGS; do
  IFS=_ read -r vns vcs depth iters <<< "$(tag "$c")"
  iverilog -g2012 -DSWEEP_NUM_VNS="$vns" -DSWEEP_VCS_PER_VN="$vcs" \
    -DSWEEP_BUFFER_DEPTH="$depth" -DSWEEP_SA_ITERS="$iters" \
    -o "sim/sweep_$(tag "$c").vvp" $RTL tb/latency_sweep_tb.sv 2>/dev/null
done

npoints=$(( $(echo $CONFIGS | wc -w) * $(echo $PATTERNS | wc -w) * $(echo $RATES | wc -w) ))
echo "Running $npoints sweep points with $JOBS parallel jobs..."
for c in $CONFIGS; do
  for p in $PATTERNS; do for r in $RATES; do echo "$(tag "$c") $p $r"; done; done
done | xargs -P "$JOBS" -n 3 bash -c \
  'vvp "sim/sweep_$0.vvp" +PATTERN=$1 +RATE=$2 +NODUMP > "'"$LOGDIR"'/c$0_p$1_r$2.log" 2>&1'

echo "num_vns,vcs_per_vn,buffer_depth,sa_iters,pattern,rate_permille,offered,accepted,avg_total_latency,avg_network_latency,p50_total_latency,p99_total_latency,max_total_latency,measured_delivered,saturated,errors,reordered_pct" > "$OUT"
missing=0
for c in $CONFIGS; do
  for p in $PATTERNS; do
    for r in $RATES; do
      log="$LOGDIR/c$(tag "$c")_p${p}_r${r}.log"
      line=$(grep '^CSV,' "$log" | sed 's/^CSV,//' || true)
      if [ -z "$line" ]; then
        echo "MISSING result for config=$c pattern=$p rate=$r -- see $log"
        missing=$((missing + 1))
      else
        echo "$line" >> "$OUT"
      fi
    done
  done
done

errors=$(awk -F, 'NR > 1 && $16 != 0' "$OUT" | wc -l)

echo
echo "Wrote $OUT"
echo
# Summary per (config, pattern). Knee = highest offered load whose average
# latency stays within 3x zero-load (same definition as M4).
awk -F, '
  BEGIN { split("uniform transpose bit-complement hotspot", name, " ") }
  NR == 1 { next }
  {
    k = $1 "x" $2 "x" $3 "x" $4 " " $5
    if (!(k in zero)) {
      zero[k] = $9; order[++n] = k; pat[k] = $5 + 1; storage[k] = $1 * $2 * $3
      cfg[k] = $1 " VN x " $2 " VC x " $3 ", " $4 "-pass SA"
    }
    if ($8 > peak[k]) peak[k] = $8
    if (!past[k] && $9 <= 3 * zero[k]) { knee[k] = $7 } else past[k] = 1
    if ($17 > maxreo[k]) maxreo[k] = $17
  }
  END {
    printf "%-28s %-15s %10s %10s %6s %14s %12s\n", "config", "pattern", "flits/port", "zero-load", "knee", "peak accepted", "max reorder"
    for (i = 1; i <= n; i++) {
      k = order[i]
      printf "%-28s %-15s %10d %10.2f %6.2f %14.3f %11.2f%%\n", cfg[k], name[pat[k]], storage[k], zero[k], knee[k], peak[k], maxreo[k]
    }
  }' "$OUT"
echo

if [ "$missing" -ne 0 ] || [ "$errors" -ne 0 ]; then
  echo "SWEEP FAILED: $missing missing point(s), $errors point(s) reporting correctness errors"
  awk -F, 'NR > 1 && $16 != 0 { print "  config=" $1 ":" $2 ":" $3 ":" $4 " pattern=" $5 " rate=" $6 " errors=" $16 }' "$OUT"
  exit 1
fi
echo "SWEEP PASSED: every point delivered every packet correctly, no invariant violations, network drained after load"
