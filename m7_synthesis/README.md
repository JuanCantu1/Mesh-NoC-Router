# M7 -- Synthesis, Timing, and Formal Verification

> **Correction (found in M8).** M7's timing numbers come from synthesizing
> **one router alone**, which treats its output ports as path endpoints.
> But a hop doesn't end at a router's output: it ends in the *next*
> router's input buffer, in the same clock cycle. M8 synthesizes the
> **whole mesh** so that path is measured end to end:
>
> | | Single router (this README) | Whole mesh (M8, the honest number) |
> |---|---|---|
> | 1 VC x 4: M6 RTL -> M7 RTL | 5.45 -> 3.62 ns (-34%) | 4.95 -> 4.13 ns (**-17%**) |
> | 4 VCs x 2, 2-pass: M6 RTL -> M7 RTL | 10.56 -> 8.15 ns (-23%) | 10.10 -> 8.79 ns (**-13%**) |
>
> The fixes were real, but about half as large as claimed below. Most of
> the gap is **route-at-write**:
> - In a single-cycle router it doesn't take the route compare *out* of
>   the cycle. It moves it from the start of the path (this router reading
>   its head flit) to the end (the next router writing the flit).
> - The single-router measurement simply stopped before the end.
> - The arbiter rewrite is the real gain.
> - Route-at-write does pay off once the router is pipelined (M8), where
>   it moves the compare out of the allocation stage.
>
> The behavioral claims (equivalence, formal, mutation) are unaffected.
> [M8's README](../m8_pipeline/README.md) has the corrected method.

M1-M6 lived entirely in simulation. M7 puts the design through the tools
an RTL team actually ships with:

- **Synthesis** onto a real standard-cell library (SkyWater sky130),
  measuring the area and critical path of every feature M5 and M6 added.
- **Timing fixes** driven by what synthesis found, each proved not to
  change behavior.
- **Formal verification** (SymbiYosys) of properties that simulation can
  only sample: arbiter fairness for *every* request sequence, and the
  router's credit protocol on every port.
- **Lint**: Verilator `-Wall`, zero warnings.

The headline finding is uncomfortable, and it's the most useful thing
here. **Per nanosecond, M5's virtual-channel router is slower than M4's
simple one.** VCs and the 2-pass allocator buy +20% throughput per cycle,
but they cost more than twice the clock period. The fix is pipelining the
allocator, and it's the obvious next milestone.

## Results at a glance

| | |
|---|---|
| **Timing fixes** | Two RTL changes found from critical-path reports cut the critical path by **16-34%** across all 8 configurations |
| **...behavior-identical** | 288 honest-traffic runs reproduce M4/M5 digit for digit; the attack matrix reproduces M6's line for line; the rewritten arbiter is **formally proved** equivalent to the original |
| **Per-nanosecond throughput** | 1 VC x 4 (M4's router): **0.209** flits/node/ns. 4 VCs x 2 with 2-pass allocation (M5's best): **0.111** |
| **Security cost** | **Negative area** (-3.4%): stamping makes the stored source bits constants, so their flops disappear. No measurable timing cost |
| **Formal** | 18 proofs pass (16 arbiter, 2 whole-router), and all 4 planted bugs are caught |
| **Lint** | 0 warnings, both views (synthesizable, and with checkers), 6 configurations |

## Setup

The tools are all open source:
- **Yosys** 0.69 with the **slang** SystemVerilog frontend, plus
  **SymbiYosys**, from YosysHQ's OSS CAD Suite (installed to
  `C:\oss-cad-suite`).
- **Verilator** 5.032.
- **The cell library:** SkyWater **sky130_fd_sc_hd**, typical corner
  (25 C, 1.8 V). The liberty file is
  `syn/sky130_fd_sc_hd__tt_025C_1v80.lib`, from OpenROAD-flow-scripts.

