#!/usr/bin/env bash
# Mutation test: verifies the verification.
#
# A checker that has never fired might simply be unable to fire. Each
# "mutant" below is a copy of the RTL with one deliberate, realistic bug
# injected; both randomized testbenches are run against it, and every
# mutant must make at least one of them FAIL. An unmutated baseline is run
# through the exact same harness first and must PASS both -- otherwise a
# broken harness could report every mutant as "caught".
#
# The mutants are chosen to need *different* checkers:
#   credit_overflow   credit counters reset one above buffer capacity.
#                     Invisible to the scoreboard until buffers actually
#                     fill (then flits are silently dropped); the embedded
#                     credit-bound invariant fires on the first cycle.
#   fixed_priority    round-robin pointer never advances. Every packet is
#                     still delivered correctly, just unfairly -- no data
#                     check can see it; only the bounded-wait (starvation)
#                     invariant can.
#   route_east_west   packets that need to go East are routed West. The
#                     scoreboard and the post-load drain check catch this
#                     (packets pile up against the mesh edge and never
#                     arrive).
#
# Usage: tools/mutation_test.sh   (exit 0 only if every mutant is caught)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

survivors=0

run_case() {
  local name=$1 file=$2 expr=$3
  local d="$WORK/$name"
  mkdir -p "$d/sim"
  cp rtl/*.sv "$d/"
  if [ -n "$expr" ]; then
    sed -i "$expr" "$d/$file"
    if cmp -s "rtl/$file" "$d/$file"; then
      echo "ERROR: mutation '$name' did not change $file (pattern not found) -- update this script"
      exit 2
    fi
  fi
  local rtl="$d/noc_pkg.sv $d/rr_arbiter.sv $d/flit_fifo.sv $d/router.sv $d/mesh_credit.sv"
  iverilog -g2012 -DPATTERN=0 -o "$d/rt.vvp" $rtl tb/random_traffic_tb.sv 2>/dev/null
  iverilog -g2012 -o "$d/sw.vvp" $rtl tb/latency_sweep_tb.sv 2>/dev/null

  local rt_out sw_out rt_pass sw_pass
  rt_out=$(cd "$d" && vvp rt.vvp 2>&1 || true)
  sw_out=$(cd "$d" && vvp sw.vvp +RATE=900 +PATTERN=0 +NODUMP 2>&1 || true)
  echo "$rt_out" | grep -q "ALL TRAFFIC ACCOUNTED FOR -- PASS" && rt_pass=1 || rt_pass=0
  echo "$sw_out" | grep -q "^PASS" && sw_pass=1 || sw_pass=0

  # First distinct failure reason from each testbench, for the report.
  # (`|| true`: on a passing run grep finds nothing and exits 1, which
  # pipefail + set -e would otherwise turn into a silent script abort.)
  local rt_why sw_why
  rt_why=$(echo "$rt_out" | grep -E "ASSERT-FAIL|\[FAIL\]| FAIL --" | head -1 | sed 's/^ *//' | cut -c1-110 || true)
  sw_why=$(echo "$sw_out" | grep -E "ASSERT-FAIL|\[FAIL\]" | head -1 | sed 's/^ *//' | cut -c1-110 || true)

  if [ -z "$expr" ]; then
    if [ "$rt_pass" -eq 1 ] && [ "$sw_pass" -eq 1 ]; then
      echo "baseline (unmutated RTL): both testbenches PASS -- harness is sound"
    else
      echo "baseline (unmutated RTL) FAILED -- the harness itself is broken; mutant results would be meaningless"
      echo "  random_traffic_tb: $rt_why"
      echo "  latency_sweep_tb:  $sw_why"
      exit 2
    fi
    return
  fi

  if [ "$rt_pass" -eq 1 ] && [ "$sw_pass" -eq 1 ]; then
    echo "SURVIVED  $name -- neither testbench noticed this bug"
    survivors=$((survivors + 1))
  else
    echo "caught    $name"
    [ "$rt_pass" -eq 0 ] && echo "            random_traffic_tb: $rt_why" || echo "            random_traffic_tb: (passed -- missed it)"
    [ "$sw_pass" -eq 0 ] && echo "            latency_sweep_tb:  $sw_why" || echo "            latency_sweep_tb:  (passed -- missed it)"
  fi
}

run_case baseline        ""               ""
run_case credit_overflow router.sv        's/credit_count\[gc\] <= BUFFER_DEPTH;/credit_count[gc] <= BUFFER_DEPTH + 1;/'
run_case fixed_priority  rr_arbiter.sv    "s/ptr_n = (win_idx == NUM_REQ-1) ? '0 : win_idx + 1'b1;/ptr_n = ptr;/"
run_case route_east_west router.sv        "s/\(if (f\.dest_x > X_ID) *route_sel\[gp\] = 3'(\)PORT_E/\1PORT_W/"

echo
if [ "$survivors" -ne 0 ]; then
  echo "MUTATION TEST FAILED: $survivors mutant(s) survived -- the verification has a blind spot"
  exit 1
fi
echo "MUTATION TEST PASSED: every injected bug was caught"
