"""Turn an Icarus VCD of a 3x3 vc_mesh run into a compact per-cycle replay.

The visualizer never models the router: every flit position it draws comes
from this file, and every value in this file comes from the waveform the
real RTL produced. Per clock cycle it records

  * link traversals   router out_valid/out_vc/out_data on N/S/E/W
  * ejections         router out_valid on the local port
  * injections        router in_valid on the local port
  * buffer contents   every input-VC FIFO (mem/head/count), and in
                      protocol_tb the endpoints' receive queues
  * security          per-router alarm bits and quarantine
  * testbench stats   cycle_num, completed, ... (whatever scalars exist)

Signals are sampled the way the flops see them: just before each rising
clock edge. Flits are identified by (message class, destination, payload),
which both testbenches keep unique among live flits, so every flit gets a
stable id from injection to ejection and the page can trace its path.

usage: python vcd2json.py run.vcd out.json --name NAME [--from C] [--to C]
                          [--meta key=value ...]
"""

import argparse
import json
import re
import sys

PORTS = "NSEWL"
FLIT_W = 34


def parse_header(f):
    """Return ({id: (fullname, width)}, timescale_ps)."""
    ids = {}
    scope = []
    tscale = 1
    lines = iter(f)
    for line in lines:
        s = line.strip()
        if s.startswith("$timescale"):
            body = s
            while "$end" not in body:
                body += " " + next(lines).strip()
            m = re.search(r"(\d+)\s*(s|ms|us|ns|ps|fs)", body)
            mult = {"s": 1e12, "ms": 1e9, "us": 1e6, "ns": 1e3, "ps": 1, "fs": 1e-3}[m.group(2)]
            tscale = int(m.group(1)) * mult
        elif s.startswith("$scope"):
            scope.append(s.split()[2])
        elif s.startswith("$upscope"):
            scope.pop()
        elif s.startswith("$var"):
            p = s.split()
            width, ident, name = int(p[2]), p[3], p[4]
            full = ".".join(scope + [name])
            ids.setdefault(ident, []).append((full, width))
        elif s.startswith("$enddefinitions"):
            break
    return ids, tscale, lines


