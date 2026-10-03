#!/usr/bin/env python3
"""Analytic model of the 3x3 XY-routed mesh, checked against the measured sweep.

For each traffic pattern (the same four latency_sweep_tb.sv generates), this
computes -- per unit of injection rate lambda -- the load on every directed
router-to-router channel and on every ejection port, assuming XY routing
and each tile injecting at rate lambda. No resource can carry more than one
flit per cycle, so the pattern's ideal saturation throughput is

    lambda* = 1 / (heaviest load on any channel, ejection port, or injection port)

It also computes the average hop count H, which predicts zero-load latency
as H + 1 cycles in latency_sweep_tb.sv's accounting (1 cycle into the
source router, then 1 cycle per hop, cut-through at every router).

Then it reads results/latency_sweep.csv and checks the model against the RTL:
  * measured zero-load latency (lowest sweep point) must be within
    ZERO_LOAD_TOL cycles of H + 1;
  * no pattern may saturate *above* its bound (that would mean the
    measurement, not the router, is broken).
A pattern that saturates well *below* its bound isn't an error -- it's
throughput the router is leaving on the table, and the report says so.

Usage: python tools/theory_check.py   (exit 0 iff the checks above hold)
"""
import csv
import os
import sys

W = H = 3
N = W * H
NAMES = ["uniform", "transpose", "bit-complement", "hotspot"]
ZERO_LOAD_TOL = 0.10  # cycles; the lowest sweep point (0.05 load) sees a little contention
KNEE_FACTOR = 3.0     # same knee definition as tools/sweep.sh: latency <= 3x zero-load
RATE_STEP = 0.05      # sweep resolution


def xy(t):
    return t % W, t // W


def tid(x, y):
    return y * W + x


def label(t):
    x, y = xy(t)
    return f"({x},{y})"


def dest_dist(pattern, s):
    """{dest: probability} for source s -- mirrors pick_dest() in latency_sweep_tb.sv."""
    sx, sy = xy(s)
    uniform = {d: 1.0 / (N - 1) for d in range(N) if d != s}
    if pattern == 0:
        return uniform
    if pattern in (1, 2):
        d = tid(sy, sx) if pattern == 1 else tid(W - 1 - sx, H - 1 - sy)
        return uniform if d == s else {d: 1.0}  # diagonal/center tiles have no partner
    # hotspot: non-zero tiles send 25% of traffic to tile 0, the rest uniform
    if s == 0:
        return uniform
    dist = {d: 0.75 * p for d, p in uniform.items()}
    dist[0] += 0.25
    return dist


def xy_path(s, d):
    """Directed (from_tile, to_tile) channels a packet crosses: X first, then Y."""
    x, y = xy(s)
    dx, dy = xy(d)
    links = []
    while x != dx:
        nx = x + (1 if dx > x else -1)
        links.append((tid(x, y), tid(nx, y)))
        x = nx
    while y != dy:
        ny = y + (1 if dy > y else -1)
        links.append((tid(x, y), tid(x, ny)))
        y = ny
    return links


def analyze(pattern):
    chan, eject, hops = {}, [0.0] * N, 0.0
    for s in range(N):
        for d, p in dest_dist(pattern, s).items():
            path = xy_path(s, d)
            hops += p * len(path)
            eject[d] += p
            for link in path:
                chan[link] = chan.get(link, 0.0) + p
    avg_hops = hops / N
    max_chan = max(chan.values())
    hot_links = sorted(l for l, v in chan.items() if abs(v - max_chan) < 1e-9)
    max_eject = max(eject)
    hot_ports = [t for t in range(N) if abs(eject[t] - max_eject) < 1e-9]
    worst = max(max_chan, max_eject, 1.0)  # 1.0 = each tile's own injection port
    if worst == max_chan and max_chan > 1.0:
        limiter = f"channel {' & '.join(f'{label(a)}->{label(b)}' for a, b in hot_links)} carries {max_chan:.3f}x lambda"
    elif worst == max_eject and max_eject > 1.0:
        limiter = f"ejection port of tile {', '.join(label(t) for t in hot_ports)} receives {max_eject:.3f}x lambda"
    else:
        limiter = f"injection/ejection (1 flit/cycle per tile); busiest channel only {max_chan:.3f}x lambda"
    return avg_hops, 1.0 / worst, limiter


def measured(path):
    rows = {}
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            rows.setdefault(int(r["pattern"]), []).append(
                (float(r["offered"]), float(r["avg_total_latency"]), int(r["rate_permille"])))
    out = {}
    for p, pts in rows.items():
        pts.sort(key=lambda t: t[2])
        zero = pts[0][1]
        knee = None
        for offered, lat, rate in pts:
            if lat > KNEE_FACTOR * zero:
                break
            knee = rate / 1000.0
        out[p] = (zero, knee)
    return out


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    meas = measured(os.path.join(root, "results", "latency_sweep.csv"))
    failures = 0
    print(f"{'pattern':<15} {'zero-load latency':>22}   {'saturation':>28}")
    print(f"{'':<15} {'model':>8} {'measured':>10}   {'bound':>8} {'measured bracket':>19}")
    notes = []
    for p, name in enumerate(NAMES):
        avg_hops, bound, limiter = analyze(p)
        zero, knee = meas[p]
        pred = avg_hops + 1.0
        ok_zero = abs(zero - pred) <= ZERO_LOAD_TOL
        ok_bound = knee <= bound + 1e-9
        lo, hi = knee, knee + RATE_STEP
        verdict = "at bound" if lo <= bound <= hi + 1e-9 else f"{bound - hi:.2f}+ below bound"
        print(f"{name:<15} {pred:>8.2f} {zero:>10.2f}   {bound:>8.3f}   {lo:.2f}-{hi:.2f}  {verdict}")
        notes.append(f"  {name:<15} limited by {limiter}")
        if not ok_zero:
            failures += 1
            notes.append(f"  FAIL {name}: zero-load latency {zero:.2f} differs from model {pred:.2f} by more than {ZERO_LOAD_TOL}")
        if not ok_bound:
            failures += 1
            notes.append(f"  FAIL {name}: saturates at {knee:.2f}, ABOVE its analytic bound {bound:.3f} -- measurement is broken")
    print()
    print("What the model says limits each pattern:")
    print("\n".join(notes))
    print()
    if failures:
        print(f"THEORY CHECK FAILED ({failures} disagreement(s))")
        return 1
    print("THEORY CHECK PASSED: zero-load latency matches the model; no pattern exceeds its bound")
    return 0


if __name__ == "__main__":
    sys.exit(main())
