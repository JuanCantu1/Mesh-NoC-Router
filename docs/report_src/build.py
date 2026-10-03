"""Build docs/NoC_Router_Project_Report.pdf from parts/*.html.

  1. concatenate parts/*.html (sorted by file name) into report.html
  2. generate the table of contents from the h1/h2 headings
  3. print to PDF with headless Chrome
  4. read each heading's page from the PDF's named destinations, write the
     page numbers into the table of contents, and print again
  5. confirm the page numbers did not move, add PDF bookmarks and metadata

usage:  python build.py            (needs Chrome and PyMuPDF; figures: make_figures.py)
"""

import glob
import html
import os
import re
import subprocess
import sys

import fitz  # PyMuPDF

HERE = os.path.dirname(os.path.abspath(__file__))
DOCS = os.path.dirname(HERE)
OUT = os.path.join(DOCS, "NoC_Router_Project_Report.pdf")
CHROME = os.environ.get("CHROME", r"C:\Program Files\Google\Chrome\Application\chrome.exe")
TITLE = "Mesh NoC Router: Project Report"

HEAD = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>%s</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans+Condensed:wght@400;500;600&family=IBM+Plex+Sans:ital,wght@0,400;0,500;0,600;1,400&display=swap" rel="stylesheet">
<style>
%s
</style></head><body>
"""

HEADING = re.compile(r'<(h[12])((?:\s[^>]*)?)>(.*?)</\1>', re.S)


def strip_tags(s):
    return html.unescape(re.sub(r"<[^>]+>", "", s)).strip()


def number_headings(body):
    """Insert chapter/section numbers into h1/h2 and return (body, [(level, id, label, text)]).

    Done here and not with CSS counters so the numbers in the text, in the
    table of contents and in the PDF bookmarks are the same by construction.
    """
    heads = []
    state = {"chap": 0, "sec": 0, "appx": 0, "in_appx": False}

    def sub(m):
        tag, attrs, inner = m.group(1), m.group(2), m.group(3)
        if "data-notoc" in attrs:
            return m.group(0)
        mid = re.search(r'id="([^"]+)"', attrs)
        if not mid:
            raise SystemExit(f"heading without id: {strip_tags(inner)[:60]}")
        hid = mid.group(1)
        cls = re.search(r'class="([^"]*)"', attrs)
        cls = cls.group(1).split() if cls else []
        text = strip_tags(inner)
        if tag == "h1":
            state["sec"] = 0
            if "appx" in cls:
                state["appx"] += 1
                state["in_appx"] = True
                label = "Appendix " + chr(64 + state["appx"])
            elif "plain" in cls:
                label = ""
            else:
                state["chap"] += 1
                label = str(state["chap"])
            heads.append((1, hid, label, text))
        else:
            state["sec"] += 1
            label = "" if (state["in_appx"] or "nonum" in cls) else f"{state['chap']}.{state['sec']}"
            heads.append((2, hid, label, text))
        span = f'<span class="hn">{label}</span>' if label else ""
        return f"<{tag}{attrs}>{span}{inner}</{tag}>"

    return HEADING.sub(sub, body), heads


def toc_html(heads, pages):
    rows = []
    for lvl, hid, label, text in heads:
        pg = pages.get(hid, "")
        lab = f"{label}&nbsp;&nbsp;" if label else ""
        rows.append(f'<li><a class="l{lvl}" href="#{hid}"><span>{lab}{html.escape(text)}</span>'
                    f'<span class="dots"></span><span class="pg">{pg}</span></a></li>')
    return "\n".join(rows)


def assemble(pages):
    body = ""
    for p in sorted(glob.glob(os.path.join(HERE, "parts", "*.html"))):
        with open(p, encoding="utf-8") as f:
            body += f.read() + "\n"
    body, heads = number_headings(body)

    def keep_short(m):
        attrs, inner = m.group(1), m.group(2)
        if inner.count("<tr") > 12:
            return m.group(0)
        if 'class="' in attrs:
            attrs = attrs.replace('class="', 'class="keep ', 1)
        else:
            attrs += ' class="keep"'
        return f"<table{attrs}>{inner}</table>"

    body = re.sub(r"<table([^>]*)>(.*?)</table>", keep_short, body, flags=re.S)
    ids = re.findall(r'id="([^"]+)"', body)
    dup = sorted({i for i in ids if ids.count(i) > 1})
    if dup:
        raise SystemExit(f"duplicate ids (named destinations would collide): {dup}")
    body = body.replace("<!--TOC-->", toc_html([h for h in heads if h[1] != "toc"], pages))
    with open(os.path.join(HERE, "style.css"), encoding="utf-8") as f:
        css = f.read()
    doc = HEAD % (TITLE, css) + body + "\n</body></html>\n"
    path = os.path.join(HERE, "report.html")
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(doc)
    return path, heads


def render(html_path, pdf_path):
    if os.path.exists(pdf_path):
        os.remove(pdf_path)
    uri = "file:///" + html_path.replace("\\", "/").replace(" ", "%20")
    cmd = [CHROME, "--headless=new", "--disable-gpu", "--no-pdf-header-footer", "--virtual-time-budget=20000",
           f"--print-to-pdf={pdf_path}", uri]
    try:
        subprocess.run(cmd, timeout=240, capture_output=True)
    except subprocess.TimeoutExpired:
        pass
    if not os.path.exists(pdf_path):
        raise SystemExit("Chrome did not write the PDF")


def heading_pages(pdf_path, heads):
    doc = fitz.open(pdf_path)
    dests = doc.resolve_names()
    pages = {}
    for _lvl, hid, _label, text in heads:
        d = dests.get(hid)
        if d is None:
            raise SystemExit(f"no destination for #{hid} ({text})")
        pages[hid] = d["page"] + 1
    n = doc.page_count
    doc.close()
    return pages, n


def main():
    tmp = os.path.join(HERE, "pass.pdf")
    path, heads = assemble({})
    heads = [h for h in heads if h[1] != "toc"]
    render(path, tmp)
    pages1, n1 = heading_pages(tmp, heads)
    path, _ = assemble(pages1)
    render(path, tmp)
    pages2, n2 = heading_pages(tmp, heads)
    if pages1 != pages2:
        moved = [h for h in pages1 if pages1[h] != pages2[h]]
        print("page numbers moved after filling the table of contents; rebuilding:", moved[:5])
        path, _ = assemble(pages2)
        render(path, tmp)
        pages3, n2 = heading_pages(tmp, heads)
        if pages3 != pages2:
            raise SystemExit("page numbers did not settle")
        pages2 = pages3
    doc = fitz.open(tmp)
    toc = []
    for lvl, hid, label, text in heads:
        toc.append([lvl, (label + "  " if label else "") + text, pages2[hid]])
    doc.set_toc(toc)
    doc.set_metadata({"title": TITLE, "subject": "Design, verification, security and implementation study of a parameterizable mesh NoC router",
                      "keywords": "NoC, router, SystemVerilog, virtual channels, deadlock, formal verification, sky130", "author": "", "creator": "build.py"})
    doc.save(OUT, garbage=3, deflate=True)
    print(f"wrote {os.path.relpath(OUT, DOCS)}: {doc.page_count} pages, {len(heads)} headings")
    doc.close()
    os.remove(tmp)


if __name__ == "__main__":
    main()
