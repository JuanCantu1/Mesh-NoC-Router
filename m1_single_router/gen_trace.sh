#!/usr/bin/env bash
# Regenerates sim/trace.log -- the real simulation trace that the "visual
# simulator" artifact (linked from README.md) is built from. Run this
# after any change to rtl/router.sv or tb/trace_gen_tb.sv and re-embed the
# new sim/trace.log into the artifact if you want the visualization to
# reflect the change.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

mkdir -p sim

iverilog -g2012 -o sim/trace_gen_tb.vvp \
  rtl/noc_pkg.sv \
  rtl/rr_arbiter.sv \
  rtl/router.sv \
  tb/trace_gen_tb.sv

vvp sim/trace_gen_tb.vvp 2>&1 | grep -E "^(MARK|TRACE)" > sim/trace.log

echo "wrote sim/trace.log ($(wc -l < sim/trace.log) lines)"
