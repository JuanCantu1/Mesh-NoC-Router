#!/usr/bin/env bash
# Compiles and runs the M3 credit-based-router test suite with Icarus
# Verilog: the flit_fifo unit test first, then the full router testbench.
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

echo "=== flit_fifo unit test ==="
iverilog -g2012 -Wall -o sim/flit_fifo_tb.vvp \
  rtl/noc_pkg.sv \
  rtl/flit_fifo.sv \
  tb/flit_fifo_tb.sv
step "flit_fifo unit test" "ALL FIFO SMOKE CHECKS PASSED" vvp sim/flit_fifo_tb.vvp

echo
echo "=== router (credit-based flow control) testbench ==="
iverilog -g2012 -Wall -o sim/router_tb.vvp \
  rtl/noc_pkg.sv \
  rtl/rr_arbiter.sv \
  rtl/flit_fifo.sv \
  rtl/router.sv \
  tb/router_tb.sv
step "router tests" "ALL TESTS PASSED" vvp sim/router_tb.vvp

echo
if [ ${#failed[@]} -ne 0 ]; then
  echo "M3 REGRESSION FAILED: ${failed[*]}"
  exit 1
fi
echo "M3 REGRESSION PASSED"
