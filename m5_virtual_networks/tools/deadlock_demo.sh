#!/usr/bin/env bash
# Protocol-deadlock demonstration: how often does each router
# configuration deadlock under coherence-style traffic, as the number of
# transactions each requester may have in flight grows?
#
# Three configurations, all with 4-flit buffers:
#   1:1  one VN, one VC        -- every class shares every buffer
#   1:3  one VN, three VCs     -- 3x the buffering, still shared by all classes
#   3:1  three VNs, one VC each -- the same buffering as 1:3, but each class
#                                 gets its own (REQ / SNP / RSP)
#
# 1:3 vs 3:1 is the point: identical buffer counts, different partitioning.
#
# Every run is also a full correctness run (protocol, routing, VN
# isolation, RTL invariants). Exits non-zero if any run reports an error,
# or if the VN configuration EVER deadlocks.
#
# Usage: tools/deadlock_demo.sh   (SEEDS=N runs per cell, default 8; JOBS=N, default 16)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p sim results

CONFIGS="1:1 1:3 3:1"
LEVELS="2 4 8 16 32 64"
NSEEDS=${SEEDS:-8}
CYCLES=5000
JOBS=${JOBS:-16}
OUT=results/deadlock_demo.csv
LOGDIR=sim/deadlock_logs
RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/vc_router.sv rtl/vc_mesh.sv"

rm -rf "$LOGDIR"
mkdir -p "$LOGDIR"

for c in $CONFIGS; do
  IFS=: read -r vns vcs <<< "$c"
  iverilog -g2012 -DPROTO_NUM_VNS="$vns" -DPROTO_VCS_PER_VN="$vcs" \
    -o "sim/proto_${vns}_${vcs}.vvp" $RTL tb/protocol_tb.sv 2>/dev/null
done

echo "Running $(( 3 * $(echo $LEVELS | wc -w) * NSEEDS )) protocol runs ($CYCLES cycles of traffic each) with $JOBS parallel jobs..."
for c in $CONFIGS; do
  IFS=: read -r vns vcs <<< "$c"
  for o in $LEVELS; do for s in $(seq 1 "$NSEEDS"); do echo "${vns}_${vcs} $o $s"; done; done
done | xargs -P "$JOBS" -n 3 bash -c \
  'vvp "sim/proto_$0.vvp" +NODUMP +CYCLES='"$CYCLES"' +OUTSTANDING=$1 +SEED=$2 > "'"$LOGDIR"'/c$0_o$1_s$2.log" 2>&1'

echo "num_vns,vcs_per_vn,buffer_depth,sa_iters,outstanding,rate_permille,seed,deadlocked,started,completed,avg_txn_latency,cycles,errors" > "$OUT"
missing=0
for c in $CONFIGS; do
  IFS=: read -r vns vcs <<< "$c"
  for o in $LEVELS; do
    for s in $(seq 1 "$NSEEDS"); do
      log="$LOGDIR/c${vns}_${vcs}_o${o}_s${s}.log"
      line=$(grep '^CSV,' "$log" | sed 's/^CSV,//' || true)
      if [ -z "$line" ]; then
        echo "MISSING result: config=$c outstanding=$o seed=$s -- see $log"
        missing=$((missing + 1))
      else
        echo "$line" >> "$OUT"
      fi
    done
  done
done

echo
echo "Wrote $OUT"
echo
echo "Runs that deadlocked, out of $NSEEDS seeds each:"
awk -F, -v n="$NSEEDS" '
  NR == 1 { next }
  {
    k = $1 ":" $2
    dl[k, $5] += $8
    if (!($5 in seen)) { seen[$5] = 1; lv[++nl] = $5 }
  }
  END {
    printf "  %-13s %-16s %-16s %-16s\n", "outstanding", "1 VN x 1 VC", "1 VN x 3 VC", "3 VN x 1 VC"
    printf "  %-13s %-16s %-16s %-16s\n", "per tile", "(shared)", "(shared, 3x buf)", "(VN per class)"
    for (i = 1; i <= nl; i++) {
      o = lv[i]
      printf "  %-13s %-16s %-16s %-16s\n", o, dl["1:1", o] "/" n, dl["1:3", o] "/" n, dl["3:1", o] "/" n
    }
  }' "$OUT"
echo

errors=$(awk -F, 'NR > 1 && $13 != 0' "$OUT" | wc -l)
vn_deadlocks=$(awk -F, 'NR > 1 && $1 == 3 && $8 != 0' "$OUT" | wc -l)
if [ "$missing" -ne 0 ] || [ "$errors" -ne 0 ] || [ "$vn_deadlocks" -ne 0 ]; then
  echo "DEADLOCK DEMO FAILED: $missing missing run(s), $errors run(s) with correctness errors, $vn_deadlocks VN-configuration deadlock(s)"
  exit 1
fi
echo "DEADLOCK DEMO PASSED: one VN per message class never deadlocked; every run was otherwise error-free"
