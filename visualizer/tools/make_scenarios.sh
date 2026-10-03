#!/usr/bin/env bash
# Runs the real M8 RTL in Icarus for every scenario the visualizer replays,
# converts each waveform to per-cycle JSON (tools/vcd2json.py), and bundles
# them into data/scenarios.js for visualizer/index.html.
#
# Every scenario is the two-stage router (PIPE=1) -- the final design.
#   uniform      4 VCs x 2, 2-pass, hardened; uniform random traffic at 0.40
#   deadlock     coherence protocol, every message class sharing ONE VN
#   vns          the same protocol, same seed, one VN per class (REQ/SNP/RSP)
#   bh_open      tile (1,1) turns into a black hole at cycle 1000, unprotected
#   bh_secure    the same attack against the hardened router (watchdog on)
#
# Each run's own PASS/FAIL line is checked, so the replay only ever shows
# runs that behaved the way the M8 regression says they do.
#
# usage: tools/make_scenarios.sh      (~1 min; needs iverilog, python)
# then open noc_replay.html (self-contained) in a browser
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

M8=../m8_pipeline
RTL="$M8/rtl/noc_pkg.sv $M8/rtl/rr_arbiter.sv $M8/rtl/flit_fifo.sv $M8/rtl/vc_router.sv $M8/rtl/vc_mesh.sv"
mkdir -p sim data

# run <name> <pass regex> <vvp> <first cycle> <last cycle> <plusargs...>
run() {
  local name=$1 pass=$2 vvp=$3 c0=$4 c1=$5
  shift 5
  mkdir -p "sim/$name/sim" && rm -f "sim/$name"/sim/*.vcd
  local out
  out=$(cd "sim/$name" && vvp "../../$vvp" "$@" 2>&1) || true
  echo "$out" | grep -E "^(PASS|FAIL)|DEADLOCK at|quarantine" | head -4 | sed "s/^/  [$name] /" || true
  if ! echo "$out" | grep -qE "$pass"; then
    echo "$out" | tail -20
    echo "scenario $name did not produce its expected result" >&2
    exit 1
  fi
  echo "$out" > "sim/$name/log.txt"
  local vcd
  vcd=$(ls sim/$name/sim/*.vcd)
  python tools/vcd2json.py "$vcd" "data/$name.json" --name "$name" --from "$c0" --to "$c1"
  rm -f "$vcd"   # tens of MB each; the JSON keeps what the page needs
}

echo "=== compiling M8 RTL + testbenches ==="
iverilog -g2012 -DPROTO_NUM_VNS=1 -DPROTO_SECURE=0 -DPROTO_PIPE=1 -o sim/proto_1vn.vvp $RTL $M8/tb/protocol_tb.sv
iverilog -g2012 -DPROTO_NUM_VNS=3 -DPROTO_SECURE=0 -DPROTO_PIPE=1 -o sim/proto_3vn.vvp $RTL $M8/tb/protocol_tb.sv
for sec in 0 1; do
  iverilog -g2012 -DSWEEP_VCS_PER_VN=4 -DSWEEP_BUFFER_DEPTH=2 -DSWEEP_SA_ITERS=2 -DSWEEP_SECURE=$sec -DSWEEP_PIPE=1 \
    -o sim/sweep_s$sec.vvp $RTL $M8/tb/latency_sweep_tb.sv
done

echo "=== running scenarios ==="
# deadlock: seed 3 with 12 transactions in flight per tile freezes for good
# around cycle 211 (the testbench declares it 500 idle cycles later)
run deadlock "^PASS"  sim/proto_1vn.vvp 0 330 +OUTSTANDING=12 +CYCLES=1500 +SEED=3 +EXPECT_DEADLOCK
run vns      "^PASS"  sim/proto_3vn.vvp 0 330 +OUTSTANDING=12 +CYCLES=1500 +SEED=3
run uniform  "^PASS"  sim/sweep_s1.vvp 1000 1200 +PATTERN=0 +RATE=400
run bh_open   "^ATTACK-PASS" sim/sweep_s0.vvp 960 1400 +PATTERN=0 +RATE=200 +BLACKHOLE=4 +BH_START=1000 +EXPECT_COMPROMISE
run bh_secure "^(ATTACK-)?PASS" sim/sweep_s1.vvp 960 1400 +PATTERN=0 +RATE=200 +BLACKHOLE=4 +BH_START=1000

echo "=== cross-checking the replays against routing/flow-control rules ==="
python tools/check_replay.py

echo "=== bundling ==="
python tools/bundle.py
