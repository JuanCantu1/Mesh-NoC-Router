#!/usr/bin/env bash
# M6 regression (Icarus Verilog), in order:
#   1. directed single-router tests: M5's suite + stamping, ingress VN
#      guard, watchdog quarantine/recovery, and the unprotected contrast
#   2. honest protocol traffic on the hardened mesh: everything completes,
#      no security alarm ever fires (false positives fail the run)
#   3. each attack against the UNPROTECTED router (SECURE=0) -- must
#      succeed (+EXPECT_COMPROMISE) -- and the HARDENED one -- must be
#      contained:  spoofing, VN hopping (protocol traffic), black hole
#      (uniform traffic)
#   4. one honest latency-sweep point, with waveform
# Exits non-zero if any step doesn't print its PASS line.
#
# Related (not run here; minutes each):
#   tools/equivalence_check.sh  with no attacker, M6 reproduces M4/M5 digit for digit (~12 min)
#   tools/attack_matrix.sh      every attack x both routers x 8 seeds / 2 tiles x 2 loads (~6 min)
#   tools/watchdog_study.sh     honest stall lengths vs. black-hole damage per WD_LIMIT (~6 min)
#   tools/mutation_test.sh      11 injected bugs (4 in the security layer); all must be caught (~4 min)
#   tools/sweep.sh              latency/throughput sweeps, SECURE=0|1
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
  echo "$out" | grep -vE "^VCD info|finish called"
  echo "$out" | grep -qE "$pass" || failed+=("$name")
}

echo "=== vc_router directed tests ==="
iverilog -g2012 -Wall -o sim/vc_router_tb.vvp $RTL tb/router_harness.sv tb/vc_router_tb.sv
check "directed tests" "ALL TESTS PASSED" vvp sim/vc_router_tb.vvp

for sec in 0 1; do
  iverilog -g2012 -Wall -DPROTO_NUM_VNS=3 -DPROTO_SECURE=$sec -o sim/protocol_s$sec.vvp $RTL tb/protocol_tb.sv
  iverilog -g2012 -Wall -DSWEEP_VCS_PER_VN=4 -DSWEEP_BUFFER_DEPTH=2 -DSWEEP_SA_ITERS=2 -DSWEEP_SECURE=$sec \
    -o sim/sweep_s$sec.vvp $RTL tb/latency_sweep_tb.sv
done

echo
echo "=== honest protocol traffic, hardened mesh: no deadlock, no false alarms ==="
check "honest protocol" "^PASS" vvp sim/protocol_s1.vvp +OUTSTANDING=16 +CYCLES=3000 +SEED=1 +NODUMP

for a in 1 2; do
  [ $a = 1 ] && nm="source spoofing" || nm="VN hopping"
  echo
  echo "=== attack: $nm -- unprotected router (must be compromised) ==="
  check "$nm, unprotected" "^ATTACK-PASS" vvp sim/protocol_s0.vvp +OUTSTANDING=8 +CYCLES=3000 +SEED=1 +ATTACK=$a +EXPECT_COMPROMISE +NODUMP
  echo
  echo "=== attack: $nm -- hardened router (must be contained) ==="
  check "$nm, hardened" "^ATTACK-PASS" vvp sim/protocol_s1.vvp +OUTSTANDING=8 +CYCLES=3000 +SEED=1 +ATTACK=$a +NODUMP
done

echo
echo "=== attack: black hole at the center tile -- unprotected router (must be compromised) ==="
check "black hole, unprotected" "^ATTACK-PASS" vvp sim/sweep_s0.vvp +PATTERN=0 +RATE=300 +BLACKHOLE=4 +EXPECT_COMPROMISE +NODUMP
echo
echo "=== attack: black hole at the center tile -- hardened router (must be contained), with waveform ==="
check "black hole, hardened" "^ATTACK-PASS" vvp sim/sweep_s1.vvp +PATTERN=0 +RATE=300 +BLACKHOLE=4

echo
echo "=== honest latency-sweep point, hardened mesh: 4 VCs x 2 flits, 2-pass, uniform @ 0.80 ==="
check "sweep point" "^PASS" vvp sim/sweep_s1.vvp +PATTERN=0 +RATE=800 +NODUMP

echo
if [ ${#failed[@]} -ne 0 ]; then
  echo "M6 REGRESSION FAILED: ${failed[*]}"
  exit 1
fi
echo "M6 REGRESSION PASSED (9/9 steps)"
