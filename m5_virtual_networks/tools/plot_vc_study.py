"""Plot the virtual-channel study from results/vc_sweep.csv (tools/sweep.sh).

Writes results/vc_study.png (light) and results/vc_study_dark.png (dark);
the README picks one via <picture> + prefers-color-scheme.

Uniform random traffic, four router configurations -- the comparison that
tells the M5 story:
  1 VC x 4, 1 pass   M4's router (the baseline)
  1 VC x 8, 1 pass   twice the buffering, spent on depth
  4 VC x 2, 1 pass   the same 8 flits, spent on virtual channels
  4 VC x 2, 2 pass   the same VCs, with a second switch-allocation pass

Two panels, one measure each (never two y-scales on one plot), same visual
system as M4's plot_sweep.py: latency vs offered load (y capped -- a curve
leaving the top IS saturation) and accepted vs offered throughput.

Colors: the data-viz reference palette's first four categorical slots in
fixed order, validated for both modes (light worst CVD dE 9.1 / normal 22.9,
dark 8.4 / 19.8). Every series is direct-labeled and the README carries the
full table, so no series depends on color alone.

Requires matplotlib:  python tools/plot_vc_study.py
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
CSV_PATH = os.path.join(ROOT, "results", "vc_sweep.csv")

# (num_vns, vcs_per_vn, buffer_depth, sa_iters) -> legend label, in palette order
SERIES = [
    ((1, 1, 4, 1), "1 VC × 4 flits (M4)"),
    ((1, 1, 8, 1), "1 VC × 8 flits"),
    ((1, 4, 2, 1), "4 VCs × 2 flits, 1-pass"),
    ((1, 4, 2, 2), "4 VCs × 2 flits, 2-pass"),
]
LATENCY_CAP = 30.0
LABEL_MIN_GAP = 0.05  # throughput units; end labels closer than this get spread apart

THEMES = {
    "light": {
        "out": "vc_study.png",
        "surface": "#fcfcfb",
        "ink_primary": "#0b0b0b",
        "ink_secondary": "#52514e",
        "ink_muted": "#898781",
        "grid": "#e1e0d9",
        "axis": "#c3c2b7",
        "series": ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"],
    },
    "dark": {
        "out": "vc_study_dark.png",
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
    data = {key: {"offered": [], "accepted": [], "latency": []} for key, _ in SERIES}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if int(row["errors"]) != 0:
                sys.exit(f"refusing to plot: a sweep point ({row}) reported correctness errors")
            key = (int(row["num_vns"]), int(row["vcs_per_vn"]), int(row["buffer_depth"]),
                   int(row["sa_iters"]))
            if key in data and int(row["pattern"]) == 0:
                data[key]["offered"].append(float(row["offered"]))
                data[key]["accepted"].append(float(row["accepted"]))
                data[key]["latency"].append(float(row["avg_total_latency"]))
    for key, label in SERIES:
        if not data[key]["offered"]:
            sys.exit(f"no uniform-traffic data for {label} {key} in {path} -- run tools/sweep.sh")
    return data


def spread(ys, gap):
    """Nudge label positions apart (keeping order) so none are closer than gap."""
    order = sorted(range(len(ys)), key=lambda i: ys[i])
    out = list(ys)
    for a, b in zip(order, order[1:]):
        if out[b] - out[a] < gap:
            out[b] = out[a] + gap
    return out


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
    fig.subplots_adjust(left=0.065, right=0.80, top=0.70, bottom=0.13, wspace=0.26)

    line_kw = dict(linewidth=2.0, solid_joinstyle="round", solid_capstyle="round")
    end_dot_kw = dict(marker="o", markersize=6.5, markeredgewidth=1.5,
                      markeredgecolor=t["surface"], linestyle="none")
    labels = [label for _, label in SERIES]

    # ---- left: latency vs offered load (capped) ----------------------------
    style_axes(ax_lat, t)
    handles = []
    for i, (key, label) in enumerate(SERIES):
        d = data[key]
        xs, ys = [], []
        for x, y in zip(d["offered"], d["latency"]):
            xs.append(x)
            ys.append(y)
            if y > LATENCY_CAP:
                break
        (h,) = ax_lat.plot(xs, ys, color=t["series"][i], label=label, clip_on=True,
                           zorder=3, **line_kw)
        handles.append(h)
    ax_lat.set_xlim(0, 1.0)
    ax_lat.set_ylim(0, LATENCY_CAP)
    ax_lat.set_xlabel("Offered load (packets / node / cycle)", color=t["ink_secondary"],
                      fontsize=11)
    ax_lat.set_ylabel("Average latency (cycles)", color=t["ink_secondary"], fontsize=11)
    ax_lat.set_title("Where latency leaves the chart is the saturation point", loc="left",
                     color=t["ink_primary"], fontsize=12.5, fontweight="semibold", pad=10)
    ax_lat.text(0.02, 0.975, f"capped at {LATENCY_CAP:.0f} cycles", transform=ax_lat.transAxes,
                ha="left", va="top", fontsize=9.5, color=t["ink_muted"])

    # ---- right: accepted vs offered throughput ----------------------------
    style_axes(ax_thr, t)
    ax_thr.set_xlim(0, 1.0)
    ax_thr.set_ylim(0, 1.0)
    ax_thr.plot([0, 1], [0, 1], color=t["axis"], linewidth=1.2, zorder=1)
    ends = [data[key]["accepted"][-1] for key, _ in SERIES]
    label_ys = spread(ends, LABEL_MIN_GAP)
    for i, (key, label) in enumerate(SERIES):
        d = data[key]
        ax_thr.plot(d["offered"], d["accepted"], color=t["series"][i], zorder=3,
                    clip_on=False, **line_kw)
        ax_thr.plot([d["offered"][-1]], [d["accepted"][-1]], color=t["series"][i],
                    zorder=4, clip_on=False, **end_dot_kw)
        ax_thr.annotate(f"{label}  {ends[i]:.2f}",
                        xy=(d["offered"][-1], d["accepted"][-1]),
                        xytext=(1.0 + 0.035, label_ys[i]), textcoords="data",
                        ha="left", va="center", fontsize=10, color=t["ink_secondary"],
                        annotation_clip=False)
    ax_thr.set_xlabel("Offered load (packets / node / cycle)", color=t["ink_secondary"],
                      fontsize=11)
    ax_thr.set_ylabel("Accepted throughput (packets / node / cycle)",
                      color=t["ink_secondary"], fontsize=11)
    ax_thr.set_title("Throughput at saturation", loc="left",
                     color=t["ink_primary"], fontsize=12.5, fontweight="semibold", pad=10)
    x0, y0 = ax_thr.transData.transform((0.0, 0.0))
    x1, y1 = ax_thr.transData.transform((1.0, 1.0))
    angle = math.degrees(math.atan2(y1 - y0, x1 - x0))
    ax_thr.text(0.16, 0.20, "accepted = offered", rotation=angle, rotation_mode="anchor",
                ha="left", va="bottom", fontsize=9.5, color=t["ink_muted"])

    # ---- shared title, subtitle, legend (each on its own row) --------------
    fig.text(0.065, 0.965, "Uniform random traffic: virtual channels pay off once the allocator can use them",
             color=t["ink_primary"], fontsize=15, fontweight="semibold", ha="left", va="top")
    fig.text(0.065, 0.915,
             "3×3 mesh · XY routing · the last three configurations hold the same 8 flits per input "
             "port · open-loop Bernoulli injection · sampled every 0.05",
             color=t["ink_secondary"], fontsize=10.5, ha="left", va="top")
    leg = fig.legend(handles=handles, labels=labels, loc="upper left",
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
