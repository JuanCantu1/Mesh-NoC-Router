# Guide: testing the project yourself

A hands-on script for checking every claim in this repo with your own runs.
Each exercise lists the command, what you should see, and what it proves.
Commands are for Git Bash on Windows, from the project root.

## 0. Toolchain

| Tool | Used by | Where the scripts look |
|---|---|---|
| Icarus Verilog (`iverilog`, `vvp`) | every simulation | `PATH` |
| GTKWave | viewing waveforms (optional) | `PATH` |
| Python 3 (standard library) | analysis, visualizer | `PATH` (`python`) |
| Python + matplotlib | `tools/plot_*.py` only | any Python with matplotlib installed |
| Verilator 5.x | M7/M8 lint | `$VERILATOR`, default `/c/Verilator/verilator-5.032/bin/verilator.exe` |
| Yosys + slang, SymbiYosys | M7/M8 synthesis and formal | `/c/oss-cad-suite/bin` (added to `PATH` by the scripts) |

Quick check: `iverilog -V | head -1 && python --version`.

## 1. One command for everything

```bash
./regress.sh            # every milestone's run.sh + replay data check
./regress.sh --full     # plus M8's long studies (equivalence, attacks,
                        # mutation, formal, synthesis, 4x4 mesh, replays)
```

Expected: one `PASS` line per step, then `PROJECT REGRESSION PASSED`. A
failing step prints `FAIL` and the log path under `regress_logs/`, and the
script exits 1. Every milestone's `run.sh` gates on its testbench's own PASS
line, so a crash, hang or wrong result can't slip through as success.

**Try breaking it.** Copy a milestone folder somewhere else, plant a bug, and
run its `run.sh`. For example, in `m1_single_router/rtl/router.sv`, route
east-bound flits west (`PORT_E` -> `PORT_W` on the `dest_x > X_ID` line).
You should get `M1 REGRESSION FAILED: router directed tests` and exit 1.
M4–M8 automate this kind of check: `tools/mutation_test.sh` plants 7–11
known bugs and requires every one to be caught.

## 2. Exercises, milestone by milestone

### M1–M3: one router, a mesh, credit flow control
```bash
bash m1_single_router/run.sh    # 13/13 directed tests
bash m2_mesh/run.sh             # 11/11, corner-to-corner XY routing
bash m3_flow_control/run.sh     # FIFO unit test + 23/23 credit tests
gtkwave m3_flow_control/sim/router_tb.vcd &   # optional
```
In the waveform, find a test where an output's credits reach 0. That
output's `out_valid` must stay low until a `credit_return` pulse comes back.
That behavior is credit-based flow control.

### M4: traffic patterns, latency/throughput, an analytic model
```bash
bash m4_verification/run.sh                  # smoke + 4 traffic patterns + 1 sweep point
bash m4_verification/tools/sweep.sh          # 80 points, ~45 s
python m4_verification/tools/theory_check.py # measured vs. channel-load model
```
Expected: uniform saturation is around 0.72–0.75 of a 1.00 bound. The README
explains the gap (head-of-line blocking) and shows that deeper buffers
barely help.

### M5: virtual channels, virtual networks, protocol deadlock
```bash
bash m5_virtual_networks/run.sh
bash m5_virtual_networks/tools/deadlock_demo.sh
```
Expected: shared buffers deadlock at 8 or more outstanding transactions, and
three shared VCs at 32 or more. One VN per message class never deadlocks.
The deadlock printout says which message each stuck tile is waiting for.

### M6: attacks and defenses
```bash
bash m6_security/run.sh
bash m6_security/tools/attack_matrix.sh      # ~6 min
```
Expected: every attack (`spoof`, `vn-hop`, `blackhole`) shows `COMPROMISED`
against `SECURE=0` and is contained with `SECURE=1`. The flood control
harms neither. Then read "Known limitation: deadlock looks like a black
hole" in the M6 README, and reproduce it with the command shown there.

### M7: synthesis, formal, lint
```bash
bash m7_synthesis/run.sh            # includes Verilator lint
bash m7_synthesis/tools/formal.sh   # proofs + 4 negative controls (~4 min)
```
Expected: every proof `PASS (expected)`, and every planted bug
`FAIL (expected)`. A negative control that passes would mean the proof
can't see that bug.

### M8: pipelining, timing, mesh size
```bash
bash m8_pipeline/run.sh                 # 15 steps, both pipeline modes
bash m8_pipeline/tools/synth.sh         # whole-mesh sky130 timing (~3 min)
bash m8_pipeline/tools/mesh_scaling.sh  # the same checks on a 4x4 mesh (~6 min)
```
Expected critical paths, two-stage: 1 VC × 4 at 3.33 ns, 4 VCs × 2 2-pass
at 7.94 ns. The 4×4 study checks zero-load latency against
(hops + 1) × 2 cycles, and peak throughput against the channel-load bound.

## 3. The visual replay

Open `visualizer/noc_replay.html` in a browser (it works offline).

1. **Uniform traffic.** Click a flit and press → repeatedly. It moves X
   first, then Y. The hop list shows one router every 2 cycles, which is
   the two-stage pipeline.
2. **Protocol deadlock.** Play at 8 cycles/s. The left mesh stops for good
   after cycle 211, while the right keeps going. Hover over stuck slots and
   note the mix of REQ, SNP and RSP sitting in shared FIFOs.
3. **Black hole.** Jump to `#blackhole.1302`. The right mesh's center
   router is outlined (quarantined), and × marks show discarded flits.
   Compare the two sparklines after that point.

To regenerate it from fresh simulations, run
`bash visualizer/tools/make_scenarios.sh` (about 1 minute). The script
refuses to bundle data that fails `check_replay.py`.

## 4. Things worth trying beyond the scripts

- Change `WD_LIMIT` (`-DSWEEP_WD_LIMIT=64`) and rerun the black hole. The
  quarantine comes sooner and victim tail latency drops; see M6's table.
- Run the protocol testbench with `+OUTSTANDING=64` on the 3-VN mesh. It
  should never deadlock, at any seed.
- Change the mesh size: `-DSWEEP_MESH_W=4 -DSWEEP_MESH_H=2` passes the
  uniform, bit-complement and hotspot patterns. Coordinates are 4 bits, so
  meshes up to 16×16 work. Transpose is refused on a non-square mesh,
  because (x,y) -> (y,x) would leave the grid. Before that check existed,
  the mesh's own edge assertion caught those flits as misroutes.
- Open any `sim/*.vcd` in GTKWave and find `alarm`, `quarantine`,
  `send1` (stage-1 grant) and the FIFO `count` signals in each router.
