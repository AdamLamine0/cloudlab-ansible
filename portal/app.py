#!/usr/bin/env python3
"""
signup-portal — self-service signup + console mockup for CloudLab.

REAL:   /signup POST creates a REAL FreeIPA account via FreeIPA's JSON-RPC
        API, authenticating as the scoped `svc-portal` service account
        (Portal Provisioner role: add-users only, proven unable to delete
        users or create groups). This path is unchanged.

REAL:   /login POST authenticates for REAL against Dex (OAuth2 password
        grant), which binds to the same FreeIPA. A successful login
        issues an HMAC-signed session cookie whose expiry can never
        outlive the Dex ID token behind it.

        /welcome and /new-project are GATED on that session (GET and
        POST alike) and redirect to /login without one. This closed
        Part 23 item 8 on 2026-08-27.

MOCKUP: /new-project's SUBMISSION is still a mockup. It validates and
        echoes back a confirmation, but creates no namespace, calls no
        n8n, touches neither kube nor Nomad, and persists nothing. It is
        now authenticated, but it still does not DO anything.

Stdlib only — no pip install, no image build. Code delivered via ConfigMap,
matching the existing `portal` app pattern (Part 16).

Writes nothing to disk (readOnlyRootFilesystem: true safe).
"""

import base64
import datetime
import hashlib
import hmac
import http.cookies
import http.cookiejar
import http.server
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

IPA_HOST = os.environ.get("IPA_HOST", "freeipa.cloudlab.internal")
IPA_USER = os.environ.get("IPA_USER", "svc-portal")
IPA_PASSWORD = os.environ.get("IPA_PASSWORD", "")
IPA_CA_CERT = os.environ.get("IPA_CA_CERT", "/etc/ipa-ca/freeipa-ca.crt")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))

IPA_BASE = f"https://{IPA_HOST}/ipa"
IPA_LOGIN_URL = f"{IPA_BASE}/session/login_password"
IPA_JSON_URL = f"{IPA_BASE}/session/json"
IPA_API_VERSION = "2.253"

# Deliberately strict: this becomes a real POSIX login name across the
# whole platform (k8s RBAC subject, Nomad ACL binding, home directory).
USERNAME_RE = re.compile(r"^[a-z][a-z0-9._-]{2,31}$")
MIN_PASSWORD_LEN = 8  # FreeIPA's own default policy floor (Problem #3)

# --- Dex / OIDC ------------------------------------------------------------
# /login authenticates for real against Dex, which binds to the same
# FreeIPA that /signup writes to. Dex's issuer is the INTERNAL cluster
# name and must stay that way: k3s's API server flags depend on it
# (Part 12). This pod is inside the cluster, so it resolves that name
# natively and Problem #77's issuer-mismatch trap does not apply.
DEX_ISSUER = os.environ.get(
    "DEX_ISSUER", "https://dex.dex.svc.cluster.local:5554/dex")
DEX_CLIENT_ID = os.environ.get("DEX_CLIENT_ID", "signup-portal")
DEX_CLIENT_SECRET = os.environ.get("DEX_CLIENT_SECRET", "")
DEX_TOKEN_URL = f"{DEX_ISSUER}/token"

# Session cookie, HMAC-signed with SESSION_KEY. This REPLACES the old
# `cl_user` display-name cookie, which was forgeable and gated nothing.
SESSION_COOKIE = "cl_session"
SESSION_KEY = os.environ.get("SESSION_KEY", "").encode()
# Hard ceiling; the real expiry is the Dex ID token's own `exp`, so a
# session can never outlive the identity assertion that created it.
SESSION_MAX_SECONDS = 12 * 3600

# The tenant's deployed site, remembered between requests.
#
# The portal persists nothing and cannot reach the Kubernetes API — its
# NetworkPolicy allows FreeIPA or n8n and nothing else, deliberately. So
# /welcome cannot ASK what a user has deployed. It is told once, by the
# submission that created it, through this cookie.
#
# Signed with the same SESSION_KEY HMAC as the session and BOUND TO THE
# USERNAME, so it cannot be replayed into another account's page or
# forged into arbitrary link text on a page we render.
#
# Honest limitation: this is per-browser. Sign in from another machine
# and /welcome will not show the link, because nothing on the server
# remembers it. Fixing that properly means giving the portal somewhere
# to persist state, which is a larger change than this feature.
SITE_COOKIE = "cl_site"
SITE_MAX_SECONDS = 30 * 24 * 3600
# Derived from SESSION_KEY rather than equal to it: domain separation, so
# a site cookie can never be presented as a session cookie or the reverse
# even though both are HMAC-SHA256 over a pipe-delimited payload.
SITE_KEY = (hmac.new(SESSION_KEY, b"cl_site-v1", hashlib.sha256).digest()
            if SESSION_KEY else b"")

MIN_PROJECT_LEN = 10

# --- app split (Part 23 item 7) --------------------------------------------
# ONE codebase, TWO deployments. The security boundary is the pod: which
# Secrets it mounts and where its NetworkPolicy lets it reach. Splitting
# the SOURCE would have duplicated SHELL and the whole CSS block, which
# is the drift hazard that killed deploy-novault.sh.
#
#   signup  : / and /signup. Holds IPA_PASSWORD. Egress to FreeIPA.
#             No n8n token, no egress to n8n -> CANNOT provision.
#   console : /login /welcome /new-project /logout. Holds the n8n webhook
#             token. Egress to n8n. No IPA_PASSWORD, no FreeIPA egress
#             -> CANNOT create FreeIPA users.
#   all     : both, for local testing only. Never deployed.
PORTAL_ROLE = os.environ.get("PORTAL_ROLE", "all")

SIGNUP_ROUTES = {"/", "/signup"}
CONSOLE_ROUTES = {"/login", "/welcome", "/new-project", "/logout",
                  "/delete-project"}

# The page images. Served by BOTH roles: every screen references them, and
# the Ingress has no /assets rule, so its `/` catch-all sends them to the
# signup pod. Both pods mount the same ConfigMap, so either can answer.
#
# This is an ALLOWLIST, not a directory listing. The name in the URL is
# only ever used to look up a key in this dict; it is never joined onto a
# filesystem path, so there is no traversal to defend against.
# The images ship in the SAME ConfigMap as app.py and land in the same
# mount, so there is no second volume and no extra env var to keep in
# step. kubectl puts them in `binaryData` automatically.
ASSET_DIR = os.environ.get("ASSET_DIR", "/app")
ASSETS = {
    "bg-aurora.png": "image/png",
    "tt-logo.png": "image/png",
    "tt-mark.png": "image/png",
}
ASSET_PREFIX = "/assets/"

# n8n provisioning webhook. Plain HTTP: this is pod-to-pod traffic inside
# the cluster, constrained by NetworkPolicy on both ends.
N8N_WEBHOOK_URL = os.environ.get(
    "N8N_WEBHOOK_URL", "http://n8n.n8n.svc.cluster.local/webhook/new-project")
N8N_WEBHOOK_TOKEN = os.environ.get("N8N_WEBHOOK_TOKEN", "")
# Groq classification plus four Kubernetes calls. Generous, because the
# alternative to waiting is telling the user it failed when it did not.
N8N_TIMEOUT = int(os.environ.get("N8N_TIMEOUT", "60"))

# The availability check lives in its own n8n workflow (Phase 2). Its URL
# is derived from the provisioning one so there is a single place to
# configure n8n, and no new environment variable to keep in step.
N8N_NAME_URL = N8N_WEBHOOK_URL.rsplit("/", 1)[0] + "/name-available"
N8N_PROJECTS_URL = N8N_WEBHOOK_URL.rsplit("/", 1)[0] + "/my-projects"
N8N_DELETE_URL = N8N_WEBHOOK_URL.rsplit("/", 1)[0] + "/delete-project"

# Grafana. A DIRECT BROWSER LINK, opened in a new tab - the portal never
# proxies or embeds it, so no pod egress and no NetworkPolicy rule is
# involved. The portal does not talk to Grafana at all.
#
# SCOPE, stated here because the UI must never imply otherwise: signing in
# through Dex makes the session PER-USER, it does not make the DATA
# per-user. Every signed-in user sees the same cluster-wide dashboards.
# Nothing in this system filters metrics by tenant yet (Part 23).
# HTTP, not HTTPS. No Traefik Ingress in this lab terminates TLS -
# signup, n8n and Grafana are all served plain (Part 20, Problem #85).
# An https:// link here simply fails to connect, and because the rail
# item opens in a new tab the breakage is silent on the page itself.
GRAFANA_URL = os.environ.get("GRAFANA_URL", "http://grafana.cloudlab.internal")

# THE PROJECT NAME becomes a DNS label and then a hostname, so the rules
# are the DNS-1123 ones and not a matter of taste.
PROJECT_NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,28}[a-z0-9]$")

# THIS LIST IS THE THIRD COPY. The provisioning workflow and the
# availability check hold the other two; tests/smoke_project_name.py
# asserts all three are identical. Duplication is accepted here because
# the portal must be able to reject a reserved name WITHOUT a round trip,
# but drift between the copies would let the portal promise a name the
# provisioner then refuses.
RESERVED_NAMES = {
    "default", "kube-system", "kube-public", "kube-node-lease",
    "build", "registry", "monitoring", "signup", "n8n", "dex", "vault",
    "user1", "user2",
    "www", "api", "admin", "apps", "auth", "login", "portal", "mail",
    "ns1", "static", "cdn", "root", "system",
}
RESERVED_PREFIXES = ("kube-", "proj-", "tenant-")


def project_name_problem(name):
    """Return a reason string if the name is unusable, else ''.

    Mirrors the workflow's rules exactly. Shape and reserved words are
    decided here with no network call; whether a usable name is FREE is a
    question only the cluster can answer (check_name below).
    """
    if not PROJECT_NAME_RE.match(name) or "--" in name:
        return "shape"
    if name in RESERVED_NAMES or name.startswith(RESERVED_PREFIXES):
        return "reserved"
    return ""


