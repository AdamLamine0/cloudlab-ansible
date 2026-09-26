# -*- coding: utf-8 -*-
"""Shell-script checks that `bash -n` cannot make.

The one that matters: a `python3 -c '...'` (or `node -e '...'`) whose code
contains a SINGLE QUOTE. Bash silently ends the string there and
concatenates the adjacent segments, so the interpreter receives mangled
source and dies at RUNTIME. `bash -n` accepts it, because adjacent quoted
segments are legal shell.

Shipped after exactly that bug reached a deploy script: a rule-printing
one-liner containing `','.join(r['resources'])` arrived at python as
`{,.join(r[resources])}`.
"""
import glob
import os
import re
import subprocess
import sys
import tempfile

from _paths import SCRIPT_DIRS
fails = []


def t(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}" + (f"   <- {detail}" if not ok else ""))
    if not ok:
        fails.append(name)


scripts = sorted(p for d in SCRIPT_DIRS
                 for p in glob.glob(os.path.join(d, "**", "*.sh"),
                                    recursive=True))
print(f"subjects: {len(scripts)} shell script(s)")
for s in scripts:
    print(f"   {os.path.basename(s)}")
if not scripts:
    print("FAIL: no shell scripts found. Refusing to report success.")
    sys.exit(2)

print()
print("== bash accepts them ==")
for s in scripts:
    r = subprocess.run(["bash", "-n", s], capture_output=True, text=True)
    t(f"{os.path.basename(s):34} parses", r.returncode == 0,
      r.stderr.strip()[:120])

print()
print("== no single-quoted -c/-e block contains a single quote ==")
# Bash single-quoted strings cannot contain an escaped quote, so the first
# "'" after the opener IS the terminator. If the interpreter source we
# extract that way fails to parse, either it is genuinely broken or it was
# cut short by an inner quote. Both are bugs.
PAT = re.compile(r"(python3?|node)\s+-(c|e)\s+'([^']*)'")
def strip_comments(src):
    """Blank out comment lines, keeping line numbers intact.

    Commentary legitimately quotes the broken form while explaining it,
    and a checker that flags its own explanation is noise.
    """
    out = []
    for ln in src.splitlines():
        out.append("" if ln.lstrip().startswith("#") else ln)
    return chr(10).join(out)


for s in scripts:
    src = strip_comments(open(s, encoding="utf-8").read())
    bad = []
    for m in PAT.finditer(src):
        lang, code = m.group(1), m.group(3)
        # Where does this fragment end in the file, and what follows it?
        after = src[m.end():m.end() + 1]
        # A fragment immediately followed by a non-space character means
        # the quote closed mid-expression and the shell is concatenating.
        if after and not after.isspace() and after not in ")|;&":
            bad.append(f"line {src[:m.start()].count(chr(10)) + 1}: quote closes mid-code")
            continue
        if lang.startswith("python"):
            try:
                compile(code, "<-c>", "exec")
            except SyntaxError as e:
                bad.append(f"line {src[:m.start()].count(chr(10)) + 1}: {e.msg}")
        else:
            with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False,
                                             encoding="utf-8") as fh:
                fh.write(code)
                tmp = fh.name
            r = subprocess.run(["node", "--check", tmp], capture_output=True, text=True)
            os.unlink(tmp)
            if r.returncode:
                bad.append(f"line {src[:m.start()].count(chr(10)) + 1}: js syntax")
    t(f"{os.path.basename(s):34} inline code intact", not bad, "; ".join(bad))

print()
print("== heredoc'd interpreter blocks parse ==")
for s in scripts:
    src = open(s, encoding="utf-8").read()
    bad = []
    for tag, lang in (("PY", "python"), ("JS", "node")):
        for block in re.findall(r"<<'" + tag + r"'\n(.*?)\n" + tag + r"\n", src, re.S):
            if lang == "python":
                try:
                    compile(block, "<heredoc>", "exec")
                except SyntaxError as e:
                    bad.append(f"{tag}: {e.msg}")
            else:
                with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False,
                                                 encoding="utf-8") as fh:
                    fh.write(block)
                    tmp = fh.name
                r = subprocess.run(["node", "--check", tmp], capture_output=True, text=True)
                os.unlink(tmp)
                if r.returncode:
                    bad.append(f"{tag}: {r.stderr.splitlines()[0][:70]}")
    t(f"{os.path.basename(s):34} heredocs parse", not bad, "; ".join(bad))

