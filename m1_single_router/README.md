# M1 -- Single Router

A single 5-port mesh router: North, South, East, West, and Local. This is
the first milestone of the larger [Mesh NoC Router project](../README.md) --
one router in isolation, with no neighbors wired up yet (that's M2) and no
input buffering or credit-based flow control yet (that's M3).

For a from-scratch, no-prior-NoC-experience walkthrough of *why* any of this
exists and how the pieces fit together, see **NoC Router 101**, and for an
interactive, cycle-by-cycle replay of a real simulation of this router in
action, see **Router Replay** -- both linked from the top-level README.
This document is the milestone-level reference: what's here, how to run
it, and what's actually verified.

## What a "router" is doing here

A Network-on-Chip (NoC) connects many small compute tiles on a chip the same
way a network connects many computers: each tile talks to a nearby router,
and routers forward traffic hop-by-hop until it reaches its destination.
This milestone builds **one** of those routers and proves it makes correct
decisions in isolation, before M2 wires many of them into a grid.

## Block diagram

```
                              N (to router above)
                              |
                     in_valid/in_data -->  +------------------+  --> out_valid/out_data
                     in_ready        <--   |                  |  <-- out_ready
                                            |                  |
   W (to router  <-- in_ready         <--  |                  |  --> out_ready
      on the left)  in_valid/in_data -->   |      router      |  <-- in_valid/in_data
                                            |    (X_ID, Y_ID)  |  --> in_ready
                                            |                  |         E (to router
                                            |                  |            on the right)
                     in_valid/in_data -->  |                  |  --> out_valid/out_data
                     in_ready        <--   +------------------+  <-- out_ready
                              |
                              S (to router below)

                     Local port (to/from this tile's own compute logic)
                     omitted from the picture above for space --
                     it's a 5th port, wired the same way as N/S/E/W.
```

Each of the 5 ports has an **independent** input half and output half, each
with its own valid/ready handshake:

```
        in_valid  ----->              out_valid ----->
        in_data   =====>  [ROUTER]     out_data =====>
        in_ready  <-----              out_ready <-----
```

## Packet (flit) format

M1 packets are a single flit -- header and payload arrive together, in one
cycle, on one port:

```
 MSB                                                    LSB
+------------------+------------------+------------------+
|  dest_x (4 bits)  |  dest_y (4 bits) |  payload (8 bits) |
+------------------+------------------+------------------+
```

`dest_x`/`dest_y` are the coordinates of the router this packet is trying to
reach. `payload` is arbitrary data along for the ride (in a real design this
would be a cache line address, a coherence message, etc.; here it's just a
byte so tests can verify data integrity end-to-end).

## Routing algorithm: XY dimension-order routing

Every input port looks at a packet's `(dest_x, dest_y)` versus this router's
own `(X_ID, Y_ID)` and decides where the packet needs to go next:

```
   dest_x > X_ID ?  --yes-->  go East
        |no
        v
   dest_x < X_ID ?  --yes-->  go West
        |no                      (X is now correct)
        v
   dest_y > Y_ID ?  --yes-->  go South
        |no
        v
   dest_y < Y_ID ?  --yes-->  go North
        |no                      (X and Y both correct --
        v                        this router *is* the destination)
   deliver to Local
```

The rule "always fix X before ever touching Y" is what's called
**dimension-order routing**. It's not an arbitrary style choice: because
every packet resolves X completely before it ever turns in Y, packets can
never form a *cyclic* waiting dependency on each other (packet A waiting on
a buffer packet B holds, while B waits on a buffer A holds). That cyclic
dependency is what causes deadlock in a network, so XY routing is
deadlock-free by construction. This matters a lot more once M3 adds real
buffering -- for M1's single router it just means "predictable, always
terminating" routing decisions.

## Arbitration: what happens when two packets want the same exit

Because this router has no buffering yet, if two input ports both compute
the same output port in the same cycle, only one of them can actually leave
that cycle -- the router isn't storing anything, so the loser has to be told
"not yet" and try again next cycle.

```
   North's packet --\
                      >---[ round-robin ]---> East output (one winner/cycle)
   West's packet  --/         arbiter
```

A **round-robin arbiter** (`rtl/rr_arbiter.sv`) resolves this fairly: it
remembers who won last time and gives the *next* requester priority, so no
input port can be starved by another one that keeps winning ties. This is
tested directly in the testbench (`contention N->E` / `contention W->E`).

## Handshake contract (valid/ready)

Every port uses the standard two-signal handshake: a transfer happens on a
clock edge only when **both** `valid` and `ready` are high at that edge.

```
clk        __/‾‾\__/‾‾\__/‾‾\__/‾‾\__
valid      ________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾\__     (sender holds valid+data
ready      ____________/‾‾‾‾‾‾\__________  until ready arrives)
                        ^
                 transfer happens here (valid && ready both high)
```

Because there's no buffering in M1, if a packet isn't granted this cycle,
the sender **must** keep `valid` asserted and `data` unchanged until it is
-- that's the whole contract, and it's exactly what the `backpressure`
test in the testbench checks (a packet destined for Local is held, with
`in_ready` staying low, for as long as the Local consumer's `out_ready` is
low, and is delivered intact the instant `out_ready` goes high).

## Files

```
m1_single_router/
  rtl/
    noc_pkg.sv       -- shared types/params: flit format, port numbering
    rr_arbiter.sv    -- reusable round-robin arbiter (one per output port)
    router.sv        -- the 5-port router itself
  tb/
    router_tb.sv     -- self-checking directed testbench (the real verification)
    trace_gen_tb.sv  -- drives the same scenarios and dumps a plain-text
                        per-cycle trace, used only to feed the Router
                        Replay visualization -- not a verification TB
  sim/               -- build output (.vvp, .vcd, trace.log) --
                        gitignored except trace.log, regenerated by the scripts below
  run.sh             -- compiles + runs the verification testbench
  gen_trace.sh       -- regenerates sim/trace.log for Router Replay
```

## How to run it

```sh
./run.sh
```

or manually:

```sh
iverilog -g2012 -Wall -o sim/router_tb.vvp rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/router.sv tb/router_tb.sv
vvp sim/router_tb.vvp
```

Every check prints `[PASS]` or `[FAIL]` to the console, and the run ends
with a single `ALL TESTS PASSED` / `N TEST(S) FAILED` summary line -- no
waveform viewer is required to know whether this milestone works. A VCD
(`sim/router_tb.vcd`) is written on every run for when you do want to look
at waveforms (e.g. in GTKWave).

To regenerate the trace behind the **Router Replay** visualization after
changing the RTL:

```sh
./gen_trace.sh
```

This writes `sim/trace.log`, a plain-text log of every port's
valid/ready/data every cycle (format documented at the top of
`tb/trace_gen_tb.sv`). The Router Replay artifact has this trace's content
embedded directly in its page, so re-publishing it after a real RTL change
means copying the new `sim/trace.log` into that page.

## What's verified (and what isn't yet)

The directed testbench drives one router (parked at mesh position
`X=1, Y=1`) through 9 packets covering:

| Scenario | What it proves |
|---|---|
| Straight-through W->E, N->S | A packet that still needs to move in the dimension it arrived from passes straight through |
| Turn E->S, W->N | A packet whose X is already correct turns to fix Y (the XY "dogleg") |
| Arrival -> Local | A packet whose (X,Y) exactly matches this router is delivered to the Local port |
| Injection Local -> E | The local compute tile can inject a new packet into the mesh |
| Contention N,W -> E | Two ports wanting the same output in the same cycle are serialized fairly by the round-robin arbiter, and both still arrive with correct data |
| Backpressure | A packet is held (not dropped/corrupted) while its destination isn't ready, and delivered intact once it is |

**Not yet covered by design (future milestones):**
- Multi-hop routing across real neighbor connections -- M2
- Any buffering, so a rejected packet must be re-driven by the sender
  every cycle rather than being queued -- M3 (credit-based flow control)
- Randomized/stress traffic, latency measurement, formal deadlock/livelock
  assertions -- M4

## A note on the toolchain (Icarus Verilog 12.0-devel)

A few spots in `router.sv` use `generate`/`genvar` loops where a plain
procedural `for` loop would normally be the more natural SystemVerilog.
That's a workaround for real *runtime* bugs found in this specific Icarus
build while bringing this milestone up -- not a style preference:

- A `for` loop that reads a packed-struct field (e.g. `f.dest_x`) inside
  `always_comb` compiles with only a cosmetic warning, but was found to
  actually corrupt the simulation (`vvp` crashes with an internal assertion
  a few clock edges in).
- Comparing two loop-variable-indexed array reads against each other inside
  a *nested* procedural loop had the same failure mode.
- An **output port** declared as an *unpacked* array of a packed struct
  (`flit_t out_data [NUM_PORTS]`), when written from inside a `generate`
  block, silently failed to propagate its value to the parent module at
  all (reads as `x` from outside, even though the value was correct when
  inspected hierarchically inside the submodule). Declaring it as a
  **packed** array instead (`flit_t [NUM_PORTS-1:0] out_data`) fixed it.

Each workaround is commented in `router.sv` at the point it's used. None of
this changes the design intent -- every workaround produces the identical
hardware structure a plain `for` loop would, just expressed in a form this
Icarus build handles correctly.
