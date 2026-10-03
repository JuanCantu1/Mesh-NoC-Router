"""Bundle the replays for the page.

  data/*.json + sim/<name>/log.txt  ->  data/scenarios.js
      window.NOC_SCENARIOS = {...}; each scenario also carries the
      testbench's own verdict lines, shown verbatim on the page.
  index.html + data/scenarios.js    ->  noc_replay.html
      one self-contained file that opens straight from disk (file://
      blocks fetch() of local JSON, so the data is inlined).

usage: python tools/bundle.py
"""

import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DATA = os.path.join(ROOT, "data")
ORDER = ["uniform", "deadlock", "vns", "bh_open", "bh_secure"]
VERDICT = re.compile(r"^(PASS|ATTACK-PASS|DEADLOCK at|transactions:|black hole at|  packets for the black hole"
                     r"|vns=|watchdog:)")

out = {}
for name in ORDER:
    path = os.path.join(DATA, name + ".json")
    if not os.path.exists(path):
        continue
    with open(path) as f:
        d = json.load(f)
    log = os.path.join(ROOT, "sim", name, "log.txt")
    d["log"] = []
    if os.path.exists(log):
        with open(log) as f:
            d["log"] = [ln.rstrip() for ln in f if VERDICT.match(ln)]
    out[name] = d

js = "window.NOC_SCENARIOS = " + json.dumps(out, separators=(",", ":")) + ";\n"
with open(os.path.join(DATA, "scenarios.js"), "w", newline="") as f:
    f.write(js)
print(f"wrote data/scenarios.js ({len(js) / 1024:.0f} KB, {len(out)} scenarios)")

page = os.path.join(ROOT, "index.html")
if os.path.exists(page):
    with open(page, encoding="utf-8") as f:
        html = f.read()
    tag = '<script src="data/scenarios.js"></script>'
    assert tag in html, "index.html must load data/scenarios.js"
    html = html.replace(tag, "<script>\n" + js + "</script>")
    head, sep, body = html.partition("<!-- /head -->")
    assert sep, "index.html must mark the end of its head material with <!-- /head -->"
    standalone = ("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
                  "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n"
                  + head + "</head>\n<body>\n" + body + "\n</body>\n</html>\n")
    with open(os.path.join(ROOT, "noc_replay.html"), "w", encoding="utf-8", newline="") as f:
        f.write(standalone)
    print(f"wrote noc_replay.html ({len(standalone) / 1024:.0f} KB, opens from disk)")