def as_int(bits):
    if bits is None or any(c in "xXzZ" for c in bits):
        return 0
    return int(bits, 2) if bits else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vcd")
    ap.add_argument("out")
    ap.add_argument("--name", required=True)
    ap.add_argument("--from", dest="c0", type=int, default=0)
    ap.add_argument("--to", dest="c1", type=int, default=10**9)
    ap.add_argument("--meta", nargs="*", default=[])
    a = ap.parse_args()

    f = open(a.vcd)
    ids, tscale, lines = parse_header(f)

    # ---- pick the signals we need ---------------------------------------
    rtr_re = re.compile(r"^(\w+)\.dut\.g_col\[(\d+)\]\.g_row\[(\d+)\]\.u_router\.(\w+)$")
    fifo_re = re.compile(r"^(\w+)\.dut\.g_col\[(\d+)\]\.g_row\[(\d+)\]\.u_router\.g_in_port\[(\d)\]\.g_in_vc\[(\d)\]\.u_fifo\.(mem|head|count)$")
    rx_re = re.compile(r"^(\w+)\.g_tile\[(\d+)\]\.g_rx_vc\[(\d)\]\.u_rx\.(mem|head|count)$")
    top_re = re.compile(r"^(\w+)\.(\w+)$")

    want = {}      # ident -> list of keys
    params = {}    # name -> ident (parameters: read their first value)
    tb_name = None
    for ident, names in ids.items():
        for full, width in names:
            m = fifo_re.match(full)
            if m:
                tb_name = m.group(1)
                x, y, p, v, sig = int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)), m.group(6)
                want.setdefault(ident, []).append(("fifo", (x, y, p, v), sig))
                continue
            m = rx_re.match(full)
            if m:
                want.setdefault(ident, []).append(("rx", (int(m.group(2)), int(m.group(3))), m.group(4)))
                continue
            m = rtr_re.match(full)
            if m:
                sig = m.group(4)
                if sig in ("out_valid", "out_vc", "out_data", "in_valid", "in_vc", "in_data",
                           "alarm", "quarantine", "st_flit"):
                    want.setdefault(ident, []).append(("rtr", (int(m.group(2)), int(m.group(3))), sig))
                continue
            m = top_re.match(full)
            if m and "." not in m.group(2):
                sig = m.group(2)
                if sig.isupper() or sig in ("MESH_W", "MESH_H"):
                    params[sig] = ident
                elif sig == "clk":
                    want.setdefault(ident, []).append(("clk", None, None))
                elif width == 32 and sig in ("cycle_num", "completed", "started", "errors",
                                             "breaches", "denials", "atk_refused",
                                             "total_delivered", "bh_discarded", "bh_delivered",
                                             "quarantine_cycle", "rate_permille", "blackhole"):
                    want.setdefault(ident, []).append(("tb", None, sig))
                elif width == 1 and sig in ("deadlocked", "generating", "measuring_window"):
                    want.setdefault(ident, []).append(("tb", None, sig))
    for ident in params.values():
        want.setdefault(ident, [])
    if tb_name is None:
        sys.exit("no vc_mesh router FIFOs found in the VCD")

    f.close()
    clk_ident = next(i for i, ks in want.items() if any(k[0] == "clk" for k in ks))
    snaps = resnapshot(a.vcd, set(want), clk_ident, a.c0, a.c1)

    # ---- decode --------------------------------------------------------
    def pval(name, default=0):
        ident = params.get(name)
        return as_int(snaps[0].get(ident)) if ident in snaps[0] else default

    W, H = pval("MESH_W", 3), pval("MESH_H", 3)
    nv = pval("NUM_VCS", 1)
    depth = pval("BUFFER_DEPTH", 4)
    cfg = dict(tb=tb_name, mesh_w=W, mesh_h=H, num_vns=pval("NUM_VNS", 1), vcs_per_vn=pval("VCS_PER_VN", 1),
               num_vcs=nv, depth=depth, sa_iters=pval("SA_ITERS", 1), secure=pval("SECURE", 0),
               wd_limit=pval("WD_LIMIT", 0), pipe=pval("PIPE", 0))
    VC_W = 3

    # declared widths: VCD values drop leading zeros, so never infer width from them
    width = {ident: names[0][1] for ident, names in ids.items()}
    idx = {}  # key tuple -> ident
    for ident, ks in want.items():
        for k in ks:
            idx[k] = ident

    def get(s, kind, where, sig):
        return s.get(idx.get((kind, where, sig)))

    def flit_fields(word):
        return dict(cls=(word >> 32) & 3, sx=(word >> 28) & 15, sy=(word >> 24) & 15,
                    dx=(word >> 20) & 15, dy=(word >> 16) & 15, pay=word & 0xFFFF)

    def key_of(word):
        return (word >> 32) & 3, (word >> 16) & 0xFF, word & 0xFFFF  # class, dest, payload

    packets = []        # uid -> record
    live = {}           # key -> uid

    def uid_for(word, cyc, inject=False):
        k = key_of(word)
        if not inject and k in live:
            return live[k]
        ff = flit_fields(word)
        rec = dict(cls=ff["cls"], src=ff["sy"] * W + ff["sx"], dst=ff["dy"] * W + ff["dx"],
                   pay=ff["pay"], inj=cyc if inject else None, ej=None, drop=None, hops=[])
        packets.append(rec)
        live[k] = len(packets) - 1
        return live[k]

    def fifo_contents(s, kind, where):
        # decode slot by slot: unwritten slots hold X (storage has no reset),
        # which must not poison the occupied ones
        cnt = as_int(get(s, kind, where, "count"))
        if cnt == 0:
            return []
        head = as_int(get(s, kind, where, "head"))
        mw = width[idx[(kind, where, "mem")]]
        bits = get(s, kind, where, "mem") or ""
        bits = bits.rjust(mw, bits[0] if bits[:1] in ("x", "z") else "0")  # VCD left-extension rule
        d = mw // FLIT_W
        out = []
        for i in range(cnt):
            slot = (head + i) % d
            lo = mw - (slot + 1) * FLIT_W
            out.append(as_int(bits[lo:lo + FLIT_W]))
        return out

    frames = []
    prev_buf = {}
    prev_rx = {}
    tb_sigs = sorted({k[2] for ks in want.values() for k in ks if k[0] == "tb"})
    for ci, s in enumerate(snaps):
        cyc = a.c0 + ci
        fr = {"m": [], "i": [], "e": [], "b": [], "a": [], "x": []}
        # injections first, so a flit injected this cycle has an id
        for x in range(W):
            for y in range(H):
                r = y * W + x
                iv = as_int(get(s, "rtr", (x, y), "in_valid"))
                if (iv >> 4) & 1:
                    word = (as_int(get(s, "rtr", (x, y), "in_data")) >> (4 * FLIT_W)) & ((1 << FLIT_W) - 1)
                    u = uid_for(word, cyc, inject=True)
                    fr["i"].append([r, u])
        for x in range(W):
            for y in range(H):
                r = y * W + x
                ov = as_int(get(s, "rtr", (x, y), "out_valid"))
                ovc = as_int(get(s, "rtr", (x, y), "out_vc"))
                od = as_int(get(s, "rtr", (x, y), "out_data"))
                for p in range(5):
                    if (ov >> p) & 1:
                        word = (od >> (p * FLIT_W)) & ((1 << FLIT_W) - 1)
                        vc = (ovc >> (p * VC_W)) & 7
                        u = uid_for(word, cyc)
                        packets[u]["hops"].append([cyc, r, p, vc])
                        if p == 4:
                            fr["e"].append([r, u, vc])
                            packets[u]["ej"] = cyc
                        else:
                            fr["m"].append([r, p, vc, u])
                al = as_int(get(s, "rtr", (x, y), "alarm"))
                q = as_int(get(s, "rtr", (x, y), "quarantine"))
                if al or q:
                    fr["a"].append([r, al, q])
                    if al & 4:  # discard pulse: the flit leaving on the local port is thrown away
                        stf = as_int(get(s, "rtr", (x, y), "st_flit"))
                        word = (stf >> (4 * FLIT_W)) & ((1 << FLIT_W) - 1)
                        u = uid_for(word, cyc)
                        packets[u]["drop"] = cyc
                        fr["x"].append([r, u])
                # buffers: emit only the ones that changed since the last frame
                for p in range(5):
                    for v in range(nv):
                        key = (r * 5 + p) * nv + v
                        cont = [uid_for(w, cyc) for w in fifo_contents(s, "fifo", (x, y, p, v))]
                        if prev_buf.get(key) != cont or ci == 0:
                            if cont or key in prev_buf:
                                fr["b"].append([key] + cont)
                            prev_buf[key] = cont
        # endpoint receive queues (protocol_tb only)
        rx = []
        for t in range(W * H):
            for v in range(nv):
                if ("rx", (t, v), "count") not in idx:
                    continue
                cont = [uid_for(w, cyc) for w in fifo_contents(s, "rx", (t, v))]
                key = t * nv + v
                if prev_rx.get(key) != cont or ci == 0:
                    rx.append([key] + cont)
                    prev_rx[key] = cont
        if rx:
            fr["r"] = rx
        st = {}
        for sig in tb_sigs:
            ident = idx.get(("tb", None, sig))
            bits = s.get(ident)
            if bits is None:
                continue
            val = as_int(bits)
            if len(bits) == 32 and val >= 2**31:
                val -= 2**32
            st[sig] = val
        fr["s"] = st
        # drop empty lists to keep the file small
        frames.append({k: v for k, v in fr.items() if v or k == "s"})

    meta = dict(kv.split("=", 1) for kv in a.meta)
    out = dict(name=a.name, cfg=cfg, first_cycle=a.c0, meta=meta,
               packets=[[p["cls"], p["src"], p["dst"], p["pay"], p["inj"], p["ej"], p["drop"]] for p in packets],
               frames=frames)
    with open(a.out, "w", newline="") as fo:
        json.dump(out, fo, separators=(",", ":"))
    n_ej = sum(1 for p in packets if p["ej"] is not None)
    print(f"{a.name}: {len(frames)} cycles, {len(packets)} flits seen, {n_ej} ejected, cfg {cfg}")


