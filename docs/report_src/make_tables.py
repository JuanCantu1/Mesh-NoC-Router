"""Generate the sweep tables of Appendix B from the result CSVs.

Writes parts/14b_generated.html. Run before build.py:  python make_tables.py
"""

import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def rows(rel):
    with open(os.path.join(ROOT, rel), newline="") as f:
        return list(csv.DictReader(f))


def by_rate(data, pred):
    return {int(r["rate_permille"]): r for r in data if pred(r)}


def cell(r):
    if r is None:
        return '<td class="num">n/a</td><td class="num">n/a</td>'
    return f'<td class="num">{float(r["accepted"]):.3f}</td><td class="num">{float(r["avg_total_latency"]):.1f}</td>'


def m4_table():
    d = rows("m4_verification/results/latency_sweep.csv")
    names = ["Uniform random", "Transpose", "Bit-complement", "Hotspot"]
    loads = [100, 300, 500, 600, 700, 800, 900, 1000]
    per = [by_rate(d, lambda r, p=p: int(r["pattern"]) == p) for p in range(4)]
    out = ['<table class="tight"><caption>B.3 M4 sweep, 3&times;3, single 4-flit queue per input: accepted throughput and average total latency (cycles) at selected offered loads</caption>',
           "<thead><tr><th rowspan=\"2\">Offered</th>" + "".join(f'<th colspan="2" style="text-align:center">{n}</th>' for n in names) + "</tr>",
           "<tr>" + "".join('<th class="num">accepted</th><th class="num">latency</th>' for _ in names) + "</tr></thead><tbody>"]
    for ld in loads:
        out.append(f'<tr><td>{ld / 1000:.2f}</td>' + "".join(cell(per[p].get(ld)) for p in range(4)) + "</tr>")
    out.append("</tbody></table>")
    return "\n".join(out)


def pipe_table():
    d3 = rows("m8_pipeline/results/sweep_pipe.csv")
    d4 = rows("m8_pipeline/results/sweep_4x4_pipe.csv")
    keys = [((1, 1, 4, 1), "1 VC &times; 4"), ((1, 4, 2, 2), "4 VCs &times; 2, 2-pass")]
    loads = [50, 200, 400, 500, 600, 700, 800, 900, 1000]

    def sel(data, key):
        return by_rate(data, lambda r: int(r["pattern"]) == 0 and (int(r["num_vns"]), int(r["vcs_per_vn"]), int(r["buffer_depth"]), int(r["sa_iters"])) == key)

    cols = [(sel(d3, k), f"{n}, 3&times;3") for k, n in keys] + [(sel(d4, k), f"{n}, 4&times;4") for k, n in keys]
    out = ['<table class="tight"><caption>B.4 Two-stage routers, uniform traffic: accepted throughput and average total latency (cycles) on 3&times;3 and 4&times;4</caption>',
           '<thead><tr><th rowspan="2">Offered</th>' + "".join(f'<th colspan="2" style="text-align:center">{n}</th>' for _, n in cols) + "</tr>",
           "<tr>" + "".join('<th class="num">accepted</th><th class="num">latency</th>' for _ in cols) + "</tr></thead><tbody>"]
    for ld in loads:
        out.append(f'<tr><td>{ld / 1000:.2f}</td>' + "".join(cell(c.get(ld)) for c, _ in cols) + "</tr>")
    out.append("</tbody></table>")
    return "\n".join(out)


def main():
    html = ('<h2 id="b-sweeps">B.3 and B.4&nbsp;&nbsp;Sweep tables</h2>\n'
            "<p>Latency is average total latency, injection queue included, in cycles, so it rises steeply past saturation where the source queues grow.</p>\n"
            + m4_table() + "\n" + pipe_table() + "\n")
    path = os.path.join(HERE, "parts", "14b_generated.html")
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(html)
    print("wrote", os.path.relpath(path, ROOT))


if __name__ == "__main__":
    main()
