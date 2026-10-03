# Visualizer: NoC Mesh Replay

An interactive, cycle-by-cycle replay of the final router (M8, two-stage
pipeline) running on the 3×3 mesh. Nothing on the page is animated by a model
of the router. Every flit position comes from a waveform the real RTL produced
in Icarus Verilog.

**Open it:** double-click [`noc_replay.html`](noc_replay.html). It is a single
self-contained file (about 1 MB), works offline, and needs no server.
Deep links pick a scenario and a cycle: `noc_replay.html#deadlock.230`,
`#blackhole.1302`, `#uniform`.

## Scenarios

| Tab | Left | Right | What to watch |
|---|---|---|---|
| Uniform traffic | 4 VCs × 2, 2-pass SA, hardened, rate 0.40 | — | XY routes, VCs passing each other, about 6.5-cycle latency |
| Protocol deadlock | REQ/SNP/RSP share one VN | one VN per class | left freezes for good after cycle 211 (72 flits stuck); right keeps completing transactions |
| Black-hole attack | tile 4 stops consuming at cycle 1000, `SECURE=0` | same, `SECURE=1` | left backs up permanently; right quarantines tile 4 at cycle 1302 and recovers |

Each panel shows:

```
      north input (VC columns, head at bottom)
          +-----------+
 west  -> | ##     .. | <- east input (VC rows, head at left)
 input    |   (x,y)   |
          |    ..  [L]|  [L] = local input (what this router's tile injected)
          +-----------+
                 \
               [tile]     endpoint; in protocol runs, its receive queues
```

- Colored slot: a buffered flit. Color = message class (REQ/SNP/RSP), or
  "for the black hole" in the attack tab.
- Dot on a lane: a flit on a link that cycle. Each neighbor pair has two
  one-way lanes.
- Faded slots: ports on the mesh edge, which have no link.
- Click any flit to follow it. The panel lists its injection, every hop with
  its cycle and VC, and its delivery.
- The sparkline under each mesh is delivered flits per node per cycle. A pair
  of meshes shares one y-scale, so the two charts compare directly. Click a
  sparkline to jump to that cycle.

## How the data is made (and checked)

```
tools/make_scenarios.sh
  ├─ iverilog: M8 rtl/ + M5/M6 testbenches (protocol_tb, latency_sweep_tb), PIPE=1
  ├─ vvp per scenario  ── the run's own PASS/ATTACK-PASS line is required
  ├─ tools/vcd2json.py  VCD -> per-cycle JSON:
  │     samples each router's in/out ports and every FIFO's mem/head/count
  │     just before each rising edge; gives every flit a stable id
  │     (class, destination, payload are unique among live flits)
  ├─ tools/check_replay.py  rejects the data unless:
  │     1. a flit sent on port p at cycle c is in the neighbor's opposite
  │        input, same VC, at c+1        (≈10,700 handoffs checked)
  │     2. every flit is ejected at its destination tile
  │     3. every hop follows XY order, and complete routes are minimal
  │     4. no flit ever sits in a VC outside its class's VN
  │     5. no FIFO ever exceeds BUFFER_DEPTH
  └─ tools/bundle.py   data/*.json + verdict lines -> data/scenarios.js,
                       and index.html + data -> noc_replay.html
```

Regenerate everything (about 1 minute): `bash tools/make_scenarios.sh`.

Two decoder bugs were caught by `check_replay.py` while this was built, and
both are fixed:
- VCD vectors drop leading zeros, so widths must come from the `$var`
  declarations.
- FIFO storage has no reset, so unwritten slots hold X. Each slot has to be
  decoded on its own, or one X slot hides the valid ones.

## Notes

- The deadlock pair runs with `SECURE=0`. With the watchdog on, a tile that
  is honestly deadlocked looks the same as a black hole: after 256 cycles
  without credits it gets quarantined, which turns the deadlock into lost
  messages. That only happens with shared buffers. With one VN per class the
  protocol cannot deadlock, so the watchdog never fires on honest traffic.
  See the M6 README.
- Cycle numbers are the testbench's `cycle_num`, the same numbers its log
  prints. That is three clock edges less than the raw edge count, because of
  reset.
- `index.html` is the page source. It loads `data/scenarios.js` and is what
  gets published. `noc_replay.html` is generated from it.
