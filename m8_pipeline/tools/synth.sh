#!/usr/bin/env bash
# Synthesize the whole 3x3 mesh (flattened) per configuration onto the
# SkyWater sky130 high-density standard cells (typical corner, 25 C, 1.8 V)
# and report area and critical-path delay.
#
# Why the MESH, not one router (M7 synthesized one router alone): a hop
# doesn't end at a router's output port -- it ends in the NEXT router's
# input buffer. Synthesized alone, a router's output and input ports are
# free endpoints, and a path that crosses the link (this router's crossbar
# + the next router's input logic, in the same cycle) is cut in two and
# never measured whole. In the flattened mesh only the tiles' ports are
# endpoints, so every router-to-router path is measured end to end.
#
#   frontend  Yosys + slang (full SystemVerilog), -DSYNTHESIS: every
#             verification-only construct in the RTL is behind
#             `ifndef SYNTHESIS, so only real hardware is synthesized
#   mapping   synth -flatten; dfflibmap; abc -liberty
#   area      stat -liberty: total cell area of the mesh (um^2); /9 per router
#   timing    ABC's static timing (stime) on the mapped netlist: the longest
#             combinational path between registers/ports, in ns. No wire
#             load, no clock-to-q or setup -- a pre-layout logic-depth
#             estimate, good for COMPARING configurations, not a signoff
#             frequency.
#
# Usage: tools/synth.sh
#   CONFIGS="name:VNS:VCS:DEPTH:SA:SECURE:PIPE ..."   configurations (default: the M8 set below)
#   RTL_DIR=../m6_security/rtl                         synthesize another milestone's RTL
#                                                      (PIPE is ignored for RTL without it)
#   OUT=results/x.csv   PARSE_ONLY=1 (re-tabulate existing logs)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PATH="/c/oss-cad-suite/bin:/c/oss-cad-suite/lib:$PATH"

LIB=syn/sky130_fd_sc_hd__tt_025C_1v80.lib
[ -f "$LIB" ] || { echo "missing $LIB (see README: Synthesis setup)"; exit 2; }
RTL_DIR=${RTL_DIR:-rtl}
RTL="$RTL_DIR/noc_pkg.sv $RTL_DIR/rr_arbiter.sv $RTL_DIR/flit_fifo.sv $RTL_DIR/vc_router.sv $RTL_DIR/vc_mesh.sv"
OUT=${OUT:-results/synth.csv}
mkdir -p syn/out results

CONFIGS=${CONFIGS:-"
m4_router:1:1:4:1:0:0
vcs_1pass:1:4:2:1:0:0
vcs_2pass:1:4:2:2:0:0
vcs_1pass_pipe:1:4:2:1:0:1
vcs_2pass_pipe:1:4:2:2:0:1
vcs_2pass_secure_pipe:1:4:2:2:1:1
full_pipe:3:2:2:2:1:1
"}

run_one() {
  IFS=: read -r name vns vcs depth sa sec pipe <<< "$1"
  local pipe_g=""
  grep -q "parameter int PIPE" "$RTL_DIR/vc_mesh.sv" && pipe_g="-G PIPE=${pipe:-0}"
  cat > "syn/out/$name.ys" <<EOF
read_slang -DSYNTHESIS $RTL --top vc_mesh -G NUM_VNS=$vns -G VCS_PER_VN=$vcs -G BUFFER_DEPTH=$depth -G SA_ITERS=$sa -G SECURE=$sec $pipe_g
synth -top vc_mesh -flatten
dfflibmap -liberty $LIB -dont_use sky130_fd_sc_hd__lpflow_*
abc -liberty $LIB -dont_use sky130_fd_sc_hd__lpflow_* -script +strash;dc2;dretime;strash;&get,-n;&dch,-f;&nf,-D,10000;&put;buffer;upsize,-D,10000;dnsize,-D,10000;stime,-p
opt_clean
stat -liberty $LIB
EOF
  # (one retry: several large Yosys runs at once can crash for lack of memory)
  yosys -m slang -q -l "syn/out/$name.log" -s "syn/out/$name.ys" > /dev/null 2>&1 \
    || yosys -m slang -q -l "syn/out/$name.log" -s "syn/out/$name.ys" > /dev/null 2>&1 \
    || echo "FAILED $name" > "syn/out/$name.failed"
}
export -f run_one
export RTL RTL_DIR LIB

if [ -z "${PARSE_ONLY:-}" ]; then
  for c in $CONFIGS; do rm -f "syn/out/${c%%:*}.failed"; done
  for c in $CONFIGS; do echo "$c"; done | xargs -P 3 -I{} bash -c 'run_one "{}"'
fi

echo "config,num_vns,vcs_per_vn,buffer_depth,sa_iters,secure,pipe,mesh_area_um2,area_per_router_um2,flops,crit_path_ns,critical_path" > "$OUT"
for c in $CONFIGS; do
  IFS=: read -r name vns vcs depth sa sec pipe <<< "$c"
  log=syn/out/$name.log
  if [ -f "syn/out/$name.failed" ] || ! grep -q "Chip area" "$log"; then echo "SYNTHESIS FAILED: $name (see $log)"; exit 1; fi
  area=$(grep -E "Chip area for (top )?module" "$log" | tail -1 | grep -oE "[0-9]+\.[0-9]+$")
  final=$(awk '/Printing statistics/ {n++} n >= 2' "$log")   # the final, mapped `stat`
  flops=$(echo "$final" | grep -E "^ +[0-9]+ +[0-9.E+-]+ +sky130_fd_sc_hd__(df|edf|sdf|dl)" | awk '{s += $1} END {print s+0}')
  delay=$(grep -oE "Delay = +[0-9.]+ ps" "$log" | tail -1 | grep -oE "[0-9.]+" | head -1)
  path=$(grep -E "ABC: Start-point" "$log" | tail -1 | sed -E 's/^ABC: Start-point = [a-z0-9]+ \(\\?([^)]*)\)\.  End-point = [a-z0-9]+ \(\\?([^)]*)\)\./\1 -> \2/; s/ \[[0-9]+\]//g')
  awk -v n="$name" -v vns="$vns" -v vcs="$vcs" -v d="$depth" -v sa="$sa" -v sec="$sec" -v p="${pipe:-0}" \
      -v a="$area" -v f="$flops" -v dl="$delay" -v path="$path" \
      'BEGIN { printf "%s,%s,%s,%s,%s,%s,%s,%.0f,%.0f,%s,%.2f,\"%s\"\n", n, vns, vcs, d, sa, sec, p, a, a/9, f, dl/1000, path }' >> "$OUT"
done

echo "Wrote $OUT"
echo
awk -F, 'NR == 1 { next }
  { printf "  %-22s %d VN x %d VC x %d, %d-pass, SECURE=%d, %d-stage   %7.0f um2/router   crit path %5.2f ns\n",
           $1, $2, $3, $4, $5, $6, $7 + 1, $9, $11 }' "$OUT"
echo
echo "Critical paths (start -> end):"
awk -F, 'NR > 1 { printf "  %-22s %s\n", $1, $12 }' "$OUT" | tr -d '"'
