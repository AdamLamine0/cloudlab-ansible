#!/usr/bin/env bash
# dex-claims-probe.sh - what claims does Dex ACTUALLY send?
#
# RUN ON THE kube VM. Read-only: it performs one login and decodes the
# token it gets back. Nothing is configured or changed.
#
# WHY
#   Grafana stores a Dex user's Login as tesuseradam3@cloudlab.internal
#   rather than the bare uid, so ${__user.login} never matches the `owner`
#   label on tenant namespaces and the per-user dashboard shows zero
#   projects for a user who really has two (Problem #161).
#
#   `login_attribute_path: preferred_username` only works if that claim is
#   actually in the token. This asks Dex, instead of reasoning about the
#   config. It requests TWO different scope sets so you can see whether
#   the `profile` scope alone is enough, or whether Dex is not emitting
#   the claim at all.
#
# WHY IT WRITES NOTHING TO A POD
#   The console pod runs with readOnlyRootFilesystem: true, deliberately.
#   `kubectl cp` into it fails with "can't remove old file ... Read-only
#   file system" and always will. So the default mode talks to Dex from
#   the kube host itself, with no pod involved at all; the fallback pipes
#   the script over stdin to `python3 -` rather than landing a file.
#
# Usage:
#   ./dex-claims-probe.sh USERNAME              from the host (default)
#   ./dex-claims-probe.sh USERNAME --via-pod    via the console pod's stdin
#
#   The password is prompted for and never echoed. It is never placed in
#   argv or in a container environment, both of which are readable by
#   anyone who can list processes or exec into the pod.
set -euo pipefail

KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
DEX_ISSUER="${DEX_ISSUER:-https://dex.dex.svc.cluster.local:5554/dex}"
DEX_HOST_IP="${DEX_HOST_IP:-192.168.1.50}"
CA="${CA:-/root/dex-setup/freeipa-ca.crt}"
CLIENT_ID="${DEX_CLIENT_ID:-signup-portal}"

USERNAME=""
VIA_POD=0
for arg in "$@"; do
  case "$arg" in
    --via-pod) VIA_POD=1 ;;
    -h|--help) awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 0 ;;
    -*) echo "unknown argument: $arg (try --help)"; exit 2 ;;
    *) USERNAME="$arg" ;;
  esac
done
[[ -n "$USERNAME" ]] || { awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 2; }

