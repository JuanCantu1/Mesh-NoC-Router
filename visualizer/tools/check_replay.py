"""Cross-check every replay file before the page is allowed to show it.

Rebuilds the buffer state from the per-cycle deltas exactly the way
index.html does, then checks, for every scenario:

  1. link handoff   a flit sent out of router r on port p at cycle c sits in
                    the neighbor's opposite input port, same VC, at cycle c+1
  2. ejection       every flit leaves on the local port of its destination
  3. XY route       every recorded hop follows dimension-order routing
                    (all X moves, then all Y moves) from source to dest
  4. VN isolation   a flit never sits in a VC outside its class's VN
  5. occupancy      no FIFO ever holds more than BUFFER_DEPTH flits

A failure means the converter (or the RTL) is wrong, and the page would be
showing something that did not happen.

usage: python tools/check_replay.py   (reads data/*.json)
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")
ORDER = ["uniform", "deadlock", "vns", "bh_open", "bh_secure"]
OPP = {0: 1, 1: 0, 2: 3, 3: 2}            # N<->S, E<->W
STEP = {0: (0, -1), 1: (0, 1), 2: (1, 0), 3: (-1, 0)}  # South is y+1


def check(name, d):
    cfg = d["cfg"]
    W, H, nv, depth = cfg["mesh_w"], cfg["mesh_h"], cfg["num_vcs"], cfg["depth"]
    vpn = cfg["vcs_per_vn"]
    pk = d["packets"]
    frames = d["frames"]
    errs = []

    # rebuild buffer state per cycle
    buf = {}
    states = []
    for fr in frames:
        for entry in fr.get("b", []):
            buf[entry[0]] = entry[1:]
        states.append({k: list(v) for k, v in buf.items() if v})

    handoffs = 0
    for ci, fr in enumerate(frames):
        st = states[ci]
        for key, cont in st.items():
            if len(cont) > depth:
                errs.append(f"cycle {ci}: FIFO {key} holds {len(cont)} > depth {depth}")
            v = key % nv
            for u in cont:
                cls = pk[u][0]
                vn = 0 if cfg["num_vns"] == 1 else min(cls, cfg["num_vns"] - 1)
                if v // vpn != vn:
                    errs.append(f"cycle {ci}: flit {u} (class {cls}) in VC {v}, outside VN {vn}")
        if ci + 1 < len(frames):
            nxt = states[ci + 1]
            for r, p, vc, u in fr.get("m", []):
                x, y = r % W, r // W
                dx, dy = STEP[p]
                nr = (y + dy) * W + (x + dx)
                key = (nr * 5 + OPP[p]) * nv + vc
                if u not in nxt.get(key, []):
                    errs.append(f"cycle {ci}: flit {u} sent {r}.{'NSEW'[p]} vc{vc} not in router {nr} input next cycle")
                handoffs += 1
        for r, u, _vc in fr.get("e", []):
            if pk[u][2] != r:
                errs.append(f"cycle {ci}: flit {u} for tile {pk[u][2]} ejected at tile {r}")

    # XY route per packet, from the hop records implied by moves
    hops = {}
    for ci, fr in enumerate(frames):
        for r, p, vc, u in fr.get("m", []):
            hops.setdefault(u, []).append(p)
    for u, ps in hops.items():
        seen_y = False
        for p in ps:
            if p in (0, 1):
                seen_y = True
            elif seen_y:
                errs.append(f"flit {u}: X move after a Y move ({''.join('NSEW'[q] for q in ps)})")
                break
        src, dst = pk[u][1], pk[u][2]
        if pk[u][4] is not None and pk[u][5] is not None:  # whole life inside the window
            sx, sy, tx, ty = src % W, src // W, dst % W, dst // W
            want = abs(tx - sx) + abs(ty - sy)
            if len(ps) != want:
                errs.append(f"flit {u}: {len(ps)} hops, Manhattan distance {want}")

    complete = sum(1 for p in pk if p[4] is not None and p[5] is not None)
    print(f"  {name:10s} {len(frames)} cycles, {handoffs} link handoffs, {complete} complete flit lives checked: "
          + ("OK" if not errs else f"{len(errs)} ERRORS"))
    for e in errs[:10]:
        print("     ", e)
    return not errs


ok = True
for name in ORDER:
    with open(os.path.join(DATA, name + ".json")) as f:
        ok &= check(name, json.load(f))
print("REPLAY CHECK PASSED" if ok else "REPLAY CHECK FAILED")
sys.exit(0 if ok else 1)
