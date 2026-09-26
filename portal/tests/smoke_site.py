# Smoke test for the tenant URL feature. Asserts against the FULL
# response body, not rendered text — the lesson of Problem #108.
import importlib.util, io, os, sys, time, re, html

os.environ.setdefault("SESSION_KEY", "k" * 32)
os.environ.setdefault("DEX_CLIENT_SECRET", "s")
os.environ.setdefault("PORTAL_ROLE", "all")

spec = importlib.util.spec_from_file_location(
    "app", r"C:\Users\adamo\cloudlab\app.py")
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)

fails = []
def t(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (
        "" if cond else "   <- " + str(detail)))
    if not cond:
        fails.append(name)

U = "nb200058"
URL = f"http://tenant-{U}.apps.cloudlab.internal/"

print("== signed site cookie ==")
val, exp = app.make_site(U, URL)
t("round-trips for its owner", app.read_site(val, U) == URL, app.read_site(val, U))
t("inert for another user", app.read_site(val, "someoneelse") is None)
t("inert with no username", app.read_site(val, "") is None)
t("rejects a tampered signature",
  app.read_site(val[:-1] + ("0" if val[-1] != "0" else "1"), U) is None)
t("rejects a tampered payload",
  app.read_site("A" + val[1:], U) is None)
t("rejects an empty cookie", app.read_site("", U) is None)
t("rejects a session cookie presented as a site cookie",
  app.read_site(app.make_session(U, time.time() + 600)[0], U) is None)
t("expires", app.SITE_MAX_SECONDS > 0 and exp > int(time.time()))

# A forged URL cannot be smuggled into the href: the signature is checked
# first, and the shape is checked after.
bad, _ = app.make_site(U, "javascript:alert(1)")
t("refuses a non-http URL even when correctly signed",
  app.read_site(bad, U) is None)
bad2, _ = app.make_site(U, "http://evil.example.com/x'\"><script>")
t("refuses a URL outside the shape this feature mints",
  app.read_site(bad2, U) is None)

print()
print("== /welcome ==")
# Phase 4: /welcome takes a LIST of the user's own projects, not one URL.
w_no = app.render_welcome(U, False, [])
one = [{"project": "moncv", "url": URL}]
two = one + [{"project": "monblog", "url": "http://tenant-monblog.apps.cloudlab.internal/"}]
w_yes = app.render_welcome(U, False, one)
w_two = app.render_welcome(U, False, two)
t("no projects -> invites a first project", "premier projet" in w_no)
t("no projects -> shows NO link", URL not in w_no)
# The aurora-glass rebuild (2026-09-15) moved these onto the reference's
# .project card markup. The BEHAVIOUR asserted is unchanged: a real
# anchor per project, the empty-state copy gone, and an accurate count.
t("one project -> renders a real anchor", f'<a class="project__url" href="{URL}">' in w_yes)
t("one project -> drops the 'aucun projet' copy", "Aucun projet" not in w_yes)
t("one project -> singular wording", "1 projet dans votre espace" in w_yes)
t("two projects -> both links present", URL in w_two and "monblog" in w_two)
t("two projects -> counts them", "2 projets dans votre espace" in w_two)
# The list arrives over the network: a malformed entry must be skipped,
# never rendered and never able to raise on a user's own page.
t("survives a malformed entry",
  "premier projet" not in app.render_welcome(U, False, ["not-a-dict"] + one))
t("skips an entry with no usable url",
  "javascript:" not in app.render_welcome(
      U, False, [{"project": "x", "url": "javascript:alert(1)"}]))

print()
print("== /new-project confirmation ==")
base = {"provisioned": True, "choice": "kubernetes", "steps": {}}

r_ready = dict(base, siteUrl=URL, siteReady=True, sitePortSource="EXPOSE")
p = app.render_project_sent("un site vitrine", r_ready)
t("ready    -> anchor present", f'<a class="sitelink" href="{URL}">' in p)
t("ready    -> no 'still building' caveat", "quelques minutes" not in p)
t("ready    -> no port caveat", "EXPOSE</code>" not in p)

r_building = dict(base, siteUrl=URL, siteReady=False, sitePortSource="EXPOSE")
p = app.render_project_sent("un site vitrine", r_building)
t("building -> anchor present", f'<a class="sitelink" href="{URL}">' in p)
t("building -> says the link is not live yet", "quelques minutes" in p)

r_guess = dict(base, siteUrl=URL, siteReady=True, sitePortSource="default")
p = app.render_project_sent("un site vitrine", r_guess)
t("guessed port -> warns the port was not found", "EXPOSE</code>" in p)

r_nomad = dict(base, choice="nomad", siteUrl=None)
p = app.render_project_sent("un petit outil", r_nomad)
t("nomad    -> no link", "apps.cloudlab.internal" not in p)
t("nomad    -> says so honestly", "aucune adresse" in p
  or "pas encore d&#x27;adresse" in p or "n&#x27;a pas encore" in p)

