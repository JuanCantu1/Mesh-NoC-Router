#!/usr/bin/env bash
# Compiles and runs the M2 mesh directed testbench with Icarus Verilog.
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

iverilog -g2012 -Wall -o sim/mesh_tb.vvp \
  rtl/noc_pkg.sv \
  rtl/rr_arbiter.sv \
  rtl/router.sv \
  rtl/mesh.sv \
  tb/mesh_tb.sv

step "mesh directed tests" "ALL TESTS PASSED" vvp sim/mesh_tb.vvp

echo
if [ ${#failed[@]} -ne 0 ]; then
  echo "M2 REGRESSION FAILED: ${failed[*]}"
  exit 1
fi
echo "M2 REGRESSION PASSED"
