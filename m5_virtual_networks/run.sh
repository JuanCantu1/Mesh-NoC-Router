#!/usr/bin/env bash
# M5 regression (Icarus Verilog), in order:
#   1. directed single-router tests (HOL bypass, VN isolation, 2-pass
#      allocation, fairness, ...)
#   2. protocol traffic, one VN per message class: every transaction must
#      complete (no deadlock)
#   3. protocol traffic, all classes sharing one VN: MUST deadlock -- the
#      hazard VNs exist to prevent, reproduced on purpose (+EXPECT_DEADLOCK)
#   4. one latency-sweep point on the best VC configuration, with waveform
# Exits non-zero if any step doesn't print its PASS line (vvp itself exits
# 0 even when a testbench reports FAIL, so this script checks the output).
#
# Related (not run here; minutes each):
#   tools/equivalence_check.sh  1 VN x 1 VC reproduces M4's whole sweep exactly (~1.5 min)
#   tools/sweep.sh              VC study: 12 configs x 20 loads -> results/vc_sweep.csv (~7 min)
#   tools/plot_vc_study.py      plots it (needs matplotlib)
#   tools/deadlock_demo.sh      deadlock rate vs outstanding transactions, 3 configs (~5 min)
#   tools/mutation_test.sh      injects 7 known bugs; every one must be caught (~10 min)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

mkdir -p sim

RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/vc_router.sv rtl/vc_mesh.sv"
failed=()

# check <step name> <regex that marks a pass> <command...>
check() {
  local name=$1 pass=$2
  shift 2
  local out
  out=$("$@" 2>&1) || true
  echo "$out"
  echo "$out" | grep -qE "$pass" || failed+=("$name")
}

echo "=== vc_router directed tests ==="
iverilog -g2012 -Wall -o sim/vc_router_tb.vvp $RTL tb/router_harness.sv tb/vc_router_tb.sv
check "directed tests" "ALL TESTS PASSED" vvp sim/vc_router_tb.vvp

echo
echo "=== protocol traffic, 3 VNs (one per class): must never deadlock ==="
iverilog -g2012 -Wall -DPROTO_NUM_VNS=3 -o sim/protocol_vn.vvp $RTL tb/protocol_tb.sv
check "protocol, 3 VNs" "^PASS" vvp sim/protocol_vn.vvp +OUTSTANDING=16 +CYCLES=3000 +SEED=1 +NODUMP

echo
echo "=== protocol traffic, 1 shared VN: must deadlock (hazard reproduced on purpose) ==="
iverilog -g2012 -Wall -DPROTO_NUM_VNS=1 -o sim/protocol_shared.vvp $RTL tb/protocol_tb.sv
check "protocol, shared VN" "^PASS" vvp sim/protocol_shared.vvp +OUTSTANDING=16 +CYCLES=3000 +SEED=1 +EXPECT_DEADLOCK

echo
echo "=== latency sweep, single point: 1 VN x 4 VCs x 2 flits, 2-pass SA, uniform @ 0.80 ==="
iverilog -g2012 -Wall -DSWEEP_VCS_PER_VN=4 -DSWEEP_BUFFER_DEPTH=2 -DSWEEP_SA_ITERS=2 \
  -o sim/latency_sweep_tb.vvp $RTL tb/latency_sweep_tb.sv
check "sweep point" "^PASS" vvp sim/latency_sweep_tb.vvp +PATTERN=0 +RATE=800

echo
if [ ${#failed[@]} -ne 0 ]; then
  echo "M5 REGRESSION FAILED: ${failed[*]}"
  exit 1
fi
echo "M5 REGRESSION PASSED (4/4 steps)"
