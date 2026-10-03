#!/usr/bin/env bash
# Equivalence check: the security layer must be INVISIBLE to honest traffic.
#
# Security hardware that changes how honest packets move is a performance
# bug at best. So with no attacker present, M6's router must reproduce
# earlier milestones digit for digit:
#   (a) M4's whole sweep (1 VN x 1 VC x 4, 4 patterns x 20 loads),
#       built with SECURE=1 and again with SECURE=0;
#   (b) M5's best VC configuration (1 VN x 4 VCs x 2, 2-pass), 4 patterns
#       x 20 loads, every column (incl. reordering), SECURE=1;
#   (c) M5's 48 protocol runs with one VN per class (6 outstanding levels
#       x 8 seeds) -- transactions started/completed, latency, cycles --
#       SECURE=1, with zero security alarms (any alarm fails the run).
# Every run is also a full correctness run.
#
# Usage: tools/equivalence_check.sh   (exit 0 iff all of it matches; ~12 min)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

M4_CSV=../m4_verification/results/latency_sweep.csv
M5_PAT=../m5_virtual_networks/results/vc_patterns.csv
M5_DL=../m5_virtual_networks/results/deadlock_demo.csv
for f in "$M4_CSV" "$M5_PAT" "$M5_DL"; do
  [ -f "$f" ] || { echo "ERROR: $f not found (run that milestone's tools first)"; exit 2; }
done
mkdir -p sim results
fail=0

for sec in 1 0; do
  out=results/equiv_m4_secure$sec.csv
  SECURE=$sec CONFIGS="1:1:4:1" PATTERNS="0 1 2 3" OUT="$out" tools/sweep.sh > sim/equiv_a$sec.log 2>&1 \
    || { echo "(a) SECURE=$sec: sweep failed -- see sim/equiv_a$sec.log"; fail=1; continue; }
  if diff <(tail -n +2 "$M4_CSV") <(tail -n +2 "$out" | cut -d, -f5-16) > sim/equiv_a$sec.diff; then
    echo "(a) SECURE=$sec: all 80 of M4's sweep points reproduced exactly"
  else
    echo "(a) SECURE=$sec: DIVERGED from M4 (sim/equiv_a$sec.diff)"; fail=1
  fi
done

out=results/equiv_m5_vc.csv
SECURE=1 CONFIGS="1:4:2:2" PATTERNS="0 1 2 3" OUT="$out" tools/sweep.sh > sim/equiv_b.log 2>&1 \
  || { echo "(b) sweep failed -- see sim/equiv_b.log"; fail=1; }
if [ -f "$out" ] && diff <(tail -n +2 "$M5_PAT") <(tail -n +2 "$out") > sim/equiv_b.diff; then
  echo "(b) all 80 of M5's VC-router points (4 VCs x 2, 2-pass) reproduced exactly"
else
  echo "(b) DIVERGED from M5's VC router (sim/equiv_b.diff)"; fail=1
fi

RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/vc_router.sv rtl/vc_mesh.sv"
iverilog -g2012 -DPROTO_NUM_VNS=3 -DPROTO_SECURE=1 -o sim/equiv_proto.vvp $RTL tb/protocol_tb.sv
LOGDIR=sim/equiv_proto_logs
rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"
for o in 2 4 8 16 32 64; do for s in 1 2 3 4 5 6 7 8; do echo "$o $s"; done; done \
  | xargs -P "${JOBS:-16}" -n 2 bash -c \
    'vvp sim/equiv_proto.vvp +NODUMP +CYCLES=5000 +OUTSTANDING=$0 +SEED=$1 > "'"$LOGDIR"'/o$0_s$1.log" 2>&1'
for o in 2 4 8 16 32 64; do for s in 1 2 3 4 5 6 7 8; do
  grep -h '^CSV,' "$LOGDIR/o${o}_s${s}.log" | sed 's/^CSV,//' || echo "MISSING o=$o s=$s"
done; done > sim/equiv_c_m6.txt
awk -F, 'NR > 1 && $1 == 3' "$M5_DL" > sim/equiv_c_m5.txt
if diff sim/equiv_c_m5.txt sim/equiv_c_m6.txt > sim/equiv_c.diff; then
  echo "(c) all 48 of M5's protocol runs (one VN per class) reproduced exactly, no security alarms"
else
  echo "(c) DIVERGED from M5's protocol runs (sim/equiv_c.diff)"; fail=1
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "EQUIVALENCE FAILED: the security layer changed honest traffic"
  exit 1
fi
echo "EQUIVALENCE PASSED: with no attacker, M6 behaves exactly like M4/M5 -- the security layer is invisible to honest traffic"
