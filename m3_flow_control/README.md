# M3 -- Real Flow Control

Replaces M1/M2's valid/ready handshake with real **credit-based flow
control**: every input port now has a small buffer, and every output port
tracks -- via a credit counter, not a live "are you ready?" signal -- how
much room is left downstream. This is the mechanism real on-chip
interconnects actually use, and it's what finally gives a router real,
bounded per-hop latency (see M2's README for why that mattered).

See [NoC Router 101](../README.md) for the concepts this builds on
(packets, XY routing, arbitration) if you haven't read M1's docs -- this
document only covers what's new.

## Why valid/ready wasn't enough

M1/M2's router had **no storage anywhere**. If a packet wasn't granted the
cycle it arrived, the sender had to keep re-offering the exact same data,
cycle after cycle, until it was accepted. That's workable for a single
router or a small mesh, but it has two real problems once you think past
this project's own scope:

- The sender needs a live combinational `ready` signal from every hop
  downstream, every cycle -- exactly the "everything is one giant
  combinational blob" problem M2's README flagged.
- There's nowhere for a flit to *wait* except by staying parked on the
  sender's output, which doesn't scale past one flit per port.

## The protocol

Every port pair now has exactly two signals per direction, and no `ready`
at all:

```
 sender ---- valid, data ---------> receiver     (unchanged in spirit)
 sender <----- credit_return ------ receiver     (new: replaces `ready`)
```

`credit_return` is a single-cycle pulse meaning "I just freed a buffer
slot you were using -- you may send me one more flit than you thought you
could." The sender never asks permission; it tracks its own credit count
(starting at `BUFFER_DEPTH`, the receiver's buffer size) and simply never
sends when that count is zero.

```
              credit_count == BUFFER_DEPTH initially
                          |
        +-----------------------------------+
        |  sender's local credit counter     |
        |  -1 every flit sent                |
        |  +1 every credit_return pulse seen |
        +-----------------------------------+
                          |
             only sends while credit_count > 0
```

## What's inside the router now

```
                    +---------------------------------------------+
   in_valid[p] ---->|  flit_fifo   -->  route_sel[p]  -->          |
   in_data[p]  ---->|  (depth =        (XY routing,     req_mat -->|--> arbiter -> grant_mat
                     |   BUFFER_DEPTH)  same as M1/M2)              |         |
   in_credit_ <------|      ^                                       |         v
     return[p]       |      | pop_grant[p]                          |   out_data[o]
                      |      | (this flit was just forwarded)        |   out_valid[o]
                      +------+---------------------------------------+
                                              ^
                                    credit_count[o] > 0 ?
                                   (gates whether o can be
                                    requested at all)
```

- **`flit_fifo.sv`** -- a small circular-buffer FIFO, one per input port,
  depth `BUFFER_DEPTH` (default 4). A flit is pushed the cycle it arrives;
  it's popped the cycle it's actually forwarded to an output.
- **`credit_count[o]`** -- one counter per output port, reset to
  `BUFFER_DEPTH`. A request for output `o` is only ever formed if
  `credit_count[o] > 0` -- so, unlike M1/M2, an output that has no credit
  simply never shows up as a candidate in arbitration at all, rather than
  winning and then being told "not yet."
- Routing and arbitration (`rr_arbiter.sv`) are otherwise **unchanged**
  from M1/M2 -- they now just operate on whatever's at the head of each
  input's FIFO instead of directly on the input wire.

## What's verified

`tb/flit_fifo_tb.sv` is a standalone unit test for the FIFO itself (push/pop
ordering, full/empty, wraparound, simultaneous push+pop) -- checked in
isolation before it's ever wired into the router, since bugs are much
cheaper to find at that level.

`tb/router_tb.sv` reruns M1's routing/arbitration scenarios (pass-through,
turn, arrival, injection, contention) to confirm they still hold with a
buffered datapath, then adds the scenario this milestone is really about:

| Scenario | Proves |
|---|---|
| Priming + queue fill | East's downstream credit is deliberately drained first, so North/West's later flits *genuinely* have nowhere to go and must queue -- not just assumed to, demonstrated |
| Buffer-full refusal | A well-behaved sender at 0 credit refuses to send a 5th flit into an already-full buffer -- and nothing was lost by *not* trying |
| Ordered drain | Once downstream resumes draining, all 4 queued flits emerge in the exact order they arrived, with unchanged data |
| **No credit leak** | After a full fill-and-drain round trip, the sender's tracked credit returns to *exactly* `BUFFER_DEPTH` -- not more, not less -- confirming every send was matched by exactly one eventual credit return |

That last row is the one this milestone's whole premise rests on. The
testbench models both ends of the link as a *real* credit-aware party
would: the sender's `try_send()` task tracks its own credit counter and
refuses to send at zero (exactly what a real upstream router would do),
and the "downstream neighbor" is modeled as an actual bounded
`flit_fifo` instance, not just a signal that instantly says yes -- so
`credit_count[o] + downstream's real occupancy` is an invariant that's
enforced by the simulation, not merely asserted by the test.

## How to run it

```sh
./run.sh
```

or manually:

```sh
iverilog -g2012 -Wall -o sim/flit_fifo_tb.vvp rtl/noc_pkg.sv rtl/flit_fifo.sv tb/flit_fifo_tb.sv
vvp sim/flit_fifo_tb.vvp

iverilog -g2012 -Wall -o sim/router_tb.vvp rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/router.sv tb/router_tb.sv
vvp sim/router_tb.vvp
```

## A debugging lesson worth keeping: cut-through means "check now," not "wait then check"

The single trickiest bug in bringing this milestone up wasn't in the RTL
-- it was in the testbench's sense of time. This router is a **cut-through**
design: a flit pushed into an empty, credit-available FIFO can be
routed, arbitrated, and show up on the output **combinationally, within
the very same cycle it arrives** (the FIFO's storage is registered, but
nothing that *decides* where a flit goes is). A polling loop that
unconditionally does "wait for the next clock edge, then check" will
systematically miss that first cycle if something else already consumed
it (in this case, the send task's own bookkeeping) -- and every check
after that ends up one flit out of phase with reality, which looked at
first like a routing or ordering bug and was actually a testbench
sequencing bug. The fix (in both `send_and_check` and the priming loop)
was to check the *current* state before ever waiting for a new edge, and
to never assume a fixed number of cycles have "definitely" settled
something -- always check the real signal, with a real settle delay,
instead of counting edges and hoping.

## Not yet covered (future milestones)

- Randomized/stress traffic and a real throughput sweep -- M4
- Formal SVA deadlock/livelock and credit-conservation assertions (this
  milestone verifies credit conservation functionally, with directed
  tests; M4 is where that becomes a property checked continuously) -- M4
- Wiring this credit-based router into a multi-hop mesh (M2's `mesh.sv`
  used the M1/M2 valid/ready router) -- mechanically similar to M2's
  wiring, just replacing `out_ready` with `credit_return` throughout, but
  not yet done in this repo
