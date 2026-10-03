#!/usr/bin/env bash
# Lint: Verilator --lint-only -Wall on the RTL, both views, several configs.
#   synthesis view (-DSYNTHESIS): exactly the hardware Yosys builds
#   simulation view:              the same plus every embedded checker
# Must report ZERO warnings. Two waivers apply globally, both forced by the
# toolchain, not the design:
#   IMPORTSTAR    packages are imported at file scope (`import noc_pkg::*;`)
#                 because this Icarus build crashes on module-header imports
#   DECLFILENAME  Verilator's file-naming style rule
# Every other waiver is inline in the RTL, next to the line it covers, with
# its reason.
#
# Usage: tools/lint.sh   (exit 0 iff zero warnings everywhere)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

V=${VERILATOR:-/c/Verilator/verilator-5.032/bin/verilator.exe}
RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/vc_router.sv rtl/vc_mesh.sv"
WAIVE="-Wno-IMPORTSTAR -Wno-DECLFILENAME"
total=0

lint() { # <label> <extra args...>
  local label=$1; shift
  local n
  n=$("$V" --lint-only -Wall $WAIVE --top-module vc_mesh "$@" $RTL 2>&1 | grep -cE '^%(Warning|Error)' || true)
  printf "  %-58s %d warning(s)\n" "$label" "$n"
  total=$((total + n))
}

echo "Verilator $("$V" --version | head -1)"
lint "synthesis view, defaults (1 VN x 1 VC x 4, secure)" -DSYNTHESIS
lint "synthesis view, 3 VNs x 2 VCs x 2, 2-pass, secure"   -DSYNTHESIS -GNUM_VNS=3 -GVCS_PER_VN=2 -GBUFFER_DEPTH=2 -GSA_ITERS=2 -GSECURE=1
lint "synthesis view, 4 VCs x 2, 2-pass"                   -DSYNTHESIS -GVCS_PER_VN=4 -GBUFFER_DEPTH=2 -GSA_ITERS=2
lint "synthesis view, unprotected, 8-deep"                 -DSYNTHESIS -GSECURE=0 -GBUFFER_DEPTH=8
lint "synthesis view, two-stage, 4 VCs x 2, 2-pass"        -DSYNTHESIS -GVCS_PER_VN=4 -GBUFFER_DEPTH=2 -GSA_ITERS=2 -GPIPE=1
lint "synthesis view, two-stage, 3 VNs x 2 VCs, secure"     -DSYNTHESIS -GNUM_VNS=3 -GVCS_PER_VN=2 -GBUFFER_DEPTH=2 -GSA_ITERS=2 -GSECURE=1 -GPIPE=1
lint "simulation view (with checkers), defaults"           --timing
lint "simulation view, 3 VNs x 2 VCs x 2, 2-pass, secure"  --timing -GNUM_VNS=3 -GVCS_PER_VN=2 -GBUFFER_DEPTH=2 -GSA_ITERS=2 -GSECURE=1

echo
if [ "$total" -ne 0 ]; then echo "LINT FAILED: $total warning(s)"; exit 1; fi
echo "LINT PASSED: zero warnings"
