"""Charts for the project report, drawn from the repo's own result CSVs.

Nothing here is typed in except labels: every number comes from a CSV in
m*/results/. Light surface only (the report is a print document).
Palette: the same four categorical slots the project's other charts use,
assigned in fixed order.

usage: python make_figures.py        (needs matplotlib)
"""

import csv
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FIG = os.path.join(HERE, "fig")

SURFACE, INK1, INK2, MUTED, GRID, AXIS = "#ffffff", "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7"
C = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]
plt.rcParams["font.family"] = ["Segoe UI", "DejaVu Sans", "sans-serif"]


def rows(rel):
    with open(os.path.join(ROOT, rel), newline="") as f:
        return list(csv.DictReader(f))


def style(ax, ygrid=True):
    ax.set_facecolor(SURFACE)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(AXIS)
    ax.tick_params(colors=MUTED, labelcolor=MUTED, labelsize=9, length=0, pad=5)
    if ygrid:
        ax.grid(True, axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)


def title(fig, text, sub=None):
    fig.text(0.01, 0.985, text, color=INK1, fontsize=12.5, fontweight="semibold", ha="left", va="top")
    if sub:
        fig.text(0.01, 0.925, sub, color=INK2, fontsize=9, ha="left", va="top")


def save(fig, name):
    path = os.path.join(FIG, name)
    fig.savefig(path, dpi=200, facecolor=SURFACE)
    plt.close(fig)
    print("wrote", os.path.relpath(path, ROOT))


# ---------------------------------------------------------------- 3x3 vs 4x4
def fig_mesh_scaling():
    r3 = rows("m8_pipeline/results/sweep_pipe.csv")
    r4 = rows("m8_pipeline/results/sweep_4x4_pipe.csv")
    cfgs = [((1, 1, 4, 1), "1 VC x 4 flits"), ((1, 4, 2, 2), "4 VCs x 2 flits, 2-pass")]
    fig, axes = plt.subplots(1, 2, figsize=(9.2, 3.7), sharey=True)
    fig.subplots_adjust(left=0.075, right=0.985, top=0.76, bottom=0.14, wspace=0.08)
    title(fig, "A larger mesh saturates lower, and virtual channels matter more",
          "Uniform random traffic, two-stage routers. Accepted vs. offered load, flits per node per cycle.")
    for ax, (key, name) in zip(axes, cfgs):
        style(ax)
        for data, label, col, ls in ((r3, "3x3", C[0], "-"), (r4, "4x4", C[1], "-")):
            pts = sorted(
                ((float(x["offered"]), float(x["accepted"])) for x in data
                 if int(x["pattern"]) == 0 and (int(x["num_vns"]), int(x["vcs_per_vn"]), int(x["buffer_depth"]), int(x["sa_iters"])) == key))
            ax.plot([p[0] for p in pts], [p[1] for p in pts], color=col, linewidth=2.0, label=label, solid_capstyle="round")
            peak = max(p[1] for p in pts)
            ax.annotate(f"{label}: peak {peak:.3f}", xy=(1.0, peak), xytext=(0.99, peak + (0.03 if label == "3x3" else -0.10)),
                        ha="right", fontsize=8.5, color=INK2)
        ax.plot([0, 1], [0, 1], color=GRID, linewidth=1, zorder=0)
        ax.set_xlim(0, 1.0)
        ax.set_ylim(0, 1.0)
        ax.set_xlabel("Offered load", color=INK2, fontsize=9.5)
        ax.set_title(name, loc="left", color=INK1, fontsize=10.5, fontweight="semibold", pad=6)
    axes[0].set_ylabel("Accepted", color=INK2, fontsize=9.5)
    save(fig, "mesh_scaling.png")


