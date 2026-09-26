#!/usr/bin/env bash
# deploy-grafana-sso.sh - Grafana login through Dex, staged.
#
# RUN ON THE kube VM. Read grafana-dex-sso.md first; this script is that
# plan, executed, with the guards made mandatory instead of advisory.
#
# WHAT THIS ACHIEVES
#   Anyone with a platform account (created at /signup, authenticated by
#   Dex against FreeIPA) logs into Grafana with that same identity. No
#   hand-made Grafana account, no second password.
#
# WHAT IT DOES NOT DO, and nothing may imply otherwise
#   It does not scope what anyone SEES. Every signed-in user, admin or
#   not, still gets the same cluster-wide dashboards. Nothing here filters
#   a metric or a dashboard by tenant. Part 23 item 24 stays open.
#
# THE INDEX HAZARD, and why this script still checks it
#   deploy-dex.sh addresses the portal's client positionally
#   (config.staticClients[$PORTAL_CLIENT_INDEX].secret) and already has an
#   ACTUAL_ID guard that refuses to run if that slot is not signup-portal.
#   That guard protects deploy-dex.sh. It does NOT protect this script,
#   which runs first and edits the list deploy-dex.sh then indexes into.
#   So this script re-checks the same invariant BEFORE writing anything.
#   Two independent checks of one assumption is the point, not redundancy.
#
#   The new client is APPENDED at the end of the list. Index 2 is never
#   read, rewritten or renumbered by this script.
#
# Usage:
#   ./deploy-grafana-sso.sh --check     guards + current state. CHANGES NOTHING.
#   ./deploy-grafana-sso.sh --dex       stage 1: Dex client + Vault secret
#   ./deploy-grafana-sso.sh --grafana   stage 2: Grafana values + helm upgrade
#   ./deploy-grafana-sso.sh --verify    what can be checked without a browser
#   ./deploy-grafana-sso.sh --fix-dex-script  repair a --set-string that was
#                                       written outside the helm command
#   ./deploy-grafana-sso.sh --dump-dex-config  print the LIVE staticClients
#                                       block, secrets redacted
#   ./deploy-grafana-sso.sh --fix-username-claim  make Dex emit the bare uid
#                                       as preferred_username
#   ./deploy-grafana-sso.sh --verify-secret   is the LIVE grafana client secret
#                                       the Vault one, or still the placeholder?
#   ./deploy-grafana-sso.sh --all       stages 1 and 2, prompting before each
#   ./deploy-grafana-sso.sh --rollback  remove the client and the Grafana auth
#   --yes    do not prompt
set -euo pipefail

KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
HELM="${HELM:-helm}"
DEX_DIR="${DEX_DIR:-/root/dex-setup}"
DEX_VALUES="$DEX_DIR/values.yaml"
DEX_SCRIPT="$DEX_DIR/deploy-dex.sh"
CA_SRC="$DEX_DIR/freeipa-ca.crt"
LIVE_VALUES="${LIVE_VALUES:-/root/prometheus-values-live.yaml}"
CHART_VERSION="${CHART_VERSION:-88.2.0}"

CLIENT_ID=grafana
GRAFANA_URL="http://grafana.cloudlab.internal"
REDIRECT="$GRAFANA_URL/login/generic_oauth"
# THE INTERNAL NAME. Dex's issuer is dex.dex.svc.cluster.local and
# changing it was considered and rejected (it would break k3s's OIDC).
# A client pointed at any other hostname fails at login with
# "issuer did not match" - Problem #77, already paid for once with Nomad.
DEX_ISSUER="https://dex.dex.svc.cluster.local:5554/dex"

ASSUME_YES=0
STAGE=""
for arg in "$@"; do
  case "$arg" in
    --check|--dex|--grafana|--verify|--all|--rollback|--fix-dex-script|--verify-secret|--dump-dex-config|--fix-username-claim) STAGE="$arg" ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)"; exit 2 ;;
  esac
done
[[ -n "$STAGE" ]] || { awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 2; }

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local a; read -r -p "    $1 [y/N] " a
  [[ "$a" == "y" || "$a" == "Y" ]] || { echo "    aborted"; exit 1; }
}