print()
print("== no unresolved placeholders ==")
PLACEHOLDER = re.compile(r"<[a-z][a-z0-9_-]*>|YOUR_|CHANGEME|TODO|FIXME")
for s in scripts:
    bad = []
    for i, line in enumerate(open(s, encoding="utf-8"), 1):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue                       # commentary may show a template
        # A usage message legitimately prints <argument> names. Skipping
        # just that line is narrower than weakening the pattern: an
        # unsubstituted template marker anywhere else still fails.
        if re.search(r"usage:", line, re.I):
            continue
        if PLACEHOLDER.search(line):
            bad.append(f"line {i}: {line.strip()[:60]}")
    t(f"{os.path.basename(s):34} no placeholders", not bad, "; ".join(bad[:2]))

print()
print("== no backticks inside double-quoted SHELL strings ==")
# A backtick inside "..." is command substitution. `note "Compare `x` ..."`
# silently runs x as a program, prints "command not found" to stderr and
# leaves a hole in the message. bash -n accepts it. Shipped once in
# build-timing-probe.sh.
#
# Heredoc bodies are skipped: a backtick inside an embedded Python or JS
# string is just a character.
def outside_heredocs(src):
    out, skip, tag = [], False, None
    for ln in src.split(chr(10)):
        if not skip:
            m = re.search(r"<<'([A-Z]+)'", ln)
            if m:
                skip, tag = True, m.group(1)
                out.append("")
                continue
            out.append(ln)
        else:
            if ln.strip() == tag:
                skip = False
            out.append("")
    return out

for s_path in scripts:
    name = os.path.basename(s_path)
    bad = []
    for i, ln in enumerate(outside_heredocs(open(s_path, encoding="utf-8").read()), 1):
        if ln.lstrip().startswith("#"):
            continue
        for m in re.finditer(r'"([^"]*)"', ln):
            if "`" in m.group(1):
                bad.append("line " + str(i))
    t(f"{name:34} no backticks in \"...\"", not bad, "; ".join(bad[:3]))

print()
print("== every accepted flag is documented in --help, and vice versa ==")
# --help used to print a HARDCODED line range, so any flag added below the
# cut worked but was invisible. That is how --dump-dex-config came to be
# "new" according to me and absent according to --help.
import subprocess
for s_path in scripts:
    name = os.path.basename(s_path)
    src = open(s_path, encoding="utf-8").read()
    # flags the case statement actually accepts
    accepted = set()
    for m in re.finditer(r"^\s*(--[a-z-]+(?:\|--[a-z-]+)*)\)", src, re.M):
        accepted.update(x for x in m.group(1).split("|") if x.startswith("--"))
    accepted -= {"--help", "--yes"}
    if not accepted:
        continue
    out = subprocess.run(["bash", s_path, "--help"], capture_output=True,
                         text=True, cwd=os.path.dirname(s_path) or ".").stdout
    undocumented = sorted(f for f in accepted if f not in out)
    t(f"{name:34} all flags in --help", not undocumented, undocumented)

print()
print("== a documented two-word form must actually parse ==")
# --help said `--diagnose NS` while the parser was a `for arg in "$@"` loop
# whose catch-all rejected every non-flag token. The documented form could
# not be typed at all. A parser that takes a positional must distinguish an
# unknown DASHED token (a typo, error) from a bare word (the argument), so
# the presence of a `-*)` branch is the marker.
for s_path in scripts:
    name = os.path.basename(s_path)
    src = open(s_path, encoding="utf-8").read()
    out = subprocess.run(["bash", s_path, "--help"], capture_output=True,
                         text=True, cwd=os.path.dirname(s_path) or ".").stdout
    # Only USAGE lines - ones that show an actual invocation. Prose in the
    # header contains capitalised words after flags ("WHY THE SPLIT") and
    # matching those flagged two scripts that were perfectly fine.
    placeholders = []
    for line in out.splitlines():
        m = re.match(r"\s*\./\S+\.sh\s+--[a-z][a-z-]*\s+([A-Z][A-Z_]{1,})", line)
        if m:
            placeholders.append(m.group(1))
    if not placeholders:
        continue
    loop_parser = re.search(r"for\s+\w+\s+in\s+\"?\$@\"?", src)
    if not loop_parser:
        continue          # positional-style parser, nothing to check
    has_dash_branch = re.search(r"^\s*-\*\)", src, re.M) is not None
    t(f"{name:34} documented ARG is parseable", has_dash_branch,
      "documents " + ",".join(sorted(set(placeholders))) +
      " but the arg loop rejects every non-flag token")

print()
print("SHELL CHECKS OK" if not fails else f"{len(fails)} CHECK(S) FAILED")
sys.exit(1 if fails else 0)