# ------------------------------------------------------- area & critical path
def fig_area_timing():
    items = [  # (csv, config, label)
        ("m8_pipeline/results/synth.csv", "m4_router", "1 VC x 4"),
        ("m8_pipeline/results/synth_extra.csv", "m4_router_pipe", "1 VC x 4, 2-stage"),
        ("m8_pipeline/results/synth_extra2.csv", "deeper_fifo", "1 VC x 8"),
        ("m8_pipeline/results/synth_extra.csv", "m4_router_8_pipe", "1 VC x 8, 2-stage"),
        ("m8_pipeline/results/synth.csv", "vcs_1pass", "4 VCs x 2, 1-pass"),
        ("m8_pipeline/results/synth.csv", "vcs_1pass_pipe", "4 VCs x 2, 1-pass, 2-stage"),
        ("m8_pipeline/results/synth.csv", "vcs_2pass", "4 VCs x 2, 2-pass"),
        ("m8_pipeline/results/synth.csv", "vcs_2pass_pipe", "4 VCs x 2, 2-pass, 2-stage"),
        ("m8_pipeline/results/synth.csv", "vcs_2pass_secure_pipe", "  + security, 2-stage"),
        ("m8_pipeline/results/synth_vns.csv", "vns_secure", "3 VNs x 1 VC x 4, secure"),
        ("m8_pipeline/results/synth_vns.csv", "vns_secure_pipe", "3 VNs x 1 VC x 4, secure, 2-stage"),
        ("m8_pipeline/results/synth.csv", "full_pipe", "3 VNs x 2 VCs x 2, 2-pass, secure, 2-stage"),
    ]
    data = []
    for rel, cfg, label in items:
        for r in rows(rel):
            if r["config"] == cfg:
                data.append((label, float(r["area_per_router_um2"]), float(r["crit_path_ns"])))
                break
        else:
            raise SystemExit(f"missing {cfg} in {rel}")
    fig, axes = plt.subplots(1, 2, figsize=(9.2, 4.6), sharey=True)
    fig.subplots_adjust(left=0.34, right=0.975, top=0.84, bottom=0.1, wspace=0.07)
    title(fig, "What each feature costs: area and critical path, whole 3x3 mesh",
          "sky130_fd_sc_hd, typical corner, pre-layout. Area is the mesh total divided by 9 routers.")
    ys = list(range(len(data)))[::-1]
    for ax, idx, unit, fmt in ((axes[0], 1, "Area per router (um$^2$)", "{:,.0f}"), (axes[1], 2, "Critical path (ns)", "{:.2f}")):
        style(ax, ygrid=False)
        ax.grid(True, axis="x", color=GRID, linewidth=0.8)
        vals = [d[idx] for d in data]
        cols = [C[1] if "2-stage" in d[0] else C[0] for d in data]
        ax.barh(ys, vals, color=cols, height=0.62)
        for y, v in zip(ys, vals):
            ax.text(v + max(vals) * 0.012, y, fmt.format(v), va="center", fontsize=8, color=INK2)
        ax.set_xlim(0, max(vals) * 1.17)
        ax.set_xlabel(unit, color=INK2, fontsize=9.5)
    axes[0].set_yticks(ys)
    axes[0].set_yticklabels([d[0] for d in data], fontsize=8.5, color=INK2)
    fig.legend(handles=[plt.Rectangle((0, 0), 1, 1, color=C[0]), plt.Rectangle((0, 0), 1, 1, color=C[1])],
               labels=["single-cycle hop", "two-stage hop"], loc="upper right", bbox_to_anchor=(0.985, 0.985),
               fontsize=9, frameon=False, ncol=2)
    save(fig, "area_timing.png")


# ------------------------------------------------------------ timing journey
def fig_timing_journey():
    labels = ["M6 RTL", "M7 RTL\n(arbiter + route-at-write)", "M8\n(two-stage)"]
    simple = [4.95, 4.13, 3.33]
    vc = [10.10, 8.79, 7.94]
    fig, ax = plt.subplots(figsize=(7.2, 3.6))
    fig.subplots_adjust(left=0.1, right=0.97, top=0.76, bottom=0.2)
    title(fig, "Critical path through the project (whole 3x3 mesh)",
          "ns, sky130 typical corner, pre-layout. Lower is better.")
    style(ax)
    xs = range(3)
    w = 0.34
    b1 = ax.bar([x - w / 2 - 0.01 for x in xs], simple, width=w, color=C[0], label="1 VC x 4 (simple router)")
    b2 = ax.bar([x + w / 2 + 0.01 for x in xs], vc, width=w, color=C[1], label="4 VCs x 2, 2-pass (VC router)")
    for bars in (b1, b2):
        for b in bars:
            ax.text(b.get_x() + b.get_width() / 2, b.get_height() + 0.15, f"{b.get_height():.2f}", ha="center", fontsize=9, color=INK2)
    ax.set_xticks(list(xs))
    ax.set_xticklabels(labels, fontsize=9, color=INK2)
    ax.set_ylim(0, 12)
    ax.set_ylabel("Critical path (ns)", color=INK2, fontsize=9.5)
    ax.legend(frameon=False, fontsize=9, loc="upper right")
    save(fig, "timing_journey.png")


