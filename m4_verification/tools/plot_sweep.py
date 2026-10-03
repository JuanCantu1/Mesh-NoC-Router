"""Plot results/latency_sweep.csv (produced by tools/sweep.sh).

Writes results/latency_sweep.png (light) and results/latency_sweep_dark.png
(dark) -- the README picks one via <picture> + prefers-color-scheme.

Two panels, one measure each (never two y-scales on one plot):
  left  -- average end-to-end latency vs offered load. The y-axis is capped:
           past each pattern's knee, latency grows without bound (source
           queues fill for as long as the run lasts), so the curve leaving the
           top of the panel IS the saturation signal.
  right -- accepted vs offered throughput, against the accepted = offered
           diagonal. Where a curve peels away from the diagonal and flattens,
           the network has hit its limit for that traffic pattern.

Colors are the data-viz reference palette's first four categorical slots in
fixed order, validated for both modes (adjacent pairlist, as used by line
charts): light worst CVD dE 9.1 / normal 22.9, dark 8.4 / 19.8. Aqua and
yellow sit below 3:1 on the light surface, so every series is direct-labeled
and the README carries a table view.

Requires matplotlib (`pip install matplotlib`):
    python tools/plot_sweep.py
"""

import csv
import math
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CSV_PATH = os.path.join(ROOT, "results", "latency_sweep.csv")

PATTERN_NAMES = ["Uniform random", "Transpose", "Bit-complement", "Hotspot"]
LATENCY_CAP = 30.0  # cycles; see module docstring

THEMES = {
    "light": {
        "out": "latency_sweep.png",
        "surface": "#fcfcfb",
        "ink_primary": "#0b0b0b",
        "ink_secondary": "#52514e",
        "ink_muted": "#898781",
        "grid": "#e1e0d9",
        "axis": "#c3c2b7",
        "series": ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"],
    },
    "dark": {
        "out": "latency_sweep_dark.png",
        "surface": "#1a1a19",
        "ink_primary": "#ffffff",
        "ink_secondary": "#c3c2b7",
        "ink_muted": "#898781",
        "grid": "#2c2c2a",
        "axis": "#383835",
        "series": ["#3987e5", "#d95926", "#199e70", "#c98500"],
    },
}


def load(path):
    data = {p: {"offered": [], "accepted": [], "latency": []} for p in range(4)}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if int(row["errors"]) != 0:
                sys.exit(f"refusing to plot: sweep point pattern={row['pattern']} "
                         f"rate={row['rate_permille']} reported correctness errors")
            p = int(row["pattern"])
            data[p]["offered"].append(float(row["offered"]))
            data[p]["accepted"].append(float(row["accepted"]))
            data[p]["latency"].append(float(row["avg_total_latency"]))
    return data


def style_axes(ax, t):
    ax.set_facecolor(t["surface"])
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(t["axis"])
        ax.spines[side].set_linewidth(1.0)
    ax.tick_params(colors=t["ink_muted"], labelcolor=t["ink_muted"], labelsize=10.5,
                   length=0, pad=6)
    ax.grid(True, axis="y", color=t["grid"], linewidth=0.8, linestyle="-")
    ax.set_axisbelow(True)


