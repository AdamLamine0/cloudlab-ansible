# REGRESSION GUARD for the 2026-09-05 bug: the user's explicit platform
# choice was parsed from the form, used only to re-tick the radio on a
# validation error, and then DROPPED. Every submission went to Groq.
#
# The assertion that matters: whatever the user picks must appear in the
# payload the portal sends to n8n. Reading the source is not enough --
# this drives the shipped code and intercepts the real request.
import importlib.util, json, os, sys, urllib.parse

os.environ.setdefault("SESSION_KEY", "k" * 32)
os.environ.setdefault("DEX_CLIENT_SECRET", "s")
os.environ.setdefault("N8N_WEBHOOK_TOKEN", "dummy")
os.environ.setdefault("PORTAL_ROLE", "all")

spec = importlib.util.spec_from_file_location(
    "app", r"C:\Users\adamo\cloudlab\app.py")
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)

fails = []
def t(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name +
          ("" if cond else "   <- " + str(detail)))
    if not cond:
        fails.append(name)

sent = {}
class Resp:
    status = 200
    def __init__(self, body): self._b = body
    def read(self): return json.dumps(self._b).encode()
    def __enter__(self): return self
    def __exit__(self, *a): return False

reply = {"provisioned": True, "choice": "nomad", "steps": {}}
def fake_urlopen(req, timeout=None):
    sent.clear()
    sent.update(json.loads(req.data.decode()))
    return Resp(reply)
app.urllib.request.urlopen = fake_urlopen

print("== the choice reaches n8n, for EVERY option ==")
for kind in ("kubernetes", "nomad", "both"):
    app.submit_project("u", "u@cloudlab.internal", "une description valable",
                       "", kind)
    t(f"{kind:11} -> forwarded as kind={kind!r}", sent.get("kind") == kind,
      f"payload keys={sorted(sent)} kind={sent.get('kind')!r}")

print()
print("== the form offers exactly the values the backend accepts ==")
page = app.render_new_project()
import re
import _paths
offered = {v for _, v in re.findall(
    r'<input type="radio" name="(\w+)" value="([^"]+)"', page)}
t("form values == PROJECT_LABELS keys",
  offered == set(app.PROJECT_LABELS), f"form={offered} labels={set(app.PROJECT_LABELS)}")

print()
print("== the confirmation states WHO decided ==")
base = {"provisioned": True, "steps": {}, "siteUrl": None}
cases = [
    ("user",       "kubernetes", "Votre choix"),
    ("classifier", "nomad",      "Ce que nous avons choisi pour vous"),
    ("default",    "kubernetes", "Choix par d&eacute;faut"),
]
for decided, choice, expect in cases:
    p = app.render_project_sent("une description", dict(
        base, choice=choice, decidedBy=decided))
    t(f"decidedBy={decided:11} -> {expect!r}", expect in p)
    # A user's own pick must never be described as ours.
    if decided == "user":
        t("user's pick is NOT called a suggestion",
          "choisi pour vous" not in p)

print()
print("== an unsure classifier is admitted, but never faked onto the user ==")
p = app.render_project_sent("d", dict(base, choice="kubernetes",
                                      decidedBy="classifier", classifierUnsure=True))
t("classifier unsure -> explains the fallback", "les deux plateformes" in p
  or "deux plateformes" in p)
p = app.render_project_sent("d", dict(base, choice="kubernetes",
                                      decidedBy="user", classifierUnsure=True))
t("never shown when the user chose", "deux plateformes" not in p)

print()
print("== server-side validation: the radio is required, not trusted ==")
t("PROJECT_LABELS is the whitelist",
  set(app.PROJECT_LABELS) == {"kubernetes", "nomad", "both"}, set(app.PROJECT_LABELS))
src = open(_paths.portal("app.py"), encoding="utf-8").read()
t("handler rejects a kind outside the whitelist",
  "if choice not in PROJECT_LABELS:" in src)
# Signature grew a `project` parameter in Phase 3; the point of this
# assertion is that `kind` is still an explicit parameter, not that the
# signature never changes.
t("submit_project takes the choice as a parameter",
  "def submit_project(username, email, description, repo_url, kind," in src)

print()
print("=" * 46)
print("CHOICE PASS-THROUGH OK" if not fails else f"{len(fails)} CHECK(S) FAILED")
sys.exit(len(fails))