def resnapshot(path, want_ids, clk_ident, c0, c1):
    """Exact pre-edge sampling: buffer one whole timestep, and if the clock
    rises in it, snapshot the values from *before* that timestep."""
    snaps = []
    cur = {}
    edge_index = -1
    with open(path) as f:
        for line in f:
            if line.startswith("$enddefinitions"):
                break
        step = []
        t = None

        def flush():
            nonlocal edge_index
            rising = False
            for ident, bits in step:
                if ident == clk_ident and bits == "1" and cur.get(clk_ident) == "0":
                    rising = True
            if rising:
                edge_index += 1
                if c0 <= edge_index <= c1:
                    snaps.append(dict(cur))
            for ident, bits in step:
                cur[ident] = bits
            step.clear()

        for line in f:
            c = line[:1]
            if c == "#":
                flush()
                if edge_index > c1:
                    break
                continue
            if c in ("0", "1", "x", "X", "z", "Z"):
                ident = line[1:].strip()
                if ident in want_ids:
                    step.append((ident, c))
            elif c == "b":
                bits, ident = line[1:].split()
                if ident in want_ids:
                    step.append((ident, bits))
            # $dumpvars / $end lines: values inside $dumpvars are plain changes
        flush()
    return snaps


if __name__ == "__main__":
    main()