```sh
./run.sh               # regression: lint + M6's suite on the M7 RTL (~3 min)
tools/lint.sh          # Verilator -Wall, 2 views x 3-4 configs: must be 0 warnings
tools/synth.sh         # sky130 synthesis, 8 configurations -> results/synth.csv (~3 min)
tools/formal.sh        # 18 proofs + 4 negative controls (~4 min)
tools/equivalence_check.sh   # honest traffic identical to M4/M5 (~14 min)
tools/attack_matrix.sh       # M6's attacks (~6 min)
tools/mutation_test.sh       # 11 injected bugs (~4 min)
```

Every simulation-only construct is wrapped in `` `ifndef SYNTHESIS ``:
the embedded checkers, the alarm counters, and the configuration checks.
Synthesis sees exactly the hardware and simulation keeps every check.

## Synthesis results

Each run synthesizes one router at the center of the mesh, so no edge
logic folds away. Area is total cell area. The critical path is ABC's
static timing on the mapped netlist. This is a **pre-layout** estimate:
no wires, no clock-to-q or setup time. It's sound for *comparing*
configurations, and it is not a sign-off frequency.

| Configuration | Flits/port | Area (um^2) | Flops | Critical path | Peak throughput (M5) | **Throughput / ns** |
|---|---|---|---|---|---|---|
| 1 VC x 4 (M4's router) | 4 | 36,226 | 805 | 3.62 ns | 0.756 | **0.209** |
| 1 VC x 8 | 8 | 65,335 | 1,565 | 3.93 ns | 0.811 | **0.206** |
| 4 VCs x 2, 1-pass | 8 | 72,563 | 1,635 | 6.11 ns | 0.824 | 0.135 |
| 4 VCs x 2, 2-pass (M5's best) | 8 | 75,336 | 1,635 | 8.15 ns | 0.905 | 0.111 |
| 3 VNs x 1 VC x 4 | 12 | 100,655 | 2,405 | 5.63 ns | -- | -- |
| 3 VNs x 1 VC x 4, secure | 12 | 97,238 | 2,339 | 5.61 ns | -- | -- |
| 4 VCs x 2, 2-pass, secure | 8 | 74,001 | 1,581 | 8.53 ns | -- | -- |
| 3 VNs x 2 VCs x 2, 2-pass, secure (everything) | 12 | 108,470 | 2,379 | 9.79 ns | -- | -- |

Full data: [`results/synth.csv`](results/synth.csv). "Throughput / ns" is
M5's measured peak uniform-traffic throughput (flits/node/cycle) divided
by the critical path. Logically equivalent designs come out of the mapper
up to ~0.5 ns apart, so smaller differences are noise.

Three findings:

- **Buffers are the router.** 63-71% of the area is flops, almost all of
  it FIFO storage (5 ports x VCs x depth x 37 bits). Doubling the storage
  roughly doubles the router.
- **VCs don't pay off per nanosecond, yet.** The allocator lengthens the
  critical path faster than it raises throughput per cycle:
  - 4 VCs with 1 pass: +69% clock period, for +9% throughput per cycle.
  - The second pass: another +33%, for another +10%.

  In flits per nanosecond, M5's best router delivers about **half** of
  M4's. With a single-cycle router, the simplest design wins. Real VC
  routers pipeline allocation for exactly this reason: one stage per
  decision, so each stage stays short. M5's throughput gains are real;
  collecting them needs a pipelined allocator (see "Next").
- **Security is free, or better.** The secure 3-VN router is 3.4%
  *smaller* than the unprotected one, with the same critical path. Source
  stamping turns the local port's 8 source bits into constants, so
  synthesis removes those flops from every local-port buffer slot: 96
  flops in the 3-VN router. That more than pays for the watchdog's
  counters. The other security checks sit on the push path and in the
  eligibility logic, off the critical path.

## What synthesis found, and the fixes

The first synthesis run (on M6's RTL) reported every critical path the
same way: starting at an input FIFO's read pointer, and running through
the router in one cycle.

```
 FIFO head ptr -> read mux -> XY route compute -> eligibility -> input arbiter
     -> output arbiter -> (pass 2: both again) -> VC mux -> crossbar -> output port
