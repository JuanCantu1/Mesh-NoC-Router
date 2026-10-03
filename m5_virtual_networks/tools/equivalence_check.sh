#!/usr/bin/env bash
# Equivalence check: the M5 VC router, configured as M4's router
# (1 VN x 1 VC x 4-flit buffers, 1-pass switch allocation), must reproduce
# M4's entire latency/throughput sweep -- all 4 patterns x 20 offered
# loads, every measured column, digit for digit.
#
# This works because the sweep testbench drives M4's exact stimulus (same
# random-number call sequence) and both routers are cycle-accurate RTL: if
# the refactor changed timing anywhere -- one cycle of extra latency, one
# different arbitration decision -- some latency or throughput number in
# the 80 points diverges. That's a far stronger check than "the new router
# also passes its tests": it pins the new design to the old one's
# *behavior*, not just its correctness.
#
# Usage: tools/equivalence_check.sh   (exit 0 iff all 80 points match)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

M4_CSV=../m4_verification/results/latency_sweep.csv
OUT=results/equivalence_1x1x4.csv
if [ ! -f "$M4_CSV" ]; then
  echo "ERROR: $M4_CSV not found (run ../m4_verification/tools/sweep.sh first)"
  exit 2
fi

CONFIGS="1:1:4:1" PATTERNS="0 1 2 3" OUT="$OUT" tools/sweep.sh > sim/equivalence_sweep.log 2>&1 || {
  echo "ERROR: the M5 sweep itself failed -- see sim/equivalence_sweep.log"
  exit 2
}

# M5 columns 5..16 (pattern .. errors) line up with M4's 12 columns.
diff <(tail -n +2 "$M4_CSV") <(tail -n +2 "$OUT" | cut -d, -f5-16) > sim/equivalence.diff && same=1 || same=0
points=$(tail -n +2 "$OUT" | wc -l)
if [ "$same" -eq 1 ]; then
  echo "EQUIVALENCE PASSED: vc_router (1 VN x 1 VC x 4, 1-pass SA) reproduced all $points of M4's sweep points exactly"
  exit 0
fi
echo "EQUIVALENCE FAILED: vc_router diverged from M4's router (M4 '<' vs M5 '>'):"
head -20 sim/equivalence.diff
exit 1
