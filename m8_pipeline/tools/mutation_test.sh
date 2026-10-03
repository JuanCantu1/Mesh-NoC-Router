#!/usr/bin/env bash
# Mutation test: verifies the verification -- now including the security.
#
# Each mutant is a copy of the RTL with one deliberate bug. Six testbench
# runs go against every copy; each mutant must make at least one FAIL:
#   directed  tb/vc_router_tb.sv (28 directed checks)
#   sweep     honest traffic, 1 VN x 2 VCs x 4, 2-pass, uniform @ 0.90
#   protocol  honest coherence traffic, 3 VNs x 2 VCs x 2, 2-pass
#   spoof     protocol traffic + spoofing attacker: must be contained
#   vnhop     protocol traffic + VN-hopping attacker: must be contained
#   blackhole uniform traffic + black-hole tile: must be contained
# The unmutated RTL goes through the identical harness first and must pass
# all six -- otherwise a broken harness could "catch" every mutant.
#
# Mutants -- M5's seven, carried forward:
#   credit_overflow, fixed_priority, route_east_west, vn_escape,
#   credit_wrong_vc, pass2_reuse_input, pass2_reuse_output   (see M5 README)
# -- plus four that break the security layer:
#   no_stamp       ingress source stamping removed: spoofing works again
#   no_vn_guard    ingress VN check removed: VN hopping works again
#   no_watchdog    the watchdog never quarantines: black holes work again
#   hair_trigger   the watchdog quarantines after 2 starved cycles instead
#                  of WD_LIMIT -- a FALSE-POSITIVE bug: honest tiles that
#                  briefly stall get their traffic thrown away
#
# Usage: tools/mutation_test.sh   (exit 0 only if every mutant is caught; ~4 min)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PIPE=${PIPE:-0}   # M8: PIPE=1 builds every testbench with two-stage routers
PF="-DTB_PIPE=$PIPE -DSWEEP_PIPE=$PIPE -DPROTO_PIPE=$PIPE"
export PF
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# name | file | sed expression ("" = baseline)
CASES=(
  "baseline||"
  "credit_overflow|vc_router.sv|s/credit_count\[gi\] <= FULL_CREDIT;/credit_count[gi] <= FULL_CREDIT + 1'b1;/"
  "fixed_priority|rr_arbiter.sv|s/ptr_n = (win_idx == LAST) ? '0 : win_idx + 1'b1;/ptr_n = ptr;/"
  "route_east_west|vc_router.sv|s/(fin\.dest_x > MY_X) ? 3'(PORT_E)/(fin.dest_x > MY_X) ? 3'(PORT_W)/"
  "vn_escape|vc_router.sv|s/assign ovc_cand\[go\]\[gw\] = win_vn\[go\]\[gw \/ VCS_PER_VN\] && /assign ovc_cand[go][gw] = /"
  "credit_wrong_vc|vc_router.sv|s/assign in_credit_return\[I\] = fifo_pop\[I\];/assign in_credit_return[I] = fifo_pop[gp*NUM_VCS + (gv+1) % NUM_VCS];/"
  "pass2_reuse_input|vc_router.sv|s/assign elig2\[gi\] = !in_won1\[gi \/ NUM_VCS\] && /assign elig2[gi] = /"
  "pass2_reuse_output|vc_router.sv|s/assign wants_free_out\[go\] = req_mat\[go\]\[gi\] && !out_won1\[go\];/assign wants_free_out[go] = req_mat[go][gi];/; s/assign out_req2\[go\]\[gq\] = !out_won1\[go\] && /assign out_req2[go][gq] = /"
  "no_stamp|vc_router.sv|s/assign fin = {raw.mclass, MY_X, MY_Y, raw.dest_x, raw.dest_y, raw.payload};/assign fin = raw;/"
  "no_vn_guard|vc_router.sv|s/assign fifo_push\[I\] = arrives && (fin.mclass == VN\[MCLASS_W-1:0\]);/assign fifo_push[I] = arrives;/"
  "no_watchdog|vc_router.sv|s/if (int'(starve_cnt) == WD_LIMIT - 1) q <= 1'b1;/if (1'b0) q <= 1'b1;/"
  "hair_trigger|vc_router.sv|s/if (int'(starve_cnt) == WD_LIMIT - 1) q <= 1'b1;/if (int'(starve_cnt) == 1) q <= 1'b1;/"
)
NAMES="directed sweep protocol spoof vnhop blackhole"

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
  iverilog -g2012 $PF -o "$d/dir.vvp" $rtl tb/router_harness.sv tb/vc_router_tb.sv 2>/dev/null || true
  iverilog -g2012 $PF -DSWEEP_VCS_PER_VN=2 -DSWEEP_SA_ITERS=2 -o "$d/sw.vvp" $rtl tb/latency_sweep_tb.sv 2>/dev/null || true
  iverilog -g2012 $PF -DSWEEP_VCS_PER_VN=4 -DSWEEP_BUFFER_DEPTH=2 -DSWEEP_SA_ITERS=2 -o "$d/bh.vvp" $rtl tb/latency_sweep_tb.sv 2>/dev/null || true
  iverilog -g2012 $PF -DPROTO_NUM_VNS=3 -DPROTO_VCS_PER_VN=2 -DPROTO_BUFFER_DEPTH=2 -DPROTO_SA_ITERS=2 \
    -o "$d/pr.vvp" $rtl tb/protocol_tb.sv 2>/dev/null || true
  iverilog -g2012 $PF -DPROTO_NUM_VNS=3 -o "$d/atk.vvp" $rtl tb/protocol_tb.sv 2>/dev/null || true

  local o_dir o_sw o_pr o_sp o_vh o_bh
  o_dir=$(cd "$d" && timeout 900 vvp dir.vvp 2>&1 || true)
  o_sw=$(cd "$d" && timeout 900 vvp sw.vvp +RATE=900 +PATTERN=0 +NODUMP 2>&1 || true)
  o_pr=$(cd "$d" && timeout 900 vvp pr.vvp +OUTSTANDING=8 +CYCLES=3000 +NODUMP 2>&1 || true)
  o_sp=$(cd "$d" && timeout 900 vvp atk.vvp +OUTSTANDING=8 +CYCLES=3000 +ATTACK=1 +NODUMP 2>&1 || true)
  o_vh=$(cd "$d" && timeout 900 vvp atk.vvp +OUTSTANDING=8 +CYCLES=3000 +ATTACK=2 +NODUMP 2>&1 || true)
  o_bh=$(cd "$d" && timeout 900 vvp bh.vvp +RATE=300 +PATTERN=0 +BLACKHOLE=4 +NODUMP 2>&1 || true)

  local p
  p=""
  echo "$o_dir" | grep -q "ALL TESTS PASSED" && p="${p}1" || p="${p}0"
  echo "$o_sw"  | grep -q "^PASS"          && p="${p}1" || p="${p}0"
  echo "$o_pr"  | grep -q "^PASS"          && p="${p}1" || p="${p}0"
  echo "$o_sp"  | grep -q "^ATTACK-PASS"   && p="${p}1" || p="${p}0"
  echo "$o_vh"  | grep -q "^ATTACK-PASS"   && p="${p}1" || p="${p}0"
  echo "$o_bh"  | grep -q "^ATTACK-PASS"   && p="${p}1" || p="${p}0"

  why() { echo "$1" | grep -E "ASSERT-FAIL|\[FAIL\]|DEADLOCK at|^FAIL|ATTACK-FAIL|^attack .*breaches [1-9]" | head -1 | sed 's/^ *//' | cut -c1-120 || true; }
  # directed: report the failing CHECK -- T7 provokes one assertion on purpose
  why_dir() { echo "$1" | grep -E "\[FAIL\]" | head -1 | sed 's/^ *//' | cut -c1-120 || true; }
  {
    echo "$p"
    echo "directed:  $(why_dir "$o_dir")"
    echo "sweep:     $(why "$o_sw")"
    echo "protocol:  $(why "$o_pr")"
    echo "spoof:     $(why "$o_sp")"
    echo "vnhop:     $(why "$o_vh")"
    echo "blackhole: $(why "$o_bh")"
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
  p=$(head -1 "$r")
  if [ "$name" = baseline ]; then
    if [ "$p" = 111111 ]; then
      echo "baseline (unmutated RTL): all six runs PASS -- harness is sound"
    else
      echo "baseline (unmutated RTL) FAILED ($p) -- the harness itself is broken"
      tail -n +2 "$r" | sed 's/^/  /'
      exit 2
    fi
    continue
  fi
  if [ "$p" = 111111 ]; then
    echo "SURVIVED  $name -- no run noticed this bug"
    survivors=$((survivors + 1))
  else
    echo "caught    $name"
    i=0
    for n in $NAMES; do
      i=$((i + 1))
      if [ "${p:$((i - 1)):1}" = 0 ]; then
        grep "^$n:" "$r" | sed 's/^/            /'
      fi
    done
  fi
done

echo
if [ "$survivors" -ne 0 ]; then
  echo "MUTATION TEST FAILED: $survivors mutant(s) survived -- the verification has a blind spot"
  exit 1
fi
echo "MUTATION TEST PASSED: every injected bug was caught (only the runs that failed are listed under each)"
