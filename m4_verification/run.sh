#!/usr/bin/env bash
# M4 regression (Icarus Verilog), in order:
#   1. directed credit-mesh smoke test
#   2. randomized-traffic scoreboard, all four synthetic traffic patterns
#   3. one latency-sweep point (uniform random, 0.50 offered load) -- so the
#      sweep testbench's own correctness checks run in every regression.
#      The full 80-point sweep takes ~45 s: tools/sweep.sh.
#
# Related (not run here; the two shell scripts take ~40 s each):
#   tools/sweep.sh           full latency/throughput sweep -> results/latency_sweep.csv
#   tools/theory_check.py    checks the sweep against an analytic model of the mesh
#   tools/plot_sweep.py      plots it (needs matplotlib)
#   tools/mutation_test.sh   injects known bugs; every one must be caught
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

mkdir -p sim

failed=()
# step <name> <regex marking a pass> <command...>: show the output; a missing
# pass line (or a crash) is recorded, and the script exits non-zero at the end
step() {
  local name=$1 pass=$2
  shift 2
  local out
  out=$("$@" 2>&1) || true
  echo "$out"
  echo "$out" | grep -qE "$pass" || failed+=("$name")
}

RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/router.sv rtl/mesh_credit.sv"

echo "=== mesh_credit directed smoke test ==="
iverilog -g2012 -Wall -o sim/mesh_credit_tb.vvp $RTL tb/mesh_credit_tb.sv
step "mesh_credit smoke test" "ALL TESTS PASSED" vvp sim/mesh_credit_tb.vvp

PATTERN_NAMES=(uniform transpose bit-complement hotspot)
for p in 0 1 2 3; do
  echo
  echo "=== randomized-traffic scoreboard: pattern=$p (${PATTERN_NAMES[$p]}) ==="
  iverilog -g2012 -Wall -DPATTERN=$p -o sim/random_traffic_tb.vvp $RTL tb/random_traffic_tb.sv
  step "random traffic pattern $p" "ALL TRAFFIC ACCOUNTED FOR -- PASS" vvp sim/random_traffic_tb.vvp
done

echo
echo "=== latency sweep, single point: uniform random @ 0.50 ==="
iverilog -g2012 -Wall -o sim/latency_sweep_tb.vvp $RTL tb/latency_sweep_tb.sv
step "latency sweep point" "^PASS" vvp sim/latency_sweep_tb.vvp +PATTERN=0 +RATE=500

echo
if [ ${#failed[@]} -ne 0 ]; then
  echo "M4 REGRESSION FAILED: ${failed[*]}"
  exit 1
fi
echo "M4 REGRESSION PASSED"