r_rej = dict(base, siteUrl=URL, siteReady=True, sitePortSource="known",
             buildRejected=True)
p = app.render_project_sent("un site", r_rej)
t("rejected build -> still gives a working link", f'<a class="sitelink" href="{URL}">' in p)
t("rejected build -> says the image was not built",
  "provisoire" in p and "relancez" in p)

r_none = dict(base, siteUrl=None, choice="kubernetes")
p = app.render_project_sent("un site", r_none)
t("no ingress -> no link at all", "apps.cloudlab.internal" not in p)

print()
print("== full-body assertions (Problem #108 discipline) ==")
pages = {"/welcome+site": w_yes, "/welcome": w_no,
         "confirmation": app.render_project_sent(
             "<script>alert(1)</script>", r_building)}
for name, body in pages.items():
    hrefs = re.findall(r'href="([^"]+)"', body)
    dead = [h for h in hrefs if h.startswith("#") or h == ""]
    t(f"{name}: no dead hrefs", not dead, dead)
    local = [h for h in hrefs if h.startswith("/")]
    known = {"/", "/signup", "/login", "/welcome", "/new-project", "/logout"}
    # A fragment is not a different route: /welcome#mes-sites IS /welcome.
    unknown = [h for h in local if h.split("?")[0].split("#")[0] not in known]
    t(f"{name}: every local href is a real route", not unknown, unknown)
t("confirmation escapes injected markup",
  "<script>alert(1)</script>" not in pages["confirmation"])
t("confirmation still shows the escaped text",
  "&lt;script&gt;" in pages["confirmation"])

# The single-colour rule, still enforced live.
for name, body in pages.items():
    # Superseded 2026-09-14: the single-colour rule was replaced by the
    # dark blue-gradient theme. The invariant that matters now is that
    # every page is on that ONE theme, with no light-theme remnants.
    t(f"{name}: on the aurora theme", "--violet:" in body and "bg__scrim" in body)
    t(f"{name}: no superseded-theme leftovers",
      not any(x in body for x in ("#FCFCFA", "--spectrum", "conic-gradient",
                                  "#0A1220", "--on-accent")))

print()
# ---------------------------------------------------------------------
# A BRAND-NEW NOMAD TENANT IS BLOCKED ON AN OPERATOR (2026-09-06).
# n8n cannot create a Nomad namespace, so for a first-time Nomad user
# nothing is placed at all. The page used to say "votre application
# tourne bien" here - asserting the app was running when it did not
# exist - and to headline "votre espace est pret". Both are now gated.
print()
print("== a first-time Nomad tenant, blocked on an operator ==")
r_blocked = dict(base, choice="nomad", siteUrl=None, provisioned=True,
                 nomadNamespaceMissing=True)
p = app.render_project_sent("un petit outil", r_blocked)
t("blocked  -> never claims the app is running",
  "tourne bien" not in p and "application tourne" not in p)
t("blocked  -> never claims the space is ready",
  "espace est pr&ecirc;t" not in p)
t("blocked  -> says a human step is needed",
  "notre &eacute;quipe" in p)
t("blocked  -> offers a concrete next step", "relancez" in p.lower())
t("blocked  -> still shows no link", "apps.cloudlab.internal" not in p)
# The identity backend is never named, even in an operator-facing state.
t("blocked  -> never names the identity backend",
  "freeipa" not in p.lower() and "svc-portal" not in p.lower())

print()
print("== every console route has an Ingress rule ==")
# The Ingress routes by PATH, and its `/` catch-all goes to the SIGNUP
# pod. A console route with no rule of its own therefore lands on a pod
# that does not serve it and answers 404 - which is exactly what
# /delete-project did when it was first added. The route existing in
# app.py proves nothing about whether traffic can reach it.
import yaml
import _paths
_here = _paths.PORTAL
_docs = [d for d in yaml.safe_load_all(
    io.open(os.path.join(_here, "signup-portal.yaml"), encoding="utf-8")) if d]
_ing = [d for d in _docs if d.get("kind") == "Ingress"][0]
_paths = {p["path"]: p["backend"]["service"]["name"]
          for p in _ing["spec"]["rules"][0]["http"]["paths"]}
for _r in sorted(app.CONSOLE_ROUTES):
    t(f"{_r} routes to the console pod", _paths.get(_r) == "console",
      _paths.get(_r, "NO INGRESS RULE"))
t("/ still falls through to the signup pod", _paths.get("/") == "signup-portal")

print("=" * 44)
print("SITE FEATURE OK" if not fails else f"{len(fails)} CHECK(S) FAILED")
sys.exit(len(fails))