note() { printf '    %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ -x "$KUBECTL" ]] || die "$KUBECTL not found. Are you on the kube VM?"

# The client secret comes from the Secret the portal already uses. Read
# into a variable, never written to a file.
CLIENT_SECRET="$($KUBECTL get secret signup-portal-oidc -n signup \
  -o go-template='{{index .data "client_secret"}}' 2>/dev/null | base64 -d || true)"
[[ -n "$CLIENT_SECRET" ]] || die "could not read signup-portal-oidc from namespace signup"

# BARE UID, never the email. Dex's LDAP connector searches FreeIPA on uid,
# and a wrongly-formatted username produces a message byte-identical to a
# wrong password (Problem #83).
read -r -s -p "    password for ${USERNAME} (not echoed): " PASSWORD
echo

# Credentials travel base64-encoded inside the script text. Base64 is
# alphanumeric plus + / =, so it cannot break out of the string it is
# substituted into, whatever the password contains. Passing them through
# argv or a container env would expose them to `ps` and to
# /proc/PID/environ instead.
U_B64="$(printf '%s' "$USERNAME"      | base64 | tr -d '\n')"
P_B64="$(printf '%s' "$PASSWORD"      | base64 | tr -d '\n')"
S_B64="$(printf '%s' "$CLIENT_SECRET" | base64 | tr -d '\n')"
unset PASSWORD CLIENT_SECRET

# The probe itself. No backslash escapes anywhere in it, so nothing can be
# flattened while it is assembled or piped.
build_script() {
cat <<PROBE
import base64, json, ssl, sys, urllib.parse, urllib.request

ISSUER = "${DEX_ISSUER}"
CA = "${1}"
CLIENT_ID = "${CLIENT_ID}"
USERNAME = base64.b64decode("${U_B64}").decode()
PASSWORD = base64.b64decode("${P_B64}").decode()
CLIENT_SECRET = base64.b64decode("${S_B64}").decode()

# TLS is verified, as everywhere else in this project. Built only for an
# https issuer, and a bad CA path says so plainly instead of throwing a
# raw traceback at someone who just mistyped a path.
ctx = None
if ISSUER.startswith("https"):
    try:
        ctx = ssl.create_default_context(cafile=CA)
    except Exception as exc:
        print("      cannot load the CA at " + CA + ": " + str(exc))
        raise SystemExit(3)

def claims_for(scope):
    body = urllib.parse.urlencode({
        "grant_type": "password",
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "username": USERNAME,
        "password": PASSWORD,
        "scope": scope,
    }).encode()
    req = urllib.request.Request(
        ISSUER + "/token", data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
            payload = json.loads(r.read().decode())
    except Exception as exc:
        return None, str(exc), None
    tok = payload.get("id_token")
    access = payload.get("access_token")
    if not tok:
        return None, "no id_token in the response", access
    part = tok.split(".")[1]
    part = part + "=" * (-len(part) % 4)
    return json.loads(base64.urlsafe_b64decode(part).decode()), None, access


def userinfo_for(access):
    """What /userinfo returns. Grafana calls this too when api_url is set,
    and it is NOT guaranteed to carry the same claims as the ID token."""
    if not access:
        return None, "no access_token to call userinfo with"
    req = urllib.request.Request(
        ISSUER + "/userinfo",
        headers={"Authorization": "Bearer " + access})
    try:
        with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
            return json.loads(r.read().decode()), None
    except Exception as exc:
        return None, str(exc)

SCOPES = [
    ("openid email groups", "what the PORTAL asks for today"),
    ("openid profile email groups", "what GRAFANA is configured to ask for"),
]

found = False
for scope, why in SCOPES:
    print("")
    print("    scope: " + scope)
    print("           (" + why + ")")
    c, err, access = claims_for(scope)
    if err:
        print("      FAILED: " + err[:160])
        continue
    print("      --- ID TOKEN claims ---")
    for k in sorted(c):
        v = c[k]
        if k in ("sub", "at_hash", "c_hash"):
            v = "(omitted)"
        print("        " + k + " = " + json.dumps(v))
    pu = c.get("preferred_username")
    if pu:
        found = True
        print("        -> preferred_username IS present: " + json.dumps(pu))
        if "@" in str(pu):
            print("           but it CONTAINS an @, so it is not the bare uid")
    else:
        print("        -> preferred_username is ABSENT from the ID token")

    # THE ENDPOINT GRAFANA ALSO READS. With api_url set, Grafana calls
    # /userinfo and evaluates login_attribute_path against THAT response
    # too. A claim present in the ID token but missing here is enough to
    # make a correct-looking config do nothing.
    ui, uerr = userinfo_for(access)
    print("      --- /userinfo response ---")
    if uerr:
        print("        FAILED: " + uerr[:160])
    elif ui is None:
        print("        (no response)")
    else:
        for k in sorted(ui):
            v = ui[k]
            if k in ("sub",):
                v = "(omitted)"
            print("        " + k + " = " + json.dumps(v))
        upu = ui.get("preferred_username")
        if upu:
            print("        -> preferred_username IS present: " + json.dumps(upu))
        else:
            print("        -> preferred_username is ABSENT from /userinfo")
            if pu:
                print("           MISMATCH: the ID token has it, /userinfo does not.")
                print("           Grafana reads BOTH; whichever it uses last wins.")

print("")
print("    VERDICT")
if found:
    print("      Dex does emit preferred_username. If Grafana still stores")
    print("      the email, the fault is Grafana's login_attribute_path,")
    print("      not Dex.")
else:
    print("      Dex emits NO preferred_username claim under either scope.")
    print("      login_attribute_path: preferred_username therefore reads")
    print("      null and Grafana falls back to the email.")
    print("")
    print("      Fix: set preferredUsernameAttr: uid inside userSearch in")
    print("      /root/dex-setup/values.yaml. Apply it with")
    print("      ./deploy-grafana-sso.sh --fix-username-claim, re-run")
    print("      deploy-dex.sh, then run this probe again.")
PROBE
}

if [[ $VIA_POD -eq 1 ]]; then
  POD="$($KUBECTL get pod -n signup -l app=console -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$POD" ]] || POD="$($KUBECTL get pod -n signup -o name 2>/dev/null | grep -m1 console | cut -d/ -f2 || true)"
  [[ -n "$POD" ]] || die "no console pod found in namespace signup"
  note "running inside pod $POD, script piped over stdin"
  note "nothing is written to the pod - its root filesystem is read-only"
  # `python3 -` reads the program from stdin. No file is created, which is
  # the whole point: kubectl cp into this pod fails by design.
  build_script /etc/ipa-ca/freeipa-ca.crt | $KUBECTL exec -i -n signup "$POD" -- python3 -
else
  note "running on the kube host, no pod involved"
  [[ -f "$CA" ]] || die "CA not found at $CA"
  # The cluster DNS name does not resolve on the host, but Dex is reachable
  # at the LoadBalancer address. Python is told to connect there while
  # still verifying the certificate for the issuer's hostname, so the
  # issuer string stays exactly what Dex signs tokens with (Problem #77).
  note "resolving $(printf '%s' "$DEX_ISSUER" | sed 's#https://##;s#/.*##') via $DEX_HOST_IP"
  {
    printf '%s\n' "import socket"
    printf '%s\n' "_real = socket.getaddrinfo"
    printf '%s\n' "def _ga(host, port, *a, **k):"
    printf '%s\n' "    if host.endswith('dex.dex.svc.cluster.local'):"
    printf '%s\n' "        host = '${DEX_HOST_IP}'"
    printf '%s\n' "    return _real(host, port, *a, **k)"
    printf '%s\n' "socket.getaddrinfo = _ga"
    build_script "$CA"
  } | python3 -
fi
