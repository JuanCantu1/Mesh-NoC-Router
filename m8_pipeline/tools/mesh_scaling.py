"""3x3 -> 4x4: does the router behave the way the topology says it should?

Nothing in the RTL is 3x3-specific (mesh size is a parameter; coordinates
are 4 bits), but every earlier result was measured on 3x3. This compares
the two sizes against a first-principles model, for uniform random traffic
with XY routing (same convention as M4's tools/theory_check.py: a tile
never sends to itself):

  zero-load latency  = (average hops + 1 routers) x (pipeline stages)
                       -- each router adds one cycle per stage, nothing else
  saturation bound   = 1 / (load on the busiest channel per unit injection)
                       -- or 1.0 if the injection/ejection port binds first

and checks:
  1. measured latency at the lowest load (0.05) is within 0.35 cycles of
     the zero-load model, on both sizes (a little contention at 0.05)
  2. peak accepted throughput never exceeds the bound
  (and reports, without judging, how much of the bound each size reaches)

usage: python tools/mesh_scaling.py results/sweep_pipe.csv results/sweep_4x4_pipe.csv
"""

import csv
import sys

CONFIGS = [((1, 1, 4, 1), "1 VC x 4"), ((1, 4, 2, 2), "4 VCs x 2, 2-pass")]
STAGES = 2  # PIPE=1


def model(W, H):
    N = W * H
    tid = lambda x, y: y * W + x
    chan, hops = {}, 0.0
    for s in range(N):
        sx, sy = s % W, s // W
        for d in range(N):
            if d == s:
                continue
            p = 1.0 / (N - 1)
            dx, dy = d % W, d // W
            x, y = sx, sy
            while x != dx:
                nx = x + (1 if dx > x else -1)
                chan[(tid(x, y), tid(nx, y))] = chan.get((tid(x, y), tid(nx, y)), 0.0) + p
                x = nx
            while y != dy:
                ny = y + (1 if dy > y else -1)
                chan[(tid(x, y), tid(x, ny))] = chan.get((tid(x, y), tid(x, ny)), 0.0) + p
                y = ny
            hops += p * (abs(dx - sx) + abs(dy - sy))
    avg_hops = hops / N
    bound = 1.0 / max(max(chan.values()), 1.0)
    return avg_hops, (avg_hops + 1) * STAGES, bound


def load(path):
    rows = {}
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if int(r["pattern"]) != 0:
                continue
            k = (int(r["num_vns"]), int(r["vcs_per_vn"]), int(r["buffer_depth"]), int(r["sa_iters"]))
            rows.setdefault(k, []).append(r)
    return rows


def main():
    p3, p4 = sys.argv[1], sys.argv[2]
    data = {3: load(p3), 4: load(p4)}
    ok = True
    print("model (uniform random, XY, two-stage routers):")
    mods = {}
    for k in (3, 4):
        h, z, b = model(k, k)
        mods[k] = (h, z, b)
        print(f"  {k}x{k}: average hops {h:.3f}, zero-load latency {z:.2f} cycles, saturation bound {b:.3f} flits/node/cycle")
    print()
    print(f"  {'router':20s} {'mesh':5s} {'latency @0.05':>14s} {'model':>6s} {'peak accepted':>14s} {'bound':>6s}  {'% of bound':>10s}")
    peaks = {}
    for key, name in CONFIGS:
        for k in (3, 4):
            rows = data[k].get(key)
            if not rows:
                print(f"  MISSING {name} on {k}x{k}")
                ok = False
                continue
            lo = min(rows, key=lambda r: int(r["rate_permille"]))
            lat = float(lo["avg_total_latency"])
            peak = max(float(r["accepted"]) for r in rows)
            peaks[(key, k)] = peak
            h, z, b = mods[k]
            flag = ""
            if abs(lat - z) > 0.35:
                flag += "  <- zero-load off model"
                ok = False
            if peak > b + 1e-9:
                flag += "  <- exceeds bound"
                ok = False
            print(f"  {name:20s} {k}x{k}   {lat:14.2f} {z:6.2f} {peak:14.3f} {b:6.3f}  {100 * peak / b:9.0f}%{flag}")
    print()
    for key, name in CONFIGS:
        if (key, 3) in peaks and (key, 4) in peaks:
            r = peaks[(key, 4)] / peaks[(key, 3)]
            rb = mods[4][2] / mods[3][2]
            print(f"  {name:20s} 4x4 / 3x3 peak = {r:.2f}   (bound ratio {rb:.2f})")
    print()
    print("MESH SCALING PASSED: both sizes match the model" if ok else "MESH SCALING FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
