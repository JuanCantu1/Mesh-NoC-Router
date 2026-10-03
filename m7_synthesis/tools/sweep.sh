#!/usr/bin/env bash
# Latency / throughput sweep for vc_mesh.sv across router configurations
# (M5's tools/sweep.sh, plus the SECURE switch).
#
# For every configuration in CONFIGS, compiles tb/latency_sweep_tb.sv once,
# then runs it at every offered load in RATES for every pattern in
# PATTERNS, in parallel, and collects everything into one CSV. Every point
# is also a full correctness run -- including "no security alarm ever
# fires on honest traffic". Exits non-zero if any point reports an error
# or produces no result.
#
# Usage: tools/sweep.sh
#   CONFIGS="1:1:4 1:2:2:2" router configs, each NUM_VNS:VCS_PER_VN:BUFFER_DEPTH[:SA_ITERS]
#   PATTERNS="0 1 2 3"      traffic patterns (default: 0 = uniform random)
#   SECURE=0|1              M6 tile-port hardening (default 1)
#   OUT=results/x.csv       output file (default results/sweep.csv)
#   JOBS=N                  parallel simulations (default 16)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p sim results

CONFIGS=${CONFIGS:-"1:4:2:2"}
PATTERNS=${PATTERNS:-"0"}
SECURE=${SECURE:-1}
RATES=$(seq 50 50 1000)
JOBS=${JOBS:-16}
OUT=${OUT:-results/sweep.csv}
LOGDIR=sim/sweep_logs_s$SECURE
RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/vc_router.sv rtl/vc_mesh.sv"

# "1:2:4" -> "1_2_4_1": file-name tag for a config (SA_ITERS defaults to 1)
tag() { IFS=: read -r a b c d <<< "$1"; echo "${a}_${b}_${c}_${d:-1}"; }

rm -rf "$LOGDIR"
mkdir -p "$LOGDIR"

for c in $CONFIGS; do
  IFS=_ read -r vns vcs depth iters <<< "$(tag "$c")"
  iverilog -g2012 -DSWEEP_NUM_VNS="$vns" -DSWEEP_VCS_PER_VN="$vcs" \
    -DSWEEP_BUFFER_DEPTH="$depth" -DSWEEP_SA_ITERS="$iters" -DSWEEP_SECURE="$SECURE" \
    -o "sim/sweep_s${SECURE}_$(tag "$c").vvp" $RTL tb/latency_sweep_tb.sv 2>/dev/null
done

npoints=$(( $(echo $CONFIGS | wc -w) * $(echo $PATTERNS | wc -w) * $(echo $RATES | wc -w) ))
echo "Running $npoints sweep points (SECURE=$SECURE) with $JOBS parallel jobs..."
for c in $CONFIGS; do
  for p in $PATTERNS; do for r in $RATES; do echo "$(tag "$c") $p $r"; done; done
done | xargs -P "$JOBS" -n 3 bash -c \
  'vvp "sim/sweep_s'"$SECURE"'_$0.vvp" +PATTERN=$1 +RATE=$2 +NODUMP > "'"$LOGDIR"'/c$0_p$1_r$2.log" 2>&1'

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
echo "Wrote $OUT"
if [ "$missing" -ne 0 ] || [ "$errors" -ne 0 ]; then
  echo "SWEEP FAILED: $missing missing point(s), $errors point(s) reporting errors (incl. false security alarms)"
  awk -F, 'NR > 1 && $16 != 0 { print "  config=" $1 ":" $2 ":" $3 ":" $4 " pattern=" $5 " rate=" $6 " errors=" $16 }' "$OUT"
  exit 1
fi
echo "SWEEP PASSED: every point correct, no false security alarms, network drained after load"
