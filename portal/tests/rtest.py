# -*- coding: utf-8 -*-
"""Responsive matrix for the portal's rendered pages.

Measures each page at 14 widths and asserts the floors that CLAUDE.md
calls non-negotiable: no horizontal overflow, no text under 13px, no tap
target under 44px, and 16px on every input (below it iOS Safari zooms on
focus).

Two things this harness does deliberately:

* It measures inside an IFRAME, never with Chrome's --window-size.
  --window-size does not give the page the viewport you asked for once
  the browser chrome and a minimum window width are involved, which is
  how Problem #111 shipped a layout that measured fine and was broken.
* It EXITS 2 on an empty match and prints the subject count. Problem
  #124 was this harness reporting success over zero pages; #153 was it
  reporting success over ten when eight were intended. A pass with no
  visible count is not evidence.

Usage:  python tests/rtest.py <dir-with-html> [glob]
"""
import glob as globmod
import json
import os
import subprocess
import sys
import tempfile

CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
WIDTHS = [320, 360, 390, 414, 480, 600, 768, 820, 900, 1024, 1280, 1440,
          1680, 1920]

HARNESS = """<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;padding:0}iframe{border:0;display:block}</style>
<body><iframe id="f"></iframe><script>
const WIDTHS = __WIDTHS__, PAGES = __PAGES__;
function probe(doc, win) {
  const out = {overflow:0, small:[], tap:[], input:[]};
  const de = doc.documentElement;
  out.overflow = Math.max(0, de.scrollWidth - de.clientWidth);
  for (const el of doc.querySelectorAll('*')) {
    const cs = win.getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') continue;
    const r = el.getBoundingClientRect();
    if (!r.width && !r.height) continue;
    const fs = parseFloat(cs.fontSize);
    const txt = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
    if (txt && fs && fs < 13) out.small.push(el.tagName.toLowerCase()+'@'+fs.toFixed(1));
    const tag = el.tagName.toLowerCase();
    if (tag === 'a' || tag === 'button' || el.classList.contains('btn')
        || el.classList.contains('opt')) {
      // min-height does not apply to inline elements (Problem #125), so
      // the RENDERED height is what gets asserted, never the CSS rule.
      if (r.height < 44) out.tap.push(tag+'.'+(el.className||'')+'@'+r.height.toFixed(1));
    }
    if (tag === 'input' || tag === 'textarea') {
      if (fs < 16) out.input.push(tag+'@'+fs.toFixed(1));
    }
  }
  return out;
}
(async () => {
  const f = document.getElementById('f'), res = [];
  for (const p of PAGES) {
    for (const w of WIDTHS) {
      f.style.width = w + 'px';
      f.style.height = '900px';
      await new Promise(r => { f.onload = r; f.src = p.url + '?w=' + w; });
      // setTimeout is fast-forwarded by --virtual-time-budget;
      // requestAnimationFrame is not pumped in headless and stalls the loop.
      await new Promise(r => setTimeout(r, 30));
      const d = f.contentDocument, win = f.contentWindow;
      res.push(Object.assign({page:p.name, width:w}, probe(d, win)));
    }
  }
  document.title = 'DONE';
  const pre = document.createElement('pre');
  pre.id = 'out'; pre.textContent = JSON.stringify(res);
  document.body.appendChild(pre);
})();
</script>"""


def main():
    if len(sys.argv) < 2:
        print("usage: rtest.py <dir> [glob]"); return 2
    d = os.path.abspath(sys.argv[1])
    pat = sys.argv[2] if len(sys.argv) > 2 else "*.html"
    files = sorted(f for f in globmod.glob(os.path.join(d, pat))
                   if os.path.basename(f) != "_harness.html")
    # Problem #124 / #153: a harness that does not state its subject count
    # can pass over nothing, or over the wrong thing, and look identical.
    print(f"subjects: {len(files)} page(s) x {len(WIDTHS)} widths "
          f"= {len(files) * len(WIDTHS)} checks")
    for f in files:
        print(f"   {os.path.basename(f)}")
    if not files:
        print("FAIL: the glob matched no pages. Refusing to report success.")
        return 2

    pages = [{"name": os.path.basename(f), "url": os.path.basename(f)}
             for f in files]
    harness = (HARNESS.replace("__WIDTHS__", json.dumps(WIDTHS))
                      .replace("__PAGES__", json.dumps(pages)))
    hp = os.path.join(d, "_harness.html")
    open(hp, "w", encoding="utf-8").write(harness)

    with tempfile.TemporaryDirectory() as prof:
        out = subprocess.run(
            [CHROME, "--headless=new", "--disable-gpu", "--no-sandbox",
             "--allow-file-access-from-files", f"--user-data-dir={prof}",
             "--virtual-time-budget=120000", "--dump-dom", hp],
            capture_output=True, text=True, timeout=300).stdout

    if '<pre id="out">' not in out:
        print("FAIL: harness did not finish; nothing was measured.")
        return 2
    body = out.split('<pre id="out">', 1)[1].split("</pre>", 1)[0]
    body = (body.replace("&quot;", '"').replace("&lt;", "<")
                .replace("&gt;", ">").replace("&amp;", "&"))
    res = json.loads(body)

    bad = 0
    for r in res:
        errs = []
        if r["overflow"] > 0:
            errs.append(f"overflow {r['overflow']}px")
        if r["small"]:
            errs.append(f"text<13px {r['small'][:3]}")
        if r["tap"]:
            errs.append(f"tap<44px {r['tap'][:3]}")
        if r["input"]:
            errs.append(f"input<16px {r['input'][:3]}")
        if errs:
            bad += 1
            print(f"  FAIL {r['page']:24} @{r['width']:>5}px  " + "; ".join(errs))
    total = len(res)
    print()
    if bad:
        print(f"{total - bad}/{total} passed, {bad} FAILED")
        return 1
    print(f"ALL RESPONSIVE CHECKS PASSED: {total}/{total} "
          f"({len(files)} pages x {len(WIDTHS)} widths, "
          f"{WIDTHS[0]}px to {WIDTHS[-1]}px)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
