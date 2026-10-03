# Mesh NoC Router

A parameterizable mesh **Network-on-Chip (NoC) router** in SystemVerilog,
built from scratch in eight milestones. It starts as one combinational
5-port router and ends as a two-stage-pipelined, virtual-channel router
for a coherence-style protocol, hardened against a compromised tile. Along
the way the router is synthesized on a real cell library, checked with
formal proofs, and verified against analytic models.

Everything is open source and reproducible on a laptop:
- simulation in Icarus Verilog;
- synthesis with Yosys on the SkyWater sky130 cells;
- formal proofs in SymbiYosys;
- lint with Verilator.

Every testbench checks itself and prints PASS or FAIL. One command,
[`./regress.sh`](regress.sh), reruns the whole project.

## Visual guides

Three interactive pages. Start with these if you are new to NoCs, or if
you'd rather watch the design run than read RTL.

| Page | What it shows |
|---|---|
| **[NoC Router 101](https://claude.ai/code/artifact/07dc8e74-d3c5-4ccc-9fe4-c1c3e0c9a40c)** | A diagram-first introduction that assumes no background: what a NoC is and why a chip needs one, mesh topology, what's inside a router, the packet format, XY routing, arbitration, and handshakes. |
| **[Router Replay](https://claude.ai/code/artifact/f8031dc8-cfcc-4917-b892-c6d98318f1b2)** | The M1 router, replayed cycle by cycle from a real Icarus simulation. Packets arrive, lose arbitration, wait, and leave on the right port. |
| **[NoC Mesh Replay](https://claude.ai/artifact/CDwjdsUh8pN7pe44jPYvUN)** | The final router (M8) on the whole 3×3 mesh, replayed from RTL simulation in three scenarios (below). Click any flit to follow it hop by hop. Also in this repo as a single offline file: [`visualizer/noc_replay.html`](visualizer/noc_replay.html). |

The three Mesh Replay scenarios:
- uniform traffic;
- a protocol deadlock next to the same traffic on virtual networks;
- a black-hole attack against the unprotected and the hardened router.

Every frame of both replays comes from a simulation waveform; nothing is
hand-animated. For the mesh replay, a checker rejects the data unless every
link handoff, route, and buffer level obeys the router's rules
([details](visualizer/README.md)).

---

## Contents

1. [Headline results](#headline-results)
2. [Background: what a NoC router does](#background-what-a-noc-router-does)
3. [The build, milestone by milestone](#the-build-milestone-by-milestone)
4. [The final design](#the-final-design)
5. [How it is verified](#how-it-is-verified)
6. [Running it](#running-it)
7. [Repo layout](#repo-layout)
8. [Limitations and next steps](#limitations-and-next-steps)
9. [Glossary](#glossary)

---

## Headline results

| Question | Answer | Where |
|---|---|---|
| How much do virtual channels buy? | Peak uniform throughput **0.756 -> 0.905** flits/node/cycle (+20%). At equal storage the gain is +12% (vs 0.811), and it takes both VCs and a 2-pass allocator. | [M5](m5_virtual_networks/README.md) |
| Can coherence traffic deadlock the network? | Yes. With shared buffers it deadlocks at 8+ outstanding transactions per tile, and tripling the buffers only moves the cliff to 32. With **one virtual network per message class: 0 deadlocks in 48 runs**, up to 64 outstanding. | [M5](m5_virtual_networks/README.md) |
| Can one compromised tile hurt the others? | Against the unprotected router, spoofing, VN hopping and black-holing all succeed. The hardened local port contains all three, and with no attacker present it behaves identically, digit for digit, over 288 runs. | [M6](m6_security/README.md) |
| What does the hardware cost? | Synthesized as a whole 3×3 mesh on sky130, typical corner, then divided per router. Simple router: 25,600 µm² and 3.95 ns critical path. VC router with 2-pass allocation: 54,500 µm² and 8.66 ns. Security costs no area (−3.4%). | [M7](m7_synthesis/README.md), [M8](m8_pipeline/README.md) |
| Which router should a chip build? | It depends on the clock. **Under ~4 ns**, build the pipelined simple router (0.221 flits/node/ns). **At ~8 ns or slower**, build the 4-VC router with 2-pass allocation (12–22% more bandwidth). Virtual networks are required either way. | [M8](m8_pipeline/README.md) |
| Does it scale past 3×3? | On 4×4, latency matches a hop-count model, and throughput stays under the channel-load bound with VCs gaining more (+31%). The protocol and security results hold. | [M8](m8_pipeline/README.md#one-size-up-the-44-mesh) |

---

## Background: what a NoC router does

A modern chip has many agents: cores, caches, memory controllers,
accelerators. One shared bus can't carry their traffic, so large chips use
a **network-on-chip**. Each agent ("tile") connects to a small router, the
routers connect to their neighbors, and messages hop router to router
until they arrive. A 2D mesh is a common layout for large multicore
chips:

```
       x=0          x=1          x=2
    +-------+    +-------+    +-------+
y=0 |  R    |<-->|  R    |<-->|  R    |      R = router (5 ports:
    | (0,0) |    | (1,0) |    | (2,0) |          N, S, E, W, Local)
    +---+---+    +---+---+    +---+---+      each router's Local port
        ^            ^            ^          connects its own tile
        v            v            v          (core, cache slice, ...)
    +---+---+    +---+---+    +---+---+
y=1 |  R    |<-->|  R    |<-->|  R    |
    | (0,1) |    | (1,1) |    | (2,1) |      tile id = y * W + x
    +---+---+    +---+---+    +---+---+
        ^            ^            ^
        v            v            v
    +---+---+    +---+---+    +---+---+
y=2 |  R    |<-->|  R    |<-->|  R    |
    | (0,2) |    | (1,2) |    | (2,2) |
    +-------+    +-------+    +-------+
```

A router's job each cycle:
1. **Buffer** what arrives.
2. **Route.** Pick the output port. This project uses **XY
   (dimension-order) routing**: travel along X to the destination column,
   then along Y. Routes are fixed and minimal, and routing alone can never
   deadlock.
3. **Arbitrate.** When several inputs want the same output, a round-robin
   arbiter picks one fairly.
4. **Flow control.** Never send unless the next router has room.

Everything travels as a single-flit packet. The final flit is 34 bits:

```
 33   32 31  28 27  24 23  20 19  16 15                0
+-------+------+------+------+------+-------------------+
| class | srcX | srcY | dstX | dstY |      payload      |
+-------+------+------+------+------+-------------------+
  REQ/SNP/RSP   4-bit coordinates (meshes up to 16x16)   16 bits
```

---

## The build, milestone by milestone

Each milestone is a self-contained folder with its own RTL, testbenches,
tools, README and `run.sh`. Later milestones copy and extend earlier ones
rather than rewrite them, and each was re-verified against the one
before.

### M1: a single router ([README](m1_single_router/README.md))

A 5-port router with XY routing and round-robin arbitration per output, and
a valid/ready handshake on every port. It is purely combinational: a
packet that wins arbitration passes through in the same cycle.
- **Verified:** 13 directed tests covering straight-through and turning
  routes, delivery to and injection from the local tile, fair arbitration
  under contention, and backpressure.

### M2: a full mesh ([README](m2_mesh/README.md))

A 3×3 grid of M1 routers, with edge ports tied off. It proves XY routing
composes across hops, including corner-to-corner paths and cross-router
contention.
- **Verified:** 11 directed tests.
- **Finding:** with no registers anywhere, a 4-hop packet arrives in the
  cycle it was sent. The whole mesh is one combinational path, which no
  real chip could close timing on. That motivates M3.

### M3: credit-based flow control ([README](m3_flow_control/README.md))

The handshake is replaced by what real interconnects use. Each input
gets a FIFO, and each output keeps a **credit counter**: the free slots
it knows the next router has.

```
sender:   credits = BUFFER_DEPTH at reset
          send only if credits > 0   ->  credits - 1
receiver: pops a flit from its FIFO  ->  credit_return pulse  ->  sender credits + 1
```

There are no combinational `ready` paths between routers anymore, every
hop is registered, and a flit is never dropped for lack of space.
- **Verified:** a FIFO unit test, plus 23 router tests. They cover credit
  conservation, full-buffer backpressure, and credit return under load.

### M4: real verification ([README](m4_verification/README.md))

Directed tests can't show a router works under sustained load, so this
milestone builds that evidence.
- **Randomized-traffic scoreboard** across four synthetic patterns:
  - uniform random;
  - transpose;
  - bit-complement;
  - hotspot.

  Every packet is accounted for: no loss, duplication, misroute, or
  reordering.
- **Invariants checked every cycle in every router:** credit
  conservation, no FIFO overflow, and arbiter fairness.
- **Latency/throughput sweep:** 80 load points, cross-checked against an
  **analytic channel-load model** of XY routing on the mesh.
  - Zero-load latency matches the model within 0.05 cycles for every
    pattern.
  - Three of the four patterns saturate exactly where the wiring says
    they must:

| Pattern | Saturation bound (model) | Measured saturation |
|---|---|---|
| uniform random | 1.00 | 0.70–0.75 |
| transpose | 0.44 | 0.40–0.45 |
| bit-complement | 0.73 | 0.70–0.75 |
| hotspot | 0.36 | 0.35–0.40 |

- **Finding:** uniform traffic is the exception. It stalls at about 75%
  of its bound because of **head-of-line blocking**: a blocked flit at
  the head of a FIFO stalls everything behind it. Doubling the buffer
  depth gains only 7%. The fix isn't more buffer. It's more queues,
  which is M5.
- **Mutation-tested:** bugs planted on purpose must make the testbenches
  fail, so a PASS means something.

### M5: virtual channels and virtual networks ([README](m5_virtual_networks/README.md))

**Virtual channels (VCs).** Each input port gets several independent FIFOs
sharing one physical link, so a blocked flit no longer blocks the flits
behind it. That adds two allocators:
- **VC allocation:** claim a free VC at the next router;
- **Switch allocation:** separable and input-first. An optional second
  pass, iSLIP-style, fills outputs the first pass left idle without
  disturbing fairness.

Results on uniform traffic:

| Router (8 flits of storage per port unless noted) | Peak accepted |
|---|---|
| M4: one 4-flit FIFO | 0.756 |
| one 8-flit FIFO | 0.811 |
| 4 VCs × 2 flits, 1-pass allocator | 0.824 |
| **4 VCs × 2 flits, 2-pass allocator** | **0.905** |

**Virtual networks (VNs)** and **protocol deadlock.** This milestone adds
a coherence-style protocol with three message classes:

```
requester --REQ--> home --SNP--> owner --RSP--> requester
```

A home can accept a REQ only if it has room to queue the SNP it causes,
and an owner can accept a SNP only if it can queue the RSP. If all
classes share buffers, REQs fill them, the SNPs and RSPs that would
drain them can't move, and the network freezes. Routing is not the
cause: XY routing is deadlock-free. The cause is dependencies between
**message classes**.

| Configuration | Result |
|---|---|
| All classes in one shared VC | deadlocks at ≥ 8 outstanding transactions per tile |
| 3 shared VCs (3× the buffers) | still deadlocks at ≥ 32 |
| One VN per class (REQ / SNP / RSP) | **0 deadlocks in 48 runs**, up to 64 outstanding |

**Verified:**
- 17 directed tests;
- 544 randomized sweep and protocol runs;
- 11 invariants checked every cycle;
- 7/7 planted bugs caught;
- **bit-exact equivalence:** configured as 1 VN × 1 VC, the VC router
  reproduces all 80 of M4's sweep points digit for digit.

### M6: fabric security ([README](m6_security/README.md))

**Threat model:** one compromised tile, which can inject anything and
refuse to consume what it's sent. Every defense sits at the **trust
boundary**, the router's local port (`SECURE=1`):

```
   compromised tile                         rest of the mesh (trusted)
        |                                          ^
        v                                          |
   +---------------- local port (SECURE=1) --------+---------------+
   |  1. source stamping: overwrite src with this router's (x,y)   |
   |  2. VN guard: refuse a flit outside its class's VN; its credit |
   |     is never returned, so a cheater only starves itself       |
   |  3. watchdog: if delivered flits sit 256 cycles with no credit |
   |     back, quarantine the tile and discard traffic for it      |
   +----------------------------------------------------------------+
```

| Attack | Analogy | Unprotected (M5 router) | Hardened (M6) |
|---|---|---|---|
| Source spoofing past an access-control list | IP spoofing | 8/8 runs breached | 0 breaches |
| VN hopping: REQs injected into the response network | priority-class abuse | 8/8 runs deadlock the fabric | 0/8; all honest traffic completes |
| Black hole: stop consuming deliveries | DoS / black-hole router | victim throughput collapses about 8×; the network can't drain | 0 victim packets lost |
| Flood with well-formed traffic (control) | volumetric DoS | slows traffic | same (rate limiting is future work) |

- **Every attack is shown to succeed** against the unprotected router, so
  a passing secure run means something.
- With no attacker, the hardened router behaves identically over **288
  runs**, with zero alarms.
- The watchdog limit (256) was chosen from data: the longest honest stall
  measured is 75 cycles. A table in the README trades detection time
  against damage.
- 11 planted bugs are all caught, including a watchdog that fires too
  early.
- **Known limitation, documented:** the watchdog can't tell a
  *deadlocked* honest tile from a black hole. So it assumes a
  deadlock-free protocol, which the VNs provide.

### M7: synthesis, timing, formal, lint ([README](m7_synthesis/README.md))

The RTL meets real tools:
- **Synthesis:** Yosys with the slang frontend, on sky130_fd_sc_hd at the
  typical corner. 8 configurations, with area and critical path per
  feature. All checker code sits behind `` `ifndef SYNTHESIS ``, so
  synthesis sees only hardware.
- **Two timing fixes from the critical-path reports:**
  - **route-at-write:** compute the output port as the flit enters the
    FIFO, and store it as a 3-bit tag;
  - **a masked round-robin arbiter:** a thermometer mask and `x & -x`
    instead of a rotate.

  Together: a **13–17% shorter critical path**, measured on the whole
  mesh. Behavior is unchanged. All honest runs reproduce M4/M5 exactly,
  and the new arbiter is **formally proved equivalent** to the old one for
  N = 1..8.
- **Formal (SymbiYosys):**
  - arbiter properties by k-induction;
  - the router's credit protocol by bounded model checking;
  - VN isolation;
  - **negative controls:** four planted bugs, each of which the proofs
    must catch.
- **Verilator lint:** 0 warnings.

### M8: pipelining, and which router to build ([README](m8_pipeline/README.md))

A `PIPE` parameter splits the router into two stages:

```
  cycle 1 (stage 1)                          cycle 2 (stage 2)
  VC allocation + switch allocation          crossbar + link
  + VC mux  ---> pipeline register --->      ---> next router's FIFO
```

Each router a flit passes through now adds 2 cycles, so zero-load latency
goes from 3.0 to 6.0 cycles. Throughput per cycle stays within 3%.

Timing was re-measured by synthesizing the **whole mesh**. That caught a
methodology error in M7's single-router numbers, and M7's README carries
a correction note. The comparison that matters is bandwidth per
nanosecond:

| Router | Critical path | Peak (flits/node/cycle) | Flits/node/ns at its best clock |
|---|---|---|---|
| 1 VC × 4, single-cycle (M4) | 3.95 ns | 0.756 | 0.191 |
| **1 VC × 4, two-stage** | **3.33 ns** | 0.737 | **0.221** |
| 4 VCs × 2, 2-pass, single-cycle | 8.66 ns | 0.905 | 0.104 |
| 4 VCs × 2, 2-pass, two-stage | 7.94 ns | 0.901 | 0.113 |

- Pipelining helps the simple router most.
- The VC router's critical path is now entirely in its allocator, so
  speculative allocation is the next step for it.
- **The decision rule:** at a tight clock (under ~4 ns), build the
  pipelined simple router. At ~8 ns or slower, the VC router delivers
  12–22% more bandwidth. The clock study chart is in
  `m8_pipeline/results/clock_study.png`.

**4×4 mesh.** The RTL has no 3×3 assumption, so the key checks were rerun
one size up:
- zero-load latency matches (hops + 1) × 2 cycles on both sizes;
- throughput stays under the channel-load bound;
- VCs gain more on the bigger mesh: +31%, vs +22% on 3×3;
- VNs never deadlock, shared buffers do, and the black hole is contained.

**Re-verified in both pipeline modes:**
- directed tests;
- protocol runs;
- the attack matrix;
- mutation tests;
- formal credit proofs;
- lint.

### Visualizer ([README](visualizer/README.md))

The NoC Mesh Replay above. A script runs the M8 RTL in Icarus for each
scenario and keeps only runs whose testbench prints PASS. Each waveform is
converted to a per-cycle replay, and `check_replay.py` verifies it before
the page is built:
- about 10,700 link handoffs land in the right VC one cycle later;
- every hop follows XY order;
- no flit ever leaves its virtual network;
- no FIFO exceeds its depth.

---

## The final design

```
                         +--------------------------- vc_router (one per tile) ---------------------------+
   from N/S/E/W/L        |                                                                                 |
   neighbors       ----> | per input port:  VC0 [FIFO] ─┐   route tag computed on write (XY)              |
   (valid, vc, flit)     |                  VC1 [FIFO] ─┤                                                  |
                         |                  ...         ├─> VC allocation (free VC in the flit's VN)       |
   <---- credit_return   |                  VCn [FIFO] ─┘   switch allocation (separable, 1 or 2 passes)   |
         per VC          |                                  VC mux  ──>  [pipeline reg, PIPE=1]  ──>       |
                         |                                  5x5 crossbar ──> out (valid, vc, flit)  ──────────> to neighbors
                         |  per output VC: credit counter   <──── credit_return from downstream             |
                         |  local port only, SECURE=1: source stamping, VN guard, starvation watchdog       |
                         +---------------------------------------------------------------------------------+
```

| Parameter | Meaning | Values exercised |
|---|---|---|
| `MESH_W`, `MESH_H` | mesh size (`vc_mesh`) | 3×3, 4×4, 4×2 |
| `NUM_VNS` | virtual networks (message classes) | 1, 3 |
| `VCS_PER_VN` | VCs per VN | 1–4 |
| `BUFFER_DEPTH` | flits per VC | 2, 4, 8 |
| `SA_ITERS` | switch-allocation passes | 1, 2 |
| `SECURE` | local-port hardening | 0, 1 |
| `WD_LIMIT` | watchdog limit (cycles) | 2 … 1024 (default 256) |
| `PIPE` | 0 = single-cycle, 1 = two-stage | 0, 1 |

The RTL for the final design is in
[`m8_pipeline/rtl/`](m8_pipeline/rtl/): `vc_router.sv`, `vc_mesh.sv`,
`flit_fifo.sv`, `rr_arbiter.sv`, `noc_pkg.sv`.

---

## How it is verified

Several independent layers, so that no single checker has to be trusted.

| Layer | What it catches | Milestones |
|---|---|---|
| Directed tests | specific behaviors and corner cases (28 tests on the final router) | all |
| Scoreboards | loss, duplication, misroute, reordering, under randomized load | M4+ |
| Embedded invariants, every cycle | credit overflow, FIFO overflow, VN escape, arbiter starvation, edge misroute | M4+ |
| Analytic models | throughput above a physical bound; latency off the hop-count model | M4, M8 |
| Equivalence runs | any behavior change from a refactor or a feature that should be invisible | M5–M8 |
| Attack matrix | defenses that don't defend, or attacks that don't attack | M6+ |
| Mutation testing | checkers that can't see a bug (7–11 planted bugs, all caught) | M4–M8 |
| Formal proofs + negative controls | properties for *all* inputs, within the proof bound | M7, M8 |
| Lint | synthesis/simulation mismatches, width bugs | M7, M8 |
| Replay checker | a visualization that shows something that didn't happen | visualizer |

---

## Running it

```bash
./regress.sh            # every milestone's run.sh + replay data check
./regress.sh --full     # plus equivalence, attack matrices, mutation tests,
                        # formal proofs, whole-mesh synthesis, the 4x4 study,
                        # and regenerating the replays
```

- Each step must print its own testbench's PASS line, and the script exits
  non-zero if any step fails.
- Logs go to `regress_logs/`.
- Every milestone also runs on its own: `bash m5_virtual_networks/run.sh`.

**[docs/NoC_Router_Project_Report.pdf](docs/NoC_Router_Project_Report.pdf)** is the full project report: motivation,
background, every milestone with its results, the final design, verification, lessons
learned and a results ledger that ties each number to its data file.

**[GUIDE.md](GUIDE.md)** walks through every result with the
command that reproduces it, what you should see, and things to try.

**Toolchain:**
- Icarus Verilog (`iverilog`, `vvp`) and Python 3 for simulation and
  analysis;
- matplotlib for the plots;
- from M7 on, Verilator for lint, and Yosys + slang + SymbiYosys from the
  OSS CAD Suite for synthesis and formal, with the sky130 liberty file
  included in `m7_synthesis/syn/`.

Testbenches dump a VCD waveform when run directly. Batch sweeps skip it
with `+NODUMP`.

---

## Repo layout

```
NoC Router Project/
  m1_single_router/     single combinational router, valid/ready
  m2_mesh/              3x3 mesh of M1 routers
  m3_flow_control/      credit-based flow control, input FIFOs
  m4_verification/      randomized scoreboards, sweeps, analytic model, mutation testing
  m5_virtual_networks/  VC router, 2-pass allocator, VNs, protocol deadlock study
  m6_security/          compromised-tile attacks and local-port defenses
  m7_synthesis/         sky130 synthesis, timing fixes, formal proofs, lint
  m8_pipeline/          two-stage router, whole-mesh timing, clock study, 4x4 mesh   <- final design
  visualizer/           NoC Mesh Replay (page + VCD-to-replay tools + checker)
  docs/                 full project report (PDF)
  LICENSE               MIT
  regress.sh            whole-project regression
  GUIDE.md              hands-on guide to reproducing every result
```

Each milestone has the same shape:

```
rtl/        the design
tb/         self-checking testbenches
tools/      sweeps, studies, plots, mutation/equivalence/formal scripts
results/    CSVs and plots the README quotes
run.sh      the milestone's regression
```

---

## Limitations and next steps

- **Single-flit packets.** Multi-flit wormhole packets were deliberately
  left out. They'd add head/body/tail handling and VC hold-until-tail
  logic.
- **Pre-layout timing.** There is no placement and routing. Real wires
  lengthen the links, which favors the pipelined designs.
- **Speculative allocation** is the step that would let VC routers win at
  tight clocks.
- **Security gaps:**
  - no rate limiting against floods;
  - no confidentiality: timing side channels through shared links are
    out of scope;
  - the watchdog relies on a deadlock-free protocol.
- **Synthetic traffic only.** No trace-driven workloads.

---

## Glossary

| Term | Meaning |
|---|---|
| **Flit** | the unit a link carries in one cycle; here a whole packet |
| **XY routing** | go along X to the destination column, then along Y |
| **Credit** | the sender's count of free slots in the receiver's buffer |
| **Head-of-line (HOL) blocking** | a stalled flit at a FIFO's head stalls everything behind it |
| **Virtual channel (VC)** | one of several independent FIFOs sharing a physical link |
| **Virtual network (VN)** | a set of VCs reserved for one message class |
| **Switch allocation (SA)** | matching waiting flits to free output ports each cycle |
| **REQ / SNP / RSP** | request to the home, snoop to the owner, response to the requester |
| **Protocol deadlock** | messages of different classes waiting on each other's buffers in a cycle |
| **Quarantine** | the hardened router cutting off a tile that stopped consuming |
| **Zero-load latency** | latency with no contention: the pipeline depth times the routers crossed |
| **Saturation** | the offered load at which accepted throughput stops rising |
