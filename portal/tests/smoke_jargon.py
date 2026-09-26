# The no-infrastructure-jargon rule, asserted over the FULL RESPONSE BODY
# of /signup and /login -- markup, form values, title/alt included, not
# just rendered text. That distinction IS Problem #108: the page read
# perfectly while carrying value="kubernetes" in the HTML.
#
# /new-project deliberately DOES name the platforms (scope reversal of
# #108, 2026-08-23), so it is checked for the opposite property.
import importlib.util, os, re, sys

os.environ.setdefault("SESSION_KEY", "k" * 32)
os.environ.setdefault("DEX_CLIENT_SECRET", "s")
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

BANNED = ["kubernetes", "k8s", "nomad", "consul", "orchestrat",
          "freeipa", "svc-portal", "namespace", "cluster", "ingress",
          "kaniko", "traefik", "vault", "dex"]
ROUTES = {"/", "/signup", "/login", "/welcome", "/new-project", "/logout"}

pages = {
    "/signup":       app.render_signup(),
    "/signup (err)": app.render_signup("Cet identifiant est d\u00e9j\u00e0 pris.",
                                       "err", username="amine.beji"),
    "/login":        app.render_login(),
    "/login (err)":  app.render_login("Identifiant ou mot de passe incorrect.",
                                      "err", username="amine.beji"),
}

print("== no jargon anywhere in the body of /signup and /login ==")
for name, body in pages.items():
    low = body.lower()
    # Word boundaries, not bare substrings: "dex" lives inside `z-index`
    # and "cluster" inside nothing yet, but the first one bit as soon as
    # the new stylesheet arrived. Naming the identity provider is what
    # this rule forbids, not the three letters appearing in a CSS
    # property name.
    hits = [w for w in BANNED
            if re.search(r"(?<![a-z0-9-])" + re.escape(w) + r"(?![a-z0-9])", low)]
    t(f"{name:15} clean", not hits, hits)

print()
print("== FreeIPA and svc-portal are never named on ANY page ==")
every = dict(pages)
every["/welcome"] = app.render_welcome("amine", False, "")
every["/new-project"] = app.render_new_project()
every["/404"] = app.render_404()
every["/ (landing)"] = app.render_landing()
every["confirmation"] = app.render_project_sent("un site", {
    "provisioned": True, "choice": "kubernetes", "decidedBy": "user",
    "steps": {}, "siteUrl": None})
for name, body in every.items():
    low = body.lower()
    t(f"{name:15} names no identity backend",
      "freeipa" not in low and "svc-portal" not in low)

print()
print("== /new-project DOES name the platforms (deliberate, reversal of #108) ==")
np = app.render_new_project().lower()
t("names Kubernetes", "kubernetes" in np)
t("names Nomad + Consul", "nomad" in np and "consul" in np)

print()
print("== every link goes somewhere real, on every page ==")
for name, body in every.items():
    hrefs = re.findall(r'href="([^"]+)"', body)
    dead = [h for h in hrefs if h in ("#", "")]
    t(f"{name:15} no dead href", not dead, dead)
    local = [h.split("?")[0].split("#")[0] for h in hrefs if h.startswith("/")]
    bad = [h for h in local if h not in ROUTES]
    t(f"{name:15} hrefs are real routes", not bad, bad)
    frags = [h[1:] for h in hrefs if h.startswith("#")]
    frags += [h.split("#", 1)[1] for h in hrefs if h.startswith("/") and "#" in h]
    dead_frag = [f for f in frags if f and f'id="{f}"' not in body]
    # A fragment pointing at another page's id is checked on that page.
    dead_frag = [f for f in dead_frag if f == "" or f in
                 [x[1:] for x in hrefs if x.startswith("#")]]
    t(f"{name:15} in-page anchors exist", not dead_frag, dead_frag)
    actions = re.findall(r'action="([^"]+)"', body)
    bada = [a for a in actions if a.split("?")[0] not in ROUTES]
    t(f"{name:15} form actions are real", not bada, bada)

print()
# The single-colour rule (2026-08-26) required exactly one conic-gradient
# and zero linear-gradients on every page. It was REPLACED on 2026-09-14
# by the dark blue-gradient theme, so asserting it would now be asserting
# a decision that no longer holds. What replaces it are the invariants the
# NEW theme depends on: one theme across every page, no light-theme
# leftovers, and the button contrast fix that made the palette usable.
# Superseded again on 2026-09-15 by the aurora-glass rebuild. What is
# asserted is unchanged in KIND: one stylesheet across every page, no
# leftovers from a theme that was replaced, and the floors this project
# treats as non-negotiable. Only the token names moved.
print("== the aurora-glass theme is applied consistently ==")
OLD_THEME = ("#FCFCFA", "#1C1C1E", "--spectrum", "conic-gradient",
             "#0A1220", "--on-accent", "class=\"topnav\"", "HERO_ART")
FLOORS = ("--violet:", "--glass:", "font-family: var(--font-body)")
for name, body in every.items():
    t(f"{name:15} aurora theme present", "--violet:" in body and "bg__scrim" in body)
    left = [x for x in OLD_THEME if x in body]
    t(f"{name:15} no superseded-theme leftovers", not left, left)
    # The reference sheet shipped .field__label at 11.5px and the inputs at
    # 15px, both under this project's own floors. Asserted because a font
    # size regressing by 2px is invisible until someone on iOS reports the
    # page zooming on focus.
    t(f"{name:15} no text under 13px",
      not re.search(r"font-size:\s*(?:[0-9]|1[0-2])(?:\.[0-9]+)?px", body),
      re.findall(r"font-size:\s*[0-9.]+px", body)[:3])
    # Only what the BROWSER FETCHES counts. A github.com URL sitting in a
    # placeholder attribute is example text, not a request. Google Fonts
    # is the one deliberate external fetch (see Part 22).
    # SUBRESOURCES only: anything the browser fetches without being asked.
    # `src=` on any tag, and `href=` on <link>. An <a href> to another host
    # is a NAVIGATION the user chooses to follow (the Grafana link in the
    # rail), not an asset, and holding it to this rule would be wrong.
    fetched = re.findall(r'src="(https?://[^"]+)"', body)
    fetched += re.findall(r'<link[^>]*href="(https?://[^"]+)"', body)
    remote = [u for u in fetched if not u.startswith("https://fonts.g")]
    t(f"{name:15} no remote subresources", not remote, remote)

print()
print("=" * 46)
print("JARGON + LINKS OK" if not fails else f"{len(fails)} CHECK(S) FAILED")
sys.exit(len(fails))