```

Two pieces of that path were doing work that didn't need to be there.

**1. Route-at-write.**
- **Before:** each input VC computed the XY route of its *head* flit, a
  4-bit compare chain sitting right after the FIFO read mux, on every
  path.
- **After:** the router computes the route **once, when the flit is
  written**, and stores it as 3 extra bits beside the flit (`flit_fifo`
  gained a `TAG_W` side-band). At the head, the route is simply read.
- **Tradeoff:** the same cycle, the same decisions, the same behavior,
  and fewer comparators (one per input *port*, not per input VC), for 3
  bits of storage per slot (+5-9% area, about half of which the smaller
  arbiter below won back).

**2. A masked round-robin arbiter.**
- **Before:** M1's arbiter found the winner with a loop of variable
  rotations, `(req >> ((ptr + i) % N))`, one requester at a time. In
  hardware that's a chain of barrel shifters, and there are 15
  arbiters in a router.
- **After:** the textbook form:

  ```
  mask  = all positions >= ptr                          (thermometer code)
  grant = lowest set bit of (req & mask), if there is one
          else lowest set bit of req                     (wrap around)
  lowest set bit of x  =  x & (~x + 1)
  ```

**3. A cleanup synthesis flagged.** Each FIFO's storage array shared the
pointers' async-reset block without being reset. That asks for reset
flops that never get a reset value. The storage now has its own block,
with no reset: an empty FIFO's contents are irrelevant, and non-reset
flops are smaller.

Effect on the critical path:

| Configuration | M6 RTL | M7 RTL | Change |
|---|---|---|---|
| 1 VC x 4 | 5.45 ns | 3.62 ns | -34% |
| 1 VC x 8 | 5.31 ns | 3.93 ns | -26% |
| 4 VCs x 2, 1-pass | 7.81 ns | 6.11 ns | -22% |
| 4 VCs x 2, 2-pass | 10.56 ns | 8.15 ns | -23% |
| 3 VNs x 1 VC x 4 | 7.55 ns | 5.63 ns | -25% |
| 4 VCs x 2, 2-pass, secure | 10.13 ns | 8.53 ns | -16% |
| everything | 13.41 ns | 9.79 ns | -27% |

**None of it changed behavior, and that's proved:**
- With no attacker, all 288 runs of M6's equivalence check reproduce
  M4's and M5's results digit for digit.
- All 56 attack runs reproduce M6's results line for line.
- The new arbiter is *formally* equivalent to the old one (below).

## Formal verification

Simulation (M1-M6) checks properties on the traffic that ran. Formal
verification checks them on **every** possible input sequence: the
solver searches for a counterexample and either finds one or proves none
exists. `tools/formal.sh` runs 18 proofs and 4 negative controls.

**1. Arbiter equivalence** (N = 1 to 8 requesters, every width the router
uses):
- **Setup:** the new arbiter and the original run side by side from
  reset, on completely free inputs.
- **Assertion:** identical grants on every cycle.
- **Why bounded checking is a complete proof here:** the only state is
  the priority pointer, and every reachable pointer value is reached one
  cycle after reset.
- **Why not a register-cut equivalence tool:** a first attempt with
  `eqy`'s default partitioning "failed". It considered pointer values N
  to 2^bits-1, which can never occur, and on which the two
  implementations legitimately differ. Choosing the right proof matters.

**2. Arbiter properties**, as concurrent SVA (`assert property`). This is
the construct M4 couldn't use because Icarus can't parse it. All are
proved by k-induction, which means unbounded: for all time.
- P1: the grant only goes to a requester.
- P2: at most one grant.
- P3: if anyone requests, someone is granted.
- P4: the same three hold for pass 2.
- **P5, fairness:** a requester that keeps asking is granted within N
  cycles. M4 checked this bound on the traffic that happened to run; this
  proves it for every request pattern.

**3. The whole router's credit protocol.** One `vc_router` sits in a
harness that models its neighbors as assumptions:
- an upstream sender only sends with a credit;
- a downstream receiver only returns a credit for a flit it holds.

The router's obligations are the assertions:
- **C1:** never send into a full buffer.
- **C2:** never return a credit it doesn't owe.
- **C3:** every flit leaves on a real VC.
- **C4:** every flit leaves in its own class's VN.

The check runs to a bound of 12 cycles (enough to fill and drain every
2-deep buffer several times), in two configurations:
- 2 VCs with 2-pass allocation;
- 3 VNs with security on.

**The trust boundary, made explicit.** The first run of C4 failed. The
solver sent a request-class flit into the response VC over the **West
link**, and the router forwarded it. The router wasn't wrong: the harness
hadn't said that neighboring *routers* keep VN discipline. That's M6's
trust model, where links are trusted and only the local port faces an
untrusted tile. Adding it as an assumption on the four link ports, and
deliberately *not* on the local port, made C4 pass. It now proves the
property M6 claimed: no flit leaves outside its VN, even when the local
tile sends anything at all.

**Negative controls.** Each check must fail on a planted bug. A proof
that can't fail proves nothing.

| Planted bug | Check | Result |
|---|---|---|
| Priority mask off by one | Arbiter equivalence | FAIL, with a counterexample trace |
| Pointer never advances (fixed priority) | Fairness P5 | FAIL: requester 4 starves |
| Credits reset one too high | Credit protocol C1/C2 | FAIL |
| VC allocation ignores the VN | VN isolation C4 | FAIL |

## Lint

`tools/lint.sh` runs Verilator `-Wall` on both views (synthesizable, and
with all checkers) across 3-4 configurations: **zero warnings**.

**Global waivers.** Two, both forced by the toolchain:
- `IMPORTSTAR`: packages are imported at file scope, because this Icarus
  build crashes on module-header imports.
- `DECLFILENAME`: a file-naming style rule.

**Inline waivers.** Every other waiver sits next to its line, with the
reason:
- `fifo_full` is unused: credits make it redundant.
- The tile's source bits are discarded when stamping.
- Edge routers' `dest < MY_X` compares are constant.
- The output-VC arbiter's pass-2 port is unused.
- A few package constants are used only by testbenches.

**Fixes along the way.**
- **Real width mismatches** were fixed with typed constants.
- **Two encoders rewritten.** My first width-clean rewrite of them was a
  chained OR; Verilator then reported `UNOPTFLAT`, a false combinational
  loop. They became flat one-hot-to-binary encoders.

## Verification that M7 changed nothing

| Check | Result |
|---|---|
| `tools/equivalence_check.sh`: honest traffic vs. M4/M5 | 288/288 identical |
| `tools/attack_matrix.sh`: M6's attacks | All pass; both result CSVs identical to M6's |
| `tools/mutation_test.sh`: 11 mutants x 6 runs | All caught |
| `tools/formal.sh` | 18 proofs pass; 4/4 planted bugs caught |
| `tools/lint.sh` | 0 warnings |
| `./run.sh` | 10/10 steps |

## Next: pipeline the allocator

Synthesis says the single-cycle router has run out of road. The natural
M8 splits each hop into stages, as production VC routers do:
- route compute is already done at write;
- switch allocation and VC allocation get a stage;
- switch traversal gets a stage.

The cost is a cycle of latency per hop, and longer credit loops (so
deeper buffers to keep links busy). The prize is a clock period set by
one allocator pass, not the whole hop. With the 2-pass allocator, that's
the difference between 8 ns and roughly half of it.

The tools to judge it already exist: the sweep for throughput,
`synth.sh` for frequency, and flits per nanosecond as the score.