# ======================================================== THE GUARDS
# Everything below refuses rather than assumes. Each prints what it saw.
guards() {
  say "guards"
  [[ -x "$KUBECTL" ]] || die "$KUBECTL not found. Are you on the kube VM?"
  [[ -f "$DEX_VALUES" ]] || die "$DEX_VALUES not found"
  [[ -f "$DEX_SCRIPT" ]] || die "$DEX_SCRIPT not found"
  command -v "$HELM" >/dev/null || die "helm not on PATH"

  # PORTAL_CLIENT_INDEX is READ from deploy-dex.sh, never assumed to be 2.
  # If the script ever changes it, this follows rather than diverging.
  PORTAL_INDEX="$(grep -oE '^[[:space:]]*PORTAL_CLIENT_INDEX=[0-9]+' "$DEX_SCRIPT" \
                  | grep -oE '[0-9]+$' | head -1 || true)"
  [[ -n "$PORTAL_INDEX" ]] \
    || die "could not read PORTAL_CLIENT_INDEX from $DEX_SCRIPT.
    This script will not guess an index into a list of secrets."
  note "deploy-dex.sh PORTAL_CLIENT_INDEX = $PORTAL_INDEX"

  $KUBECTL get deploy/dex -n dex >/dev/null 2>&1 || die "deploy/dex not found"

  DEX_DIR="$DEX_DIR" DEX_VALUES="$DEX_VALUES" PORTAL_INDEX="$PORTAL_INDEX" \
  CLIENT_ID="$CLIENT_ID" python3 - <<'PY'
import os, re, sys

values = open(os.environ["DEX_VALUES"], encoding="utf-8", newline="").read()
want_index = int(os.environ["PORTAL_INDEX"])
client_id = os.environ["CLIENT_ID"]

# Parse the staticClients list positionally, by text, so this needs no
# PyYAML on the VM (nothing else here depends on it either).
m = re.search(r"^([ \t]*)staticClients:[ \t]*$", values, re.M)
if not m:
    sys.exit("REFUSING: no staticClients: block in values.yaml")
indent = len(m.group(1))
lines = values[m.end():].split("\n")

ids, depth = [], None
for ln in lines:
    if not ln.strip():
        continue
    cur = len(ln) - len(ln.lstrip())
    if ln.lstrip().startswith("- "):
        if depth is None:
            depth = cur
        if cur == depth:
            im = re.match(r"-\s*id:\s*(\S+)", ln.strip())
            ids.append(im.group(1) if im else "(unnamed)")
            continue
    # a line at or left of the block's own indent ends the list
    if cur <= indent and not ln.lstrip().startswith("-"):
        break

print("    staticClients, as they are RIGHT NOW:")
for i, c in enumerate(ids):
    mark = "   <- PORTAL_CLIENT_INDEX" if i == want_index else ""
    print(f"      [{i}] {c}{mark}")

if want_index >= len(ids):
    sys.exit(f"REFUSING: PORTAL_CLIENT_INDEX={want_index} but the list has "
             f"only {len(ids)} client(s).")

# THE SAME INVARIANT deploy-dex.sh's ACTUAL_ID guard enforces, checked
# here too because this script runs FIRST and edits the list that script
# indexes into. If signup-portal is not where deploy-dex.sh thinks it is,
# neither script may proceed.
if ids[want_index] != "signup-portal":
    sys.exit(f"REFUSING: staticClients[{want_index}] is '{ids[want_index]}', "
             f"not 'signup-portal'.\n"
             f"    deploy-dex.sh would write the portal's secret over that "
             f"client. Fix the ordering before adding anything.")
print(f"    OK: staticClients[{want_index}] is signup-portal, as deploy-dex.sh expects")

if client_id in ids:
    print(f"    NOTE: '{client_id}' already present at index {ids.index(client_id)}"
          f" - stage 1 will skip the append and is safe to re-run")
else:
    print(f"    '{client_id}' is absent; it will be APPENDED as index {len(ids)}")
    print(f"    index {want_index} is not read, rewritten or renumbered by this script")
PY
  note "guards passed"
}

