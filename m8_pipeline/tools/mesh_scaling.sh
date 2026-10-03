#!/usr/bin/env bash
# M8 on a 4x4 mesh: every earlier result was measured on 3x3; the RTL is
# size-generic, so run the same checks one size up (~6 min).
#   1. uniform sweeps, two-stage routers 1 VC x 4 and 4 VCs x 2 2-pass
#      (results/sweep_4x4_pipe.csv), compared with the 3x3 sweeps and an
#      analytic model (tools/mesh_scaling.py)
#   2. coherence protocol, one VN per class, hardened: 4 seeds x 16/64
#      outstanding -- all complete, no deadlock, no false alarms
#   3. the same protocol with one shared VN (SECURE=0): deadlocks
#   4. black hole at interior tile 5 (1,1): compromises the unprotected
#      router, contained by the hardened one
# Exits non-zero unless everything passes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p sim results
RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/vc_router.sv rtl/vc_mesh.sv"
M="-DPROTO_MESH_W=4 -DPROTO_MESH_H=4 -DPROTO_PIPE=1"
S="-DSWEEP_MESH_W=4 -DSWEEP_MESH_H=4 -DSWEEP_PIPE=1 -DSWEEP_VCS_PER_VN=4 -DSWEEP_BUFFER_DEPTH=2 -DSWEEP_SA_ITERS=2"
failed=()

echo "=== 1. uniform sweeps on 4x4 (two-stage routers) ==="
MESH=4x4 PIPE=1 CONFIGS="1:1:4 1:4:2:2" OUT=results/sweep_4x4_pipe.csv tools/sweep.sh | tail -3 || failed+=("sweep")
python tools/mesh_scaling.py results/sweep_pipe.csv results/sweep_4x4_pipe.csv || failed+=("scaling model")

echo
echo "=== 2. protocol, one VN per class, hardened, 4x4 ==="
iverilog -g2012 $M -DPROTO_NUM_VNS=3 -DPROTO_SECURE=1 -o sim/p44_vn.vvp $RTL tb/protocol_tb.sv
for o in 16 64; do
  for seed in 1 2 3 4; do echo "$o $seed"; done
done | xargs -P 8 -n 2 bash -c 'vvp sim/p44_vn.vvp +OUTSTANDING=$0 +SEED=$1 +CYCLES=4000 +NODUMP > sim/p44_vn_o$0_s$1.log 2>&1'
for o in 16 64; do for seed in 1 2 3 4; do
  l=sim/p44_vn_o${o}_s$seed.log
  r=$(grep -E "^(PASS|FAIL)" "$l" | head -1)
  echo "  outstanding $o seed $seed: $(grep '^transactions' "$l" | cut -c1-60) | $r"
  grep -q "^PASS" "$l" || failed+=("protocol o$o s$seed")
done; done

echo
echo "=== 3. protocol, shared VN, unprotected, 4x4: must deadlock ==="
iverilog -g2012 $M -DPROTO_NUM_VNS=1 -DPROTO_SECURE=0 -o sim/p44_1vn.vvp $RTL tb/protocol_tb.sv
out=$(vvp sim/p44_1vn.vvp +OUTSTANDING=16 +SEED=1 +CYCLES=4000 +EXPECT_DEADLOCK +NODUMP 2>&1 || true)
echo "$out" | grep -E "DEADLOCK at|^PASS|^FAIL" | sed 's/^/  /'
echo "$out" | grep -q "^PASS" || failed+=("shared-VN deadlock")

echo
echo "=== 4. black hole at tile 5 (1,1), uniform 0.20, 4x4 ==="
for sec in 0 1; do
  iverilog -g2012 $S -DSWEEP_SECURE=$sec -o sim/bh44_s$sec.vvp $RTL tb/latency_sweep_tb.sv
done
o0=$(vvp sim/bh44_s0.vvp +RATE=200 +BLACKHOLE=5 +EXPECT_COMPROMISE +NODUMP 2>&1 || true)
o1=$(vvp sim/bh44_s1.vvp +RATE=200 +BLACKHOLE=5 +NODUMP 2>&1 || true)
echo "$o0" | grep -E "^black hole at|^  packets|PASS|FAIL" | sed 's/^/  SECURE=0  /'
echo "$o1" | grep -E "^black hole at|^  packets|PASS|FAIL" | sed 's/^/  SECURE=1  /'
echo "$o0" | grep -q "^ATTACK-PASS" || failed+=("black hole SECURE=0")
echo "$o1" | grep -qE "^(ATTACK-)?PASS" || failed+=("black hole SECURE=1")

echo
if [ ${#failed[@]} -eq 0 ]; then
  echo "4x4 PASSED: sweeps match the model, VNs never deadlock, shared buffers do, the black hole is contained"
else
  echo "4x4 FAILED: ${failed[*]}"
  exit 1
fi
