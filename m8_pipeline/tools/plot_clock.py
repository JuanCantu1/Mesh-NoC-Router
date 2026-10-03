"""Bandwidth vs. clock-period target: which router to build at a given clock.

A chip's clock is set by its cores and caches; the router has to meet it.
For each router design, if its critical path fits in the clock period T,
it delivers (peak accepted flits/node/cycle) / T flits/node/ns at that
clock; if not, it can't be used at all. Plotting that for every T shows
which design wins where.

Inputs (all measured, nothing typed in):
  critical paths  results/synth*.csv          (tools/synth.sh, whole-mesh timing)
  1-stage peaks   ../m5_virtual_networks/results/vc_sweep.csv  (uniform traffic)
  2-stage peaks   results/sweep_pipe.csv      (tools/sweep.sh with PIPE=1)

Writes results/clock_study.png and results/clock_study_dark.png.
Colors: the data-viz reference palette's first four categorical slots in
fixed order (validated for both modes in M4's plot_sweep.py); every series
is direct-labeled, and the README carries the same numbers as a table.

Requires matplotlib:  python tools/plot_clock.py
"""

import csv
import glob
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (synth config name, sweep key (vns, vcs, depth, sa), pipelined?, label) -- palette order
SERIES = [
    ("m4_router",        (1, 1, 4, 1), False, "1 VC x 4, single-cycle (M4)"),
    ("m4_router_pipe",   (1, 1, 4, 1), True,  "1 VC x 4, two-stage"),
    ("m4_router_8_pipe", (1, 1, 8, 1), True,  "1 VC x 8, two-stage"),
    ("vcs_2pass_pipe",   (1, 4, 2, 2), True,  "4 VCs x 2, 2-pass, two-stage"),
]

THEMES = {
    "light": dict(out="clock_study.png", surface="#fcfcfb", ink1="#0b0b0b", ink2="#52514e",
                  muted="#898781", grid="#e1e0d9", axis="#c3c2b7",
                  series=["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]),
    "dark": dict(out="clock_study_dark.png", surface="#1a1a19", ink1="#ffffff", ink2="#c3c2b7",
                 muted="#898781", grid="#2c2c2a", axis="#383835",
                 series=["#3987e5", "#d95926", "#199e70", "#c98500"]),
}


def crit_paths():
    out = {}
    for path in glob.glob(os.path.join(ROOT, "results", "synth*.csv")):
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                out[r["config"]] = float(r["crit_path_ns"])
    return out


def peaks(path):
    out = {}
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if int(r["pattern"]) != 0:
                continue
            k = (int(r["num_vns"]), int(r["vcs_per_vn"]), int(r["buffer_depth"]), int(r["sa_iters"]))
            out[k] = max(out.get(k, 0.0), float(r["accepted"]))
    return out


def main():
    cp = crit_paths()
    pk1 = peaks(os.path.join(ROOT, "..", "m5_virtual_networks", "results", "vc_sweep.csv"))
    pk2 = peaks(os.path.join(ROOT, "results", "sweep_pipe.csv"))
    data = []
    for name, key, piped, label in SERIES:
        peak = (pk2 if piped else pk1)[key]
        data.append((label, cp[name], peak))
        print(f"{label:34s} crit {cp[name]:5.2f} ns  peak {peak:.3f}/cycle  -> {peak / cp[name]:.3f} flits/node/ns at its own limit")

    for theme in ("light", "dark"):
        t = THEMES[theme]
        plt.rcParams["font.family"] = ["Segoe UI", "DejaVu Sans", "sans-serif"]
        fig, ax = plt.subplots(figsize=(10.5, 5.6), dpi=150)
        fig.patch.set_facecolor(t["surface"])
        fig.subplots_adjust(left=0.08, right=0.70, top=0.80, bottom=0.12)
        ax.set_facecolor(t["surface"])
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
        for side in ("left", "bottom"):
            ax.spines[side].set_color(t["axis"])
        ax.tick_params(colors=t["muted"], labelcolor=t["muted"], labelsize=10.5, length=0, pad=6)
        ax.grid(True, axis="y", color=t["grid"], linewidth=0.8)
        ax.set_axisbelow(True)

        tmax = 10.0
        ys_end = []
        for i, (label, c, peak) in enumerate(data):
            ts = [c + k * (tmax - c) / 200 for k in range(201)]
            ys = [peak / x for x in ts]
            ax.plot(ts, ys, color=t["series"][i], linewidth=2.0, solid_capstyle="round", zorder=3)
            # where the design first meets timing: its best clock
            ax.plot([c], [peak / c], marker="o", markersize=7, color=t["series"][i],
                    markeredgecolor=t["surface"], markeredgewidth=1.5, zorder=4)
            ys_end.append(peak / tmax)
        # direct labels at the right end, nudged apart
        order = sorted(range(len(data)), key=lambda i: ys_end[i])
        placed = {}
        last = None
        for i in order:
            y = ys_end[i]
            if last is not None and y - last < 0.0075:
                y = last + 0.0075
            placed[i] = y
            last = y
        for i, (label, c, peak) in enumerate(data):
            ax.annotate(f"{label}  (from {c:.2f} ns)", xy=(tmax, ys_end[i]), xytext=(tmax + 0.12, placed[i]),
                        textcoords="data", va="center", ha="left", fontsize=9.5, color=t["ink2"],
                        annotation_clip=False)
        ax.set_xlim(3.0, tmax)
        ax.set_ylim(0, 0.24)
        ax.set_xlabel("Clock period the router must meet (ns)", color=t["ink2"], fontsize=11)
        ax.set_ylabel("Delivered bandwidth (flits / node / ns)", color=t["ink2"], fontsize=11)
        fig.text(0.08, 0.955, "Which router to build depends on the clock it has to meet",
                 color=t["ink1"], fontsize=15, fontweight="semibold", ha="left", va="top")
        fig.text(0.08, 0.905,
                 "Each line starts where that router first meets timing (dot) and delivers its peak "
                 "uniform-traffic throughput at every slower clock.\n3x3 mesh, sky130 typical corner, "
                 "pre-layout critical path of the whole mesh.",
                 color=t["ink2"], fontsize=10, ha="left", va="top")
        out = os.path.join(ROOT, "results", t["out"])
        fig.savefig(out, facecolor=t["surface"])
        plt.close(fig)
        print("wrote", os.path.relpath(out, ROOT))


if __name__ == "__main__":
    main()
