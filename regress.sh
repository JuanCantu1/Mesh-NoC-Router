#!/usr/bin/env bash
# Whole-project regression. Runs every milestone's own regression (run.sh)
# in order, then checks the visualizer's replay data. Every step requires
# its own PASS line and exits non-zero otherwise, so this script's exit
# code is the project's status.
#
#   ./regress.sh          M1..M8 run.sh + replay check            (~10 min)
#   ./regress.sh --full   also M8's long studies:                 (~45 min)
#                           equivalence vs. M4/M5, attack matrix (both
#                           pipeline modes), mutation testing (both modes),
#                           formal proofs, whole-mesh synthesis, the 4x4
#                           mesh study, and regenerating the replays
#
# Logs: regress_logs/<step>.log. Needs iverilog/vvp and python; M7/M8 also
# need Verilator (lint) and, for --full, Yosys/SymbiYosys (OSS CAD Suite).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

FULL=0
[ "${1:-}" = "--full" ] && FULL=1
LOGS=regress_logs
rm -rf "$LOGS" && mkdir -p "$LOGS"

names=() results=() times=()
# step <name> <pass regex> <command...>
step() {
  local name=$1 pass=$2
  shift 2
  local log="$LOGS/$name.log" t0=$SECONDS rc
  printf '%-34s ' "$name"
  "$@" > "$log" 2>&1
  rc=$?
  local dt=$((SECONDS - t0))
  if [ $rc -eq 0 ] && grep -qE "$pass" "$log"; then
    printf 'PASS  %4ds\n' "$dt"
    results+=(PASS)
  else
    printf 'FAIL  %4ds   (exit %d; see %s)\n' "$dt" "$rc" "$log"
    results+=(FAIL)
  fi
  names+=("$name"); times+=("$dt")
}

echo "=== milestone regressions ==="
step m1_single_router    "M1 REGRESSION PASSED"  bash m1_single_router/run.sh
step m2_mesh             "M2 REGRESSION PASSED"  bash m2_mesh/run.sh
step m3_flow_control     "M3 REGRESSION PASSED"  bash m3_flow_control/run.sh
step m4_verification     "M4 REGRESSION PASSED"  bash m4_verification/run.sh
step m5_virtual_networks "M5 REGRESSION PASSED"  bash m5_virtual_networks/run.sh
step m6_security         "M6 REGRESSION PASSED"  bash m6_security/run.sh
step m7_synthesis        "M7 REGRESSION PASSED"  bash m7_synthesis/run.sh
step m8_pipeline         "M8 REGRESSION PASSED"  bash m8_pipeline/run.sh
step replay_check        "REPLAY CHECK PASSED"   python visualizer/tools/check_replay.py

if [ $FULL -eq 1 ]; then
  echo
  echo "=== M8 long studies ==="
  step m8_equivalence    "EQUIVALENCE PASSED"    bash m8_pipeline/tools/equivalence_check.sh
  step m8_attacks_pipe0  "ATTACK MATRIX PASSED"  env PIPE=0 bash m8_pipeline/tools/attack_matrix.sh
  step m8_attacks_pipe1  "ATTACK MATRIX PASSED"  env PIPE=1 bash m8_pipeline/tools/attack_matrix.sh
  step m8_mutation_pipe0 "MUTATION TEST PASSED"  env PIPE=0 bash m8_pipeline/tools/mutation_test.sh
  step m8_mutation_pipe1 "MUTATION TEST PASSED"  env PIPE=1 bash m8_pipeline/tools/mutation_test.sh
  step m8_formal         "FORMAL PASSED"         bash m8_pipeline/tools/formal.sh
  step m8_synthesis      "Critical paths"        bash m8_pipeline/tools/synth.sh
  step m8_mesh_4x4       "4x4 PASSED"            bash m8_pipeline/tools/mesh_scaling.sh
  step visualizer_regen  "REPLAY CHECK PASSED"   bash visualizer/tools/make_scenarios.sh
fi

echo
nfail=0
for r in "${results[@]}"; do [ "$r" = FAIL ] && nfail=$((nfail + 1)); done
if [ $nfail -eq 0 ]; then
  echo "PROJECT REGRESSION PASSED: ${#names[@]} of ${#names[@]} steps, ${SECONDS}s"
else
  echo "PROJECT REGRESSION FAILED: $nfail of ${#names[@]} steps failed"
  exit 1
fi
