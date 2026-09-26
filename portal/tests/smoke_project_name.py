# Phase 3: the project-name field on /new-project.
#
# The reserved-word list now exists in THREE places - the provisioning
# workflow, the availability check, and the portal. The portal needs its
# own copy so it can reject a reserved name without a round trip, but
# drift between the copies would let the portal promise a name the
# provisioner then refuses. So all three are compared here.
import importlib.util, io, json, os, re, sys

os.environ.setdefault("SESSION_KEY", "k" * 32)
os.environ.setdefault("DEX_CLIENT_SECRET", "s")
os.environ.setdefault("N8N_WEBHOOK_TOKEN", "dummy")
os.environ.setdefault("PORTAL_ROLE", "all")

import _paths
ROOT = _paths.PORTAL
spec = importlib.util.spec_from_file_location("app", _paths.portal("app.py"))
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)

fails = []
def t(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name +
          ("" if cond else "   <- " + str(detail)))
    if not cond:
        fails.append(name)


def reserved_from(js):
    i = js.index("const RESERVED")
    body = js[i:js.index("];", i)]
    return set(re.findall(r"'([a-z0-9-]+)'", body))


print("== the reserved list is identical in all THREE places ==")
prov = json.load(io.open(_paths.wf("provision.json"), encoding="utf-8"))
chk = json.load(io.open(_paths.wf("name-check.json"), encoding="utf-8"))
prov_list = reserved_from(
    [n for n in prov["nodes"] if n["name"] == "Validate input"][0]["parameters"]["jsCode"])
chk_list = reserved_from(
    [n for n in chk["nodes"] if n["name"] == "Is the name usable at all?"][0]["parameters"]["jsCode"])
t("provisioner == availability check", prov_list == chk_list,
  prov_list ^ chk_list)
t("portal == provisioner", app.RESERVED_NAMES == prov_list,
  app.RESERVED_NAMES ^ prov_list)

print()
print("== shape rules match the workflow's regex ==")
good = ["moncv", "restaurant-schmitt", "abc", "a" * 30, "shop2024"]
bad = ["ab", "a" * 31, "Moncv", "-lead", "trail-", "my--shop",
       "mon_cv", "mon cv", "9lives", ""]
for n in good:
    t(f"accepts {n!r}", app.project_name_problem(n) == "", app.project_name_problem(n))
for n in bad:
    t(f"rejects {n!r}", app.project_name_problem(n) == "shape", app.project_name_problem(n))

print()
print("== reserved names and platform prefixes are refused ==")
for n in ["vault", "dex", "n8n", "signup", "kube-system", "default", "admin"]:
    t(f"reserved {n!r}", app.project_name_problem(n) == "reserved")
for n in ["kube-foo", "tenant-foo", "proj-foo"]:
    t(f"prefix {n!r}", app.project_name_problem(n) == "reserved")

print()
print("== the form asks for the name, and keeps it on a rejection ==")
page = app.render_new_project()
t("form has a project field", 'name="project"' in page)
t("field is required", re.search(r'id="project"[^>]*required', page) is not None)
t("field constrains the shape client-side", 'pattern="[a-z][a-z0-9-]{1,28}[a-z0-9]"' in page)
kept = app.render_new_project("Ce nom est déjà pris.", "err",
                              description="une boutique en ligne",
                              choice="nomad", repo_url="https://github.com/a/b",
                              project="moncv")
t("keeps the name", 'value="moncv"' in kept)
t("keeps the description", "une boutique en ligne" in kept)
t("keeps the repo link", "https://github.com/a/b" in kept)
t("keeps the platform choice", re.search(r'value="nomad"[^>]*checked', kept) is not None)
t("shows the rejection message", "déjà pris" in kept)

print()
print("== the name is forwarded to the provisioner ==")
sent = {}
class Resp:
    status = 200
    def read(self): return json.dumps({"provisioned": True, "choice": "kubernetes",
                                       "steps": {}}).encode()
    def __enter__(self): return self
    def __exit__(self, *a): return False
def fake(req, timeout=None):
    sent.clear(); sent.update(json.loads(req.data.decode())); return Resp()
app.urllib.request.urlopen = fake
app.submit_project("u", "u@x", "une description valable", "", "kubernetes", "moncv")
t("payload carries the project name", sent.get("project") == "moncv",
  f"keys={sorted(sent)} project={sent.get('project')!r}")

print()
print("== an unverifiable name is never treated as free ==")
def boom(req, timeout=None): raise OSError("n8n unreachable")
app.urllib.request.urlopen = boom
t("check_name -> unknown when n8n is down", app.check_name("moncv", "u") == "unknown")

print()
print("=" * 46)
print("PROJECT NAME OK" if not fails else f"{len(fails)} CHECK(S) FAILED")
sys.exit(len(fails))