# -------------------------------------------------------------- watchdog study
def fig_watchdog():
    b = [r for r in rows("m6_security/results/watchdog_study.csv") if r["part"] == "b" and r["outstanding_or_limit"] != "open"]
    lim = [int(r["outstanding_or_limit"]) for r in b]
    det = [float(r["detection_delay"]) for r in b]
    p99 = [float(r["victim_p99_latency"]) for r in b]
    a = [r for r in rows("m6_security/results/watchdog_study.csv") if r["part"] == "a"]
    stall = {}
    for r in a:
        k = int(r["outstanding_or_limit"])
        stall[k] = max(stall.get(k, 0), int(r["max_honest_stall"]))
    fig, axes = plt.subplots(1, 3, figsize=(9.2, 3.5))
    fig.subplots_adjust(left=0.07, right=0.985, top=0.74, bottom=0.2, wspace=0.34)
    title(fig, "Choosing the watchdog limit: honest stalls vs. damage window",
          "Left: how long honest tiles really stall.  Middle and right: what each limit costs when a tile does go dark.")
    ax = axes[0]
    style(ax)
    ks = sorted(stall)
    ax.bar(range(len(ks)), [stall[k] for k in ks], color=C[2], width=0.62)
    for i, k in enumerate(ks):
        ax.text(i, stall[k] + 2, str(stall[k]), ha="center", fontsize=8.5, color=INK2)
    ax.set_xticks(range(len(ks)))
    ax.set_xticklabels([str(k) for k in ks], fontsize=8.5, color=INK2)
    ax.set_xlabel("Outstanding transactions per tile", color=INK2, fontsize=9)
    ax.set_ylabel("Longest honest stall (cycles)", color=INK2, fontsize=9)
    ax.set_ylim(0, 95)
    for ax, ys, ylabel, col in ((axes[1], det, "Detection delay (cycles)", C[0]), (axes[2], p99, "Victim p99 latency (cycles)", C[1])):
        style(ax)
        ax.plot(range(len(lim)), ys, color=col, linewidth=2, marker="o", markersize=5, markeredgecolor=SURFACE)
        ax.set_yscale("log")
        ax.set_xticks(range(len(lim)))
        ax.set_xticklabels([str(v) for v in lim], fontsize=8.5, color=INK2)
        ax.set_xlabel("WD_LIMIT (cycles)", color=INK2, fontsize=9)
        ax.set_ylabel(ylabel, color=INK2, fontsize=9)
        i = lim.index(256)
        ax.annotate("default 256", xy=(i, ys[i]), xytext=(i - 2.0, ys[i] * 3.2), fontsize=8.5, color=INK1,
                    arrowprops=dict(arrowstyle="-", color=MUTED, lw=0.8))
    axes[1].set_ylim(30, 3000)
    axes[2].set_ylim(4, 3000)
    save(fig, "watchdog.png")


# ---------------------------------------------------------------- deadlock grid
def fig_deadlock():
    d = rows("m5_virtual_networks/results/deadlock_demo.csv")
    cfgs = [((1, 1), "1 VN x 1 VC (shared)", C[1]), ((1, 3), "1 VN x 3 VCs (shared, 3x buffers)", C[3]), ((3, 1), "3 VNs x 1 VC (one per class)", C[0])]
    outs = sorted({int(r["outstanding"]) for r in d})
    fig, ax = plt.subplots(figsize=(7.2, 3.6))
    fig.subplots_adjust(left=0.1, right=0.97, top=0.76, bottom=0.2)
    title(fig, "Protocol deadlock vs. outstanding transactions per tile",
          "Fraction of 8 seeded runs that deadlock. The 3 VN line sits on zero.")
    style(ax)
    for (key, label, col), off in zip(cfgs, (0.0, 0.0, 0.0)):
        ys = []
        for o in outs:
            sel = [r for r in d if (int(r["num_vns"]), int(r["vcs_per_vn"])) == key and int(r["outstanding"]) == o]
            ys.append(sum(int(r["deadlocked"]) for r in sel) / len(sel))
        ax.plot(range(len(outs)), ys, color=col, linewidth=2.2, marker="o", markersize=6, markeredgecolor=SURFACE, label=label)
    ax.set_xticks(range(len(outs)))
    ax.set_xticklabels([str(o) for o in outs], fontsize=9, color=INK2)
    ax.set_yticks([0, 0.25, 0.5, 0.75, 1.0])
    ax.set_yticklabels(["0", "25%", "50%", "75%", "100%"])
    ax.set_ylim(-0.06, 1.08)
    ax.set_xlabel("Outstanding transactions per tile", color=INK2, fontsize=9.5)
    ax.set_ylabel("Runs deadlocked", color=INK2, fontsize=9.5)
    ax.legend(frameon=False, fontsize=8.5, loc="center left", bbox_to_anchor=(0.0, 0.62))
    save(fig, "deadlock.png")


if __name__ == "__main__":
    os.makedirs(FIG, exist_ok=True)
    fig_mesh_scaling()
    fig_area_timing()
    fig_timing_journey()
    fig_watchdog()
    fig_deadlock()