# ======================================================== STAGE 1: DEX
stage_dex() {
  guards
  say "STAGE 1 - Dex static client"
  confirm "append the '$CLIENT_ID' client to $DEX_VALUES?"

  cp -a "$DEX_VALUES" "$DEX_VALUES.bak.$(date +%Y%m%d%H%M%S)"

  DEX_VALUES="$DEX_VALUES" CLIENT_ID="$CLIENT_ID" REDIRECT="$REDIRECT" \
  python3 - <<'PY'
import os, re, sys

path = os.environ["DEX_VALUES"]
client_id = os.environ["CLIENT_ID"]
redirect = os.environ["REDIRECT"]
src = open(path, encoding="utf-8", newline="").read()

if re.search(r"^\s*-\s*id:\s*%s\s*$" % re.escape(client_id), src, re.M):
    print(f"    '{client_id}' already present - not appending again")
    sys.exit(0)

m = re.search(r"^([ \t]*)staticClients:[ \t]*$", src, re.M)
indent = len(m.group(1))
head_end = m.end() + 1
rest = src[head_end:]
lines = rest.split("\n")

# Find where the list ENDS, so the new entry is APPENDED after the last
# existing client rather than inserted anywhere among them.
depth, last = None, 0
for i, ln in enumerate(lines):
    if not ln.strip():
        last = i + 1
        continue
    cur = len(ln) - len(ln.lstrip())
    if ln.lstrip().startswith("- ") and depth is None:
        depth = cur
    if depth is not None and cur >= depth:
        last = i + 1
        continue
    if cur <= indent:
        break
pad = " " * (depth if depth is not None else indent + 2)

entry = (f"{pad}- id: {client_id}\n"
         f"{pad}  name: Grafana\n"
         # Placeholder, like connectors[0].config.bindPW. The real secret
         # is injected at deploy time from Vault and never written to a
         # source file.
         f"{pad}  secret: PLACEHOLDER-SET-BY-deploy-dex.sh\n"
         f"{pad}  redirectURIs:\n"
         f"{pad}  - {redirect}\n")

out = src[:head_end] + "\n".join(lines[:last]).rstrip("\n") + "\n" + entry + \
      "\n".join(lines[last:])
open(path, "w", encoding="utf-8", newline="").write(out)
print(f"    appended '{client_id}' at the END of staticClients")
PY

  say "diff of $DEX_VALUES"
  diff "$(ls -t "$DEX_VALUES".bak.* | head -1)" "$DEX_VALUES" || true

  say "re-running the guards against the EDITED file"
  guards

  # The secret: Vault, following bindPW's pattern rather than the inline
  # plaintext that `kubernetes` and `nomad` use (already flagged as debt;
  # a new client should not add to it).
  if $KUBECTL exec -n vault vault-0 -- vault kv get cloudlab/grafana-oidc >/dev/null 2>&1; then
    note "cloudlab/grafana-oidc already exists in Vault - reusing it"
  else
    say "generating the client secret into Vault"
    SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
    $KUBECTL exec -n vault vault-0 -- \
      vault kv put cloudlab/grafana-oidc client_secret="$SECRET"
    unset SECRET
    note "stored at cloudlab/grafana-oidc"
  fi

  # deploy-dex.sh must inject the new secret the same way it injects the
  # portal's. This script will NOT silently rewrite that file: it shows
  # the exact line and refuses if the expected anchor is absent.
  if grep -q "GRAFANA_CLIENT_INDEX" "$DEX_SCRIPT"; then
    note "deploy-dex.sh already injects the grafana secret"
  else
    say "deploy-dex.sh needs one addition"
    cat <<EOF
    Add these, next to the existing PORTAL_CLIENT_INDEX lines. The index
    is discovered, not hardcoded, so it survives another client being
    appended later:

      GRAFANA_CLIENT_INDEX=\$(python3 -c "
    import re,sys
    s=open('$DEX_VALUES').read()
    ids=re.findall(r'^\s*-\s*id:\s*(\S+)', s[s.index('staticClients:'):], re.M)
    print(ids.index('grafana'))")
      ACTUAL_GRAFANA=\$(python3 -c "
    import re
    s=open('$DEX_VALUES').read()
    ids=re.findall(r'^\s*-\s*id:\s*(\S+)', s[s.index('staticClients:'):], re.M)
    print(ids[\$GRAFANA_CLIENT_INDEX])")
      [ "\$ACTUAL_GRAFANA" = "grafana" ] || { echo "grafana index moved"; exit 1; }
      GRAFANA_SECRET=\$(kubectl exec -n vault vault-0 -- \\
        vault kv get -field=client_secret cloudlab/grafana-oidc)

    and append to the helm upgrade line:

      --set-string "config.staticClients[\$GRAFANA_CLIENT_INDEX].secret=\${GRAFANA_SECRET}"
EOF
    confirm "have you added that to $DEX_SCRIPT?"
    grep -q "GRAFANA_CLIENT_INDEX" "$DEX_SCRIPT" \
      || die "still not present in $DEX_SCRIPT. Refusing to deploy Dex with a
    placeholder secret - the client would exist but never authenticate."
  fi

  say "running deploy-dex.sh"
  confirm "run $DEX_SCRIPT now?"
  ( cd "$DEX_DIR" && ./deploy-dex.sh )
  $KUBECTL rollout status deploy/dex -n dex --timeout=180s
  note "Dex rolled out"
  verify_dex
}

verify_dex() {
  say "verifying Dex"
  # The discovery document is the only thing that proves the issuer, and
  # it must match what Grafana will be configured with EXACTLY.
  local issuer
  issuer="$($KUBECTL exec -n dex deploy/dex -- \
    wget -qO- --no-check-certificate \
    https://localhost:5554/dex/.well-known/openid-configuration 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])' 2>/dev/null || true)"
  if [[ -n "$issuer" ]]; then
    note "Dex reports issuer: $issuer"
    [[ "$issuer" == "$DEX_ISSUER" ]] \
      || die "issuer mismatch. Grafana is configured for $DEX_ISSUER but Dex
    says $issuer. A login would fail with 'issuer did not match'."
    note "matches what Grafana will be configured with"
  else
    note "could not read the discovery document; check by hand:"
    note "  $KUBECTL exec -n dex deploy/dex -- wget -qO- --no-check-certificate \\"
    note "    https://localhost:5554/dex/.well-known/openid-configuration"
  fi
  note "NOT verified here: nomad login. Check it manually - the index"
  note "hazard would break it silently and nothing else would report it."
}

# ==================================================== STAGE 2: GRAFANA
stage_grafana() {
  say "STAGE 2 - Grafana"
  [[ -f "$CA_SRC" ]] || die "CA cert not at $CA_SRC"

  # THE LIVE VALUES, never the file on disk. /root/prometheus-values.yaml
  # is STALE and shows additionalScrapeConfigs: [] - applying it would
  # silently delete the real scrape configs.
  say "reading the LIVE helm values"
  $HELM get values monitoring -n monitoring -o yaml > "$LIVE_VALUES"
  note "wrote $LIVE_VALUES ($(wc -c < "$LIVE_VALUES") bytes)"
  grep -q "additionalScrapeConfigs" "$LIVE_VALUES" \
    || note "WARNING: no additionalScrapeConfigs in the LIVE values either - check before applying"

  say "the two mounted Secrets"
  $KUBECTL create secret generic grafana-oidc -n monitoring \
    --from-literal=client_secret="$($KUBECTL exec -n vault vault-0 -- \
       vault kv get -field=client_secret cloudlab/grafana-oidc)" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  $KUBECTL create secret generic grafana-dex-ca -n monitoring \
    --from-file=freeipa-ca.crt="$CA_SRC" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  note "grafana-oidc and grafana-dex-ca applied"

  cp -a "$LIVE_VALUES" "$LIVE_VALUES.bak.$(date +%Y%m%d%H%M%S)"
  LIVE_VALUES="$LIVE_VALUES" GRAFANA_URL="$GRAFANA_URL" DEX_ISSUER="$DEX_ISSUER" \
  python3 - <<'PY'
import os, re

path = os.environ["LIVE_VALUES"]
root = os.environ["GRAFANA_URL"]
iss = os.environ["DEX_ISSUER"]
src = open(path, encoding="utf-8", newline="").read()

if "auth.generic_oauth" in src:
    print("    generic_oauth already configured - not adding it twice")
    raise SystemExit(0)

block = f"""  grafana.ini:
    server:
      root_url: {root}
    auth.generic_oauth:
      enabled: true
      name: CloudLab
      allow_sign_up: true
      client_id: grafana
      client_secret: $__file{{/etc/grafana/secrets/oidc/client_secret}}
      scopes: openid profile email groups
      auth_url: {iss}/auth
      token_url: {iss}/token
      api_url: {iss}/userinfo
      login_attribute_path: preferred_username
      tls_client_ca: /etc/grafana/secrets/ca/freeipa-ca.crt
    auth.basic:
      enabled: true
  extraSecretMounts:
    - name: oidc
      secretName: grafana-oidc
      mountPath: /etc/grafana/secrets/oidc
      readOnly: true
    - name: ca
      secretName: grafana-dex-ca
      mountPath: /etc/grafana/secrets/ca
      readOnly: true
"""

m = re.search(r"^grafana:[ \t]*$", src, re.M)
if m:
    out = src[:m.end() + 1] + block + src[m.end() + 1:]
else:
    out = src.rstrip("\n") + "\n\ngrafana:\n" + block
open(path, "w", encoding="utf-8", newline="").write(out)
print("    added auth.generic_oauth + extraSecretMounts under grafana:")
PY

  say "diff of the helm values"
  diff "$(ls -t "$LIVE_VALUES".bak.* | head -1)" "$LIVE_VALUES" || true
  confirm "apply this with helm (chart pinned to $CHART_VERSION)?"

  $HELM upgrade monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --version "$CHART_VERSION" -f "$LIVE_VALUES"
  $KUBECTL rollout status deploy/monitoring-grafana -n monitoring --timeout=300s
  note "Grafana rolled out"
  verify_grafana
}

verify_grafana() {
  say "verifying Grafana"
  local pod
  pod="$($KUBECTL get pod -n monitoring -l app.kubernetes.io/name=grafana \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { note "no grafana pod found"; return; }

  note "the rendered config Grafana is actually running with:"
  $KUBECTL exec -n monitoring "$pod" -c grafana -- \
    sh -c 'sed -n "/generic_oauth/,/^\[/p" /etc/grafana/grafana.ini' 2>/dev/null \
    | sed 's/^/      /' || note "      (could not read grafana.ini)"

  note "the secret files are mounted and non-empty:"
  $KUBECTL exec -n monitoring "$pod" -c grafana -- \
    sh -c 'wc -c /etc/grafana/secrets/oidc/client_secret /etc/grafana/secrets/ca/freeipa-ca.crt' \
    2>/dev/null | sed 's/^/      /' || note "      (mounts missing - login will fail)"

  note "the login page offers the Dex button AND keeps the local form:"
  $KUBECTL exec -n monitoring "$pod" -c grafana -- \
    sh -c 'wget -qO- http://localhost:3000/login' 2>/dev/null \
    | grep -oE 'generic_oauth|Sign in with [A-Za-z]+|loginForm' | sort -u | sed 's/^/      /' \
    || note "      (could not fetch the login page)"
}

# ============================================================ VERIFY
verify_all() {
  verify_dex
  verify_grafana
  say "WHAT THIS SCRIPT CANNOT VERIFY - do these by hand"
  cat <<'EOF'
    1. Open http://grafana.cloudlab.internal and log in as a REAL user
       (e.g. tesuseradam3). It must redirect to Dex, not show the local
       form, and must succeed.
    2. Do the same as a SECOND real user.
    3. Server Admin -> Users must list them as TWO DISTINCT accounts, not
       one shared auto-provisioned identity.
    4. admin / <set at install time; see Vault> must still log in via the local form.
    5. Both Dex users must see the SAME dashboards as each other and as
       admin. That is the no-scoping limitation, confirmed by looking
       rather than assumed.
    6. `nomad login` must still work for a tenant.

    BROWSER PREREQUISITE: the machine doing the login must resolve
    dex.dex.svc.cluster.local, because that is Dex's issuer and the
    redirect goes there. .51 and jumpbox already have hosts entries; a
    Windows workstation needs, in an elevated editor:
        192.168.1.50 dex.dex.svc.cluster.local
        192.168.1.50 grafana.cloudlab.internal
    Without it the login dies at the redirect with a DNS error that looks
    like Dex being down.
EOF
}

rollback() {
  say "rollback"
  note "removes the grafana client from Dex values and the Grafana auth block."
  note "Does NOT delete the Vault secret or the mounted Secrets."
  confirm "proceed?"
  DEX_VALUES="$DEX_VALUES" python3 - <<'PY'
import os, re
p = os.environ["DEX_VALUES"]; s = open(p, encoding="utf-8", newline="").read()
out = re.sub(r"\n[ \t]*-[ \t]*id:[ \t]*grafana\b(?:\n(?![ \t]*-[ \t]*id:)[^\n]*)*", "", s)
open(p, "w", encoding="utf-8", newline="").write(out)
print("    removed the grafana client" if out != s else "    grafana client was not present")
PY
  note "now re-run $DEX_SCRIPT, then helm upgrade with the auth block removed."
}

fix_dex_script() {
  say "repairing the grafana --set-string in $DEX_SCRIPT"
  note "A shell command continues across lines only while each line ends"
  note "with a backslash. A flag written on its OWN line after the last"
  note "line of the command is not an argument to anything - the shell"
  note "tries to run --set-string as a program. That is why the grafana"
  note "client kept the literal placeholder from values.yaml."
  [[ -f "$DEX_SCRIPT" ]] || die "$DEX_SCRIPT not found"
  cp -a "$DEX_SCRIPT" "$DEX_SCRIPT.bak.$(date +%Y%m%d%H%M%S)"

  DEX_SCRIPT="$DEX_SCRIPT" python3 - <<'PY'
import os, sys

# No regex escapes and no string escapes anywhere in this block, on
# purpose: an earlier version had its backslashes flattened while being
# written, which is the same class of damage it exists to repair.
BS = chr(92)
NL = chr(10)

path = os.environ["DEX_SCRIPT"]
text = open(path, encoding="utf-8", newline="").read()
lines = text.splitlines()

FLAG = ('  --set-string '
        '"config.staticClients[$GRAFANA_CLIENT_INDEX].secret=${GRAFANA_SECRET}"')

def is_helm_upgrade(ln):
    t = ln.strip()
    if t.startswith("#"):
        return False
    parts = t.split()
    return len(parts) >= 3 and parts[0] == "helm" and parts[1] == "upgrade" \
        and "dex" in parts

start = None
for i, ln in enumerate(lines):
    if is_helm_upgrade(ln):
        start = i
        break
if start is None:
    sys.exit("    REFUSING: no `helm upgrade ... dex` command found.")

# FOLLOW the continuations, so the length of the file is irrelevant.
end = start
while end < len(lines) - 1 and lines[end].rstrip().endswith(BS):
    end += 1
print("    helm command spans lines " + str(start + 1) + "-" + str(end + 1))
for i in range(start, end + 1):
    print("      | " + lines[i])

if any("GRAFANA_CLIENT_INDEX" in lines[i] for i in range(start, end + 1)):
    print("    the grafana flag is ALREADY inside the command - nothing to do")
    sys.exit(0)

# The stray standalone flag is what produced `--set-string: command not found`.
stray = [i for i in range(end + 1, len(lines))
         if lines[i].strip().startswith("--set-string") and "GRAFANA" in lines[i]]
for i in reversed(stray):
    print("    removing stray standalone flag at line " + str(i + 1))
    del lines[i]
if not stray:
    print("    no stray standalone flag found")

last = lines[end].rstrip()
if last.endswith(BS):
    sys.exit("    REFUSING: the command's last line still ends with a backslash.")
lines[end] = last + " " + BS
lines.insert(end + 1, FLAG)
print("    line " + str(end + 1) + " now continues; the flag is line " + str(end + 2))
open(path, "w", encoding="utf-8", newline="").write(NL.join(lines) + NL)
PY

  say "diff"
  diff "$(ls -t "$DEX_SCRIPT".bak.* | head -1)" "$DEX_SCRIPT" || true
  bash -n "$DEX_SCRIPT" || die "$DEX_SCRIPT no longer parses - restore the .bak"
  note "bash -n passes - but it passed on the BROKEN version too, so that"
  note "is not the proof. The proof is --verify-secret after re-deploying."
}

verify_secret() {
  say "is the LIVE grafana client secret real, or still the placeholder?"
  note "Not the 'Release upgraded' message. This reads the config Dex is"
  note "actually serving and compares it to Vault by HASH, so neither"
  note "secret is printed."

  local vault_sha live_cfg
  vault_sha="$($KUBECTL exec -n vault vault-0 -- \
    vault kv get -field=client_secret cloudlab/grafana-oidc 2>/dev/null \
    | tr -d "\r\n" | sha256sum | cut -c1-16 || true)"
  [[ -n "$vault_sha" ]] || die "could not read cloudlab/grafana-oidc from Vault"
  note "Vault value sha256[0:16] = $vault_sha"

  # The chart mounts /etc/dex from a Secret. Try the running pod first,
  # then the Secret, and say which one answered.
  live_cfg="$($KUBECTL exec -n dex deploy/dex -- sh -c 'cat /etc/dex/config.yaml' 2>/dev/null || true)"
  if [[ -n "$live_cfg" ]]; then
    note "read from the running pod: /etc/dex/config.yaml"
  else
    local sec
    sec="$($KUBECTL get secret -n dex -o name 2>/dev/null | grep -m1 dex || true)"
    [[ -n "$sec" ]] || die "could not read Dex's config from the pod or a Secret"
    live_cfg="$($KUBECTL get "$sec" -n dex -o go-template='{{index .data "config.yaml"}}' 2>/dev/null | base64 -d || true)"
    note "read from $sec"
  fi
  [[ -n "$live_cfg" ]] || die "Dex config came back empty"

  printf '%s' "$live_cfg" | CLIENT_ID="$CLIENT_ID" VAULT_SHA="$vault_sha" python3 - <<'PY'
import hashlib, os, sys

# Escape-free on purpose (an earlier version had its backslashes
# flattened in transit).
#
# PARSE BY INDENTATION, not by assuming `id:` sits on the dash line.
# YAML map keys have no guaranteed order, and Helm/Dex may render a
# client as `- name: Grafana` / `  id: grafana`. The first version of
# this check only looked at the dash line, so it reported "no grafana
# client" for a client that was plainly present - and sent someone
# chasing a deploy script that was not the problem.
cfg = sys.stdin.read()
client_id = os.environ["CLIENT_ID"]
vault_sha = os.environ["VAULT_SHA"]
NL = chr(10)

lines = cfg.splitlines()

# Locate the staticClients block, wherever it is nested.
anchor = None
for i, ln in enumerate(lines):
    if ln.strip().rstrip(":") == "staticClients" and ln.rstrip().endswith(":"):
        anchor = i
        break
if anchor is None:
    sys.exit("    REFUSING: no staticClients block in the LIVE Dex config.")
anchor_indent = len(lines[anchor]) - len(lines[anchor].lstrip())

# Collect each list item as a block of lines.
items = []
cur = None
dash_indent = None
for ln in lines[anchor + 1:]:
    if not ln.strip():
        continue
    ind = len(ln) - len(ln.lstrip())
    t = ln.strip()
    if t.startswith("- "):
        if dash_indent is None:
            dash_indent = ind
        if ind == dash_indent:
            if cur is not None:
                items.append(cur)
            cur = [t[2:]]
            continue
    if dash_indent is not None and ind > dash_indent:
        if cur is not None:
            cur.append(t)
        continue
    if ind <= anchor_indent:
        break
if cur is not None:
    items.append(cur)

def field(block, key):
    for entry in block:
        if entry.startswith(key + ":"):
            return entry.split(":", 1)[1].strip().strip('"').strip("'")
    return None

ids = [field(b, "id") for b in items]
print("    clients in the LIVE config: " + ", ".join(str(x) for x in ids))

match = [b for b in items if field(b, "id") == client_id]
if not match:
    sys.exit("    REFUSING: no '" + client_id + "' client in the LIVE Dex config."
             + NL + "    The values.yaml edit never reached the cluster.")

live = field(match[0], "secret")
if live is None:
    sys.exit("    REFUSING: the '" + client_id + "' client has no secret field.")

if "PLACEHOLDER" in live.upper():
    sys.exit("    STILL THE PLACEHOLDER (" + live + ")." + NL +
             "    The --set-string never reached helm. Run --fix-dex-script,"
             + NL + "    then deploy-dex.sh, then this check again.")

live_sha = hashlib.sha256(live.encode()).hexdigest()[:16]
print("    live value  sha256[0:16] = " + live_sha)
if live_sha == vault_sha:
    print("    MATCH: the '" + client_id + "' client is using the Vault secret.")
else:
    sys.exit("    MISMATCH: the live secret is neither the placeholder nor the"
             + NL + "    Vault value. Something else set it. Do not proceed.")
PY
  note "Grafana must be configured with the SAME value - stage 2 mounts it"
  note "from Vault, so re-run --grafana if it was applied before this fix."
}

dump_dex_config() {
  say "the staticClients block Dex is ACTUALLY serving"
  note "Secrets are redacted to their sha256 prefix. This is ground truth:"
  note "what helm rendered, not what values.yaml on disk says."
  local live_cfg sec
  live_cfg="$($KUBECTL exec -n dex deploy/dex -- sh -c 'cat /etc/dex/config.yaml' 2>/dev/null || true)"
  if [[ -n "$live_cfg" ]]; then
    note "source: the running pod, /etc/dex/config.yaml"
  else
    sec="$($KUBECTL get secret -n dex -o name 2>/dev/null | grep -m1 dex || true)"
    [[ -n "$sec" ]] || die "could not read Dex's config from the pod or a Secret"
    live_cfg="$($KUBECTL get "$sec" -n dex -o go-template='{{index .data "config.yaml"}}' 2>/dev/null | base64 -d || true)"
    note "source: $sec"
  fi
  [[ -n "$live_cfg" ]] || die "Dex config came back empty"
  printf '%s' "$live_cfg" | python3 - <<'PY'
import hashlib, sys
show = False
for ln in sys.stdin.read().splitlines():
    t = ln.strip()
    if t.rstrip(":") == "staticClients" and t.endswith(":"):
        show = True
        print("      " + ln)
        continue
    if show:
        if t and not ln.startswith(" ") and not t.startswith("-"):
            break
        if t.startswith("secret:") or t.startswith("- secret:"):
            v = t.split("secret:", 1)[1].strip().strip('"').strip("'")
            tag = "PLACEHOLDER" if "PLACEHOLDER" in v.upper() else \
                  "sha256:" + hashlib.sha256(v.encode()).hexdigest()[:16]
            print("      " + ln.split("secret:")[0] + "secret: <" + tag + ">")
        else:
            print("      " + ln)
PY
}

fix_username_claim() {
  say "make Dex emit preferred_username (the bare uid)"
  note "Grafana stores a Dex user's Login from login_attribute_path. That"
  note "path only resolves if the claim EXISTS. Dex's LDAP connector emits"
  note "preferred_username only when userSearch.preferredUsernameAttr is"
  note "set; without it Grafana falls back to the email, which is why the"
  note "per-user dashboard matches nothing."
  note ""
  note "Run ./dex-claims-probe.sh USERNAME first. Do not apply this on"
  note "the strength of the reasoning alone."
  [[ -f "$DEX_VALUES" ]] || die "$DEX_VALUES not found"

  cp -a "$DEX_VALUES" "$DEX_VALUES.bak.$(date +%Y%m%d%H%M%S)"
  DEX_VALUES="$DEX_VALUES" python3 - <<'PY'
import os, sys

# Escape-free.
path = os.environ["DEX_VALUES"]
src = open(path, encoding="utf-8", newline="").read()
lines = src.splitlines()

if "preferredUsernameAttr" in src:
    print("    preferredUsernameAttr already set - nothing to do")
    sys.exit(0)

# Find userSearch, then the `username:` entry inside it, and add the new
# key at the SAME indent. Located by structure, not by line number.
anchor = None
for i, ln in enumerate(lines):
    if ln.strip().rstrip(":") == "userSearch" and ln.rstrip().endswith(":"):
        anchor = i
        break
if anchor is None:
    sys.exit("    REFUSING: no userSearch block in " + path)

base = len(lines[anchor]) - len(lines[anchor].lstrip())
target = None
for i in range(anchor + 1, len(lines)):
    ln = lines[i]
    if not ln.strip():
        continue
    ind = len(ln) - len(ln.lstrip())
    if ind <= base:
        break
    if ln.strip().startswith("username:"):
        target = i
        indent = ind
if target is None:
    sys.exit("    REFUSING: no `username:` key inside userSearch.")

lines.insert(target + 1, " " * indent +
             "# The BARE uid, so Grafana's login_attribute_path has a claim")
lines.insert(target + 2, " " * indent +
             "# to read. Additive: the email claim is unchanged, so the k8s")
lines.insert(target + 3, " " * indent +
             "# and Nomad binding rules that select on email are untouched.")
lines.insert(target + 4, " " * indent + "preferredUsernameAttr: uid")
open(path, "w", encoding="utf-8", newline="").write(chr(10).join(lines) + chr(10))
print("    added preferredUsernameAttr: uid inside userSearch")
PY

  say "diff"
  diff "$(ls -t "$DEX_VALUES".bak.* | head -1)" "$DEX_VALUES" || true
  note ""
  note "Next: cd $DEX_DIR && ./deploy-dex.sh"
  note "Then: ./dex-claims-probe.sh USERNAME  -- confirm the claim appears"
  note "Then: check Grafana Server Admin > Users. The EXISTING Dex user"
  note "      still has the email as its Login; Grafana will not rename it"
  note "      retroactively. Delete that user so the next login"
  note "      re-provisions it with the bare uid, and watch for a DUPLICATE"
  note "      account rather than assuming it updated in place."
}

case "$STAGE" in
  --check)    guards ;;
  --fix-dex-script) fix_dex_script ;;
  --verify-secret)  verify_secret ;;
  --fix-username-claim) fix_username_claim ;;
  --dump-dex-config) dump_dex_config ;;
  --dex)      stage_dex ;;
  --grafana)  stage_grafana ;;
  --verify)   verify_all ;;
  --rollback) rollback ;;
  --all)      stage_dex; stage_grafana; verify_all
              say "stages 1 and 2 done - the six manual checks above remain" ;;
esac
