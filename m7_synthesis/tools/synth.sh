#!/usr/bin/env bash
# Synthesize one vc_router (mesh center, so no edge logic folds away) per
# configuration onto the SkyWater sky130 high-density standard cells
# (typical corner, 25 C, 1.8 V) and report area and critical-path delay.
#
#   frontend  Yosys + slang (full SystemVerilog), -DSYNTHESIS: every
#             verification-only construct in the RTL is behind
#             `ifndef SYNTHESIS, so only real hardware is synthesized
#   mapping   synth -flatten; dfflibmap; abc -liberty -D <target>
#   area      stat -liberty: total cell area (um^2), and how much is flops
#   timing    ABC's static timing (stime) on the mapped netlist: the longest
#             combinational path between registers/ports, in ns. No wire
#             load, no clock-to-q or setup -- a pre-layout logic-depth
#             estimate, good for COMPARING configurations, not a signoff
#             frequency.
#
# Usage: tools/synth.sh   (CONFIGS="name:VNS:VCS:DEPTH:SA:SECURE ..." to override; ~3 min)
#        PARSE_ONLY=1 tools/synth.sh   re-tabulate existing logs
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PATH="/c/oss-cad-suite/bin:/c/oss-cad-suite/lib:$PATH"

LIB=syn/sky130_fd_sc_hd__tt_025C_1v80.lib
[ -f "$LIB" ] || { echo "missing $LIB (see README: Synthesis setup)"; exit 2; }
RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/vc_router.sv"
mkdir -p syn/out results

CONFIGS=${CONFIGS:-"
m4_baseline:1:1:4:1:0
deeper_fifo:1:1:8:1:0
vcs_1pass:1:4:2:1:0
vcs_2pass:1:4:2:2:0
vns:3:1:4:1:0
vns_secure:3:1:4:1:1
vcs_2pass_secure:1:4:2:2:1
full:3:2:2:2:1
"}

run_one() {
  IFS=: read -r name vns vcs depth sa sec <<< "$1"
  cat > "syn/out/$name.ys" <<EOF
read_slang -DSYNTHESIS $RTL --top vc_router -G X_ID=1 -G Y_ID=1 -G NUM_VNS=$vns -G VCS_PER_VN=$vcs -G BUFFER_DEPTH=$depth -G SA_ITERS=$sa -G SECURE=$sec
synth -top vc_router -flatten
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
export RTL LIB

if [ -z "${PARSE_ONLY:-}" ]; then
  rm -f syn/out/*.failed
  for c in $CONFIGS; do echo "$c"; done | xargs -P 4 -I{} bash -c 'run_one "{}"'
fi

OUT=results/synth.csv
rm -f syn/out/critical_paths.txt
echo "config,num_vns,vcs_per_vn,buffer_depth,sa_iters,secure,area_um2,flop_area_um2,cells,flops,crit_path_ns" > "$OUT"
for c in $CONFIGS; do
  IFS=: read -r name vns vcs depth sa sec <<< "$c"
  log=syn/out/$name.log
  if [ -f "syn/out/$name.failed" ] || ! grep -q "Chip area" "$log"; then echo "SYNTHESIS FAILED: $name (see $log)"; exit 1; fi
  area=$(grep -E "Chip area for (top )?module" "$log" | tail -1 | grep -oE "[0-9]+\.[0-9]+$")
  # the final `stat -liberty` (Yosys prints large areas as e.g. 2.04E+04)
  final=$(awk '/Printing statistics/ {n++} n >= 2' "$log")
  cells=$(echo "$final" | grep -E "^ +[0-9]+ +[0-9.E+-]+ +cells$" | tail -1 | awk '{print $1}')
  # flops: every sky130 sequential cell is a df*/edf*/sdf*/dl* cell
  flops=$(echo "$final" | grep -E "^ +[0-9]+ +[0-9.E+-]+ +sky130_fd_sc_hd__(df|edf|sdf|dl)" | awk '{s += $1} END {print s+0}')
  flop_area=$(echo "$final" | grep -E "^ +[0-9]+ +[0-9.E+-]+ +sky130_fd_sc_hd__(df|edf|sdf|dl)" | awk '{s += $2} END {printf "%.1f", s}')
  delay=$(grep -oE "Delay = +[0-9.]+ ps" "$log" | tail -1 | grep -oE "[0-9.]+" | head -1)
  grep -E "ABC: Start-point" "$log" | tail -1 | sed "s/^ABC: /  $name: /" >> syn/out/critical_paths.txt
  delay_ns=$(awk -v d="$delay" 'BEGIN {printf "%.2f", d/1000}')
  echo "$name,$vns,$vcs,$depth,$sa,$sec,$area,$flop_area,$cells,$flops,$delay_ns" >> "$OUT"
done

echo "Wrote $OUT"
echo
awk -F, 'NR == 1 { next }
  NR == 2 { base = $7 }
  { printf "  %-17s %d VN x %d VC x %d, %d-pass, SECURE=%d  area %9.0f um2 (%5.1f%% flops, %+6.1f%% vs M4)  flops %5d  crit path %5.2f ns\n",
           $1, $2, $3, $4, $5, $6, $7, 100*$8/$7, 100*($7-base)/base, $10, $11 }' "$OUT"
echo
echo "Critical-path endpoints:"
cat syn/out/critical_paths.txt
