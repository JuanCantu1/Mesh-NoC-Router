#!/usr/bin/env bash
# Mutation test: verifies the verification.
#
# Each mutant is a copy of the RTL with one deliberate, realistic bug.
# Three testbenches run against every copy, and each mutant must make at
# least one of them FAIL:
#   directed  tb/vc_router_tb.sv                    (17 directed checks)
#   sweep     tb/latency_sweep_tb.sv, 1 VN x 2 VC x 4, 2-pass SA, uniform @ 0.90
#   protocol  tb/protocol_tb.sv,      3 VN x 2 VC x 2, 2-pass SA, 8 outstanding
# The unmutated RTL goes through the identical harness first and must PASS
# all three -- otherwise a broken harness could "catch" every mutant.
#
# The mutants (M4's three, carried forward, plus three new to VCs/VNs):
#   credit_overflow    credit counters reset one above buffer capacity
#   fixed_priority     round-robin pointers never advance (fixed priority)
#   route_east_west    East-bound flits routed West
#   vn_escape          output-VC allocation ignores the VN: a flit can leave
#                      on a VC belonging to another message class
#   credit_wrong_vc    a popped flit returns its credit on the NEXT VC's wire
#   pass2_reuse_input  pass 2 of switch allocation lets an input that already
#                      won in pass 1 win again (a second flit through one
#                      crossbar input: one flit duplicated, another lost)
#   pass2_reuse_output pass 2 may grant an output pass 1 already gave away
#                      (two flits for one output: one lost)
#
# Usage: tools/mutation_test.sh   (exit 0 only if every mutant is caught)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# name | file | sed expression ("" = baseline)
CASES=(
  "baseline||"
  "credit_overflow|vc_router.sv|s/credit_count\[gi\] <= BUFFER_DEPTH;/credit_count[gi] <= BUFFER_DEPTH + 1;/"
  "fixed_priority|rr_arbiter.sv|s/ptr_n = (win_idx == NUM_REQ-1) ? '0 : win_idx + 1'b1;/ptr_n = ptr;/"
  "route_east_west|vc_router.sv|s/(f\.dest_x > X_ID) ? 3'(PORT_E)/(f.dest_x > X_ID) ? 3'(PORT_W)/"
  "vn_escape|vc_router.sv|s/assign ovc_cand\[go\]\[gw\] = win_vn\[go\]\[gw \/ VCS_PER_VN\] && /assign ovc_cand[go][gw] = /"
  "credit_wrong_vc|vc_router.sv|s/assign in_credit_return\[I\] = fifo_pop\[I\];/assign in_credit_return[I] = fifo_pop[gp*NUM_VCS + (gv+1) % NUM_VCS];/"
  "pass2_reuse_input|vc_router.sv|s/assign elig2\[gi\] = !in_won1\[gi \/ NUM_VCS\] && /assign elig2[gi] = /"
  "pass2_reuse_output|vc_router.sv|s/assign wants_free_out\[go\] = req_mat\[go\]\[gi\] && !out_won1\[go\];/assign wants_free_out[go] = req_mat[go][gi];/; s/assign out_req2\[go\]\[gq\] = !out_won1\[go\] && /assign out_req2[go][gq] = /"
)

run_case() {
  local name=$1 file=$2 expr=$3
  local d="$WORK/$name"
  mkdir -p "$d/sim"
  cp rtl/*.sv "$d/"
  if [ -n "$expr" ]; then
    sed -i "$expr" "$d/$file"
    if cmp -s "rtl/$file" "$d/$file"; then
      echo "ERROR: mutation '$name' did not change $file (pattern not found) -- update this script" > "$d/result"
      return
    fi
  fi
  local rtl="$d/noc_pkg.sv $d/rr_arbiter.sv $d/flit_fifo.sv $d/vc_router.sv $d/vc_mesh.sv"
  iverilog -g2012 -o "$d/dir.vvp" $rtl tb/router_harness.sv tb/vc_router_tb.sv 2>/dev/null || true
  iverilog -g2012 -DSWEEP_VCS_PER_VN=2 -DSWEEP_SA_ITERS=2 -o "$d/sw.vvp" $rtl tb/latency_sweep_tb.sv 2>/dev/null || true
  iverilog -g2012 -DPROTO_NUM_VNS=3 -DPROTO_VCS_PER_VN=2 -DPROTO_BUFFER_DEPTH=2 -DPROTO_SA_ITERS=2 \
    -o "$d/pr.vvp" $rtl tb/protocol_tb.sv 2>/dev/null || true

  local out_dir out_sw out_pr
  out_dir=$(cd "$d" && timeout 600 vvp dir.vvp 2>&1 || true)
  out_sw=$(cd "$d" && timeout 600 vvp sw.vvp +RATE=900 +PATTERN=0 +NODUMP 2>&1 || true)
  out_pr=$(cd "$d" && timeout 600 vvp pr.vvp +OUTSTANDING=8 +CYCLES=3000 +NODUMP 2>&1 || true)

  local p_dir=0 p_sw=0 p_pr=0
  echo "$out_dir" | grep -q "ALL TESTS PASSED" && p_dir=1
  echo "$out_sw"  | grep -q "^PASS" && p_sw=1
  echo "$out_pr"  | grep -q "^PASS" && p_pr=1

  # first failure reason from each (|| true: grep finding nothing is fine)
  local w_dir w_sw w_pr
  w_dir=$(echo "$out_dir" | grep -E "ASSERT-FAIL|\[FAIL\]" | head -1 | sed 's/^ *//' | cut -c1-120 || true)
  w_sw=$(echo "$out_sw"   | grep -E "ASSERT-FAIL|\[FAIL\]" | head -1 | sed 's/^ *//' | cut -c1-120 || true)
  w_pr=$(echo "$out_pr"   | grep -E "ASSERT-FAIL|\[FAIL\]|DEADLOCK at|^FAIL" | head -1 | sed 's/^ *//' | cut -c1-120 || true)

  {
    echo "$p_dir $p_sw $p_pr"
    echo "directed: ${w_dir:-(passed -- missed it)}"
    echo "sweep:    ${w_sw:-(passed -- missed it)}"
    echo "protocol: ${w_pr:-(passed -- missed it)}"
  } > "$d/result"
}

for c in "${CASES[@]}"; do
  IFS='|' read -r name file expr <<< "$c"
  run_case "$name" "$file" "$expr" &
done
wait

survivors=0
for c in "${CASES[@]}"; do
  IFS='|' read -r name file expr <<< "$c"
  r="$WORK/$name/result"
  if grep -q "^ERROR" "$r"; then cat "$r"; exit 2; fi
  read -r p_dir p_sw p_pr < "$r"
  if [ "$name" = baseline ]; then
    if [ "$p_dir$p_sw$p_pr" = 111 ]; then
      echo "baseline (unmutated RTL): all three testbenches PASS -- harness is sound"
    else
      echo "baseline (unmutated RTL) FAILED -- the harness itself is broken; mutant results would be meaningless"
      tail -n +2 "$r" | sed 's/^/  /'
      exit 2
    fi
    continue
  fi
  if [ "$p_dir$p_sw$p_pr" = 111 ]; then
    echo "SURVIVED  $name -- no testbench noticed this bug"
    survivors=$((survivors + 1))
  else
    echo "caught    $name"
    tail -n +2 "$r" | sed 's/^/            /'
  fi
done

echo
if [ "$survivors" -ne 0 ]; then
  echo "MUTATION TEST FAILED: $survivors mutant(s) survived -- the verification has a blind spot"
  exit 1
fi
echo "MUTATION TEST PASSED: every injected bug was caught"