def render(data, theme_name):
    t = THEMES[theme_name]
    plt.rcParams["font.family"] = ["Segoe UI", "DejaVu Sans", "sans-serif"]

    fig, (ax_lat, ax_thr) = plt.subplots(1, 2, figsize=(12.0, 5.4), dpi=150)
    fig.patch.set_facecolor(t["surface"])
    # Right margin leaves room for the throughput panel's direct end labels.
    fig.subplots_adjust(left=0.065, right=0.845, top=0.70, bottom=0.13, wspace=0.26)

    # Plain 2px lines. Per-point markers with a surface ring were tried first:
    # at 20 samples per series the rings cut the line into what reads as a
    # dashed "projection" line. Sample spacing (every 0.05) is stated in the
    # subtitle instead; only line ENDS get a dot (below).
    line_kw = dict(linewidth=2.0, solid_joinstyle="round", solid_capstyle="round")
    end_dot_kw = dict(marker="o", markersize=8, markeredgewidth=2.0,
                      markeredgecolor=t["surface"], linestyle="none")

    # ---- left: latency vs offered load (capped) ----------------------------
    style_axes(ax_lat, t)
    handles = []
    for p in range(4):
        d = data[p]
        # Keep points through the first one past the cap so the curve visibly
        # exits the top of the panel instead of stopping short of it.
        xs, ys = [], []
        for x, y in zip(d["offered"], d["latency"]):
            xs.append(x)
            ys.append(y)
            if y > LATENCY_CAP:
                break
        (h,) = ax_lat.plot(xs, ys, color=t["series"][p], label=PATTERN_NAMES[p],
                           clip_on=True, zorder=3, **line_kw)
        handles.append(h)
    ax_lat.set_xlim(0, 1.0)
    ax_lat.set_ylim(0, LATENCY_CAP)
    ax_lat.set_xlabel("Offered load (packets / node / cycle)", color=t["ink_secondary"],
                      fontsize=11)
    ax_lat.set_ylabel("Average latency (cycles)", color=t["ink_secondary"], fontsize=11)
    ax_lat.set_title("Latency climbs, then leaves the chart at saturation", loc="left",
                     color=t["ink_primary"], fontsize=12.5, fontweight="semibold", pad=10)
    # Top-left stays empty: no curve reaches the cap before x ~ 0.35.
    ax_lat.text(0.02, 0.975, f"capped at {LATENCY_CAP:.0f} cycles",
                transform=ax_lat.transAxes, ha="left", va="top", fontsize=9.5,
                color=t["ink_muted"])

    # ---- right: accepted vs offered throughput ----------------------------
    style_axes(ax_thr, t)
    ax_thr.set_xlim(0, 1.0)
    ax_thr.set_ylim(0, 1.0)
    ax_thr.plot([0, 1], [0, 1], color=t["axis"], linewidth=1.2, zorder=1)
    for p in range(4):
        d = data[p]
        ax_thr.plot(d["offered"], d["accepted"], color=t["series"][p], zorder=3,
                    clip_on=False, **line_kw)
        ax_thr.plot([d["offered"][-1]], [d["accepted"][-1]], color=t["series"][p],
                    zorder=4, clip_on=False, **end_dot_kw)
        # Direct label at the line end: the colored end-dot beside it carries
        # identity; the text itself stays in ink.
        ax_thr.annotate(f"{PATTERN_NAMES[p]}  {d['accepted'][-1]:.2f}",
                        xy=(d["offered"][-1], d["accepted"][-1]),
                        xytext=(10, 0), textcoords="offset points",
                        ha="left", va="center", fontsize=10, color=t["ink_secondary"],
                        annotation_clip=False)
    ax_thr.set_xlabel("Offered load (packets / node / cycle)", color=t["ink_secondary"],
                      fontsize=11)
    ax_thr.set_ylabel("Accepted throughput (packets / node / cycle)",
                      color=t["ink_secondary"], fontsize=11)
    ax_thr.set_title("Throughput flattens where each pattern saturates", loc="left",
                     color=t["ink_primary"], fontsize=12.5, fontweight="semibold", pad=10)
    # Label the diagonal along its own slope, in the empty upper-left
    # triangle (accepted can never exceed offered, so nothing is drawn there).
    x0, y0 = ax_thr.transData.transform((0.0, 0.0))
    x1, y1 = ax_thr.transData.transform((1.0, 1.0))
    angle = math.degrees(math.atan2(y1 - y0, x1 - x0))
    ax_thr.text(0.16, 0.20, "accepted = offered", rotation=angle, rotation_mode="anchor",
                ha="left", va="bottom", fontsize=9.5, color=t["ink_muted"])

    # ---- shared title, subtitle, legend (each on its own row) --------------
    fig.text(0.065, 0.965, "3×3 credit-based mesh: latency and throughput by traffic pattern",
             color=t["ink_primary"], fontsize=15, fontweight="semibold", ha="left", va="top")
    fig.text(0.065, 0.915,
             "XY routing · 4-flit input FIFOs · one queue per input port · open-loop Bernoulli "
             "injection · sampled every 0.05 · 1,000-cycle warmup, 2,000-cycle measurement",
             color=t["ink_secondary"], fontsize=10.5, ha="left", va="top")
    leg = fig.legend(handles=handles, labels=PATTERN_NAMES, loc="upper left",
                     bbox_to_anchor=(0.058, 0.875), ncol=4, frameon=False, fontsize=10.5,
                     handlelength=2.2, columnspacing=1.8)
    for text in leg.get_texts():
        text.set_color(t["ink_secondary"])

    out = os.path.join(ROOT, "results", t["out"])
    fig.savefig(out, facecolor=t["surface"])
    plt.close(fig)
    print(f"wrote {os.path.relpath(out, ROOT)}")


def main():
    data = load(CSV_PATH)
    for theme in ("light", "dark"):
        render(data, theme)


if __name__ == "__main__":
    main()
