#!/usr/bin/env bash
# Formal verification (SymbiYosys + Yosys/slang), in three parts plus
# negative controls:
#
#  1. EQUIVALENCE  M7's rewritten rr_arbiter == the M1-M6 original, for
#                  N = 1..8 requesters (every width the router uses):
#                  bounded model check from reset, complete because every
#                  reachable pointer value is reached in one cycle.
#  2. PROPERTIES   rr_arbiter's grant is a one-hot subset of the requests,
#                  work-conserving (also for pass 2), and FAIR (a requester
#                  that keeps asking wins within N cycles) -- concurrent SVA,
#                  proved by k-induction: for all input sequences, unbounded.
#  3. CREDITS      a whole vc_router never violates the credit protocol on
#                  any port, and every flit leaves on a real VC in its own
#                  VN -- bounded proof, 12 cycles, two configurations.
#  4. NEGATIVE CONTROLS  each check must FAIL on a planted bug; a check that
#                  can't fail proves nothing.
#
# Usage: tools/formal.sh   (exit 0 iff every proof passes and every control fails; ~6 min)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../formal"
export PATH="/c/oss-cad-suite/bin:/c/oss-cad-suite/lib:$PATH"

WORK=runs
rm -rf "$WORK"; mkdir -p "$WORK"
bad=0

# mk_sby <name> <mode> <depth> <top> <params> <rtl-dir> <files...>
mk_sby() {
  local name=$1 mode=$2 depth=$3 top=$4 params=$5 rtl=$6; shift 6
  local reads="" files=""
  for f in "$@"; do
    # [files] paths resolve relative to the .sby file (in $WORK/), and must
    # not contain spaces (this project's path does) -- so: relative paths.
    case "$f" in mut_*) ;; *) f="../$f" ;; esac
    reads="$reads $(basename "$f")"
    files="$files"$'\n'"$f"
  done
  cat > "$WORK/$name.sby" <<EOF
[options]
mode $mode
depth $depth

[engines]
smtbmc yices

[script]
plugin -i slang
read_slang -DSYNTHESIS$reads --top $top $params
prep -top $top

[files]$files
EOF
}

# run <name> <expect: PASS|FAIL> <label>
run() {
  local name=$1 expect=$2 label=$3
  local res
  # sby exits non-zero on FAIL, so don't let its status (via pipefail) decide;
  # the verdict is SBY's final "DONE (...)" line, or ERROR if there is none.
  res=$( { (cd "$WORK" && timeout 3600 sby -f "$name.sby" 2>&1) || true; } \
         | grep -oE "\] DONE \((PASS|FAIL|ERROR|UNKNOWN)" | tail -1 | grep -oE "PASS|FAIL|ERROR|UNKNOWN" || true)
  [ -n "$res" ] || res=ERROR
  if [ "$res" = "$expect" ]; then
    printf "  %-58s %s (expected)\n" "$label" "$res"
  else
    printf "  %-58s %s  <-- expected %s (see formal/%s/%s)\n" "$label" "$res" "$expect" "$WORK" "$name"
    bad=$((bad + 1))
  fi
}

R=../rtl
echo "1. Equivalence: new rr_arbiter vs. M1-M6 original"
for n in 1 2 3 4 5 6 7 8; do
  mk_sby eq_$n bmc 6 arb_equiv "-G N=$n" $R $R/rr_arbiter.sv rr_arbiter_ref.sv arb_equiv.sv
  run eq_$n PASS "N=$n: grants identical on every cycle, all inputs"
done

echo "2. Properties of rr_arbiter (k-induction, unbounded)"
for n in 1 2 3 4 5 6 7 8; do
  mk_sby props_$n prove $((2 * n + 4)) arb_props "-G N=$n" $R $R/rr_arbiter.sv arb_props.sv
  run props_$n PASS "N=$n: one-hot subset, work-conserving, fair within $n cycles"
done

echo "3. Credit protocol of a whole vc_router (bounded, 12 cycles)"
RTL4="$R/noc_pkg.sv $R/rr_arbiter.sv $R/flit_fifo.sv $R/vc_router.sv"
mk_sby credit_vc bmc 12 router_credit "-G NUM_VNS=1 -G VCS_PER_VN=2 -G BUFFER_DEPTH=2 -G SA_ITERS=2 -G SECURE=1" $R $RTL4 router_credit.sv
run credit_vc PASS "1 VN x 2 VCs x 2, 2-pass: C1-C3"
mk_sby credit_vn bmc 12 router_credit "-G NUM_VNS=3 -G VCS_PER_VN=1 -G BUFFER_DEPTH=2 -G SA_ITERS=1 -G SECURE=1" $R $RTL4 router_credit.sv
run credit_vn PASS "3 VNs x 1 VC x 2, secure: C1-C4 (VN isolation)"

echo "4. Negative controls: each planted bug must make its check FAIL"
mut() { # <name> <file> <sed>
  mkdir -p "$WORK/mut_$1"; cp $R/*.sv "$WORK/mut_$1/"; sed -i "$3" "$WORK/mut_$1/$2"
  cmp -s "$R/$2" "$WORK/mut_$1/$2" && { echo "  ERROR: mutation $1 didn't apply"; bad=$((bad + 1)); }
}
M="mut_mask"
mut mask rr_arbiter.sv "s/ << ptr) - 1'b1);/ << ptr) << 1) - 1'b1);/; s/assign mask = ~((/assign mask = ~(((/"
mk_sby neg_eq bmc 6 arb_equiv "-G N=5" x mut_mask/rr_arbiter.sv rr_arbiter_ref.sv arb_equiv.sv
run neg_eq FAIL "equivalence vs. an off-by-one priority mask"
mut fixed rr_arbiter.sv "s/ptr_n = (win_idx == LAST) ? '0 : win_idx + 1'b1;/ptr_n = ptr;/"
mk_sby neg_fair prove 14 arb_props "-G N=5" x mut_fixed/rr_arbiter.sv arb_props.sv
run neg_fair FAIL "fairness vs. a fixed-priority arbiter"
mut ovf vc_router.sv "s/credit_count\[gi\] <= FULL_CREDIT;/credit_count[gi] <= FULL_CREDIT + 1'b1;/"
mk_sby neg_credit bmc 12 router_credit "-G NUM_VNS=1 -G VCS_PER_VN=2 -G BUFFER_DEPTH=2 -G SA_ITERS=2 -G SECURE=1" x \
  mut_ovf/noc_pkg.sv mut_ovf/rr_arbiter.sv mut_ovf/flit_fifo.sv mut_ovf/vc_router.sv router_credit.sv
run neg_credit FAIL "credit protocol vs. credits reset one too high"
mut vne vc_router.sv "s/assign ovc_cand\[go\]\[gw\] = win_vn\[go\]\[gw \/ VCS_PER_VN\] && /assign ovc_cand[go][gw] = /"
mk_sby neg_vn bmc 12 router_credit "-G NUM_VNS=3 -G VCS_PER_VN=1 -G BUFFER_DEPTH=2 -G SA_ITERS=1 -G SECURE=1" x \
  mut_vne/noc_pkg.sv mut_vne/rr_arbiter.sv mut_vne/flit_fifo.sv mut_vne/vc_router.sv router_credit.sv
run neg_vn FAIL "VN isolation vs. VC allocation that ignores the VN"

echo
if [ "$bad" -ne 0 ]; then echo "FORMAL FAILED: $bad unexpected result(s)"; exit 1; fi
echo "FORMAL PASSED: every proof holds, and every planted bug is caught"