def list_projects(username):
    """This user's own projects, or [] — never anyone else's.

    THE OWNERSHIP BOUNDARY IS NOT HERE. `username` comes from a session
    the portal already verified (HMAC over username|expiry, the expiry
    capped by the Dex token), and n8n turns it into a Kubernetes label
    selector. Kubernetes does the filtering server-side, so there is no
    per-item ownership decision in this file or in the workflow that
    could be wrong — the same rule that closed Problem #147, reused
    rather than reimplemented.

    Returns [] on any failure. An empty list reads as "no projects yet",
    which is the honest thing to show when we could not find out —
    inventing a project would be worse than showing none.
    """
    if not username or not N8N_WEBHOOK_TOKEN:
        return []
    payload = json.dumps({"username": username}).encode()
    req = urllib.request.Request(
        N8N_PROJECTS_URL, data=payload,
        headers={"Content-Type": "application/json",
                 "Accept": "application/json",
                 "X-Portal-Token": N8N_WEBHOOK_TOKEN},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.loads(resp.read().decode() or "{}")
    except Exception as exc:                       # noqa: BLE001
        print(f"[warn] project list failed: {exc}", file=sys.stderr)
        return []
    if isinstance(body, list):
        body = body[0] if body else {}
    items = body.get("projects")
    return items if isinstance(items, list) else []


def delete_project(username, project):
    """Ask n8n to stop routing `project`, if it really belongs to `username`.

    Returns (status, message) on the same three-state contract as
    submit_project: "ok" | "denied" | "error".

    THE OWNERSHIP DECISION IS NOT HERE, deliberately. The portal forwards
    the session's username and the submitted project name; n8n re-checks
    ownership with the SAME label selector it uses to list projects, and
    the Kubernetes API server does the filtering. Trusting this form's
    input for ownership would reopen Problem #147 - the portal has the
    project name only because a page rendered it, which proves nothing
    about who owns it now.

    SCOPE: a FULL teardown, changed 2026-09-21 at the operator's explicit
    request. Deleting the Kubernetes namespace cascades to the quota, the
    RoleBinding, every workload and every Secret in it; the Nomad job is
    purged and its namespace dropped. There is no undo.

    The portal performs none of that. It forwards an identity and a name.
    n8n re-checks ownership against the cluster, and a
    ValidatingAdmissionPolicy refuses any namespace delete by n8n that is
    not a `tenant-*` namespace labelled `provisioned-by: n8n` - the bound
    RBAC cannot express, because `resourceNames` has no prefix form.
    """
    if not N8N_WEBHOOK_TOKEN:
        print("[error] N8N_WEBHOOK_TOKEN is empty", file=sys.stderr)
        return "error", "Service momentan\u00e9ment indisponible. R\u00e9essayez dans un instant."
    if not username or not project:
        return "error", "Demande incompl\u00e8te."
    payload = json.dumps({"username": username, "project": project}).encode()
    req = urllib.request.Request(
        N8N_DELETE_URL, data=payload,
        headers={"Content-Type": "application/json",
                 "Accept": "application/json",
                 "X-Portal-Token": N8N_WEBHOOK_TOKEN},
    )
    try:
        with urllib.request.urlopen(req, timeout=N8N_TIMEOUT) as resp:
            body = json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        print(f"[error] n8n delete HTTP {exc.code}", file=sys.stderr)
        return "error", "Un probl\u00e8me est survenu de notre c\u00f4t\u00e9. R\u00e9essayez dans un instant."
    except Exception as exc:                       # noqa: BLE001
        print(f"[error] n8n delete failed: {exc}", file=sys.stderr)
        return "error", "Un probl\u00e8me est survenu de notre c\u00f4t\u00e9. R\u00e9essayez dans un instant."
    if isinstance(body, list):
        body = body[0] if body else {}
    if not isinstance(body, dict):
        return "error", "R\u00e9ponse inattendue. Rien n'a \u00e9t\u00e9 supprim\u00e9."

    # NEVER claim a deletion the workflow did not confirm. `deleted` is
    # set only after the API calls came back as real removals; anything
    # else - refused, partial, unreadable - is reported as not done.
    if body.get("deleted") is True:
        return "ok", str(body.get("message") or "")
    if body.get("owned") is False:
        # Deliberately the same wording as a name that does not exist. The
        # portal should not confirm to one user that another user's
        # project is real.
        return "denied", ("Ce projet est introuvable dans votre espace. "
                          "Rien n'a \u00e9t\u00e9 supprim\u00e9.")
    return "error", (str(body.get("message") or
                     "La suppression n'a pas pu \u00eatre confirm\u00e9e. "
                     "Rien n'a \u00e9t\u00e9 supprim\u00e9 avec certitude."))


def check_name(name, username):
    """Ask n8n whether `name` can be claimed by `username`.

    Returns a reason: free | taken | yours | reserved | shape | unknown.
    Anything that is not a clear answer is 'unknown' rather than 'free' —
    promising a name and then refusing it at submit time is worse than
    asking the user to try again.
    """
    if not N8N_WEBHOOK_TOKEN:
        return "unknown"
    payload = json.dumps({"name": name, "username": username}).encode()
    req = urllib.request.Request(
        N8N_NAME_URL, data=payload,
        headers={"Content-Type": "application/json",
                 "Accept": "application/json",
                 "X-Portal-Token": N8N_WEBHOOK_TOKEN},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.loads(resp.read().decode() or "{}")
    except Exception as exc:                       # noqa: BLE001
        print(f"[warn] name check failed: {exc}", file=sys.stderr)
        return "unknown"
    if isinstance(body, list):
        body = body[0] if body else {}
    reason = str(body.get("reason") or "")
    return reason if reason else "unknown"

GITHUB_RE = re.compile(
    r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$")


def serves(path):
    """Does THIS pod serve this route?"""
    if PORTAL_ROLE == "all":
        return True
    if path.startswith(ASSET_PREFIX):
        return True          # both roles serve the page images
    if PORTAL_ROLE == "signup":
        return path in SIGNUP_ROUTES
    return path in CONSOLE_ROUTES


def build_ssl_context():
    """Verify FreeIPA's cert against its own CA. No verify=False anywhere."""
    if os.path.exists(IPA_CA_CERT):
        ctx = ssl.create_default_context(cafile=IPA_CA_CERT)
    else:
        # Fail loudly rather than silently downgrading to no verification.
        raise RuntimeError(f"FreeIPA CA cert not found at {IPA_CA_CERT}")
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    return ctx


def ipa_session():
    """Log in as svc-portal, return an opener carrying the session cookie."""
    ctx = build_ssl_context()
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx),
        urllib.request.HTTPCookieProcessor(jar),
    )
    body = urllib.parse.urlencode(
        {"user": IPA_USER, "password": IPA_PASSWORD}
    ).encode()
    req = urllib.request.Request(
        IPA_LOGIN_URL,
        data=body,
        headers={
            "Referer": IPA_BASE,
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "text/plain",
        },
    )
    with opener.open(req, timeout=15) as resp:
        if resp.status != 200:
            raise RuntimeError(f"FreeIPA login failed: HTTP {resp.status}")
    return opener


def ipa_call(opener, method, args, params):
    """One JSON-RPC call against FreeIPA."""
    params = dict(params)
    params["version"] = IPA_API_VERSION
    payload = json.dumps({"method": method, "params": [args, params], "id": 0})
    req = urllib.request.Request(
        IPA_JSON_URL,
        data=payload.encode(),
        headers={
            "Referer": IPA_BASE,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    with opener.open(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def create_user(username, password, first, last):
    """Create a real FreeIPA account. Returns (ok, message)."""
    try:
        opener = ipa_session()
    except Exception as exc:
        # Never leak the service account password into a user-facing error.
        print(f"[error] FreeIPA login failed: {exc}", file=sys.stderr)
        return False, "Service momentanément indisponible. Réessayez dans un instant."

    try:
        result = ipa_call(
            opener,
            "user_add",
            [username],
            {
                "givenname": first,
                "sn": last,
                "userpassword": password,
            },
        )
    except urllib.error.HTTPError as exc:
        print(f"[error] user_add HTTP {exc.code}", file=sys.stderr)
        return False, "Un problème est survenu de notre côté. Réessayez dans un instant."
    except Exception as exc:
        print(f"[error] user_add failed: {exc}", file=sys.stderr)
        return False, "Service momentanément indisponible. Réessayez dans un instant."

    err = result.get("error")
    if err:
        name = err.get("name", "")
        msg = err.get("message", "Unknown error")
        print(f"[error] FreeIPA error {name}: {msg}", file=sys.stderr)
        if name == "DuplicateEntry":
            return False, "Cet identifiant est déjà pris. Essayez-en un autre."
        if name == "ACIError":
            return False, "Un problème est survenu de notre côté. Réessayez dans un instant."
        return False, "La création du compte a échoué. Réessayez dans un instant."

    summary = result.get("result", {}).get("summary", "Account created")
    print(f"[ok] {summary}", file=sys.stderr)
    return True, summary


# ---------------------------------------------------------------------------
# Authentication against Dex
#
# WHY THERE IS NO JWT SIGNATURE VERIFICATION HERE, AND WHEN THAT BREAKS
#
# Verifying Dex's RS256 signature needs a crypto library, which would
# break this app's stdlib-only constraint. It is not needed, because the
# token is fetched by THIS PROCESS directly from Dex's token endpoint
# over a TLS connection we opened and verified ourselves. OIDC Core 1.0
# §3.1.3.7 covers exactly that case:
#
#   "If the ID Token is received via direct communication between the
#    Client and the Token Endpoint ... the TLS server validation MAY be
#    used to validate the issuer in place of checking the token
#    signature."
#
# THIS REASONING HOLDS ONLY FOR THE PASSWORD GRANT. If anyone ever
# switches this to the authorization-code flow, the token arrives via
# the user's browser instead — an untrusted channel — and signature
# verification becomes MANDATORY. Do not carry this shortcut across.
#
# Skipping the signature is not skipping validation: iss, aud and exp
# are all checked below, and build_ssl_context() raises rather than
# downgrading if the CA is missing.
# ---------------------------------------------------------------------------

def _decode_claims(id_token):
    """Decode an ID token's claims. Signature NOT checked — see above."""
    parts = id_token.split(".")
    if len(parts) != 3:
        raise ValueError("malformed ID token")
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(payload).decode())


def _validate_claims(claims):
    """Raise unless the token is really ours, really Dex's, and current."""
    if claims.get("iss") != DEX_ISSUER:
        raise ValueError(f"issuer mismatch: {claims.get('iss')!r}")
    aud = claims.get("aud")
    aud = aud if isinstance(aud, list) else [aud]
    if DEX_CLIENT_ID not in aud:
        raise ValueError(f"audience mismatch: {aud!r}")
    exp = claims.get("exp")
    if not isinstance(exp, int) or exp <= time.time():
        raise ValueError("token expired or missing exp")
    return claims


def dex_login(username, password):
    """Verify credentials against Dex.

    Returns (status, payload) where status is one of:
      "ok"     -> payload is the validated claims dict
      "denied" -> payload is a user-facing message; the credentials were
                  rejected by Dex
      "error"  -> payload is a user-facing message; something on OUR side
                  or Dex's failed. Deliberately distinct from "denied":
                  telling a user their password is wrong when Dex is
                  simply unreachable sends them to reset a working
                  password.

    Note the account's FreeIPA password is expired from the moment
    user_add creates it (the standard 'set by someone else' marker), and
    Dex's LDAP simple bind authenticates it anyway where Kerberos would
    refuse. Proven 2026-08-27; see Part 22.
    """
    if not DEX_CLIENT_SECRET:
        print("[error] DEX_CLIENT_SECRET is empty", file=sys.stderr)
        return "error", "Service momentanément indisponible. Réessayez dans un instant."

    body = urllib.parse.urlencode({
        "grant_type": "password",
        "client_id": DEX_CLIENT_ID,
        "client_secret": DEX_CLIENT_SECRET,
        # Dex's LDAP connector searches FreeIPA on `uid`, so this must be
        # the BARE uid, never the email (Problem #83).
        "username": username,
        "password": password,
        "scope": "openid email groups",
    }).encode()
    req = urllib.request.Request(
        DEX_TOKEN_URL,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Accept": "application/json"},
    )

    try:
        ctx = build_ssl_context()
        with urllib.request.urlopen(req, timeout=15, context=ctx) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        # Dex returns 401 for bad credentials. Never echo its body.
        if exc.code in (400, 401):
            print(f"[auth] rejected login for {username!r} (HTTP {exc.code})",
                  file=sys.stderr)
            return "denied", "Identifiant ou mot de passe incorrect."
        print(f"[error] Dex HTTP {exc.code}", file=sys.stderr)
        return "error", "Service momentanément indisponible. Réessayez dans un instant."
    except Exception as exc:
        print(f"[error] Dex request failed: {exc}", file=sys.stderr)
        return "error", "Service momentanément indisponible. Réessayez dans un instant."

    token = data.get("id_token")
    if not token:
        print("[error] Dex returned no id_token", file=sys.stderr)
        return "error", "Service momentanément indisponible. Réessayez dans un instant."

    try:
        claims = _validate_claims(_decode_claims(token))
    except Exception as exc:
        print(f"[error] ID token rejected: {exc}", file=sys.stderr)
        return "error", "Service momentanément indisponible. Réessayez dans un instant."

    print(f"[auth] login OK for {claims.get('email')!r}", file=sys.stderr)
    return "ok", claims


def submit_project(username, email, description, repo_url, kind,
                   project=""):
    """Hand the submission to n8n, which does the real provisioning.

    Returns (status, payload) on the same three-state contract as
    dex_login: "ok" | "denied" | "error". The portal deliberately knows
    nothing about namespaces, quotas or Kubernetes — it forwards an
    identity and a description, and renders whatever n8n reports back.
    """
    if not N8N_WEBHOOK_TOKEN:
        print("[error] N8N_WEBHOOK_TOKEN is empty", file=sys.stderr)
        return "error", "Service momentanément indisponible. Réessayez dans un instant."

    payload = json.dumps({
        "username": username,
        "email": email,
        "description": description,
        "repoUrl": repo_url,
        # THE USER'S OWN PLATFORM CHOICE. Forgetting this line is the whole
        # of the bug found 2026-09-05: the radio was parsed, used to re-tick
        # the form on a validation error, and then dropped — so every
        # submission was classified by Groq no matter what was selected.
        # n8n whitelists it again on arrival; sending it is not trusting it.
        "kind": kind,
        # The name the user chose. The provisioner validates and
        # whitelists it again on arrival — sending it is not trusting it.
        "project": project,
    }).encode()
    req = urllib.request.Request(
        N8N_WEBHOOK_URL,
        data=payload,
        headers={"Content-Type": "application/json",
                 "Accept": "application/json",
                 "X-Portal-Token": N8N_WEBHOOK_TOKEN},
    )
    try:
        with urllib.request.urlopen(req, timeout=N8N_TIMEOUT) as resp:
            result = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        # n8n answers 403 when the shared token is wrong, and 500 with a
        # generic body when a workflow node throws.
        print(f"[error] n8n HTTP {exc.code}", file=sys.stderr)
        return "error", "Un problème est survenu de notre côté. Réessayez dans un instant."
    except Exception as exc:
        print(f"[error] n8n request failed: {exc}", file=sys.stderr)
        return "error", "Service momentanément indisponible. Réessayez dans un instant."

    if not isinstance(result, dict) or "provisioned" not in result:
        print(f"[error] unexpected n8n response: {str(result)[:200]}",
              file=sys.stderr)
        return "error", "Un problème est survenu de notre côté. Réessayez dans un instant."

    print(f"[ok] provisioning for {username!r}: "
          f"provisioned={result.get('provisioned')} "
          f"choice={result.get('choice')}", file=sys.stderr)
    return "ok", result


# --- sessions --------------------------------------------------------------
# HMAC-SHA256 over a `username|expiry` payload. hmac and hashlib are
# stdlib, so signing our OWN cookie needs no third-party crypto — it was
# only RS256 JWT verification that would have.

def make_session(username, token_exp):
    """Sign a session that can never outlive the Dex token behind it."""
    expiry = min(int(token_exp), int(time.time()) + SESSION_MAX_SECONDS)
    payload = f"{username}|{expiry}"
    raw = base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")
    sig = hmac.new(SESSION_KEY, raw.encode(), hashlib.sha256).hexdigest()
    return f"{raw}.{sig}", expiry


def read_session(value):
    """Return the username from a valid session, else None."""
    if not value or not SESSION_KEY:
        return None
    raw, _, sig = value.rpartition(".")
    if not raw or not sig:
        return None
    expected = hmac.new(SESSION_KEY, raw.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        return None
    try:
        payload = base64.urlsafe_b64decode(
            raw + "=" * (-len(raw) % 4)).decode()
    except Exception:
        return None
    username, _, expiry = payload.rpartition("|")
    if not username or not expiry.isdigit() or int(expiry) <= time.time():
        return None
    return username[:32]


# --- the tenant's deployed site -------------------------------------------
# Same HMAC construction as the session, with the OWNER baked into the
# signed payload. Reading it requires naming the user you expect, so a
# cookie lifted from one account is inert in another.

SITE_RE = re.compile(r"^http://[a-z0-9][a-z0-9.-]{0,120}/$")


def make_site(username, url):
    expiry = int(time.time()) + SITE_MAX_SECONDS
    payload = f"{username}|{expiry}|{url}"
    raw = base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")
    sig = hmac.new(SITE_KEY, raw.encode(), hashlib.sha256).hexdigest()
    return f"{raw}.{sig}", expiry


def read_site(value, username):
    """Return this user's site URL from a valid cookie, else None."""
    if not value or not SITE_KEY or not username:
        return None
    raw, _, sig = value.rpartition(".")
    if not raw or not sig:
        return None
    expected = hmac.new(SITE_KEY, raw.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        return None
    try:
        payload = base64.urlsafe_b64decode(
            raw + "=" * (-len(raw) % 4)).decode()
    except Exception:
        return None
    owner, _, rest = payload.partition("|")
    expiry, _, url = rest.partition("|")
    if owner != username:
        return None
    if not expiry.isdigit() or int(expiry) <= time.time():
        return None
    # Belt and braces. The signature already proves we minted this, but
    # the value is interpolated into an href, so it is also checked
    # against the only shape this feature ever produces.
    return url if SITE_RE.match(url) else None


# ---------------------------------------------------------------------------
# Presentation
#
# One shared design across all five screens. Quiet, near-monochrome, warm
# off-white. The ONLY colour on any page is the 34px spectrum logo mark;
# everything else is ink, greys and fills. No gradients, no glows, no
# decorative shadows beyond a single soft ambient card shadow.
#
# SHELL is a str.format template, so every literal CSS brace is doubled
# ({{ / }}). Page bodies are formatted separately and injected as {body};
# str.format does not re-scan substituted values, so bodies need no
# doubling.
#
# Responsive rules carried over from the 2026-08-25 responsiveness pass and
# verified by the same 14-width harness: no fixed px widths, 100dvh, 16px
# input floor (below it iOS zooms on focus and breaks the layout), 13px
# text floor, 44px tap targets, clamp() type, auto-fit column collapse.
# ---------------------------------------------------------------------------

SHELL = """<!DOCTYPE html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,700&display=swap" rel="stylesheet">
<style>
/* ==========================================================================
   CloudLab, Aurora Glass
   Shared stylesheet for sign-up, log-in and dashboard.
   ========================================================================== */

:root {{
  /* Palette */
  --ink:            #060a20;
  --ink-deep:       #05071c;
  --ink-solid:      #131836;
  --violet:         #6b4eff;
  --violet-soft:    #b9c4ff;
  --aqua:           #00c4e2;
  --mint:           #7ef0d6;
  --green:          #48e3b0;
  --pink:           #ec408c;
  --amber:          #ff9d4d;

  --text:           #ffffff;
  --text-muted:     #c9d0ea;
  --text-dim:       #b3bcdc;

  /* Glass */
  --glass:          rgba(255, 255, 255, .11);
  --glass-strong:   rgba(255, 255, 255, .14);
  --glass-line:     rgba(255, 255, 255, .20);
  --glass-line-2:   rgba(255, 255, 255, .28);
  --blur:           blur(26px);

  /* Radii */
  --r-sm: 12px;
  --r-md: 16px;
  --r-lg: 22px;
  --r-xl: 30px;
  --r-pill: 999px;

  /* Type */
  --font-display: 'Space Grotesk', system-ui, sans-serif;
  --font-body: 'DM Sans', system-ui, -apple-system, sans-serif;

  /* Elevation */
  --shadow-card: 0 30px 70px rgba(4, 6, 30, .45);
  --shadow-soft: 0 18px 44px rgba(4, 6, 30, .32);

  /* Layout */
  --rail: 66px;
  --gutter: 56px;
}}

* {{ box-sizing: border-box; }}

html, body {{ min-height: 100%; }}

body {{
  margin: 0;
  font-family: var(--font-body);
  color: var(--text);
  background: var(--ink);
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}}

a {{ color: var(--text); text-decoration: none; }}
a:hover {{ opacity: .78; }}

h1, h2, h3 {{ font-family: var(--font-display); letter-spacing: -.03em; margin: 0; }}

/* --------------------------------------------------------------------------
   Page shell + full-bleed background
   -------------------------------------------------------------------------- */

.page {{
  position: relative;
  min-height: 100dvh;
  overflow: hidden;
  isolation: isolate;
}}

.bg {{ position: absolute; inset: 0; z-index: -1; }}

.bg__img {{
  position: absolute;
  inset: -2%;
  width: 104%;
  height: 104%;
  object-fit: cover;
  filter: blur(3px) saturate(1.05);
}}

/* Diagonal scrim: guarantees contrast over the photo */
.bg__scrim {{
  position: absolute;
  inset: 0;
  background: linear-gradient(
    105deg,
    rgba(5, 7, 28, .94) 0%,
    rgba(6, 10, 32, .84) 46%,
    rgba(10, 14, 46, .72) 100%
  );
}}

/* Coloured aurora glow on top of the scrim */
.bg__glow {{
  position: absolute;
  inset: 0;
  background:
    radial-gradient(70% 60% at 82% 16%, rgba(107, 78, 255, .32), transparent 65%),
    radial-gradient(60% 50% at 6% 92%, rgba(0, 196, 226, .22), transparent 65%),
    radial-gradient(50% 45% at 45% 110%, rgba(236, 64, 140, .16), transparent 65%);
}}

/* --------------------------------------------------------------------------
   Icon rail
   -------------------------------------------------------------------------- */

.rail {{
  position: fixed;
  left: 24px;
  top: 24px;
  bottom: 24px;
  width: var(--rail);
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
  padding: 16px 0;
  border-radius: var(--r-pill);
  background: rgba(255, 255, 255, .08);
  border: 1px solid rgba(255, 255, 255, .16);
  backdrop-filter: blur(18px);
  -webkit-backdrop-filter: blur(18px);
  z-index: 5;
}}

.rail__logo {{ width: 40px; height: auto; display: block; margin-bottom: 4px; }}

.rail__item {{
  width: 44px;
  height: 44px;
  flex: none;
  border-radius: 50%;
  display: grid;
  place-items: center;
  background: rgba(255, 255, 255, .12);
  color: #fff;
  transition: background .18s ease, transform .18s ease;
}}
.rail__item:hover {{ background: rgba(255, 255, 255, .24); transform: translateY(-1px); opacity: 1; }}
.rail__item svg {{ display: block; }}

.rail__item--active {{ background: #fff; color: var(--ink-solid); }}
.rail__item--active:hover {{ background: #fff; }}

.rail__spacer {{ flex: 1; }}

.rail__avatar {{
  width: 44px; height: 44px; flex: none;
  border-radius: 50%;
  display: grid; place-items: center;
  background: linear-gradient(135deg, var(--violet), var(--aqua));
  font-size: 13px; font-weight: 600; letter-spacing: .02em;
}}

/* --------------------------------------------------------------------------
   Auth layout: pitch on the left, form card on the right
   -------------------------------------------------------------------------- */

.auth {{
  position: relative;
  min-height: 100dvh;
  padding: 48px var(--gutter) 48px calc(var(--rail) + 72px);
  display: grid;
  grid-template-columns: minmax(0, 1fr) 420px;
  gap: 64px;
  align-items: center;
  max-width: 1400px;
  margin: 0 auto;
}}

.pitch {{ max-width: 560px; }}

.eyebrow {{
  display: inline-flex;
  align-items: center;
  gap: 9px;
  padding: 7px 15px 7px 8px;
  border-radius: var(--r-pill);
  background: var(--glass);
  border: 1px solid var(--glass-line);
  font-size: 13px;
  letter-spacing: .01em;
  white-space: nowrap;
}}

.eyebrow__dot {{
  width: 20px; height: 20px;
  border-radius: 50%;
  background: linear-gradient(135deg, var(--aqua), var(--violet));
  flex: none;
}}

.pitch__title {{
  margin-top: 24px;
  font-weight: 500;
  font-size: clamp(42px, 5.2vw, 72px);
  line-height: 1;
  text-wrap: balance;
}}
.pitch__title em {{ font-style: normal; color: var(--violet-soft); }}

.pitch__body {{
  margin: 22px 0 0;
  max-width: 430px;
  font-size: 16.5px;
  line-height: 1.6;
  color: var(--text-muted);
  text-wrap: pretty;
}}

/* Floating stat / info badges */
.badges {{ display: flex; flex-wrap: wrap; gap: 12px; margin-top: 36px; }}

.stat {{
  padding: 14px 20px;
  border-radius: var(--r-lg);
  background: var(--glass);
  border: 1px solid var(--glass-line);
  backdrop-filter: var(--blur);
  -webkit-backdrop-filter: var(--blur);
}}
.stat__value {{ font-family: var(--font-display); font-size: 25px; font-weight: 600; letter-spacing: -.02em; }}
.stat__label {{ font-size: 13px; color: var(--text-muted); margin-top: 3px; }}

.badge {{
  display: inline-flex;
  align-items: center;
  gap: 10px;
  padding: 11px 17px 11px 12px;
  border-radius: var(--r-pill);
  background: var(--glass-strong);
  border: 1px solid var(--glass-line-2);
  backdrop-filter: blur(20px);
  -webkit-backdrop-filter: blur(20px);
  font-size: 13px;
  white-space: nowrap;
}}
.badge__dot {{
  width: 22px; height: 22px; flex: none;
  border-radius: 50%;
  background: linear-gradient(135deg, var(--mint), var(--aqua));
}}
.badge strong {{ font-weight: 600; }}

.badge-row {{ display: flex; flex-wrap: wrap; gap: 12px; margin-top: 28px; }}

/* --------------------------------------------------------------------------
   Glass card + form
   -------------------------------------------------------------------------- */

.card {{
  padding: 38px 34px;
  border-radius: var(--r-xl);
  background: rgba(255, 255, 255, .12);
  border: 1px solid rgba(255, 255, 255, .22);
  backdrop-filter: var(--blur);
  -webkit-backdrop-filter: var(--blur);
  box-shadow: var(--shadow-card);
}}

.card__title {{ font-size: 27px; font-weight: 600; letter-spacing: -.025em; }}
.card__sub {{ margin: 9px 0 28px; font-size: 13.5px; color: var(--text-muted); }}
.card__sub--tight {{ margin-bottom: 26px; }}

.field {{ display: block; margin-top: 17px; }}
.field:first-of-type {{ margin-top: 0; }}

.field__label {{
  display: block;
  font-size: 13px;
  letter-spacing: .07em;
  text-transform: uppercase;
  color: var(--text-dim);
  margin-bottom: 8px;
}}

.field__input {{
  width: 100%;
  padding: 13px 15px;
  border-radius: var(--r-sm);
  border: 1px solid rgba(255, 255, 255, .26);
  background: rgba(255, 255, 255, .10);
  color: #fff;
  font-family: inherit;
  font-size: 16px;
  outline: none;
  transition: border-color .18s ease, background .18s ease, box-shadow .18s ease;
}}
.field__input::placeholder {{ color: rgba(255, 255, 255, .42); }}
.field__input:hover {{ border-color: rgba(255, 255, 255, .38); }}
.field__input:focus {{
  border-color: rgba(185, 196, 255, .9);
  background: rgba(255, 255, 255, .16);
  box-shadow: 0 0 0 3px rgba(107, 78, 255, .28);
}}

.field-pair {{ display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 17px; }}
.field-pair .field {{ margin-top: 0; }}

/* Buttons */
.btn {{
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 16px 28px;
  border: 0;
  border-radius: var(--r-md);
  background: #fff;
  color: var(--ink-solid);
  font-family: var(--font-display);
  font-size: 16px;
  font-weight: 600;
  letter-spacing: -.01em;
  cursor: pointer;
  transition: transform .16s ease, box-shadow .16s ease, background .16s ease;
}}
.btn:hover {{ transform: translateY(-1px); box-shadow: 0 14px 30px rgba(4, 6, 30, .4); opacity: 1; }}
.btn:active {{ transform: translateY(0); }}
.btn:focus-visible {{ outline: 3px solid rgba(185, 196, 255, .8); outline-offset: 3px; }}

.btn--block {{ width: 100%; margin-top: 28px; }}
.btn--sm {{ padding: 14px 24px; font-size: 15px; }}

.btn--ghost {{
  background: rgba(255, 255, 255, .12);
  border: 1px solid var(--glass-line-2);
  color: #fff;
  backdrop-filter: blur(18px);
  -webkit-backdrop-filter: blur(18px);
}}
.btn--ghost:hover {{ background: rgba(255, 255, 255, .2); }}

.card__foot {{ margin: 20px 0 0; text-align: center; font-size: 13.5px; color: var(--text-muted); }}
.card__foot a {{ font-weight: 500; text-decoration: underline; text-underline-offset: 3px; text-decoration-color: rgba(255,255,255,.4); }}
.card__foot a:hover {{ text-decoration-color: #fff; opacity: 1; }}

/* Standalone logo lockup (log-in page) */
.lockup {{
  position: absolute;
  left: var(--gutter);
  top: 40px;
  padding: 13px 17px;
  border-radius: var(--r-lg);
  background: #fff;
  box-shadow: 0 14px 34px rgba(4, 6, 30, .4);
}}
.lockup img {{ width: 118px; height: auto; display: block; }}

/* --------------------------------------------------------------------------
   Dashboard
   -------------------------------------------------------------------------- */

.app {{
  position: relative;
  min-height: 100dvh;
  padding: 44px var(--gutter) 44px calc(var(--rail) + 72px);
  max-width: 1500px;
  margin: 0 auto;
  display: flex;
  flex-direction: column;
  gap: 34px;
}}

.topbar {{
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 32px;
  flex-wrap: wrap;
}}

.kicker {{
  font-size: 13px;
  letter-spacing: .15em;
  text-transform: uppercase;
  color: var(--text-dim);
}}

.greeting {{
  margin-top: 12px;
  font-weight: 500;
  font-size: clamp(36px, 4.2vw, 58px);
  line-height: 1;
}}

.greeting-sub {{ margin: 14px 0 0; font-size: 16px; color: var(--text-muted); }}

.topbar__actions {{ display: flex; align-items: center; gap: 22px; padding-top: 6px; }}

.link-quiet {{ font-size: 13.5px; color: var(--text-muted); }}
.link-quiet:hover {{ color: #fff; opacity: 1; }}

/* Project grid */
.projects {{
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 22px;
}}

.project {{
  display: flex;
  flex-direction: column;
  padding: 26px;
  border-radius: 26px;
  background: var(--glass);
  border: 1px solid var(--glass-line);
  backdrop-filter: blur(24px);
  -webkit-backdrop-filter: blur(24px);
  transition: transform .18s ease, background .18s ease, box-shadow .18s ease;
}}
.project:hover {{
  transform: translateY(-3px);
  background: rgba(255, 255, 255, .15);
  box-shadow: var(--shadow-soft);
}}

.project__head {{ display: flex; align-items: center; justify-content: space-between; }}

.project__glyph {{
  width: 30px; height: 30px;
  border-radius: 10px;
  background: linear-gradient(135deg, var(--violet), var(--aqua));
}}
.project__glyph--warm {{ background: linear-gradient(135deg, var(--pink), var(--amber)); }}
.project__glyph--cool {{ background: linear-gradient(135deg, var(--aqua), var(--mint)); }}

.status {{ display: inline-flex; align-items: center; gap: 7px; font-size: 13px; color: #a9f3dd; }}
.status__dot {{ width: 7px; height: 7px; border-radius: 50%; background: var(--green); }}

.project__name {{ margin: 20px 0 7px; font-size: 21px; font-weight: 600; letter-spacing: -.015em; }}

.project__url {{
  font-size: 14px;
  color: var(--violet-soft);
  word-break: break-all;
  text-decoration: underline;
  text-underline-offset: 3px;
  text-decoration-color: rgba(185, 196, 255, .4);
}}
.project__url:hover {{ color: #fff; text-decoration-color: #fff; opacity: 1; }}

.project__meta {{
  margin-top: auto;
  padding-top: 18px;
  font-size: 13px;
  color: var(--text-muted);
}}
.project__meta::before {{
  content: "";
  display: block;
  height: 1px;
  background: rgba(255, 255, 255, .16);
  margin-bottom: 16px;
}}

/* Prompt strip */
.strip {{
  display: flex;
  align-items: center;
  gap: 18px;
  padding: 22px 26px;
  border-radius: 24px;
  background: rgba(255, 255, 255, .09);
  border: 1px solid rgba(255, 255, 255, .18);
  backdrop-filter: blur(22px);
  -webkit-backdrop-filter: blur(22px);
  margin-top: auto;
  flex-wrap: wrap;
}}
.strip__glyph {{
  width: 34px; height: 34px; flex: none;
  border-radius: 12px;
  background: linear-gradient(135deg, var(--mint), var(--violet));
}}
.strip__text {{ flex: 1; min-width: 240px; }}
.strip__title {{ font-size: 15px; font-weight: 500; }}
.strip__sub {{ font-size: 13px; color: var(--text-muted); margin-top: 4px; }}
.strip__cta {{ font-size: 13.5px; font-weight: 500; white-space: nowrap; }}

/* Empty state */
.empty {{
  flex: 1;
  display: grid;
  place-items: center;
  padding: 24px 0;
}}

.empty__card {{
  width: min(620px, 100%);
  text-align: center;
  padding: 44px 46px;
  border-radius: 32px;
  background: rgba(255, 255, 255, .11);
  border: 1px dashed rgba(255, 255, 255, .32);
  backdrop-filter: var(--blur);
  -webkit-backdrop-filter: var(--blur);
}}

.empty__diagram {{ display: block; margin: 0 auto 26px; }}
.empty__title {{ font-size: 31px; font-weight: 600; letter-spacing: -.025em; }}
.empty__body {{
  margin: 15px auto 0;
  max-width: 410px;
  font-size: 15.5px;
  line-height: 1.6;
  color: var(--text-muted);
  text-wrap: pretty;
}}
.empty__card .btn {{ margin-top: 30px; }}

.footnotes {{ display: flex; flex-wrap: wrap; gap: 12px; justify-content: center; }}

/* --------------------------------------------------------------------------
   Responsive
   -------------------------------------------------------------------------- */

@media (max-width: 1080px) {{
  .auth {{ grid-template-columns: minmax(0, 1fr); gap: 40px; align-items: start; padding-top: 112px; }}
  .auth--login {{ padding-top: 132px; }}
  .card {{ max-width: 460px; }}
}}

@media (max-width: 720px) {{
  :root {{ --gutter: 22px; }}
  .rail {{
    left: 0; right: 0; top: auto; bottom: 0;
    width: auto; height: auto;
    flex-direction: row;
    border-radius: 0;
    padding: 12px 16px;
    gap: 14px;
  }}
  .rail__logo {{ width: 32px; margin: 0; }}
  .rail__spacer {{ flex: 1; }}
  .auth, .app {{ padding-left: var(--gutter); padding-right: var(--gutter); padding-bottom: 104px; }}
  .field-pair {{ grid-template-columns: 1fr; }}
  .lockup {{ position: static; display: inline-block; margin-bottom: 26px; }}
  .auth {{ padding-top: 32px; }}
  .empty__card {{ padding: 34px 24px; }}
}}

/* --------------------------------------------------------------------------
   Floors this project treats as non-negotiable, applied on top of the
   reference sheet. `min-height` does not apply to an inline element
   (Problem #125), so every tap target is given a box first.
   -------------------------------------------------------------------------- */
/* 16px on EVERY control, not just .field__input. A bare <input> falls back
   to the browser's 13.3px, which is what the radios on /new-project were
   rendering at. Below 16px iOS Safari zooms the page on focus. */
input, textarea, select, button {{ font-family: inherit; }}
input, textarea, select {{ font-size: 16px; }}

/* Delete control on a project card. Quiet by default so it cannot
   dominate the card or be hit casually, but a real button with a real
   44px target, not a decoration. The CONFIRM state is deliberately
   louder than the trigger. */
/* One pill, for the stopped state only, and the asymmetry is the point.
   Absence of routing is something this app measures. The opposite is
   not: a claimed address does not prove the thing behind it answers. So
   the only state named here is the one that was measured (#136). */
.status--off {{ color: var(--amber); }}
.status--off .status__dot {{ background: var(--amber); }}
.project__stopped {{ font-size: 14px; color: var(--text-dim);
  line-height: 1.5; margin: 0; }}
.project__foot {{ margin-top: 14px; display: flex; justify-content: flex-end; }}
.project__del {{
  display: inline-flex; align-items: center; gap: 7px;
  min-height: 44px; padding: 0 12px;
  border: 1px solid var(--glass-line);
  border-radius: var(--r-pill);
  background: transparent; color: var(--text-dim);
  font-family: inherit; font-size: 13px; cursor: pointer;
}}
.project__del:hover {{ background: rgba(255,255,255,.12); color: #fff;
  border-color: var(--glass-line-2); opacity: 1; }}
.project__del:focus-visible {{ outline: 3px solid rgba(185,196,255,.8);
  outline-offset: 2px; }}
.project__confirm {{
  margin-top: 14px; padding: 13px 14px;
  border-radius: var(--r-md);
  background: rgba(255,255,255,.10);
  border: 1px solid var(--glass-line-2);
  border-left: 3px solid var(--amber);
}}
.project__confirm p {{ margin: 0 0 12px; font-size: 13px; line-height: 1.5;
  color: #fff; }}
.project__confirm .row {{ display: flex; flex-wrap: wrap; gap: 10px; }}
.project__confirm form {{ margin: 0; }}
.btn--danger {{ background: #fff; color: #7a1029; padding: 0 16px;
  min-height: 44px; font-size: 14px; }}
.btn--quiet {{ background: transparent; color: var(--text-muted);
  border: 1px solid var(--glass-line); padding: 0 16px; min-height: 44px;
  font-size: 14px; display: inline-flex; align-items: center; }}
.btn--quiet:hover {{ background: rgba(255,255,255,.10); color: #fff; opacity: 1; }}

.btn, .rail__item, .rail__avatar {{ min-height: 44px; }}
.card__foot a, .project__url, .link-quiet, .strip__cta, .topbar__actions a {{
  display: inline-flex;
  align-items: center;
  min-height: 44px;
}}
.project__url {{ overflow-wrap: anywhere; word-break: break-word; }}

/* --------------------------------------------------------------------------
   Form primitives carried over from the previous theme, restyled onto the
   aurora tokens. /new-project, the confirmation page and /404 use these,
   so they stay on ONE stylesheet with the four rebuilt screens instead of
   the site running two design systems at once.
   -------------------------------------------------------------------------- */
.lede {{ margin: 9px 0 26px; font-size: 15.5px; line-height: 1.6; color: var(--text-muted); }}
.hint {{ font-size: 13px; line-height: 1.55; color: var(--text-dim); margin-top: 8px; }}
.hint code {{
  font-size: 13px; color: #fff;
  background: rgba(255,255,255,.14); border-radius: 5px; padding: 1px 6px;
}}
.soft {{ color: var(--text-dim); font-weight: 400; }}
.alt {{ margin: 20px 0 0; font-size: 13.5px; color: var(--text-muted); }}
.alt a {{ text-decoration: underline; text-underline-offset: 3px;
  text-decoration-color: rgba(255,255,255,.4); display: inline-flex;
  align-items: center; min-height: 44px; }}
.foot {{ margin-top: 26px; padding-top: 18px; font-size: 13px; color: var(--text-dim);
  border-top: 1px solid rgba(255,255,255,.14); }}

/* Messages. Colour is NEVER the only signal (WCAG 1.4.1): every state
   carries a left rule, a glyph and its own wording. That rule predates
   this redesign and survives it unchanged. */
.msg {{
  display: flex; gap: 11px; align-items: flex-start;
  margin: 0 0 22px; padding: 13px 15px;
  border-radius: var(--r-sm);
  background: rgba(255,255,255,.10);
  border: 1px solid var(--glass-line);
  font-size: 14px; line-height: 1.55; color: #fff;
}}
.msg svg {{ flex: none; margin-top: 2px; }}
.msg.err  {{ border-left: 3px solid #fff; }}
.msg.ok   {{ border-left: 3px solid var(--green); }}
.msg.note {{ border-left: 3px solid var(--violet-soft); color: var(--text-muted); }}

.two {{ display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }}
textarea.field__input {{ min-height: 104px; resize: vertical; line-height: 1.55; }}

/* Radio options on /new-project. `.opt` is a <label> and must keep these
   resets, or each blurb renders heavier than its own title. */
.opts {{ display: grid; gap: 10px; margin-top: 10px; }}
.opt {{
  display: flex; align-items: flex-start; gap: 12px;
  margin: 0; font-weight: 400;
  padding: 15px 16px; border-radius: var(--r-md);
  background: rgba(255,255,255,.08);
  border: 1px solid var(--glass-line);
  cursor: pointer; min-height: 44px;
}}
.opt:hover {{ background: rgba(255,255,255,.14); }}
.opt input {{ margin-top: 3px; flex: none; accent-color: var(--violet-soft); width: 17px; height: 17px; }}
.opt b {{ display: block; font-size: 15px; font-weight: 600; }}
.opt em {{ display: block; font-style: normal; font-size: 13px; line-height: 1.55;
  color: var(--text-muted); margin-top: 4px; }}

.panelnote {{ margin: 0 0 14px; font-size: 14.5px; line-height: 1.6; color: var(--text-muted); }}
.sitelink {{ display: block; margin-top: 6px; font-size: 14px; color: var(--violet-soft);
  overflow-wrap: anywhere; text-decoration: underline; text-underline-offset: 3px;
  min-height: 44px; }}

/* The card is a form surface on these pages, not a fixed-width auth panel. */
.card--form {{ width: min(680px, 100%); }}
.card--form .btn {{ margin-top: 26px; }}
</style>
</head>
<body>
<div class="page">
  <div class="bg">
    <img class="bg__img" src="/assets/bg-aurora.png" alt="" aria-hidden="true">
    <div class="bg__scrim"></div>
    <div class="bg__glow"></div>
  </div>
{body}
</div>
</body></html>"""

# The icon rail. Ported from the reference, with ONE change: the reference
# carried "Activity" and "Settings" items pointing at placeholder pages.
# Nothing in this app corresponds to either, so they are gone rather than
# wired to something that is not what the icon says. What is left points
# only at routes that exist.
RAIL_ICONS = {
    "overview": ('<svg width="16" height="16" viewBox="0 0 16 16" fill="none" '
                 'stroke="currentColor" stroke-width="1.6">'
                 '<rect x="2" y="2" width="5" height="5" rx="1"/>'
                 '<rect x="9" y="2" width="5" height="5" rx="1"/>'
                 '<rect x="2" y="9" width="5" height="5" rx="1"/>'
                 '<rect x="9" y="9" width="5" height="5" rx="1"/></svg>'),
    "new":      ('<svg width="16" height="16" viewBox="0 0 16 16" fill="none" '
                 'stroke="currentColor" stroke-width="1.6">'
                 '<circle cx="8" cy="4" r="2.2"/><circle cx="4" cy="12" r="2.2"/>'
                 '<circle cx="12" cy="12" r="2.2"/>'
                 '<path d="M8 6.2 L4 9.8 M8 6.2 L12 9.8"/></svg>'),
    "monitor":  ('<svg width="16" height="16" viewBox="0 0 16 16" fill="none" '
                 'stroke="currentColor" stroke-width="1.6" stroke-linecap="round" '
                 'stroke-linejoin="round"><path d="M1.6 8.4h3L6.2 5l2.4 6 1.8-3.6h2.6"/>'
                 '</svg>'),
    "logout":   ('<svg width="16" height="16" viewBox="0 0 16 16" fill="none" '
                 'stroke="currentColor" stroke-width="1.6" stroke-linecap="round">'
                 '<path d="M6 2.5H3.2A1.2 1.2 0 0 0 2 3.7v8.6a1.2 1.2 0 0 0 1.2 1.2H6"/>'
                 '<path d="M10.5 11 14 8 10.5 5"/><path d="M14 8H6"/></svg>'),
}


def initials(username):
    """Two letters from the real signed-in username, or empty.

    The reference hardcoded "AB". This derives from the actual session
    user, so the avatar is never showing somebody else's initials.
    """
    parts = [p for p in re.split(r"[._-]+", username or "") if p]
    if not parts:
        return ""
    if len(parts) == 1:
        return esc(parts[0][:2].upper())
    return esc((parts[0][0] + parts[1][0]).upper())


def rail(active="", username=""):
    """Primary nav. Every href here is a route this app actually serves."""
    def item(href, label, key):
        on = " rail__item--active" if key == active else ""
        cur = ' aria-current="page"' if key == active else ""
        return (f'<a class="rail__item{on}" href="{href}" '
                f'aria-label="{label}"{cur}>{RAIL_ICONS[key]}</a>')
    who = initials(username)
    avatar = (f'<span class="rail__avatar" aria-hidden="true">{who}</span>'
              if who else "")
    return (
        '<nav class="rail" aria-label="Navigation principale">'
        '<img class="rail__logo" src="/assets/tt-mark.png" alt="Tunisie Telecom">'
        + item("/welcome", "Mes projets", "overview")
        + item("/new-project", "Nouveau projet", "new")
        # Grafana. A plain browser link to a separate host, opened in a new
        # tab. Labelled "Monitoring" and nothing more: signing in there
        # through Dex is per-USER, but the DASHBOARDS are cluster-wide and
        # identical for everyone. Wording that implied "your project's
        # metrics" would promise isolation this system does not have
        # (Part 23). Do not reword it into a promise.
        + (f'<a class="rail__item" href="{esc(GRAFANA_URL)}" '
           f'target="_blank" rel="noopener noreferrer" '
           f'aria-label="Monitoring">{RAIL_ICONS["monitor"]}</a>')
        + '<span class="rail__spacer"></span>'
        + item("/logout", "Se deconnecter", "logout")
        + avatar
        + '</nav>')


LOCKUP = ('<div class="lockup">'
          '<img src="/assets/tt-logo.png" alt="Tunisie Telecom"></div>')


def auth_page(title, pitch, card, lang="fr", login=False, nav=""):
    """The two-column auth layout: pitch on the left, glass card right."""
    cls = "auth auth--login" if login else "auth"
    body = f'{nav}{LOCKUP if login else ""}<main class="{cls}">{pitch}{card}</main>'
    return SHELL.format(title=title, body=body, lang=lang)


def app_page(title, main, active="", username="", lang="fr"):
    """The signed-in dashboard layout: icon rail plus a full-width column."""
    body = f'{rail(active, username)}<main class="app">{main}</main>'
    return SHELL.format(title=title, body=body, lang=lang)


def plain_page(title, main, lang="fr"):
    """A single centred card with no rail, for pages reachable signed out."""
    body = (f'{LOCKUP}<main class="auth auth--login">'
            f'<section class="pitch"></section>'
            f'<div class="card">{main}</div></main>')
    return SHELL.format(title=title, body=body, lang=lang)


def field(name, label, **kw):
    """One .field row. Attributes are passed through unchanged, so the
    real validation on every input survives the restyle verbatim."""
    attrs = ""
    for k, v in kw.items():
        k = k.rstrip("_").replace("_", "-")
        if v is True:
            attrs += f" {k}"
        elif v not in (None, False, ""):
            attrs += f' {k}="{esc(str(v))}"'
    return (f'<label class="field"><span class="field__label">{label}</span>'
            f'<input class="field__input" id="{name}" name="{name}"{attrs}>'
            f'</label>')

ICON_CHECK = ('<svg width="21" height="21" viewBox="0 0 24 24" fill="none" '
              'stroke="currentColor" stroke-width="2.2" stroke-linecap="round" '
              'stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>')
ICON_ALERT = ('<svg class="g" width="17" height="17" viewBox="0 0 24 24" '
              'fill="none" stroke="currentColor" stroke-width="2" '
              'stroke-linecap="round"><circle cx="12" cy="12" r="9"/>'
              '<path d="M12 7.5v5.5"/><path d="M12 16.5h.01"/></svg>')
ICON_INFO = ('<svg class="g" width="17" height="17" viewBox="0 0 24 24" '
             'fill="none" stroke="currentColor" stroke-width="2" '
             'stroke-linecap="round"><circle cx="12" cy="12" r="9"/>'
             '<path d="M12 11v5"/><path d="M12 7.5h.01"/></svg>')

# Landing-page tile icons. Drawn here for the same reason HERO_ART is:
# no package manager exists in this deployment.
ICON_BOLT = ('<svg width="21" height="21" viewBox="0 0 24 24" fill="none" '
             'stroke="currentColor" stroke-width="1.9" stroke-linecap="round" '
             'stroke-linejoin="round"><path d="M13 2 4.5 13.5H11L10 22l8.5-'
             '11.5H12z"/></svg>')
ICON_GLOBE = ('<svg width="21" height="21" viewBox="0 0 24 24" fill="none" '
              'stroke="currentColor" stroke-width="1.9" stroke-linecap="round">'
              '<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/>'
              '<path d="M12 3a15 15 0 0 1 0 18a15 15 0 0 1 0-18"/></svg>')
ICON_SHIELD = ('<svg width="21" height="21" viewBox="0 0 24 24" fill="none" '
               'stroke="currentColor" stroke-width="1.9" stroke-linecap="round" '
               'stroke-linejoin="round"><path d="M12 3l7 3v6c0 4.4-3 7.6-7 9'
               'c-4-1.4-7-4.6-7-9V6z"/><path d="m9 12 2 2 4-4"/></svg>')

FOOT = '<div class="foot">Un service Tunisie Telecom</div>'


def esc(value):
    return (
        str(value)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def page(title, main, wide=False, nav="", active="", username=""):
    """The signed-in form pages: icon rail plus one glass card.

    /new-project, the confirmation page and /404 were not part of the
    rebuild brief, but they share this SHELL. Leaving them on the previous
    stylesheet would have meant carrying two design systems at once, or
    shipping them unstyled, so they render inside the same .app shell and
    the same .card surface as the four rebuilt screens.
    """
    body = (f'{rail(active, username)}'
            f'<main class="app"><div class="card card--form">{main}</div></main>')
    return SHELL.format(title=title, body=body, lang="fr")


def heading(strong, soft=""):
    """Card headline. Same two-tone split, on the reference's .card__title."""
    tail = f' <span class="soft">{soft}</span>' if soft else ""
    return f'<h2 class="card__title">{strong}{tail}</h2>'


def msg_block(message, kind):
    if not message:
        return ""
    glyph = ICON_ALERT if kind == "err" else ICON_INFO
    return f'<div class="msg {kind}">{glyph}<div>{esc(message)}</div></div>'


# --- / (public landing page, ENGLISH) --------------------------------------

# The four signed-in screens stay French; this page stays English. The
# language split predates this rebuild and is deliberate, so the aurora
# port moved the visuals and left the languages where they were.
#
# The no-jargon rule is STRICTEST here: / is the most public surface the
# project has, so Kubernetes, Nomad, Consul, FreeIPA, Dex and Vault appear
# nowhere in the response body, markup included.
#
# The reference set has no landing page of its own, so this is built from
# the same primitives signup.html uses: the pitch column, the stat and
# badge blocks, and the glass card.

def render_landing():
    pitch = """<section class="pitch">
      <p class="eyebrow"><span class="eyebrow__dot"></span>CloudLab by Tunisie Telecom</p>
      <h1 class="pitch__title">Describe it.<br><em>Watch it go live.</em></h1>
      <p class="pitch__body">Write what you want to put online in plain
        language. CloudLab prepares the space, publishes it, and hands you
        the address. Nothing to rent, nothing to install.</p>
      <div class="badges">
        <div class="stat">
          <div class="stat__value">0</div>
          <div class="stat__label">servers to rent or install</div>
        </div>
        <div class="stat">
          <div class="stat__value">1</div>
          <div class="stat__label">web address per project</div>
        </div>
      </div>
      <div class="badge-row">
        <p class="badge"><span class="badge__dot"></span>Your projects sit in a space of your own</p>
      </div>
    </section>"""
    card = """<div class="card">
      <h2 class="card__title">Get started</h2>
      <p class="card__sub">Create an account, describe a project, and it is
        published for you.</p>
      <a class="btn btn--block" href="/signup">Create an account</a>
      <p class="card__foot">Already have an account? <a href="/login">Log in</a></p>
    </div>"""
    return auth_page("CloudLab, your website live", pitch, card,
                     lang="en", login=True)


# --- /signup ---------------------------------------------------------------

# REAL: this form creates a real FreeIPA account. The restyle changed the
# wrapper classes and nothing else: same field names, same `required`, same
# autocomplete, same server-side validation, same error copy.

def render_signup(message="", kind="", username="", first="", last=""):
    pitch = """<section class="pitch">
      <p class="eyebrow"><span class="eyebrow__dot"></span>CloudLab par Tunisie Telecom</p>
      <h1 class="pitch__title">D&eacute;crivez-le.<br><em>Voyez-le en ligne.</em></h1>
      <p class="pitch__body">&Eacute;crivez ce que vous voulez mettre en ligne,
        avec vos mots. CloudLab pr&eacute;pare votre espace, le publie et vous
        donne l'adresse. Rien &agrave; louer, rien &agrave; installer.</p>
      <div class="badges">
        <div class="stat">
          <div class="stat__value">0</div>
          <div class="stat__label">serveur &agrave; louer ou &agrave; installer</div>
        </div>
        <div class="stat">
          <div class="stat__value">1</div>
          <div class="stat__label">adresse web par projet</div>
        </div>
      </div>
      <div class="badge-row">
        <p class="badge"><span class="badge__dot"></span>Un espace rien qu'&agrave; vous</p>
      </div>
    </section>"""
    card = f"""<form class="card" method="POST" action="/signup">
      <h2 class="card__title">Cr&eacute;ez votre compte</h2>
      <p class="card__sub">Moins d'une minute, c'est promis.</p>
      {msg_block(message, kind)}
      {field("username", "Identifiant", type="text", required=True,
             autofocus=True, autocomplete="username",
             placeholder="amine.beji", value=username)}
      <div class="hint">C'est le nom que vous utiliserez pour vous connecter.</div>
      <div class="field-pair">
        {field("first", "Pr&eacute;nom", type="text", required=True,
               autocomplete="given-name", value=first)}
        {field("last", "Nom", type="text", required=True,
               autocomplete="family-name", value=last)}
      </div>
      {field("password", "Mot de passe", type="password", required=True,
             autocomplete="new-password")}
      <div class="hint">Au moins 8 caract&egrave;res.</div>
      <button class="btn btn--block" type="submit">Cr&eacute;er mon compte</button>
      <p class="card__foot">Vous avez d&eacute;j&agrave; un compte ?
        <a href="/login">Connectez-vous</a></p>
    </form>"""
    return auth_page("Creer mon compte · CloudLab", pitch, card, login=True)


# --- /login ----------------------------------------------------------------

# REAL: authenticates against Dex over the same FreeIPA and issues an
# HMAC-signed session. Username and password only. There is no social
# sign-in, no "remember me" and no one-time code in this system, so no UI
# for any of them appears here.

def render_login(message="", kind="", username=""):
    pitch = """<section class="pitch">
      <h1 class="pitch__title">De retour<br><em>dans votre espace.</em></h1>
      <p class="pitch__body">Vos projets vous attendent, chacun dans son
        espace isol&eacute;.</p>
      <div class="badge-row">
        <p class="badge"><span class="badge__dot"></span>Identifiant et mot de passe, rien d'autre</p>
      </div>
    </section>"""
    card = f"""<form class="card" method="POST" action="/login">
      <h2 class="card__title">Connexion</h2>
      <p class="card__sub card__sub--tight">Connectez-vous pour retrouver
        votre espace.</p>
      {msg_block(message, kind)}
      {field("username", "Identifiant", type="text", required=True,
             autofocus=True, autocomplete="username",
             placeholder="amine.beji", value=username)}
      {field("password", "Mot de passe", type="password", required=True,
             autocomplete="current-password")}
      <button class="btn btn--block" type="submit">Se connecter</button>
      <p class="card__foot">Vous n'avez pas encore de compte ?
        <a href="/signup">Cr&eacute;er un compte</a></p>
    </form>"""
    return auth_page("Se connecter · CloudLab", pitch, card, login=True)


# --- /welcome --------------------------------------------------------------

MONTHS_FR = ("janvier", "février", "mars", "avril", "mai", "juin",
             "juillet", "août", "septembre", "octobre", "novembre",
             "décembre")


def fr_date(stamp):
    """Format an ISO creation timestamp, or return "" if we cannot.

    Returns "" rather than guessing. A project card with no date is
    honest; one carrying an invented date is not.
    """
    if not stamp:
        return ""
    try:
        d = datetime.datetime.strptime(str(stamp)[:10], "%Y-%m-%d")
    except (ValueError, TypeError):
        return ""
    return f"{d.day} {MONTHS_FR[d.month - 1]} {d.year}"


# The reference dashboard showed a "Live" status pill and a meta line
# reading "Kubernetes / 3 replicas / deployed 6 days ago". None of that is
# available here: the projects feed returns namespace, project, url,
# created and legacy, and nothing in this app checks whether a tenant's
# site actually responds. Claiming "Live" would be precisely the defect
# Problem #136 recorded, so the pill is dropped and the meta line carries
# the real creation date.
GLYPHS = ("", " project__glyph--warm", " project__glyph--cool")

ICON_TRASH = ('<svg width="15" height="15" viewBox="0 0 16 16" fill="none" '
              'stroke="currentColor" stroke-width="1.5" stroke-linecap="round" '
              'stroke-linejoin="round"><path d="M2.5 4h11"/>'
              '<path d="M6 4V2.6h4V4"/><path d="M3.8 4l.6 9.4h7.2L12.2 4"/>'
              '<path d="M6.6 6.6v4.6M9.4 6.6v4.6"/></svg>')


def del_control(pname, confirm):
    """The per-card delete control, in one of its two states.

    The confirmation is SERVER-RENDERED, not a client-side toggle: the
    trigger is a link to /welcome?confirm=<project>, and only the
    confirmed state contains a form that can POST. That keeps the page
    working with no JavaScript, and means the dangerous control does not
    exist in the DOM until the user has asked for it.
    """
    if confirm == pname:
        return (
            '<div class="project__confirm">'
            f'<p>Supprimer d&eacute;finitivement <b>{pname}</b> ? Son '
            'espace et tout ce qu&rsquo;il contient seront '
            'effac&eacute;s. <b>Cette action est irr&eacute;versible.</b></p>'
            '<div class="row">'
            '<form method="POST" action="/delete-project">'
            # The project name travels in the BODY, so this submission is
            # bound to one named project and cannot be replayed against
            # another. n8n re-checks that it belongs to this session user.
            f'<input type="hidden" name="project" value="{pname}">'
            '<button class="btn btn--danger" type="submit">Oui, '
            'supprimer d&eacute;finitivement</button>'
            '</form>'
            '<a class="btn btn--quiet" href="/welcome#mes-sites">Annuler</a>'
            '</div></div>')
    return ('<div class="project__foot">'
            f'<a class="project__del" href="/welcome?confirm={pname}#mes-sites" '
            f'aria-label="Supprimer le projet {pname}">'
            f'{ICON_TRASH}Supprimer</a></div>')


def render_welcome(username="", fresh=False, projects=None,
                   confirm="", message="", kind=""):
    name = esc(username) if username else ""
    who = name or "vous"
    note = msg_block(message, kind)
    if fresh:
        # Disproved 2026-08-27: a brand-new portal account authenticates to
        # Dex immediately with its signup password, with no change step.
        note = (f'<div class="msg note">{ICON_INFO}<div>Votre compte est '
                'pr&ecirc;t. Vous pouvez vous connecter d&egrave;s maintenant '
                'avec l&rsquo;identifiant et le mot de passe que vous venez '
                'de choisir.</div></div>') + note

    # THE OWNERSHIP BOUNDARY IS NOT HERE. Every row arrived because the
    # Kubernetes API server matched a label selector bound to this session
    # user. This code only shapes the answer.
    rows = projects or []
    cards = ""
    shown = 0
    for proj in rows:
        # Defensive: this list comes over the network. A malformed entry is
        # skipped, never rendered and never allowed to raise, because a 500
        # on /welcome would lock a user out of their own page.
        if not isinstance(proj, dict):
            continue
        pname = esc(str(proj.get("project") or ""))
        url = str(proj.get("url") or "")
        # `routing` is what n8n MEASURED by looking for the project's
        # Ingress: True it exists, False it is gone, None it could not be
        # determined. A stopped project has no url, and must still be
        # listed - it is the user's project, it is simply not answering.
        routing = proj.get("routing")
        if not pname:
            continue
        if routing is not False and not url.startswith("http://"):
            continue
        when = fr_date(proj.get("created"))
        meta = f"Cr&eacute;&eacute; le {when}" if when else "Espace actif"
        if proj.get("legacy"):
            meta += " &middot; espace historique"
        if routing is False:
            # NO LINK. Its address is known not to answer, and a link that
            #404s is worse than no link - the same rule the provisioner
            # follows for siteUrl. The pill says what was measured.
            pill = ('<span class="status status--off">'
                    '<span class="status__dot"></span>Arr&ecirc;t&eacute;</span>')
            # A DELETED project never reaches this branch now: its
            # namespace is gone, so the list cannot return it. This
            # state means only what it says - the project exists and is
            # not answering.
            addr = ('<p class="project__stopped">Ce projet ne r&eacute;pond '
                    'plus pour le moment.</p>')
        else:
            pill = ""
            addr = f'<a class="project__url" href="{esc(url)}">{esc(url)}</a>'
        cards += (
            f'<article class="project">'
            f'<div class="project__head">'
            f'<span class="project__glyph{GLYPHS[shown % 3]}" aria-hidden="true"></span>'
            f'{pill}'
            f'</div>'
            f'<h2 class="project__name">{pname}</h2>'
            f'{addr}'
            f'<p class="project__meta">{meta}</p>'
            f'{del_control(pname, confirm)}'
            f'</article>')
        shown += 1

    if shown:
        count = ("1 projet dans votre espace" if shown == 1
                 else f"{shown} projets dans votre espace")
        topbar = f"""<header class="topbar">
          <div>
            <p class="kicker">Votre espace</p>
            <h1 class="greeting">Bonjour, {who}.</h1>
            <p class="greeting-sub">{count}.</p>
          </div>
          <div class="topbar__actions">
            <a class="link-quiet" href="/logout">Se d&eacute;connecter</a>
            <a class="btn btn--sm" href="/new-project">Lancer un autre projet</a>
          </div>
        </header>"""
        main = f"""{topbar}{note}
        <section class="projects" id="mes-sites" aria-label="Projets d&eacute;ploy&eacute;s">
          {cards}
        </section>
        <aside class="strip">
          <span class="strip__glyph" aria-hidden="true"></span>
          <div class="strip__text">
            <p class="strip__title">D&eacute;crivez votre prochain projet en une phrase.</p>
            <p class="strip__sub">CloudLab pr&eacute;pare son espace et vous
              rend une adresse.</p>
          </div>
          <a class="strip__cta" href="/new-project">Commencer</a>
        </aside>"""
    else:
        # The empty state is the reference dashboard-empty.html layout: the
        # topbar without the launch button, a dashed .empty__card, and the
        # two footnote badges.
        topbar = f"""<header class="topbar">
          <div>
            <p class="kicker">Votre espace</p>
            <h1 class="greeting">Bonjour, {who}.</h1>
          </div>
          <div class="topbar__actions">
            <a class="link-quiet" href="/logout">Se d&eacute;connecter</a>
          </div>
        </header>"""
        main = f"""{topbar}{note}
        <section class="empty" id="mes-sites">
          <div class="empty__card">
            <svg class="empty__diagram" width="180" height="70" viewBox="0 0 180 70" aria-hidden="true">
              <g stroke="rgba(255,255,255,.45)" fill="none" stroke-width="1.2">
                <path d="M20 35 H62 M90 35 H118 M146 35 H162"/>
              </g>
              <circle cx="20" cy="35" r="9" fill="none" stroke="rgba(255,255,255,.55)"/>
              <rect x="62" y="21" width="28" height="28" rx="8" fill="rgba(255,255,255,.18)" stroke="rgba(255,255,255,.5)"/>
              <rect x="118" y="21" width="28" height="28" rx="8" fill="rgba(255,255,255,.1)" stroke="rgba(255,255,255,.4)"/>
              <circle cx="168" cy="35" r="6" fill="#48e3b0"/>
            </svg>
            <h2 class="empty__title">Aucun projet pour l&rsquo;instant</h2>
            <p class="empty__body">Dites &agrave; CloudLab ce que vous voulez
              mettre en ligne. Un site, une API, un petit service. Votre
              espace est pr&eacute;par&eacute; et vous recevez une adresse.</p>
            <a class="btn" href="/new-project">Cr&eacute;er mon premier projet</a>
          </div>
        </section>
        <div class="footnotes">
          <p class="badge"><span class="badge__dot"></span>Un espace rien qu&rsquo;&agrave; vous</p>
          <p class="badge"><span class="badge__dot"></span>Rien &agrave; installer</p>
        </div>"""
    return app_page("Mon espace · CloudLab", main, active="overview",
                    username=username)


# --- /new-project (MOCKUP) -------------------------------------------------

# This page NAMES the platforms, deliberately. It is reached only after
# an account exists, by someone choosing how to run a project, and the
# earlier benefit-only labels made the choice harder to reason about,
# not easier. The no-jargon rule still holds for /signup and /login,
# which is where a first-time non-technical visitor lands.
# Recorded as a scope reversal of Problem #108 in Part 22, not a
# regression of it.
PROJECT_OPTIONS = (
    ("kubernetes", "Kubernetes — robuste et évolutif",
     "Une application solide, capable de monter en charge, avec "
     "plusieurs composants qui doivent rester disponibles en permanence "
     "(site à fort trafic, plusieurs services, base de données "
     "critique)."),
    ("nomad", "Nomad + Consul — léger et rapide",
     "Un projet simple à déployer rapidement, sans les couches de "
     "complexité d'un système plus lourd (petit outil, prototype, "
     "service isolé)."),
    ("both", "Je ne sais pas, aidez-moi à choisir",
     "Décrivez votre projet, on choisit la bonne plateforme pour vous."),
)

PROJECT_LABELS = {value: label for value, label, _ in PROJECT_OPTIONS}


def render_new_project(message="", kind="", description="", choice="",
                       repo_url="", project=""):
    opts = ""
    for value, label, blurb in PROJECT_OPTIONS:
        checked = " checked" if choice == value else ""
        opts += (f'<label class="opt"><input type="radio" name="kind" '
                 f'value="{value}" required{checked}>'
                 f'<span><b>{label}</b><em>{blurb}</em></span></label>')
    main = f"""{heading("Votre", "nouveau projet")}
    <p class="lede">Deux questions, et c'est tout.</p>
    {msg_block(message, kind)}
    <form method="POST" action="/new-project">
      <label class="field__label" for="project">Quel nom donnez-vous
        &agrave; votre projet ?</label>
      <input class="field__input" id="project" name="project" required autofocus
             minlength="3" maxlength="30"
             pattern="[a-z][a-z0-9-]{{1,28}}[a-z0-9]"
             placeholder="moncv"
             value="{esc(project)}">
      <div class="hint">Ce nom devient l&rsquo;adresse de votre projet.
        Lettres minuscules, chiffres et tirets&nbsp;: <code>moncv</code>,
        <code>restaurant-schmitt</code>.</div>
      <label class="field__label" for="description">Qu'est-ce que vous voulez
        mettre en ligne ?</label>
      <textarea class="field__input" id="description" name="description" required
        placeholder="Un site vitrine pour ma boutique de Sfax, avec les horaires et un formulaire de contact."
        >{esc(description)}</textarea>
      <div class="hint">Pas besoin d'&ecirc;tre technique. Dites-le avec vos
        mots, en une ou deux phrases.</div>
      <label class="field__label" for="repo">Lien GitHub <span class="soft">(facultatif)</span></label>
      <input class="field__input" id="repo" name="repo" type="url" inputmode="url"
             placeholder="https://github.com/amine/ma-boutique"
             value="{esc(repo_url)}">
      <div class="hint">Si votre projet est d&eacute;j&agrave; sur GitHub, on
        le regarde pour mieux pr&eacute;parer votre espace. Le d&eacute;p&ocirc;t
        doit &ecirc;tre public.</div>
      <label class="field__label">De quoi s'agit-il ?</label>
      <div class="opts">{opts}</div>
      <button class="btn btn--block" type="submit">Envoyer ma demande</button>
    </form>
    <div class="alt"><a href="/welcome">Retour &agrave; mon espace</a></div>"""
    # No avatar here: render_new_project has 13 call sites and does not
    # receive the username. Threading it through all of them for two
    # initials is not worth the churn, and rail() renders fine without it.
    return page("Nouveau projet · CloudLab", main, active="new")


def render_project_sent(description, result):
    """Render what n8n ACTUALLY did, not what was requested.

    Never claims more than happened: a partially provisioned space says
    so, and the Nomad half says plainly that it is not automated yet.
    """
    # `provisioned` is about the KUBERNETES space (namespace, quota,
    # binding), which is created for a Nomad tenant too. But if the Nomad
    # side is blocked on an operator, nothing the user asked for is
    # actually running, and "votre espace est pret" would overclaim.
    provisioned = (bool(result.get("provisioned"))
                   and not result.get("nomadNamespaceMissing"))
    choice = result.get("choice", "")
    label = PROJECT_LABELS.get(choice, "")
    ready = ("Votre espace est pr&ecirc;t." if provisioned else
             "Votre demande est enregistr&eacute;e.")
    head = (heading("C'est parti,", "on s'en occupe") if provisioned else
            heading("Demande re&ccedil;ue,", "en cours de traitement"))

    extra = ""
    if provisioned:
        extra += ('<p class="panelnote"><b>Votre espace</b>Il est cr&eacute;&eacute; '
                  'et vous y avez acc&egrave;s avec le compte que vous venez '
                  'd\'utiliser.</p>')
    else:
        extra += ('<p class="panelnote"><b>Ce qui se passe</b>Une partie de la '
                  'mise en place n\'a pas abouti automatiquement. Votre '
                  'demande est conserv&eacute;e et sera termin&eacute;e '
                  'manuellement.</p>')
    # --- the browsable address ---------------------------------------
    # Shown ONLY when n8n actually created the Ingress. Everything below
    # states the real condition of the link rather than a hopeful one:
    #   siteReady false  -> the image is still building, so it 503s now
    #   sitePortSource   -> 'default' means the port was NOT read from a
    #                       Dockerfile and the app may not answer on it
    site_url = result.get("siteUrl") or ""
    if site_url:
        extra += ('<p class="panelnote"><b>Votre adresse</b>'
                  f'<a class="sitelink" href="{esc(site_url)}">{esc(site_url)}</a></p>')
        if not result.get("siteReady"):
            extra += ('<p class="panelnote"><b>Encore quelques minutes</b>'
                      'Nous pr&eacute;parons votre application. L\'adresse '
                      'ci-dessus r&eacute;pondra d&egrave;s que c\'est '
                      'termin&eacute;&nbsp;; rafra&icirc;chissez la page '
                      'dans quelques minutes.</p>')
        if result.get("sitePortSource") == "default":
            extra += ('<p class="panelnote"><b>&Agrave; v&eacute;rifier</b>'
                      'Nous n\'avons pas trouv&eacute; dans votre projet '
                      'l\'indication du port utilis&eacute;. Si votre '
                      'application ne r&eacute;pond pas &agrave; cette '
                      'adresse, ajoutez une ligne <code>EXPOSE</code> &agrave; '
                      'votre Dockerfile et relancez la demande.</p>')
    elif result.get("choice") == "nomad":
        # REPLACED 2026-09-06. This used to say "ce type de projet n'a pas
        # encore d'adresse ... votre application tourne bien". BOTH halves
        # became wrong: Nomad tenants DO get a URL now, and the second half
        # asserted the app was running when the commonest reason for having
        # no URL is that nothing was placed at all. Never tell a user their
        # application is fine without knowing that it is.
        if result.get("nomadNamespaceMissing"):
            # The one condition an operator must clear by hand, and the
            # only honest thing to say is that it is not automatic yet.
            extra += ('<p class="panelnote"><b>Une derni&egrave;re '
                      '&eacute;tape de notre c&ocirc;t&eacute;</b>Votre '
                      'espace Nomad doit &ecirc;tre ouvert par notre '
                      '&eacute;quipe avant que votre projet puisse '
                      'd&eacute;marrer. Votre demande est '
                      'conserv&eacute;e&nbsp;: relancez-la une fois que '
                      'nous vous confirmons que c\'est fait.</p>')
        else:
            # Submitted, but no address to give yet. Says only that.
            extra += ('<p class="panelnote"><b>Adresse web</b>Votre projet a '
                      '&eacute;t&eacute; envoy&eacute;, mais aucune adresse '
                      'n\'est disponible pour l\'instant. Relancez la '
                      'demande dans quelques minutes.</p>')

    # The platform was too busy to build the tenant's own image, so a
    # working placeholder went up instead. Both halves are stated: the
    # site is real, the image is not theirs yet.
    if result.get("buildRejected"):
        extra += ('<p class="panelnote"><b>Votre application</b>Beaucoup de '
                  'projets &eacute;taient en pr&eacute;paration en m&ecirc;me '
                  'temps, nous n\'avons pas pu construire la v&ocirc;tre cette '
                  'fois. Une page d\'accueil provisoire est en ligne&nbsp;; '
                  'relancez la demande pour construire votre application.</p>')

    # WHO decided the platform, stated rather than blurred. The old copy
    # said "Ce qui a été retenu" for every case, which read as though the
    # user's selection had been applied even when Groq had chosen instead
    # — and for a while the selection was being dropped entirely.
    decided = result.get("decidedBy")

    # The classifier could not separate the two platforms. Kubernetes is
    # the deliberate fallback, and the user is told it was a fallback
    # rather than a confident recommendation. Never shown when the user
    # chose for themselves — there was no uncertainty to report.
    if result.get("classifierUnsure") and decided != "user":
        extra += ('<p class="panelnote"><b>Comment nous avons '
                  'd&eacute;cid&eacute;</b>Votre description pouvait '
                  'convenir aux deux plateformes. Nous avons retenu la plus '
                  'compl&egrave;te des deux&nbsp;; vous pouvez nous dire si '
                  'vous pr&eacute;f&eacute;rez l&rsquo;autre.</p>')
    if decided == "user":
        pick = ("<b>Votre choix</b>" + esc(label))
    elif decided == "classifier":
        pick = ("<b>Ce que nous avons choisi pour vous</b>" + esc(label))
    elif decided == "default":
        pick = ("<b>Choix par d&eacute;faut</b>" + esc(label))
    else:
        pick = ("<b>Ce qui a &eacute;t&eacute; retenu</b>" + esc(label))

    main = f"""<div class="done">{ICON_CHECK}</div>
    {head}
    <p class="lede">{ready}</p>
    <p class="panelnote"><b>Votre demande</b>{esc(description)}</p>
    <p class="panelnote">{pick}</p>
    {extra}
    <a class="btn" href="/welcome">Retour &agrave; mon espace</a>
    <div class="alt"><a href="/new-project">Envoyer une autre demande</a></div>"""
    return page("Demande envoy\u00e9e \u00b7 CloudLab", main, active="new")


# --- 404 -------------------------------------------------------------------

def render_404():
    main = f"""{heading("Page", "introuvable")}
    <p class="lede">Ce lien ne m&egrave;ne nulle part.</p>
    <a class="btn" href="/welcome">Retour &agrave; mon espace</a>
    <div class="alt"><a href="/login">Se connecter</a></div>"""
    return plain_page("Page introuvable \u00b7 CloudLab", main)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "signup-portal/1.0"

    # -- plumbing ----------------------------------------------------------

    def _send(self, status, body, ctype="text/html; charset=utf-8",
              cookie=None):
        raw = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(raw)

    def _redirect(self, location, cookie=None):
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def _current_user(self):
        """Username from a VALID signed session, or "" if not signed in.

        Unlike the cl_user cookie this replaces, forging this requires
        SESSION_KEY. Routes may be gated on it.
        """
        raw = self.headers.get("Cookie")
        if not raw:
            return ""
        try:
            jar = http.cookies.SimpleCookie()
            jar.load(raw)
        except http.cookies.CookieError:
            return ""
        if SESSION_COOKIE not in jar:
            return ""
        return read_session(jar[SESSION_COOKIE].value) or ""

    def _site_url(self, username):
        """This user's deployed site, or "" — from their signed cookie."""
        raw = self.headers.get("Cookie")
        if not raw:
            return ""
        try:
            jar = http.cookies.SimpleCookie()
            jar.load(raw)
        except http.cookies.CookieError:
            return ""
        if SITE_COOKIE not in jar:
            return ""
        return read_site(jar[SITE_COOKIE].value, username) or ""

    @staticmethod
    def _site_cookie(username, url):
        value, expiry = make_site(username, url)
        max_age = max(0, expiry - int(time.time()))
        # Not HttpOnly-sensitive in the way the session is — it holds no
        # authority — but it is signed, so keep it on the same terms.
        return (f"{SITE_COOKIE}={value}; Path=/; HttpOnly; "
                f"SameSite=Lax; Max-Age={max_age}")

    @staticmethod
    def _session_cookie(username, token_exp):
        value, expiry = make_session(username, token_exp)
        max_age = max(0, expiry - int(time.time()))
        return (f"{SESSION_COOKIE}={value}; Path=/; HttpOnly; "
                f"SameSite=Lax; Max-Age={max_age}")

    def _require_session(self):
        """Gate a route. Returns the username, or redirects and returns ""."""
        user = self._current_user()
        if not user:
            self._redirect("/login")
        return user

    def _read_form(self):
        """Parse a urlencoded body. Returns None if the request is unusable."""
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length <= 0 or length > 8192:
            return None
        return urllib.parse.parse_qs(self.rfile.read(length).decode())

    # -- routing -----------------------------------------------------------

    def _send_asset(self, name):
        """Serve one allowlisted image, or 404.

        `name` has already been matched against ASSETS, so this only ever
        opens a file this code named itself. Assets are immutable for the
        life of a rollout (the ConfigMap changes only on deploy), so they
        are the one response here that is cacheable.
        """
        ctype = ASSETS.get(name)
        if not ctype:
            self._send(404, render_404())
            return
        try:
            with open(os.path.join(ASSET_DIR, name), "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            print(f"[error] asset {name} unreadable: {exc}", file=sys.stderr)
            self._send(404, render_404())
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path == "/healthz":
            self._send(200, '{"status":"ok"}', "application/json")
            return
        if path.startswith(ASSET_PREFIX):
            self._send_asset(path[len(ASSET_PREFIX):])
            return
        if not serves(path):
            # Traefik path rules should never send this here. If one is
            # missing or mis-ordered, 404 rather than pretend.
            self._send(404, render_404())
            return
        if path == "/":
            # PUBLIC landing page. Not gated on anything; / no longer
            # renders the signup form, which now lives only at /signup.
            self._send(200, render_landing())
        elif path == "/signup":
            self._send(200, render_signup())
        elif path == "/login":
            self._send(200, render_login())
        elif path == "/welcome":
            # GATED. Closes Part 23 item 8.
            user = self._require_session()
            if not user:
                return
            query = urllib.parse.parse_qs(parsed.query)
            fresh = query.get("new", [""])[0] == "1"
            # `confirm` only selects WHICH card renders its confirmation
            # state. It causes no effect and confers no authority: a name
            # that is not in this user's own list simply matches no card.
            confirm = query.get("confirm", [""])[0].strip().lower()
            if not PROJECT_NAME_RE.match(confirm or ""):
                confirm = ""
            self._send(200, render_welcome(user, fresh, list_projects(user),
                                           confirm=confirm))
        elif path == "/new-project":
            # GATED.
            if not self._require_session():
                return
            self._send(200, render_new_project())
        elif path == "/logout":
            self._redirect("/login",
                           f"{SESSION_COOKIE}=; Path=/; Max-Age=0; HttpOnly; "
                           "SameSite=Lax")
        elif path == "/healthz":
            self._send(200, '{"status":"ok"}', "application/json")
        else:
            self._send(404, render_404())

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not serves(path):
            self._send(404, render_404())
            return
        if path == "/signup":
            self._post_signup()
        elif path == "/login":
            self._post_login()
        elif path == "/new-project":
            self._post_new_project()
        elif path == "/delete-project":
            self._post_delete_project()
        else:
            self._send(404, render_404())

    # -- POST /delete-project — REAL, and scoped to "stop routing" --------

    def _post_delete_project(self):
        """Stop routing one project. Gated exactly like /new-project.

        SCOPE (decided, not an oversight): this removes the Ingress,
        Service and Deployment. The namespace, its ResourceQuota and its
        RoleBinding are left in place, idle. Namespace deletion is one
        cascading operation with no undo and is delegated to nothing.

        The portal does NOT decide ownership. It sends the session's
        username and the submitted project name; n8n re-checks with the
        same label selector that backs the project list, and the API
        server does the filtering (the Problem #147 rule, reused).
        """
        user = self._require_session()
        if not user:
            return
        fields = self._read_form()
        if fields is None:
            self._send(400, render_welcome(
                user, False, list_projects(user),
                message="Requ\u00eate invalide.", kind="err"))
            return
        project = fields.get("project", [""])[0].strip().lower()
        # Shape-checked before it leaves the portal. This is not an
        # ownership check and must never be mistaken for one.
        if not PROJECT_NAME_RE.match(project or ""):
            self._send(400, render_welcome(
                user, False, list_projects(user),
                message="Nom de projet invalide. Rien n'a \u00e9t\u00e9 supprim\u00e9.",
                kind="err"))
            return

        status, detail = delete_project(user, project)
        if status == "ok":
            # Redirect so the list is re-fetched from n8n/Kubernetes. The
            # page must show what the source of truth now says, not a
            # client-side removal that would look identical whether or not
            # anything was actually deleted.
            self._redirect("/welcome?removed=1#mes-sites")
            return
        # Not confirmed deleted. Say that plainly and re-read the list, so
        # the user sees the real current state either way.
        self._send(200 if status == "denied" else 503, render_welcome(
            user, False, list_projects(user), message=detail, kind="err"))

    # -- POST /signup — REAL FreeIPA, logic unchanged ----------------------

    def _post_signup(self):
        fields = self._read_form()
        if fields is None:
            self._send(400, render_signup("Requête invalide.", "err"))
            return

        username = fields.get("username", [""])[0].strip().lower()
        password = fields.get("password", [""])[0]
        first = fields.get("first", [""])[0].strip()
        last = fields.get("last", [""])[0].strip()

        keep = {"username": username, "first": first, "last": last}

        if not USERNAME_RE.match(username):
            self._send(400, render_signup(
                "L'identifiant doit commencer par une lettre et ne contenir "
                "que des minuscules, chiffres, point, - ou _ "
                "(3 à 32 caractères).",
                "err", **keep))
            return
        if len(password) < MIN_PASSWORD_LEN:
            self._send(400, render_signup(
                f"Le mot de passe doit contenir au moins "
                f"{MIN_PASSWORD_LEN} caractères.", "err", **keep))
            return
        if not first or not last:
            self._send(400, render_signup(
                "Le prénom et le nom sont obligatoires.", "err", **keep))
            return

        ok, message = create_user(username, password, first, last)
        if not ok:
            self._send(400, render_signup(message, "err", **keep))
            return

        # The account exists and we hold credentials known to be valid, so
        # sign the user straight in rather than bouncing them to /login.
        # If Dex refuses for any reason the account is still created, so
        # fall back to the login page rather than failing the signup.
        status, result = dex_login(username, password)
        if status == "ok":
            self._redirect("/welcome?new=1",
                           self._session_cookie(username, result["exp"]))
        else:
            print(f"[warn] account {username!r} created but auto-login "
                  f"failed; sending user to /login", file=sys.stderr)
            self._redirect("/login")

    # -- POST /login — REAL, verified against Dex --------------------------

    def _post_login(self):
        fields = self._read_form()
        if fields is None:
            self._send(400, render_login("Requête invalide.", "err"))
            return

        username = fields.get("username", [""])[0].strip().lower()
        password = fields.get("password", [""])[0]

        if not username or not password:
            self._send(400, render_login(
                "Entrez votre identifiant et votre mot de passe.",
                "err", username=username))
            return

        status, result = dex_login(username, password)
        if status == "denied":
            self._send(401, render_login(result, "err", username=username))
            return
        if status != "ok":
            self._send(503, render_login(result, "err", username=username))
            return

        self._redirect("/welcome",
                       self._session_cookie(username, result["exp"]))

    # -- POST /new-project — MOCKUP, persists nothing ----------------------

    def _post_new_project(self):
        # GATED, like the GET. Without this the form would remain an
        # unauthenticated entry point even though the page requires a
        # session to reach. The session ALSO supplies the identity sent
        # to n8n — it is never taken from the form, so a submission
        # cannot provision a namespace for someone else.
        user = self._require_session()
        if not user:
            return
        fields = self._read_form()
        if fields is None:
            self._send(400, render_new_project("Requête invalide.", "err"))
            return

        description = fields.get("description", [""])[0].strip()
        choice = fields.get("kind", [""])[0]
        repo_url = fields.get("repo", [""])[0].strip()
        project = fields.get("project", [""])[0].strip().lower()

        # Every re-render carries the whole form back. A rejected name must
        # never cost the user their description, their link or their choice.
        keep = {"description": description, "choice": choice,
                "repo_url": repo_url, "project": project}

        if len(description) < MIN_PROJECT_LEN:
            self._send(400, render_new_project(
                "Décrivez votre projet en une phrase au moins.",
                "err", **keep))
            return
        if choice not in PROJECT_LABELS:
            self._send(400, render_new_project(
                "Choisissez ce que vous voulez mettre en ligne.",
                "err", **keep))
            return
        # Optional, but if given it must be a plausible public GitHub repo.
        # Validated here so a malformed URL is a form error the user can
        # fix, rather than a silent no-op deep inside the workflow.
        if repo_url and not GITHUB_RE.match(repo_url):
            self._send(400, render_new_project(
                "Le lien GitHub doit ressembler à "
                "https://github.com/utilisateur/projet",
                "err", **keep))
            return

        # THE PROJECT NAME. `pattern` on the input is client-side only, so
        # the same rules are applied here — shape and reserved words first,
        # because neither needs a network call and a bad name should fail
        # instantly.
        problem = project_name_problem(project)
        if problem == "shape":
            self._send(400, render_new_project(
                "Utilisez 3 à 30 caractères\u00a0: lettres "
                "minuscules, chiffres et tirets.", "err", **keep))
            return
        if problem == "reserved":
            self._send(400, render_new_project(
                "Ce nom est réservé, choisissez-en un autre.",
                "err", **keep))
            return

        # Is it FREE? Only the cluster can answer that, so it is asked
        # BEFORE any provisioning starts. This is advisory: the workflow
        # re-checks ownership authoritatively when it creates the space,
        # because any check-then-create has a race between them.
        verdict = check_name(project, user)
        if verdict == "taken":
            self._send(400, render_new_project(
                "Ce nom est déjà pris, choisissez-en un autre.",
                "err", **keep))
            return
        if verdict == "reserved":
            self._send(400, render_new_project(
                "Ce nom est réservé, choisissez-en un autre.",
                "err", **keep))
            return
        if verdict == "shape":
            self._send(400, render_new_project(
                "Utilisez 3 à 30 caractères\u00a0: lettres "
                "minuscules, chiffres et tirets.", "err", **keep))
            return
        if verdict == "unknown":
            # Said plainly rather than guessed. Claiming a name we could
            # not verify would hand the user a failure at the next step.
            self._send(503, render_new_project(
                "Nous n'avons pas pu vérifier ce nom pour l'instant. "
                "Réessayez dans un instant.", "err", **keep))
            return
        # 'free' proceeds; 'yours' proceeds too — re-submitting to your own
        # project is a normal thing to do, not a collision.

        # `required` on the radio is client-side only, so the value is
        # checked here too — an unrecognised platform must be a form error,
        # never something forwarded to the provisioner.
        if choice not in PROJECT_LABELS:
            self._send(400, render_new_project(
                "Choisissez comment vous voulez héberger votre projet.",
                "err", **keep))
            return

        status, result = submit_project(
            user, f"{user}@cloudlab.internal", description, repo_url, choice, project)
        if status != "ok":
            self._send(503, render_new_project(result, "err", **keep))
            return

        # Remember the address for /welcome. Only a URL n8n actually
        # created an Ingress for is stored, and only in this browser —
        # see SITE_COOKIE for why the server cannot hold it instead.
        cookie = None
        site_url = result.get("siteUrl") or ""
        if site_url and SITE_RE.match(site_url):
            cookie = self._site_cookie(user, site_url)
        self._send(200, render_project_sent(description, result), cookie=cookie)

    def log_message(self, fmt, *args):
        # Never log request bodies — they contain passwords.
        sys.stderr.write(f"{self.address_string()} {fmt % args}\n")


def main():
    # Same discipline as IPA_PASSWORD: refuse to start rather than run
    # degraded. A missing SESSION_KEY would make every session invalid;
    # a missing DEX_CLIENT_SECRET would make every login fail. Both would
    # otherwise roll out green and fail per-request.
    # Role-aware: each pod demands only what its own routes need. The
    # console has no IPA_PASSWORD by design and must not be made to want
    # one, or the split would be undone by a startup check.
    required = [("SESSION_KEY", SESSION_KEY),
                ("DEX_CLIENT_SECRET", DEX_CLIENT_SECRET)]
    if PORTAL_ROLE in ("signup", "all"):
        required.append(("IPA_PASSWORD", IPA_PASSWORD))
    if PORTAL_ROLE in ("console", "all"):
        required.append(("N8N_WEBHOOK_TOKEN", N8N_WEBHOOK_TOKEN))
    if PORTAL_ROLE not in ("signup", "console", "all"):
        print(f"[fatal] PORTAL_ROLE={PORTAL_ROLE!r} is not one of "
              "signup/console/all — refusing to start", file=sys.stderr)
        sys.exit(1)

    missing = [n for n, v in required if not v]
    if missing:
        print(f"[fatal] empty: {', '.join(missing)} — refusing to start",
              file=sys.stderr)
        sys.exit(1)
    try:
        build_ssl_context()
    except Exception as exc:
        print(f"[fatal] {exc}", file=sys.stderr)
        sys.exit(1)

    server = http.server.ThreadingHTTPServer(("", LISTEN_PORT), Handler)
    print(f"[ready] signup-portal role={PORTAL_ROLE} on :{LISTEN_PORT}, "
          f"IPA={IPA_HOST} as {IPA_USER}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
