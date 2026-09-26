# -*- coding: utf-8 -*-
"""Grafana Dex SSO: the config facts that can be checked without a browser.

Driving an actual login is a manual step and stays one. What IS checkable
offline is that the planned Grafana OIDC config agrees with the Dex issuer
this system has already PROVEN works - the one the portal authenticates
against every day.

That agreement is the whole ballgame. Problem #77: Dex's issuer is the
INTERNAL name, changing it was considered and rejected because k3s's API
server flags expect that exact string, and a client pointed at any other
hostname fails at login with `oidc: issuer did not match the issuer
returned by provider`. Object creation does not catch it; only a real
login does.

This suite exists because the first draft of grafana-dex-sso.md got that
wrong.
"""
import io
import os
import re
import sys

import _paths
HERE = _paths.PORTAL
sys.path.insert(0, HERE)
os.environ.setdefault("PORTAL_ROLE", "all")
os.environ.setdefault("ASSET_DIR", "assets")
import app  # noqa: E402

fails = []


def t(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}" + (f"   <- {detail}" if not ok else ""))
    if not ok:
        fails.append(name)


PLAN = os.path.join(_paths.DOCS, "grafana-dex-sso.md")
if not os.path.exists(PLAN):
    print("FAIL: grafana-dex-sso.md is missing. Refusing to report success.")
    sys.exit(2)
plan = io.open(PLAN, encoding="utf-8").read()
print(f"subject: grafana-dex-sso.md ({len(plan.splitlines())} lines)")

print()
print("== the OIDC endpoints agree with the issuer the portal already uses ==")
# app.py's DEX_ISSUER is not a guess: the portal authenticates real users
# against it, so it is the one value in this repo known to be correct.
issuer = app.DEX_ISSUER
t("app.py has an issuer to compare against", bool(issuer), issuer)
print(f"      DEX_ISSUER = {issuer}")

for kind in ("auth_url", "token_url", "api_url"):
    m = re.search(rf"^\s*{kind}\s*[:=]\s*(\S+)", plan, re.M)
    t(f"{kind} is present in the plan", bool(m))
    if not m:
        continue
    url = m.group(1)
    t(f"{kind} is built on DEX_ISSUER", url.startswith(issuer), url)
    # The specific wrong value that was in the first draft.
    t(f"{kind} does NOT use the external Dex name",
      "dex.cloudlab.internal" not in url, url)

print()
print("== Grafana's own URL matches how Traefik actually serves it ==")
# Grafana is behind a Traefik Ingress on plain HTTP (Problem #85). An
# https root_url would make Grafana build an https redirect_uri, which
# would not match the redirectURI registered in Dex, and the login would
# fail after a successful authentication - the most confusing failure
# shape available.
gurl = app.GRAFANA_URL
print(f"      GRAFANA_URL = {gurl}")
m = re.search(r"^\s*root_url\s*[:=]\s*(\S+)", plan, re.M)
t("root_url is present", bool(m))
if m:
    t("root_url matches the portal's GRAFANA_URL", m.group(1).rstrip("/") == gurl.rstrip("/"),
      f"{m.group(1)} vs {gurl}")

cb = re.findall(r"^\s*-\s*(https?://\S*/login/generic_oauth)\s*$", plan, re.M)
t("a redirectURI is registered", bool(cb), cb)
if cb and m:
    t("the redirectURI is built on the same root_url",
      all(c.startswith(m.group(1).rstrip("/")) for c in cb), cb)

print()
print("== break-glass is kept ==")
t("basic auth stays enabled",
  re.search(r"auth\.basic[\s\S]{0,160}enabled\s*[:=]\s*true", plan) is not None)
t("the plan says not to remove the admin login",
  "BREAK GLASS" in plan or "break-glass" in plan.lower())
t("no disable_login_form = true", "disable_login_form = true" not in plan)

print()
print("== TLS is verified, as everywhere else in this project ==")
t("a CA is pointed at", "tls_client_ca" in plan)
t("no tls_skip_verify_insecure = true",
  not re.search(r"tls_skip_verify_insecure\s*=\s*true", plan))

print()
print("== the index hazard is still called out ==")
# Dex staticClients are addressed positionally by deploy-dex.sh. A new
# client must be APPENDED or the next deploy writes one client's secret
# over another's.
t("the plan says to append, not insert", "Appending `grafana` as `[3]`" in plan
  or "appended after" in plan)
t("it names what breaks", "nomad" in plan.lower())

print()
print("== the limitation is stated, and the UI does not contradict it ==")
t("the plan says login-only", "login-only" in plan.lower()
  or "does not scope" in plan.lower() or "Does not" in plan)
t("Part 23 is referenced", "Part 23" in plan)

# The rail link must say Monitoring and nothing that implies scoping.
page = app.render_welcome("amine.beji", projects=[])
t("the rail link is present", app.GRAFANA_URL in page)
t('it is labelled exactly "Monitoring"', 'aria-label="Monitoring"' in page)
CLAIMS = ["vos métriques", "your metrics", "votre consommation",
          "your project's metrics", "métriques de votre", "isolées",
          "your usage", "votre quota"]
hits = [c for c in CLAIMS if c.lower() in page.lower()]
t("no copy implies per-user data scoping", not hits, hits)

print()
print("GRAFANA SSO CONFIG OK" if not fails else f"{len(fails)} CHECK(S) FAILED")
sys.exit(1 if fails else 0)
